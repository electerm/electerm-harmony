/**
 * Index page — ArkWeb host for the electerm web app.
 *
 * Startup sequence:
 *   1. resolve the writable el2 data dir — the one the previous build used,
 *      so an in-place upgrade keeps its bookmarks
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
 * The data dir must live under el2 — the app-owned area that an in-place
 * upgrade keeps (same bundleName + same signing cert ⇒ same UID ⇒ the previous
 * build's el2 tree is still there).
 *
 * `bundleCodeDir` is the *opposite*: the el1 HAP install dir. It is owned by
 * the installer, mounted read-only, signature-verified and re-extracted on
 * every install, so mkdir there fails with 13900012 (EPERM) and any data put
 * there would be wiped by the next update anyway.
 *
 * Two el2 candidates are inherited from the previous (Electron) build:
 *   - app level  /data/storage/el2/base/files            (AbilityStage marker)
 *   - HAP level  /data/storage/el2/base/haps/entry/files (context.filesDir)
 * PickDataDir() prefers whichever already holds data, so an upgrade keeps its
 * bookmarks instead of starting from an empty db.
 */
const EL2_APP_FILES: string = '/data/storage/el2/base/files';
/** Sub-dir used when neither candidate holds data yet (fresh install). */
const DATA_SUBDIR: string = 'electerm-data';
/** Marker an older build left behind with the dir it actually used. */
const DATA_PATH_MARKER: string = '.electerm-data-path';

@Entry
@Component
struct Index {
  controller: webview.WebviewController = new webview.WebviewController();
  @State serverReady: boolean = false;
  @State bootFailed: boolean = false;
  @State statusMessage: string = 'Starting electerm …';
  dataDir: string = '';
  /** Result of the last HTTP probe — shown on the overlay so a screenshot
   * reveals whether anything is listening on 127.0.0.1:5577 at all. */
  lastProbeError: string = '';
  /** Last line of node-boot.log, refreshed at 0.5 Hz (file I/O on the UI thread). */
  lastBootLine: string = '';

  aboutToAppear(): void {
    // Called directly, NOT via setTimeout: the only thing that used to make
    // this slow was the synchronous dlopen of libnode.so, and that now runs
    // on a background thread. A timer adds a failure mode we cannot observe
    // (if it never fires the overlay sits on its default message forever with
    // zero log output) and buys nothing.
    this.statusMessage = 'Preparing …';
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
      this.dataDir = this.pickDataDir(context);
      const scriptPath: string = this.resolveScriptPath(context.bundleCodeDir);
      const nodePath: string = this.resolveNodePath(context.bundleCodeDir);

      // 1. writable data dir (db, ssh keys, logs — the resfile install dir
      //    the backend itself runs from is read-only)
      if (!this.dirExists(this.dataDir)) {
        fs.mkdirSync(this.dataDir, true);
      }
      this.pinDataDir(this.dataDir);

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

      this.statusMessage = 'Preparing data dir …';
      hilog.info(DOMAIN, TAG, 'backend params: %{public}s', entryParams);
      hilog.info(DOMAIN, TAG, 'script=%{public}s node=%{public}s', scriptPath,
        nodePath !== '' ? nodePath : '(not found)');

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
        this.statusMessage = 'Loading engine (libnode.so) …';
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
      this.statusMessage = 'In-process engine failed — starting child process …';
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

  /** el2 candidates, most preferred first. Never anything under el1/bundle. */
  dataDirCandidates(context: common.Context): string[] {
    return [
      `${EL2_APP_FILES}/${DATA_SUBDIR}`,
      EL2_APP_FILES,
      `${context.filesDir}/${DATA_SUBDIR}`,
      context.filesDir
    ];
  }

  /** True when `dir` already holds an electerm nedb tree
   * (<DATA_PATH>/users/<user>/electerm.*.nedb) — i.e. an older build used it. */
  hasElectermData(dir: string): boolean {
    return this.dirExists(`${dir}/users`);
  }

  /** Contents of a marker left by an older build; '' when absent or not el2. */
  readMarker(path: string): string {
    try {
      const text: string = fs.readTextSync(path).trim();
      return text.startsWith('/data/storage/el2/') ? text : '';
    } catch {
      return '';
    }
  }

  /** Fail fast on a dir that exists but is not writable (locked el2, etc.). */
  writeProbe(dir: string): void {
    const probe: string = `${dir}/.write-test`;
    fs.closeSync(fs.openSync(probe, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE));
    fs.unlinkSync(probe);
  }

  /**
   * Resolve the writable data dir, el2 only.
   *
   * An in-place upgrade keeps the app's el2 tree, so the previous build's nedb
   * files are still on disk — the only thing that has to match is the
   * directory. A dir that already holds `users/` therefore beats everything
   * else; the marker is only a hint for layouts we no longer recognise.
   */
  pickDataDir(context: common.Context): string {
    const candidates: string[] = this.dataDirCandidates(context);

    for (let i = 0; i < candidates.length; i++) {
      if (this.hasElectermData(candidates[i])) {
        hilog.info(DOMAIN, TAG, 'reusing previous data dir: %{public}s', candidates[i]);
        return candidates[i];
      }
    }
    for (let i = 0; i < candidates.length; i++) {
      const marker: string = this.readMarker(`${candidates[i]}/${DATA_PATH_MARKER}`);
      if (marker !== '') {
        hilog.info(DOMAIN, TAG, 'using marker data dir: %{public}s', marker);
        return marker;
      }
    }
    for (let i = 0; i < candidates.length; i++) {
      try {
        if (!this.dirExists(candidates[i])) {
          fs.mkdirSync(candidates[i], true);
        }
        this.writeProbe(candidates[i]);
        hilog.info(DOMAIN, TAG, 'using fresh data dir: %{public}s', candidates[i]);
        return candidates[i];
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'data dir unusable: %{public}s (%{public}s)',
          candidates[i], JSON.stringify(e));
      }
    }
    return context.tempDir;
  }

