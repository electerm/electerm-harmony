/**
 * Index page — ArkWeb host for the electerm web app.
 *
 * Startup sequence:
 *   1. create the writable data dir (filesDir/electerm-data)
 *   2. start the Node.js backend as a *native child process*
 *      (libnode_launcher.so:Main → execv libnode.so index.js — the backend
 *      serves the UI + SSH/SFTP/... API on http://127.0.0.1:5577)
 *   3. poll the backend with plain HTTP until it answers
 *   4. navigate the Web component from the local loading page to the backend
 *
 * While the engine is starting (or failed to start) a native overlay is
 * shown; the Web component stays loaded with rawfile/loading.html behind it.
 *
 * All logging goes through hilog (visible in release-build hilog, unlike
 * console.info which is filtered out) — `hdc hilog | grep electerm.Index`.
 */

import { webview } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';
import { childProcessManager } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import fs from '@ohos.file.fs';
import http from '@ohos.net.http';
import { BackendManager } from '../BackendManager';

const TAG: string = 'electerm.Index';
const DOMAIN: number = 0xE1EC;
const BACKEND_PORT: number = 5577;
const SERVER_URL: string = `http://127.0.0.1:${BACKEND_PORT}`;
const POLL_INTERVAL_MS: number = 500;
const BOOT_TIMEOUT_MS: number = 90_000;
/**
 * Prefer the per-process el2 junction over the parent's filesDir string:
 * /data/storage/el2/base/files points at the same storage but is mounted in
 * EVERY process of the app (including the native child), while the
 * sandbox-style absolute path the parent gets may not be.
 */
const EL2_FILES_DIR: string = '/data/storage/el2/base/files';

@Entry
@Component
struct Index {
  controller: webview.WebviewController = new webview.WebviewController();
  @State serverReady: boolean = false;
  @State bootFailed: boolean = false;
  @State statusMessage: string = 'Starting electerm …';
  dataDir: string = '';

  aboutToAppear(): void {
    this.startBackend();
  }

  /**
   * Resolve the backend entry script inside the installed HAP.
   * The HAP layout is entry/src/main/resources/resfile/electerm → installed
   * at <bundleCodeDir>/entry/resources/resfile/electerm (note: "resources",
   * plural — matches the packaged HAP contents). bundleCodeDir may or may not
   * already include the module segment, so try both shapes and verify.
   */
  resolveScriptPath(bundleCodeDir: string): string {
    const candidates: string[] = [
      `${bundleCodeDir}/entry/resources/resfile/electerm/index.js`,
      `${bundleCodeDir}/resources/resfile/electerm/index.js`
    ];
    for (let i = 0; i < candidates.length; i++) {
      hilog.info(DOMAIN, TAG, 'script candidate: %{public}s', candidates[i]);
      if (this.fileExists(candidates[i])) {
        hilog.info(DOMAIN, TAG, 'using script: %{public}s', candidates[i]);
        return candidates[i];
      }
      hilog.warn(DOMAIN, TAG, 'script candidate missing: %{public}s', candidates[i]);
    }
    return candidates[0]; // let the launcher report the failure
  }

  /** Create the writable data dir and spawn the node backend. */
  async startBackend(): Promise<void> {
    try {
      const context = getContext(this) as common.Context;
      const filesDir: string = context.filesDir;
      // el2 junction path (visible in the child too) when available
      this.dataDir = this.dirExists(EL2_FILES_DIR)
        ? `${EL2_FILES_DIR}/electerm-data`
        : `${filesDir}/electerm-data`;
      const scriptPath: string = this.resolveScriptPath(context.bundleCodeDir);

      // 1. writable data dir (db, ssh keys, logs — the resfile install dir
      //    the backend itself runs from is read-only)
      if (!this.dirExists(this.dataDir)) {
        fs.mkdirSync(this.dataDir, true);
      }

      // 2. start the native child process
      // entryParams is a plain "key=value\n" string parsed by node_launcher.c
      const entryParams: string = [
        `dataDir=${this.dataDir}`,
        `script=${scriptPath}`,
        `port=${BACKEND_PORT}`
      ].join('\n');

      this.statusMessage = 'Starting Node.js engine …';
      hilog.info(DOMAIN, TAG, 'starting native child process, params: %{public}s', entryParams);
      const pid: number = await childProcessManager.startNativeChildProcess(
        'libnode_launcher.so:Main',
        { entryParams: entryParams }
      );
      BackendManager.setPid(pid);
      hilog.info(DOMAIN, TAG, 'node child process started, pid=%{public}d', pid);

      // 3. wait for the HTTP server
      const ok: boolean = await this.waitForBackend();
      if (!ok) {
        this.bootFailed = true;
        const lastLine: string = this.readBootLogLastLine();
        this.statusMessage = lastLine
          ? `Engine failed: ${lastLine}`
          : 'Engine failed to start (no node-boot.log — child never ran?)';
        this.logBootTail();
        return;
      }

      // 4. load the real UI
      this.serverReady = true;
      this.controller.loadUrl(SERVER_URL);
    } catch (e) {
      const err = e as BusinessError;
      this.bootFailed = true;
      this.statusMessage = `Startup error: [${err.code}] ${err.message}`;
      hilog.error(DOMAIN, TAG, 'startBackend failed: %{public}s', JSON.stringify(e));
    }
  }

