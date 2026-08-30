/**
 * Index page — ArkWeb host for the electerm web app.
 *
 * Startup sequence:
 *   1. create the writable data dir (filesDir/electerm-data)
 *   2. start the Node.js backend — primarily IN-PROCESS in this app
 *      process (libnode_ctl.so startBackend → dlopen libnode.so →
 *      node::Start; the electron-harmony pattern), falling back to a
 *      *native child process* (libnode_launcher.so:Main). The backend
 *      serves the UI + SSH/SFTP/... API on http://127.0.0.1:5577
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
import { startBackend, getBackendStatus } from 'libnode_ctl.so';
import { BackendManager } from '../BackendManager';

const TAG: string = 'electerm.Index';
const DOMAIN: number = 0xE1EC;
const BACKEND_PORT: number = 5577;
const SERVER_URL: string = `http://127.0.0.1:${BACKEND_PORT}`;
const POLL_INTERVAL_MS: number = 500;
/**
 * How long to wait for the backend before giving up on a boot strategy.
 *
 * This used to be 90s. A dead backend therefore pinned the app on the boot
 * overlay for a minute and a half — indistinguishable from "stuck on the
 * splash screen", which is exactly the bug report. The in-process path
 * reports hard failures (missing script / no libnode.so / dlopen failure)
 * within a few hundred ms via getBackendStatus(), so a short timeout loses
 * nothing and turns a hang into a readable error.
 */
