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

// Result of running a command via runCommandCapture.
interface CmdResult {
  exitCode: number;
  stdout: string;
  stderr: string;
}

// The port the Node.js backend listens on (must match .env PORT).
const BACKEND_PORT = 5577;
const BACKEND_URL = `http://127.0.0.1:${BACKEND_PORT}`;

// How long to wait for the backend before giving up (ms).
const POLL_INTERVAL = 1000;
const POLL_TIMEOUT = 90000;

@Entry
@Component
struct Index {
  controller: webview.WebviewController = new webview.WebviewController();
  @State serverReady: boolean = false;
  @State statusMessage: string = 'Starting electerm...';
  @State errorMessage: string = '';
  @State elapsedSeconds: number = 0;
  private electermDir: string = '';
  private pollStartTime: number = 0;
  private pollTimerId: number = -1;
  private backendExited: boolean = false;
  private exitCode: number = -1;
  private stderrText: string = '';
  private stdoutText: string = '';

  aboutToAppear(): void {
    this.startBackend();
  }

  aboutToDisappear(): void {
    if (this.pollTimerId !== -1) {
      clearTimeout(this.pollTimerId);
      this.pollTimerId = -1;
    }
  }

  /**
   * Check if a file exists without throwing.
   */
  fileExists(path: string): boolean {
    try {
      fs.accessSync(path);
      return true;
    } catch {
      return false;
    }
  }

