import { webview } from '@kit.ArkWeb';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';
import process from '@ohos.process';
import http from '@ohos.net.http';
import { NodeProcessState } from '../NodeProcessState';

const DOMAIN = 0x0001;
const TAG = 'electerm';

const BACKEND_PORT = 5577;
const BACKEND_URL = `http://127.0.0.1:${BACKEND_PORT}`;
const POLL_INTERVAL = 1000;
const POLL_TIMEOUT = 90000;

@Entry
@Component
struct Index {
  controller: webview.WebviewController = new webview.WebviewController();
  @State serverReady: boolean = false;
  @State statusMessage: string = 'Starting electerm...';
  @State errorMessage: string = '';
  @State diagInfo: string = '';
  private electermDir: string = '';
  private pollStartTime: number = 0;
  private pollTimerId: number = -1;
  private backendExited: boolean = false;

  aboutToAppear(): void {
    this.startBackend();
  }

  aboutToDisappear(): void {
    if (this.pollTimerId !== -1) {
      clearTimeout(this.pollTimerId);
      this.pollTimerId = -1;
    }
  }

  fileExists(path: string): boolean {
    try {
      fs.accessSync(path);
      return true;
    } catch {
      return false;
    }
  }

  getErrorMessage(err: object): string {
    const businessErr = err as BusinessError;
    if (businessErr && businessErr.message) {
      return `[${businessErr.code}] ${businessErr.message}`;
    }
    const error = err as Error;
    if (error && error.message) {
      return error.message;
    }
    try {
      return JSON.stringify(err);
    } catch {
      return String(err);
    }
  }

  /**
   * Diagnostic: probe the process object to find what APIs are available.
   * Logs results to hilog and returns a summary string.
   */
  probeProcessApi(): string {
    const lines: string[] = [];

    // Test basic properties that should always exist
    try {
      const pid = process.pid;
      lines.push(`process.pid = ${pid}`);
      hilog.info(DOMAIN, TAG, `DIAG process.pid = ${pid}`);
    } catch (e) {
      lines.push(`process.pid: ERROR ${this.getErrorMessage(e as object)}`);
    }

    try {
      const ppid = process.ppid;
      lines.push(`process.ppid = ${ppid}`);
      hilog.info(DOMAIN, TAG, `DIAG process.ppid = ${ppid}`);
    } catch (e) {
      lines.push(`process.ppid: ERROR ${this.getErrorMessage(e as object)}`);
    }

    // Try process.version (API 9+)
    try {
      const ver = process.version;
      lines.push(`process.version = ${ver}`);
      hilog.info(DOMAIN, TAG, `DIAG process.version = ${ver}`);
    } catch (e) {
      lines.push(`process.version: ERROR ${this.getErrorMessage(e as object)}`);
    }

    // Try process.cwd() (API 9+)
    try {
      const cwd = process.cwd();
      lines.push(`process.cwd() = ${cwd}`);
      hilog.info(DOMAIN, TAG, `DIAG process.cwd() = ${cwd}`);
    } catch (e) {
      lines.push(`process.cwd(): ERROR ${this.getErrorMessage(e as object)}`);
    }

    // Try process.uptime() 
    try {
      const up = process.uptime();
      lines.push(`process.uptime() = ${up}`);
      hilog.info(DOMAIN, TAG, `DIAG process.uptime() = ${up}`);
    } catch (e) {
      lines.push(`process.uptime(): ERROR ${this.getErrorMessage(e as object)}`);
    }

    // Try process.runCmd (the one we need)
    // We try to call it with a simple command. If the function doesn't
    // exist, we'll get "undefined is not callable" or similar.
    try {
      hilog.info(DOMAIN, TAG, 'DIAG: attempting process.runCmd("echo test")...');
      const child = process.runCmd('echo test');
      lines.push('process.runCmd: EXISTS (returned a promise)');
      hilog.info(DOMAIN, TAG, 'DIAG process.runCmd EXISTS! It returned a value.');
    } catch (e) {
      const msg = this.getErrorMessage(e as object);
      lines.push(`process.runCmd: NOT AVAILABLE (${msg})`);
      hilog.error(DOMAIN, TAG, `DIAG process.runCmd NOT AVAILABLE: ${msg}`);
    }

    // Try process.kill (exists in API 9+)
    try {
      // process.kill(signal, pid) — just check it's callable, don't actually kill
      // We check by calling with pid 0 (self) and signal 0 (just check existence)
      hilog.info(DOMAIN, TAG, 'DIAG: checking process.kill...');
      // Don't actually call kill, just note it should exist
      lines.push('process.kill: declared (not tested)');
    } catch (e) {
      lines.push(`process.kill: ERROR ${this.getErrorMessage(e as object)}`);
    }

    return lines.join('\n');
  }