const BOOT_TIMEOUT_MS: number = 20_000;
/** Never read more than this from node-boot.log — this runs on the UI thread. */
const MAX_BOOT_LOG_BYTES: number = 256 * 1024;
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
    // Defer the boot by a frame. aboutToAppear() runs BEFORE the first
    // render, so anything started synchronously here delays the very
    // overlay that is supposed to tell the user the engine is starting.
    setTimeout(() => {
      this.startBackend();
    }, 50);
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

  /**
   * Resolve libnode.so in the app's native libs dir and log the dir listing —
   * this tells us from the parent side whether the installer actually
   * extracted the 92MB node binary. Empty string when not found.
   *
   * We cover every ABI the HAP is built for: arm64-v8a (phones/tablets/2in1)
   * and x86_64 (the emulator). The ABI dir actually installed is the one for
   * the device that installed the app; probing both keeps the same code
   * working on a phone, a tablet and the x86_64 emulator.
   */
  resolveNodePath(bundleCodeDir: string): string {
    const libsDirs: string[] = [
      `${bundleCodeDir}/entry/libs/arm64-v8a`,
      `${bundleCodeDir}/entry/libs/x86_64`,
      `${bundleCodeDir}/libs/arm64-v8a`,
      `${bundleCodeDir}/libs/x86_64`
    ];
    for (let i = 0; i < libsDirs.length; i++) {
      const libsDir: string = libsDirs[i];
      try {
        const names: string[] = fs.listFileSync(libsDir);
        hilog.info(DOMAIN, TAG, 'libs dir %{public}s → %{public}s', libsDir, names.join(', '));
        const nodePath: string = `${libsDir}/libnode.so`;
        if (this.fileExists(nodePath)) {
          hilog.info(DOMAIN, TAG, 'using node: %{public}s', nodePath);
          return nodePath;
        }
      } catch (e) {
        hilog.error(DOMAIN, TAG, 'libs dir not listable: %{public}s (%{public}s)',
          libsDir, JSON.stringify(e));
      }
    }
    return '';
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
      const nodePath: string = this.resolveNodePath(context.bundleCodeDir);

      // 1. writable data dir (db, ssh keys, logs — the resfile install dir
      //    the backend itself runs from is read-only)
      if (!this.dirExists(this.dataDir)) {
        fs.mkdirSync(this.dataDir, true);
      }

      // 2. start the backend
      // entryParams is a plain "key=value\n" string parsed by node_launcher.c
      const paramLines: string[] = [
        `dataDir=${this.dataDir}`,
        `script=${scriptPath}`,
        `port=${BACKEND_PORT}`
      ];
      if (nodePath) {
        paramLines.push(`node=${nodePath}`);
      }
      const entryParams: string = paramLines.join('\n');

      this.statusMessage = 'Starting Node.js engine …';
      hilog.info(DOMAIN, TAG, 'backend params: %{public}s', entryParams);

      // Primary path: run node IN the main app process (dlopen libnode.so +
      // node::Start via libnode_ctl.so — the electron-harmony / nodejs-mobile
      // pattern). The nativespawn child runs under a stricter seccomp filter
      // whose event-loop syscall blocks kill libuv there; the main process
      // runs libuv-class loops of its own (NETSTACK/curl), so node lives here.
      //
      // startBackend() RETURNS IMMEDIATELY — the dlopen of the ~120MB
      // libnode.so and node::Start happen on a background thread. Doing them
      // inline here blocked the UI thread long enough that the Index page
      // never painted: the window sat on its splash screen until the
      // APP_INPUT_BLOCK watchdog fired and the ANR dialog killed the app.
      let launchedInProcess: boolean = false;
      try {
        const rc: string = startBackend(entryParams);
        launchedInProcess = !rc.startsWith('err:');
        hilog.info(DOMAIN, TAG, 'in-process startBackend → %{public}s', rc);
      } catch (e) {
        hilog.error(DOMAIN, TAG, 'in-process startBackend threw: %{public}s', JSON.stringify(e));
      }

      if (launchedInProcess) {
        BackendManager.setInProcess();
        hilog.info(DOMAIN, TAG, 'node running in-process (background thread)');

        // 3. wait for the HTTP server, bailing out early on a hard failure
        const ok: boolean = await this.waitForBackend(BOOT_TIMEOUT_MS, true);
        if (ok) {
          // 4. load the real UI
          this.serverReady = true;
          this.controller.loadUrl(SERVER_URL);
          return;
        }
        // The in-process node thread is detached — if it is merely slow
        // rather than dead, it may still bind the port later; either way the
        // next bind attempt just fails and the child takes over.
        hilog.error(DOMAIN, TAG, 'in-process backend never answered — trying native child process');
      }

      // Fallback: native child process (libnode_launcher.so:Main).
      const pid: number = await childProcessManager.startNativeChildProcess(
        'libnode_launcher.so:Main',
        { entryParams: entryParams }
      );
      BackendManager.setPid(pid);
      hilog.info(DOMAIN, TAG, 'node child process started, pid=%{public}d', pid);

      const ok: boolean = await this.waitForBackend(BOOT_TIMEOUT_MS, false);
      if (!ok) {
        this.bootFailed = true;
        const tail: string = this.readBootLogTailLines(14);
        this.statusMessage = tail
          ? tail
          : 'Engine failed to start (no node-boot.log — child never ran?)';
        this.logBootTail();
        return;
      }

      this.serverReady = true;
      this.controller.loadUrl(SERVER_URL);
    } catch (e) {
      const err = e as BusinessError;
      this.bootFailed = true;
      this.statusMessage = `Startup error: [${err.code}] ${err.message}`;
      hilog.error(DOMAIN, TAG, 'startBackend failed: %{public}s', JSON.stringify(e));
    }
  }

  /** Read the launcher/node boot log (written by the child).
   * Size-guarded: this runs on the UI thread on every poll tick, and a
   * runaway writer would otherwise turn each read into a UI stall. */
  readBootLog(): string {
    if (!this.dataDir) {
      return '';
    }
    const path: string = `${this.dataDir}/node-boot.log`;
    try {
      const stat = fs.statSync(path);
      if (stat.size > MAX_BOOT_LOG_BYTES) {
        return '';
      }
      return fs.readTextSync(path);
    } catch {
      return '';
    }
  }

  /** Last non-empty log line — shown in the overlay while booting so the
   * failure reason is visible on a plain screen mirror (cloud debug). */
  readBootLogLastLine(): string {
    return this.readBootLogTailLines(1);
  }

  /** Last `n` non-empty log lines joined by newline — the failure overlay
   * shows the whole launcher ladder (stat → dlopen → dlsym → start) so one
   * device round-trip is enough to see exactly which step failed. */
  readBootLogTailLines(n: number): string {
    const text: string = this.readBootLog();
    if (!text) {
      return '';
    }
    const lines: string[] = text.split('\n');
    const picked: string[] = [];
    for (let i = lines.length - 1; i >= 0 && picked.length < n; i--) {
      const line: string = lines[i].trim();
      if (line) {
        const clipped: string = line.length > 120
          ? `…${line.substring(line.length - 119)}`
          : line;
        picked.unshift(clipped);
      }
    }
    return picked.join('\n');
  }

  /** Dump the launcher's boot log tail to hilog — the fastest way to see why
   * exec failed when only hilog (no file pull) is available, e.g. cloud debug. */
  logBootTail(): void {
    this.logBootTailWindow(2400);
  }

  /** Dump the last `n` chars of the boot log to hilog (periodic ring-buffer
   * insurance — see waitForBackend). hilog truncates a single message at
   * ~140 bytes, so the tail goes out in 110-char chunks, each its own line. */
  logBootTailWindow(n: number): void {
    const text: string = this.readBootLog();
    if (!text) {
      return;
    }
    const tail: string = text.length > n
      ? text.substring(text.length - n)
      : text;
    const parts: string[] = [];
    for (let i = 0; i < tail.length; i += 110) {
      parts.push(tail.substring(i, i + 110));
    }
    hilog.error(DOMAIN, TAG, 'node-boot.log tail ▼ %{public}d parts', parts.length.toString());
    for (let i = 0; i < parts.length; i++) {
      hilog.error(DOMAIN, TAG, 't%{public}d: %{public}s', i.toString(), parts[i]);
    }
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

  /** Poll http://127.0.0.1:5577 until it answers or `timeoutMs` elapses.
   * While waiting, surface the child's latest boot-log line in the overlay so
   * a stuck boot is diagnosable from the screen alone.
   *
   * When `checkStatus` is set (in-process boot only), getBackendStatus() is
   * consulted every tick: a hard bootstrap failure is known in milliseconds
   * instead of after the whole timeout, so we can fall back to the native
   * child process instead of staring at a spinner. */
  async waitForBackend(timeoutMs: number, checkStatus: boolean): Promise<boolean> {
    const deadline: number = Date.now() + timeoutMs;
    let tick: number = 0;
    let shownLine: string = '';
    while (Date.now() < deadline) {
      if (await this.probe()) {
        return true;
      }
      if (checkStatus) {
        const st: string = getBackendStatus();
        if (st.startsWith('failed:')) {
          const reason: string = st.substring('failed:'.length).replace('err:', '');
          hilog.error(DOMAIN, TAG, 'bootstrap failed: %{public}s', reason);
          this.bootFailed = true;
          this.statusMessage = `Engine failed to start: ${reason}`;
          this.logBootTail();
          return false;
        }
      }
      tick++;
      if (tick % 4 === 0) { // every ~2s
        const line: string = this.readBootLogLastLine();
        if (line && line !== shownLine) {
          shownLine = line;
          this.statusMessage = line;
          hilog.info(DOMAIN, TAG, 'boot: %{public}s', line);
        }
        // Periodic tail dump: the cloud-debug hilog export grabs the OLDEST
        // buffered lines, and ~1600 lines/s of system noise flushes the ring
        // long before the 90s deadline — re-dumping the tail every ~2s keeps
        // a copy of the boot ladder (and any crash marker) inside whatever
        // window survives.
        this.logBootTailWindow(1100);
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
            .fontSize(this.bootFailed ? 11 : 13)
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
