import { webview } from '@kit.ArkWeb';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';
import http from '@ohos.net.http';
import { spawnProcess, waitProcess, chmod, diagnose, resolveFd, spawnFromFd, diagnoseFd, checkPaths, Diagnostics, FdDiagnostics, PathInfo } from 'libspawn.so';
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
      fs.statSync(path);
      return true;
    } catch {
      return false;
    }
  }

  /**
   * Resolves a sandbox (virtual) path to the real physical path on disk.
   *
   * HarmonyOS sandbox paths like /data/storage/el2/base/... are only
   * accessible via ArkTS fs APIs. Native POSIX calls (access, open,
   * posix_spawn) cannot find them. This function opens the file via
   * ArkTS (which CAN access the virtual path), then reads
   * /proc/self/fd/<fd> via NAPI to discover the real path.
   *
   * Returns the original path if resolution fails (as a fallback).
   */
  resolveRealPath(virtualPath: string): string {
    try {
      const file = fs.openSync(virtualPath, fs.OpenMode.READ_ONLY);
      const realPath: string = resolveFd(file.fd);
      fs.closeSync(file);
      hilog.info(DOMAIN, TAG, `Resolved: ${virtualPath} -> ${realPath}`);
      return realPath;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, `resolveRealPath failed for ${virtualPath}: ${this.getErrorMessage(e as object)}`);
      return virtualPath;  // fallback to original
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

      // --- Step 2: Open node binary via ArkTS and spawn via /proc/self/fd ---
      // HarmonyOS sandbox paths are virtual — only ArkTS fs APIs can see them.
      // NAPI POSIX calls (access, open, posix_spawn) cannot find these paths.
      // But an fd opened by ArkTS is a real kernel fd. We pass it to NAPI
      // and use /proc/self/fd/<fd> as the binary path for posix_spawn.
      this.statusMessage = 'Opening engine binary...';
      hilog.info(DOMAIN, TAG, 'Opening node binary via ArkTS for fd-based spawn...');

      let nodeFile: fs.File;
      try {
        nodeFile = fs.openSync(nodeBin, fs.OpenMode.READ_ONLY);
      } catch (openErr) {
        const msg = this.getErrorMessage(openErr as object);
        hilog.error(DOMAIN, TAG, `fs.openSync(${nodeBin}, READ_ONLY) failed: ${msg}`);

        const errorParts: string[] = [];
        errorParts.push(`Cannot open node binary (READ_ONLY): ${msg}`);
        errorParts.push('');
        errorParts.push(`nodeBin: ${nodeBin}`);
        errorParts.push(`nodeBin exists (statSync): ${this.fileExists(nodeBin)}`);

        // Try statSync to get file info
        try {
          const stat = fs.statSync(nodeBin);
          errorParts.push(`nodeBin stat: size=${stat.size} mode=${stat.mode} isDirectory=${stat.isDirectory()} isFile=${stat.isFile()}`);
        } catch (statErr) {
          errorParts.push(`nodeBin statSync failed: ${this.getErrorMessage(statErr as object)}`);
        }

        // Try opening with READ_WRITE mode (READ_ONLY=0 might be treated as falsy)
        try {
          const file2 = fs.openSync(nodeBin, fs.OpenMode.READ_WRITE);
          errorParts.push(`openSync(READ_WRITE) succeeded! fd=${file2.fd}`);
          fs.closeSync(file2);
        } catch (rwErr) {
          errorParts.push(`openSync(READ_WRITE) failed: ${this.getErrorMessage(rwErr as object)}`);
        }

        // Try opening without any mode
        try {
          const file3 = fs.openSync(nodeBin);
          errorParts.push(`openSync() (no mode) succeeded! fd=${file3.fd}`);
          fs.closeSync(file3);
        } catch (nomodeErr) {
          errorParts.push(`openSync() (no mode) failed: ${this.getErrorMessage(nomodeErr as object)}`);
        }

        // Try opening entryScript to see if ANY file can be opened
        try {
          const file4 = fs.openSync(entryScript, fs.OpenMode.READ_ONLY);
          errorParts.push(`openSync(entryScript, READ_ONLY) succeeded! fd=${file4.fd}`);
          fs.closeSync(file4);
        } catch (esErr) {
          errorParts.push(`openSync(entryScript) failed: ${this.getErrorMessage(esErr as object)}`);
        }

        // List bin/ directory contents
        const binDir = `${this.electermDir}/bin`;
        try {
          const files = fs.listFileSync(binDir);
          errorParts.push(`bin/ dir listing (${files.length} entries): ${files.join(', ')}`);
        } catch (listErr) {
          errorParts.push(`bin/ listFileSync failed: ${this.getErrorMessage(listErr as object)}`);
        }

        // List electerm/ directory contents
        try {
          const files2 = fs.listFileSync(this.electermDir);
          errorParts.push(`electerm/ dir listing (${files2.length} entries): ${files2.slice(0, 30).join(', ')}`);
        } catch (listErr2) {
          errorParts.push(`electerm/ listFileSync failed: ${this.getErrorMessage(listErr2 as object)}`);
        }

        this.errorMessage = errorParts.join('\n');
        this.statusMessage = 'Engine error';
        return;
      }
      hilog.info(DOMAIN, TAG, `nodeBin fd: ${nodeFile.fd}`);

      // Diagnose the fd to see if we can read the ELF header
      try {
        const fdDiag: FdDiagnostics = diagnoseFd(nodeFile.fd);
        hilog.info(DOMAIN, TAG, `FdDiagnostics: fdValid=${fdDiag.fdValid} magic=${fdDiag.magic} interpreter=${fdDiag.interpreter} fdPath=${fdDiag.fdPath} fdPathAccessible=${fdDiag.fdPathAccessible}`);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, `diagnoseFd failed: ${this.getErrorMessage(e as object)}`);
      }

      // Derive libDir for LD_LIBRARY_PATH (still virtual, but dynamic linker
      // in child process may have same restriction... we'll try anyway)
      const libDir = `${this.electermDir}/lib`;

      // Build environment variables
      const envVars: Record<string, string> = {
        'LD_LIBRARY_PATH': libDir,
        'HOME': sandboxDir,
        'NODE_PATH': `${libDir}/node_modules`,
      };

      let pid: number;
      try {
        // Try fd-based spawn first (most likely to work)
        hilog.info(DOMAIN, TAG, `Spawning via /proc/self/fd/${nodeFile.fd}...`);
        pid = spawnFromFd(nodeFile.fd, [entryScript], envVars);
        hilog.info(DOMAIN, TAG, `Node.js backend spawned (via fd), PID: ${pid}`);
      } catch (e) {
        const msg = this.getErrorMessage(e as object);
        hilog.error(DOMAIN, TAG, `spawnFromFd failed: ${msg}`);

        const errorParts: string[] = [];
        errorParts.push(`Failed to spawn Node.js: ${msg}`);
        errorParts.push('');
        errorParts.push(`nodeBin (virtual): ${nodeBin}`);
        errorParts.push(`nodeBin exists (ArkTS): ${this.fileExists(nodeBin)}`);
        errorParts.push(`libDir: ${libDir}`);
        errorParts.push(`entryScript: ${entryScript}`);

        // FdDiagnostics
        try {
          const fdDiag: FdDiagnostics = diagnoseFd(nodeFile.fd);
          errorParts.push('');
          errorParts.push('=== FdDiagnostics ===');
          errorParts.push(`fdValid: ${fdDiag.fdValid}`);
          errorParts.push(`stat: ${fdDiag.stat}`);
          errorParts.push(`magic: ${fdDiag.magic}`);
          errorParts.push(`interpreter: ${fdDiag.interpreter}`);
          errorParts.push(`interpreterExists: ${fdDiag.interpreterExists}`);
          errorParts.push(`fdPath: ${fdDiag.fdPath}`);
          errorParts.push(`fdPathAccessible: ${fdDiag.fdPathAccessible}`);
        } catch (diagErr) {
          errorParts.push(`diagnoseFd failed: ${this.getErrorMessage(diagErr as object)}`);
        }

        // Accessible paths
        try {
          const paths: PathInfo[] = checkPaths();
          errorParts.push('');
          errorParts.push('=== Accessible Paths (NAPI) ===');
          for (const p of paths) {
            errorParts.push(`${p.path}: exists=${p.exists} exec=${p.executable} (${p.stat})`);
          }
        } catch (pathsErr) {
          errorParts.push(`checkPaths failed: ${this.getErrorMessage(pathsErr as object)}`);
        }

        this.errorMessage = errorParts.join('\n');
        this.statusMessage = 'Engine error';
        fs.closeSync(nodeFile);
        return;
      }

      // Close the fd in parent process — child has its own copy
      fs.closeSync(nodeFile);

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