  /** Read the launcher/node boot log (written by the child). */
  readBootLog(): string {
    if (!this.dataDir) {
      return '';
    }
    try {
      return fs.readTextSync(`${this.dataDir}/node-boot.log`);
    } catch {
      return '';
    }
  }

  /** Last non-empty log line — shown in the overlay while booting so the
   * failure reason is visible on a plain screen mirror (cloud debug). */
  readBootLogLastLine(): string {
    const text: string = this.readBootLog();
    if (!text) {
      return '';
    }
    const lines: string[] = text.split('\n');
    for (let i = lines.length - 1; i >= 0; i--) {
      const line: string = lines[i].trim();
      if (line) {
        return line.length > 160 ? `…${line.substring(line.length - 159)}` : line;
      }
    }
    return '';
  }

  /** Dump the launcher's boot log tail to hilog — the fastest way to see why
   * exec failed when only hilog (no file pull) is available, e.g. cloud debug. */
  logBootTail(): void {
    const text: string = this.readBootLog();
    if (!text) {
      hilog.error(DOMAIN, TAG,
        'node-boot.log empty/missing at %{public}s — child never wrote anything', this.dataDir);
      return;
    }
    const tail: string = text.length > 800
      ? text.substring(text.length - 800)
      : text;
    hilog.error(DOMAIN, TAG, 'node-boot.log tail: %{public}s', tail);
  }

  fileExists(path: string): boolean {
    try {
      const stat = fs.statSync(path);
      return stat.isFile();
    } catch {
      return false;
    }
  }

  dirExists(path: string): boolean {
    try {
      const stat = fs.statSync(path);
      return stat.isDirectory();
    } catch {
      return false;
    }
  }

  /** Poll http://127.0.0.1:5577 until it answers or BOOT_TIMEOUT_MS elapses.
   * While waiting, surface the child's latest boot-log line in the overlay so
   * a stuck boot is diagnosable from the screen alone. */
  async waitForBackend(): Promise<boolean> {
    const deadline: number = Date.now() + BOOT_TIMEOUT_MS;
    let tick: number = 0;
    let shownLine: string = '';
    while (Date.now() < deadline) {
      if (await this.probe()) {
        return true;
      }
      tick++;
      if (tick % 4 === 0) { // every ~2s
        const line: string = this.readBootLogLastLine();
        if (line && line !== shownLine) {
          shownLine = line;
          this.statusMessage = line;
          hilog.info(DOMAIN, TAG, 'boot: %{public}s', line);
        }
      }
      await this.sleep(POLL_INTERVAL_MS);
    }
    return false;
  }

  async probe(): Promise<boolean> {
    const httpClient = http.createHttp();
    try {
      const response = await httpClient.request(SERVER_URL, {
        method: http.RequestMethod.GET,
        connectTimeout: 3000,
        readTimeout: 3000,
        usingCache: false
      });
      return response.responseCode >= 200 && response.responseCode < 500;
    } catch {
      return false;
    } finally {
      httpClient.destroy();
    }
  }

  sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve) => {
      setTimeout(() => resolve(), ms);
    });
  }

  onBackPress(): boolean {
    try {
      if (this.controller.accessBackward()) {
        this.controller.backward();
        return true;
      }
    } catch {
      // controller not attached yet — fall through
    }
    return false;
  }

  build() {
    Stack() {
      Web({ src: $rawfile('loading.html'), controller: this.controller })
        .width('100%')
        .height('100%')
        .javaScriptAccess(true)
        .domStorageAccess(true)

      if (!this.serverReady) {
        Column({ space: 16 }) {
          Text('electerm')
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor('#cfd6e4')
          if (!this.bootFailed) {
            LoadingProgress()
              .width(36)
              .height(36)
              .color('#4aa3ff')
          }
          Text(this.statusMessage)
            .fontSize(13)
            .fontColor(this.bootFailed ? '#e5484d' : '#8b93a7')
            .textAlign(TextAlign.Center)
            .padding({ left: 24, right: 24 })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor('#15171a')
      }
    }
    .width('100%')
    .height('100%')
  }
}