  async startBackend(): Promise<void> {
    try {
      const context = getContext(this) as common.Context;
      const sandboxDir = context.filesDir;
      this.electermDir = `${sandboxDir}/electerm`;

      const nodeBin = `${this.electermDir}/bin/bin/node`;
      const entryScript = `${this.electermDir}/index.js`;

      // --- Step 1: Extract rawfile resources if needed ---
      if (!this.fileExists(entryScript)) {
        hilog.info(DOMAIN, TAG, 'Extracting bundled resources from rawfile...');
        this.statusMessage = 'Extracting resources...';
        await this.extractAllRawfiles(context, sandboxDir);
        hilog.info(DOMAIN, TAG, 'All resources extracted.');
      } else {
        hilog.info(DOMAIN, TAG, 'Resources already extracted, skipping.');
      }

      if (!this.fileExists(nodeBin)) {
        throw new Error(`Node.js binary not found at ${nodeBin}.`);
      }
      if (!this.fileExists(entryScript)) {
        throw new Error(`Entry script not found at ${entryScript}.`);
      }

      hilog.info(DOMAIN, TAG, `nodeBin: ${nodeBin}`);
      hilog.info(DOMAIN, TAG, `entryScript: ${entryScript}`);

      // --- Step 2: Probe process API availability ---
      this.statusMessage = 'Diagnosing runtime API...';
      hilog.info(DOMAIN, TAG, '=== PROCESS API DIAGNOSTICS ===');
      const diag = this.probeProcessApi();
      this.diagInfo = diag;
      hilog.info(DOMAIN, TAG, '=== END DIAGNOSTICS ===');

      // --- Step 3: Try to run node --version via process.runCmd ---
      this.statusMessage = 'Verifying Node.js engine...';
      hilog.info(DOMAIN, TAG, 'Attempting to run node --version...');

      try {
        const child = await process.runCmd(`"${nodeBin}" --version`, { timeout: 10000 });
        const exitCode = await child.wait();
        let stdout = '';
        let stderr = '';
        try { stdout = await child.getOutput(); } catch (e) {
          hilog.warn(DOMAIN, TAG, `getOutput failed: ${this.getErrorMessage(e as object)}`);
        }
        try { stderr = await child.getErrorOutput(); } catch (e) {
          hilog.warn(DOMAIN, TAG, `getErrorOutput failed: ${this.getErrorMessage(e as object)}`);
        }

        hilog.info(DOMAIN, TAG, `node --version: exit=${exitCode} stdout=${stdout} stderr=${stderr}`);

        if (exitCode !== 0) {
          const detail = stderr || stdout || '(no output)';
          throw new Error(
            `Node.js binary failed (exit ${exitCode}). Output: ${detail.substring(0, 500)}`);
        }
        hilog.info(DOMAIN, TAG, `Node.js version: ${stdout.trim()}`);
      } catch (e) {
        const msg = this.getErrorMessage(e as object);
        hilog.error(DOMAIN, TAG, `Node version check failed: ${msg}`);

        // Build a comprehensive error message with diagnostics
        const errorParts: string[] = [];
        errorParts.push(`Failed to run Node.js: ${msg}`);
        errorParts.push('');
        errorParts.push('=== Process API Diagnostics ===');
        errorParts.push(this.diagInfo);
        errorParts.push('');
        errorParts.push(`nodeBin path: ${nodeBin}`);
        errorParts.push(`nodeBin exists: ${this.fileExists(nodeBin)}`);
        errorParts.push(`entryScript: ${entryScript}`);
        errorParts.push(`entryScript exists: ${this.fileExists(entryScript)}`);

        this.errorMessage = errorParts.join('\n');
        this.statusMessage = 'Engine error';
        return;
      }

      // --- Step 4: Spawn the Node.js backend ---
      this.statusMessage = 'Starting Node.js engine...';
      hilog.info(DOMAIN, TAG, `Spawning: ${nodeBin} ${entryScript}`);

      const command = `"${nodeBin}" "${entryScript}"`;
      const child = await process.runCmd(command, { timeout: 0 });

      NodeProcessState.set(child, child.pid);
      hilog.info(DOMAIN, TAG, `Node.js backend started, PID: ${child.pid}`);

      child.wait().then((code: number) => {
        hilog.error(DOMAIN, TAG, `Node.js backend exited with code ${code}`);
        NodeProcessState.clear();
        this.backendExited = true;

        child.getErrorOutput().then((stderr: string) => {
          hilog.error(DOMAIN, TAG, `Node.js stderr: ${stderr.substring(0, 2000)}`);
          this.showExitError(code, stderr);
        }).catch(() => {
          this.showExitError(code, '');
        });
      }).catch((err: BusinessError) => {
        hilog.error(DOMAIN, TAG, `Node.js backend wait error: ${err.message}`);
        NodeProcessState.clear();
        this.backendExited = true;
        this.showExitError(-999, err.message);
      });

      // --- Step 5: Poll the backend ---
      hilog.info(DOMAIN, TAG, 'Starting to poll backend...');
      this.pollStartTime = Date.now();
      this.pollBackend();

    } catch (err) {
      const msg = this.getErrorMessage(err as object);
      hilog.error(DOMAIN, TAG, `Failed to start: ${msg}`);
      this.statusMessage = 'Error';
      this.errorMessage = msg;
    }
  }

