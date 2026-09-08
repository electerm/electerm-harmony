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
import { getBackendStatus } from 'libnode_ctl.so';
import { BackendManager } from '../BackendManager';
import { launchInProcessEarly, buildEntryParams } from '../BackendLauncher';

const TAG: string = 'electerm.Index';
const DOMAIN: number = 0xE1EC;
const BACKEND_PORT: number = 5577;
const SERVER_URL: string = `http://127.0.0.1:${BACKEND_PORT}`;
/**
 * Probe backoff schedule (ms). The backend typically answers ~0.9s after
 * launch; a fixed 500ms poll discovered it up to half a second late. Fast
 * early probes are cheap (loopback HTTP), so front-load them and stretch
 * out only for the slow tail.
 */
const POLL_DELAYS_MS: number[] = [
  20, 20, 20, 20, 20, 20, 20, 20, 20, 20, //   0–200ms: catch a fast backend
  50, 50, 50, 50, 50, 50, 50, 50,         // 200–600ms
  200, 200, 200, 200                      // 600ms–1.4s
];
const POLL_DELAY_DEFAULT_MS: number = 500;
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
 * ArkTS object injected into the ArkWeb page as `window.harmonyNative`.
 *
 * The electerm UI runs in a single Web component pointed at the local backend
 * (http://127.0.0.1:5577), so clicking an http(s) link must open the OS
 * default browser — it must NEVER navigate this webview away from the app.
 * The client (src/client/web-components/web-pre.js) calls
 * window.harmonyNative.openExternal(url) for that.
 */
class NativeBridge {
  private ctx: common.UIAbilityContext;

  constructor(ctx: common.UIAbilityContext) {
    this.ctx = ctx;
  }

  /** Open a link with the OS default app (browser for http/https). */
  openExternal(url: string): void {
    const trimmed: string = (url || '').trim();
    if (!/^(https?|mailto|tel):/i.test(trimmed)) {
      hilog.warn(DOMAIN, TAG, 'blocked openExternal for non-openable url: %{public}s', trimmed);
      return;
    }
    this.ctx.openLink(trimmed).catch((err: BusinessError) => {
      hilog.error(DOMAIN, TAG, 'openLink(%{public}s) failed: %{public}s', trimmed, JSON.stringify(err));
    });
  }
}

@Entry
@Component
struct Index {
  controller: webview.WebviewController = new webview.WebviewController();
  /** JS bridge exposed to the webview as window.harmonyNative (openExternal). */
  nativeBridge: NativeBridge = new NativeBridge(getContext(this) as common.UIAbilityContext);
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
   * Bring the backend up and load the UI.
   *
   * The launch itself was already fired from EntryAbility.onCreate (see
   * launchInProcessEarly) — by the time aboutToAppear runs, node has been
   * bootstrapping for ~150ms in parallel with the ArkWeb engine. This method
   * only: retries the launch if onCreate never ran it, waits for HTTP,
   * and falls back to a native child process on failure.
   */
  async startBackend(): Promise<void> {
    try {
      const context = getContext(this) as common.Context;
      this.dataDir = BackendManager.dataDir;
      this.statusMessage = 'Loading engine …';

      // 1. in-process path (usually already launched from onCreate)
      if (!BackendManager.launchAttempted) {
        // onCreate didn't run (defensive) — launch from here instead.
        launchInProcessEarly(context);
        this.dataDir = BackendManager.dataDir;
      }
      if (BackendManager.inProcess) {
        const ok: boolean = await this.waitForBackend(BOOT_TIMEOUT_MS, true);
        if (ok) {
          // 2. load the real UI
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
      let entryParams: string = BackendManager.entryParams;
      if (entryParams === '') {
        entryParams = buildEntryParams(context);
        this.dataDir = BackendManager.dataDir;
      }
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
    const dataDir: string = this.dataDir || BackendManager.dataDir;
    if (!dataDir) {
      return '';
    }
    const path: string = `${dataDir}/node-boot.log`;
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
    let lastOverlayAt: number = 0;
    let lastLogAt: number = 0;
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
      const now: number = Date.now();

      // Always refresh the overlay, and always log — including when
      // node-boot.log is EMPTY. An empty boot log means the native side never
      // wrote a line, which is itself the single most useful fact to know,
      // and the old code logged nothing at all in that case (logBootTailWindow
      // returns early on empty input). hilog is ring-buffered away under
      // cloud-debug system noise far faster than it can be exported, so the
      // SCREEN is the primary diagnostic channel and must never go static.
      // With the backoff schedule the tick is no longer a fixed 500ms, so
      // overlay/log cadence is throttled by wall-clock time instead of tick
      // count: overlay every 250ms, hilog + boot-log read every 1s.
      if (now - lastOverlayAt >= 250) {
        lastOverlayAt = now;
        const secs: number = Math.round((now - startedAt) / 1000);
        const parts: string[] = [`Starting engine … ${secs}s`, `probe: ${this.lastProbeError}`];
        if (checkStatus) {
          parts.push(`backend: ${status !== '' ? status : 'unknown'}`);
        }
        if (this.lastBootLine) {
          parts.push(this.lastBootLine);
        }
        this.statusMessage = parts.join('\n');
      }
      if (now - lastLogAt >= 1000) {
        lastLogAt = now;
        // Reading the boot log is file I/O on the UI thread — keep it at 1 Hz.
        this.lastBootLine = this.readBootLogLastLine();
        const secs: number = Math.round((now - startedAt) / 1000);
        hilog.info(DOMAIN, TAG, 'waiting %{public}ds probe=%{public}s status=%{public}s boot=%{public}s',
          secs.toString(), this.lastProbeError, status, this.lastBootLine);
        this.logBootTailWindow(1100);
      }
      tick++;
      const delay: number = tick <= POLL_DELAYS_MS.length
        ? POLL_DELAYS_MS[tick - 1]
        : POLL_DELAY_DEFAULT_MS;
      await this.sleep(delay);
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

  /** True for an http(s) url that lives outside the local backend — such a
   * main-frame navigation would take the whole webview away from the app UI,
   * so it must be diverted to the OS default browser instead. */
  isExternalWebUrl(url: string): boolean {
    return /^https?:\/\//i.test(url) &&
      !url.startsWith('http://127.0.0.1') &&
      !url.startsWith('http://localhost');
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
        // Expose window.harmonyNative.openExternal(url) so the electerm UI can
        // ask the OS to open http(s)/mailto/tel links in the default app.
        .javaScriptProxy({
          object: this.nativeBridge,
          name: 'harmonyNative',
          methodList: ['openExternal'],
          controller: this.controller
        })
        // Backstop: no MAIN-frame navigation may leave the local backend
        // (the built-in web-session tab browses external sites in a subframe
        // and must stay untouched). Anything external — a raw <a href> click
        // that bypassed the client's openExternal funnel, a redirect, … — is
        // cancelled here and handed to the OS default browser.
        .onLoadIntercept((event) => {
          if (!event.data.isMainFrame()) {
            return false;
          }
          const url: string = event.data.getRequestUrl();
          if (this.isExternalWebUrl(url)) {
            hilog.info(DOMAIN, TAG, 'diverting main-frame nav to system browser: %{public}s', url);
            this.nativeBridge.openExternal(url);
            return true;
          }
          return false;
        })

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
