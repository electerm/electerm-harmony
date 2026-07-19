import { webview } from '@kit.ArkWeb';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';
import http from '@ohos.net.http';
import { spawnProcess, waitProcess, chmod, diagnose, Diagnostics } from 'libspawn.so';
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

  async startBackend(): Promise<void> {
    try {
      const context = getContext(this) as common.Context;
      const sandboxDir = context.filesDir;
      this.electermDir = `${sandboxDir}/electerm`;

      const nodeBin = `${this.electermDir}/bin/node`;
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

      // --- Step 2: Make node binary executable ---
      this.statusMessage = 'Preparing engine...';
      try {
        chmod(nodeBin, 0o755);
        hilog.info(DOMAIN, TAG, `chmod 0755 ${nodeBin}`);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, `chmod failed (non-fatal): ${this.getErrorMessage(e as object)}`);
      }

      // --- Step 3: Spawn the Node.js backend via NAPI ---
      this.statusMessage = 'Starting Node.js engine...';
      hilog.info(DOMAIN, TAG, `Spawning: ${nodeBin} ${entryScript}`);

      // Build environment variables for the Node.js process.
      // LD_LIBRARY_PATH is critical — without it, the dynamic linker
      // cannot find Node's shared libraries and posix_spawn returns ENOENT.
      const nodeDir = `${this.electermDir}`;
      const libDir = `${nodeDir}/lib`;
      const envVars: Record<string, string> = {
        'LD_LIBRARY_PATH': libDir,
        'HOME': sandboxDir,
        'NODE_PATH': `${nodeDir}/lib/node_modules`,
      };

      let pid: number;
      try {
        pid = spawnProcess(nodeBin, [entryScript], envVars);
        hilog.info(DOMAIN, TAG, `Node.js backend spawned, PID: ${pid}`);
      } catch (e) {
        const msg = this.getErrorMessage(e as object);
        hilog.error(DOMAIN, TAG, `spawnProcess failed: ${msg}`);

        const errorParts: string[] = [];
        errorParts.push(`Failed to spawn Node.js: ${msg}`);
        errorParts.push('');
        errorParts.push(`nodeBin path: ${nodeBin}`);
        errorParts.push(`nodeBin exists: ${this.fileExists(nodeBin)}`);
        errorParts.push(`libDir path: ${libDir}`);
        errorParts.push(`libDir exists: ${this.fileExists(libDir)}`);
        errorParts.push(`entryScript: ${entryScript}`);
        errorParts.push(`entryScript exists: ${this.fileExists(entryScript)}`);

        // NAPI-side diagnostics: check ELF header, interpreter, etc.
        try {
          const diag: Diagnostics = diagnose(nodeBin);
          errorParts.push('');
          errorParts.push('=== NAPI Diagnostics ===');
          errorParts.push(`exists: ${diag.exists}`);
          errorParts.push(`executable: ${diag.executable}`);
          errorParts.push(`stat: ${diag.stat}`);
          errorParts.push(`magic: ${diag.magic}`);
          errorParts.push(`interpreter: ${diag.interpreter}`);
          errorParts.push(`interpreterExists: ${diag.interpreterExists}`);
          errorParts.push(`cwd: ${diag.cwd}`);
          errorParts.push(`realpath: ${diag.realpath}`);
          errorParts.push(`dirListing: ${diag.dirListing}`);
        } catch (diagErr) {
          errorParts.push(`diagnose failed: ${this.getErrorMessage(diagErr as object)}`);
        }

        this.errorMessage = errorParts.join('\n');
        this.statusMessage = 'Engine error';
        return;
      }

      if (pid <= 0) {
        this.errorMessage = `spawnProcess returned invalid PID: ${pid}`;
        this.statusMessage = 'Engine error';
        return;
      }

      NodeProcessState.set(pid);

      // --- Step 4: Monitor process exit asynchronously ---
      waitProcess(pid).then((exitCode: number) => {
        hilog.error(DOMAIN, TAG, `Node.js backend exited with code ${exitCode}`);
        NodeProcessState.clear();
        this.backendExited = true;
        this.showExitError(exitCode, '');
      }).catch((err: BusinessError) => {
        hilog.error(DOMAIN, TAG, `waitProcess error: ${err.message}`);
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

          if (this.errorMessage.length > 0) {
            Scroll() {
              Column() {
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