  showExitError(code: number, stderr: string): void {
    const parts: string[] = [];
    parts.push(`Node.js engine exited (code ${code}).`);
    if (stderr.length > 0) {
      parts.push(`stderr: ${stderr.substring(0, 800)}`);
    } else {
      parts.push('(no stderr output)');
    }
    this.errorMessage = parts.join('\n');
    this.statusMessage = 'Engine error';
    hilog.error(DOMAIN, TAG, `Exit error: ${this.errorMessage}`);
  }

  pollBackend(): void {
    if (this.backendExited) {
      if (this.errorMessage.length === 0) {
        this.showExitError(-1, '');
      }
      return;
    }

    const elapsed = Date.now() - this.pollStartTime;
    const secs = Math.floor(elapsed / 1000);

    if (elapsed > POLL_TIMEOUT) {
      this.errorMessage =
        `Backend failed to start within ${Math.round(POLL_TIMEOUT / 1000)}s.`;
      this.statusMessage = 'Timeout';
      return;
    }

    this.statusMessage = `Waiting for engine... (${secs}s)`;

    const httpRequest = http.createHttp();
    httpRequest.request(BACKEND_URL, {
      method: http.RequestMethod.GET,
      connectTimeout: 2000,
      readTimeout: 2000,
    }).then(() => {
      httpRequest.destroy();
      hilog.info(DOMAIN, TAG, 'Backend is ready!');
      this.serverReady = true;
    }).catch(() => {
      httpRequest.destroy();
      this.pollTimerId = setTimeout(() => this.pollBackend(), POLL_INTERVAL);
    });
  }