  /**
   * Safely extract a human-readable message from an error object.
   */
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
   * Run a command and capture its stdout, stderr, and exit code.
   */
  async runCommandCapture(command: string): Promise<CmdResult> {
    const child = await process.runCmd(command, { timeout: 0 });
    const exitCode = await child.wait();
    let stdout = '';
    let stderr = '';
    try {
      stdout = await child.getOutput();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, `getOutput failed: ${this.getErrorMessage(e as object)}`);
    }
    try {
      stderr = await child.getErrorOutput();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, `getErrorOutput failed: ${this.getErrorMessage(e as object)}`);
    }
    const result: CmdResult = { exitCode, stdout, stderr };
    return result;
  }

  /**
   * Main startup sequence:
   *   1. Extract rawfile/electerm/ → filesDir/electerm/
   *   2. Make the node binary executable
   *   3. Pre-flight: test node --version
   *   4. Spawn the Node.js backend (node index.js)
   *   5. Poll http://127.0.0.1:5577 until the backend responds
   *   6. Switch to the WebView loading the backend URL directly
   */
  async startBackend(): Promise<void> {
    try {
      const context = getContext(this) as common.Context;
      const sandboxDir = context.filesDir;
      this.electermDir = `${sandboxDir}/electerm`;

      // The node binary path inside the extracted sandbox.
      const nodeBin = `${this.electermDir}/bin/bin/node`;
      // The entry script that sets env vars and imports app.bundle.mjs.
      const entryScript = `${this.electermDir}/index.js`;

      // --- Step 1: Extract rawfile resources if needed -------------------
      if (!this.fileExists(entryScript)) {
        hilog.info(DOMAIN, TAG, 'Extracting bundled resources from rawfile...');
        this.statusMessage = 'Extracting resources...';
        await this.extractAllRawfiles(context, sandboxDir);
        hilog.info(DOMAIN, TAG, 'All resources extracted.');
      } else {
        hilog.info(DOMAIN, TAG, 'Resources already extracted, skipping.');
      }

      // Verify the node binary exists
      if (!this.fileExists(nodeBin)) {
        throw new Error(
          `Node.js binary not found at ${nodeBin}.`);
      }
      if (!this.fileExists(entryScript)) {
        throw new Error(
          `Entry script not found at ${entryScript}.`);
      }

      hilog.info(DOMAIN, TAG, `nodeBin: ${nodeBin}`);
      hilog.info(DOMAIN, TAG, `entryScript: ${entryScript}`);
      hilog.info(DOMAIN, TAG, `electermDir: ${this.electermDir}`);
      hilog.info(DOMAIN, TAG, `sandboxDir: ${sandboxDir}`);

      // --- Step 2: Make the node binary executable -----------------------
      this.statusMessage = 'Preparing Node.js engine...';
      try {
        const chmodChild = await process.runCmd(`chmod 755 "${nodeBin}"`);
        await chmodChild.wait();
        hilog.info(DOMAIN, TAG, `chmod +x ${nodeBin} done`);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, `chmod failed (non-fatal): ${this.getErrorMessage(e as object)}`);
      }

      // --- Step 3: Pre-flight check — does node run at all? -------------
      // Run "node --version" to verify the binary is executable on this
      // device. If this fails, there's no point trying to run the backend.
      this.statusMessage = 'Verifying Node.js engine...';
      hilog.info(DOMAIN, TAG, 'Pre-flight: running node --version...');
      try {
        const result = await this.runCommandCapture(`"${nodeBin}" --version`);
        hilog.info(DOMAIN, TAG, `node --version exit code: ${result.exitCode}`);
        hilog.info(DOMAIN, TAG, `node --version stdout: ${result.stdout}`);
        hilog.info(DOMAIN, TAG, `node --version stderr: ${result.stderr}`);

        if (result.exitCode !== 0) {
          // Node binary exists but crashes — likely arch mismatch
          const detail = result.stderr || result.stdout || '(no output)';
          throw new Error(
            `Node.js binary failed to run (exit ${result.exitCode}). ` +
            `Output: ${detail.substring(0, 500)}. ` +
            'This likely means the binary architecture does not match the device.');
        }
        hilog.info(DOMAIN, TAG, `Node.js version: ${result.stdout.trim()}`);
      } catch (e) {
        // If runCmd itself threw (not the node process), e.g. "no such file"
        const msg = this.getErrorMessage(e as object);
        hilog.error(DOMAIN, TAG, `Pre-flight check failed: ${msg}`);
        throw new Error(
          `Node.js pre-flight check failed: ${msg}. ` +
          'The binary may not be compatible with this device architecture.');
      }

      // --- Step 4: Pre-flight check — can node execute a simple script? --
      this.statusMessage = 'Testing Node.js runtime...';
      const testScript = `console.log("node-ok")`;
      hilog.info(DOMAIN, TAG, 'Pre-flight: running node -e test...');
      try {
        const result = await this.runCommandCapture(
          `"${nodeBin}" -e "${testScript}"`
        );
        hilog.info(DOMAIN, TAG, `node -e test exit code: ${result.exitCode}`);
        hilog.info(DOMAIN, TAG, `node -e test stdout: ${result.stdout}`);
        hilog.info(DOMAIN, TAG, `node -e test stderr: ${result.stderr}`);

        if (result.exitCode !== 0) {
          const detail = result.stderr || result.stdout || '(no output)';
          throw new Error(
            `Node.js script execution failed (exit ${result.exitCode}). ` +
            `Output: ${detail.substring(0, 500)}`);
        }
      } catch (e) {
        const msg = this.getErrorMessage(e as object);
        hilog.error(DOMAIN, TAG, `Script test failed: ${msg}`);
        throw new Error(`Node.js script test failed: ${msg}`);
      }

      // --- Step 5: Spawn the Node.js backend -----------------------------
      this.statusMessage = 'Starting Node.js engine...';
      hilog.info(DOMAIN, TAG, `Spawning: ${nodeBin} ${entryScript}`);

      const command = `"${nodeBin}" "${entryScript}"`;
      const child = await process.runCmd(command, { timeout: 0 });

      NodeProcessState.set(child, child.pid);
      hilog.info(DOMAIN, TAG, `Node.js backend started, PID: ${child.pid}`);

      // Monitor the process in the background. When it exits, capture
      // stdout, stderr, and exit code, then build a detailed error message.
      child.wait().then((code: number) => {
        hilog.error(DOMAIN, TAG, `Node.js backend exited with code ${code}`);
        NodeProcessState.clear();
        this.exitCode = code;
        this.backendExited = true;

        // Capture stderr and stdout after process exits
        child.getErrorOutput().then((stderr: string) => {
          this.stderrText = stderr || '';
          hilog.error(DOMAIN, TAG, `Node.js stderr (len=${stderr.length}): ${stderr.substring(0, 2000)}`);
          this.buildExitError();
        }).catch(() => {
          this.buildExitError();
        });

        child.getOutput().then((stdout: string) => {
          this.stdoutText = stdout || '';
          hilog.info(DOMAIN, TAG, `Node.js stdout (len=${stdout.length}): ${stdout.substring(0, 1000)}`);
          this.buildExitError();
        }).catch(() => {
          this.buildExitError();
        });
      }).catch((err: BusinessError) => {
        hilog.error(DOMAIN, TAG, `Node.js backend wait error: ${err.message}`);
        NodeProcessState.clear();
        this.exitCode = -999;
        this.stderrText = err.message;
        this.backendExited = true;
        this.buildExitError();
      });

      // --- Step 6: Poll the backend until it responds --------------------
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

  /**
   * Build a detailed error message when the Node.js process exits.
   * Includes exit code, stderr, and stdout.
   */
  buildExitError(): void {
    if (!this.backendExited) {
      return;
    }
    // Only build once we have both stdout and stderr (or they've been
    // attempted). We use a small delay to let both promises settle.
    const parts: string[] = [];
    parts.push(`Node.js engine exited (code ${this.exitCode}).`);

    if (this.stderrText.length > 0) {
      // Truncate stderr to keep the UI readable
      const trimmed = this.stderrText.substring(0, 800);
      parts.push(`stderr: ${trimmed}`);
    }
    if (this.stdoutText.length > 0) {
      const trimmed = this.stdoutText.substring(0, 400);
      parts.push(`stdout: ${trimmed}`);
    }
    if (this.stderrText.length === 0 && this.stdoutText.length === 0) {
      parts.push('(no output captured)');
    }

    this.errorMessage = parts.join('\n');
    this.statusMessage = 'Engine error';
    hilog.error(DOMAIN, TAG, `Exit error: ${this.errorMessage}`);
  }

  /**
   * Poll the backend HTTP endpoint. When it responds, switch to the
   * WebView. Uses the HarmonyOS http module to make a GET request to
   * http://127.0.0.1:5577/ — if the connection succeeds, the backend
   * is running.
   */
  pollBackend(): void {
    // Check if backend process already exited
    if (this.backendExited) {
      // buildExitError() will have set the error message
      if (this.errorMessage.length === 0) {
        this.buildExitError();
      }
      return;
    }

    const elapsed = Date.now() - this.pollStartTime;
    this.elapsedSeconds = Math.floor(elapsed / 1000);

    // Check timeout
    if (elapsed > POLL_TIMEOUT) {
      this.errorMessage =
        `Backend failed to start within ${Math.round(POLL_TIMEOUT / 1000)}s. ` +
        'The Node.js engine may not be compatible with this device.';
      this.statusMessage = 'Timeout';
      return;
    }

    this.statusMessage = `Waiting for engine... (${this.elapsedSeconds}s)`;

    const httpRequest = http.createHttp();
    httpRequest.request(BACKEND_URL, {
      method: http.RequestMethod.GET,
      connectTimeout: 2000,
      readTimeout: 2000,
    }).then(() => {
      httpRequest.destroy();
      hilog.info(DOMAIN, TAG, 'Backend is ready! Switching to WebView.');
      this.serverReady = true;
    }).catch((err: BusinessError) => {
      httpRequest.destroy();
      // Backend not ready yet — schedule next poll
      this.pollTimerId = setTimeout(() => this.pollBackend(), POLL_INTERVAL);
    });
  }

  /**
   * Extract all rawfile resources to the sandbox using the manifest.json
   * that is generated at build time by scripts/gen-manifest.sh.
   */
  async extractAllRawfiles(context: common.Context, sandboxDir: string): Promise<void> {
    const resourceMgr = context.resourceManager;

    // Read manifest.json from rawfile
    const manifestBytes = await resourceMgr.getRawFileContent('manifest.json');
    const decoder = util.TextDecoder.create('utf-8');
    const manifest: Record<string, string[]> =
      JSON.parse(decoder.decodeToString(manifestBytes)) as Record<string, string[]>;
    const files: string[] = manifest['files'] || [];

    hilog.info(DOMAIN, TAG, `Manifest contains ${files.length} files to extract`);

    let count = 0;
    for (const filePath of files) {
      const destPath = `${sandboxDir}/${filePath}`;

      // Create parent directories
      const lastSlash = destPath.lastIndexOf('/');
      if (lastSlash > 0) {
        const parentDir = destPath.substring(0, lastSlash);
        if (!this.fileExists(parentDir)) {
          fs.mkdirSync(parentDir, true);
        }
      }

      // Read from rawfile and write to sandbox
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
        // Load the backend directly — no loading.html, no file:// protocol.
        // The backend serves the full electerm web UI at http://127.0.0.1:5577/.
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
            hilog.info(DOMAIN, TAG, 'WebView attached, loading backend URL');
          })
          .onPageEnd(() => {
            hilog.info(DOMAIN, TAG, 'WebView page ended loading');
          })
          .onErrorReceive(() => {
            hilog.error(DOMAIN, TAG, 'WebView error loading backend URL');
          })
      } else {
        // Native ArkTS loading UI — always visible with explicit colors
        // so it works regardless of system theme (dark/light).
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

          if (this.errorMessage.length > 0) {
            // Use Scroll so long error messages are readable
            Scroll() {
              Text(this.errorMessage)
                .fontSize(13)
                .fontColor('#cc0000')
                .textAlign(TextAlign.Start)
                .padding({ left: 20, right: 20, top: 16 })
                .fontFamily('monospace')
            }
            .layoutWeight(1)
            .width('100%')
            .padding({ top: 8 })
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