  /** Record the dir we settled on so the next version resolves it directly. */
  pinDataDir(dir: string): void {
    try {
      if (!this.dirExists(EL2_APP_FILES)) {
        fs.mkdirSync(EL2_APP_FILES, true);
      }
      const markerPath: string = `${EL2_APP_FILES}/${DATA_PATH_MARKER}`;
      const file = fs.openSync(markerPath,
        fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, dir);
      fs.closeSync(file);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'could not pin data dir: %{public}s', JSON.stringify(e));
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
    const startedAt: number = Date.now();
    const deadline: number = startedAt + timeoutMs;
    let tick: number = 0;
    while (Date.now() < deadline) {
      if (await this.probe()) {
        return true;
      }
      let status: string = '';
      if (checkStatus) {
        status = getBackendStatus();
        if (status.startsWith('failed:')) {
          const reason: string = status.substring('failed:'.length).replace('err:', '');
          hilog.error(DOMAIN, TAG, 'bootstrap failed: %{public}s', reason);
          this.bootFailed = true;
          this.statusMessage = `Engine failed to start: ${reason}`;
          this.logBootTail();
          return false;
        }
      }

      // Always refresh the overlay, and always log — including when
      // node-boot.log is EMPTY. An empty boot log means the native side never
      // wrote a line, which is itself the single most useful fact to know,
      // and the old code logged nothing at all in that case (logBootTailWindow
      // returns early on empty input). hilog is ring-buffered away under
      // cloud-debug system noise far faster than it can be exported, so the
      // SCREEN is the primary diagnostic channel and must never go static.
      const secs: number = Math.round((Date.now() - startedAt) / 1000);
      const parts: string[] = [`Starting engine … ${secs}s`, `probe: ${this.lastProbeError}`];
      if (checkStatus) {
        parts.push(`backend: ${status !== '' ? status : 'unknown'}`);
      }
      if (this.lastBootLine) {
        parts.push(this.lastBootLine);
      }
      this.statusMessage = parts.join('\n');

      if (tick % 4 === 0) { // every ~2s
        // Reading the boot log is file I/O on the UI thread — keep it at
        // 0.5 Hz and reuse the cached line for the per-tick overlay refresh.
        this.lastBootLine = this.readBootLogLastLine();
        hilog.info(DOMAIN, TAG, 'waiting %{public}ds probe=%{public}s status=%{public}s boot=%{public}s',
          secs.toString(), this.lastProbeError, status, this.lastBootLine);
        this.logBootTailWindow(1100);
      }
      tick++;
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
      this.lastProbeError = `HTTP ${response.responseCode}`;
      return response.responseCode >= 200 && response.responseCode < 500;
    } catch (e) {
      const err = e as BusinessError;
      this.lastProbeError = `[${err.code}] ${err.message}`;
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