  async extractAllRawfiles(context: common.Context, sandboxDir: string): Promise<void> {
    const resourceMgr = context.resourceManager;
    const manifestBytes = await resourceMgr.getRawFileContent('manifest.json');
    const decoder = util.TextDecoder.create('utf-8');
    const manifest: Record<string, string[]> =
      JSON.parse(decoder.decodeToString(manifestBytes)) as Record<string, string[]>;
    const files: string[] = manifest['files'] || [];

    hilog.info(DOMAIN, TAG, `Manifest contains ${files.length} files to extract`);

    let count = 0;
    for (const filePath of files) {
      const destPath = `${sandboxDir}/${filePath}`;
      const lastSlash = destPath.lastIndexOf('/');
      if (lastSlash > 0) {
        const parentDir = destPath.substring(0, lastSlash);
        if (!this.fileExists(parentDir)) {
          fs.mkdirSync(parentDir, true);
        }
      }
      const content = await resourceMgr.getRawFileContent(filePath);
      const file = fs.openSync(destPath,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, content.buffer, {
        offset: content.byteOffset,
        length: content.byteLength,
      });
      fs.closeSync(file);
      count++;
      if (count % 200 === 0) {
        this.statusMessage = `Extracting... (${count}/${files.length})`;
        hilog.info(DOMAIN, TAG, `Extracted ${count}/${files.length} files`);
      }
    }
    hilog.info(DOMAIN, TAG, `Extraction complete: ${count} files`);
  }

  build() {
    Column() {
      if (this.serverReady) {
        Web({ src: BACKEND_URL, controller: this.controller })
          .width('100%')
          .height('100%')
          .javaScriptAccess(true)
          .domStorageAccess(true)
          .fileAccess(true)
          .imageAccess(true)
          .onlineImageAccess(true)
          .geolocationAccess(false)
          .mixedMode(MixedMode.All)
          .onControllerAttached(() => {
            hilog.info(DOMAIN, TAG, 'WebView attached');
          })
          .onPageEnd(() => {
            hilog.info(DOMAIN, TAG, 'WebView page ended loading');
          })
          .onErrorReceive(() => {
            hilog.error(DOMAIN, TAG, 'WebView error loading backend URL');
          })
      } else {
        Column() {
          Text('Electerm')
            .fontSize(32)
            .fontWeight(FontWeight.Bold)
            .fontColor('#333333')
            .margin({ bottom: 24 })

          if (this.errorMessage.length === 0) {
            LoadingProgress()
              .width(48)
              .height(48)
              .color('#4aa3ff')
              .margin({ bottom: 24 })
          }

          Text(this.statusMessage)
            .fontSize(16)
            .fontColor('#666666')
            .textAlign(TextAlign.Center)
            .padding({ left: 20, right: 20 })

          if (this.errorMessage.length > 0 || this.diagInfo.length > 0) {
            Scroll() {
              Column() {
                if (this.diagInfo.length > 0) {
                  Text('Diagnostics:')
                    .fontSize(14)
                    .fontColor('#333333')
                    .fontWeight(FontWeight.Bold)
                    .padding({ left: 20, right: 20, top: 16, bottom: 8 })
                  Text(this.diagInfo)
                    .fontSize(12)
                    .fontColor('#555555')
                    .textAlign(TextAlign.Start)
                    .padding({ left: 20, right: 20, bottom: 8 })
                    .fontFamily('monospace')
                }
                if (this.errorMessage.length > 0) {
                  Text('Error:')
                    .fontSize(14)
                    .fontColor('#cc0000')
                    .fontWeight(FontWeight.Bold)
                    .padding({ left: 20, right: 20, top: 8, bottom: 8 })
                  Text(this.errorMessage)
                    .fontSize(12)
                    .fontColor('#cc0000')
                    .textAlign(TextAlign.Start)
                    .padding({ left: 20, right: 20, bottom: 16 })
                    .fontFamily('monospace')
                }
              }
            }
            .layoutWeight(1)
            .width('100%')
            .backgroundColor('#f5f5f5')
          }
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#ffffff')
        .justifyContent(this.errorMessage.length > 0 ? FlexAlign.Start : FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      }
    }
    .width('100%')
    .height('100%')
  }
}
