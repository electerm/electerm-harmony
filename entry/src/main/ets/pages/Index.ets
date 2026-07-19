import { webview } from '@kit.ArkWeb';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';
import process from '@ohos.process';
import { NodeProcessState } from '../NodeProcessState';

const DOMAIN = 0x0001;
const TAG = 'electerm';

// The port the Node.js backend listens on (must match .env PORT).
const BACKEND_PORT = 5577;
const BACKEND_URL = `http://127.0.0.1:${BACKEND_PORT}`;

@Entry
@Component
struct Index {
  controller: webview.WebviewController = new webview.WebviewController();
  @State serverReady: boolean = false;
  @State statusMessage: string = 'Starting electerm...';
  @State webError: string = '';
  private electermDir: string = '';

  aboutToAppear(): void {
    this.startBackend();
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
   * Main startup sequence:
   *   1. Extract rawfile/electerm/ → filesDir/electerm/
   *   2. Make the node binary executable
   *   3. Spawn the Node.js backend (node index.js)
   *   4. Load loading.html (polls the backend, then redirects)
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
      // We check for the entry script — if it exists, the extraction was
      // already done (or partially done) in a previous launch.
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
          `Node.js binary not found at ${nodeBin}. ` +
          'Run ./scripts/prepare-node.sh to download it.');
      }
      if (!this.fileExists(entryScript)) {
        throw new Error(
          `Entry script not found at ${entryScript}. ` +
          'Run ./scripts/prepare-web.sh to build it.');
      }

      // --- Step 2: Make the node binary executable -----------------------
      // Rawfile resources may lose the executable bit. Use chmod via runCmd.
      // If process.runCmd doesn't exist at runtime, the call will throw
      // and be caught by the outer catch block with a clear error message.
      this.statusMessage = 'Preparing Node.js engine...';
      try {
        const chmodChild = await process.runCmd(`chmod 755 "${nodeBin}"`);
        await chmodChild.wait();
        hilog.info(DOMAIN, TAG, `chmod +x ${nodeBin} done`);
      } catch (e) {
        // chmod might fail if the binary is already executable or if
        // the filesystem doesn't support permissions. Not fatal.
        hilog.warn(DOMAIN, TAG, `chmod failed (non-fatal): ${this.getErrorMessage(e as object)}`);
      }

      // --- Step 3: Spawn the Node.js backend -----------------------------
      this.statusMessage = 'Starting Node.js engine...';
      hilog.info(DOMAIN, TAG, `Spawning: ${nodeBin} ${entryScript}`);

      // runCmd executes the command in a child process. We do NOT await
      // child.wait() — the process should keep running for the lifetime
      // of the app. The Promise from runCmd resolves once the process
      // has started, giving us the ChildProcess handle.
      const command = `"${nodeBin}" "${entryScript}"`;
      const child = await process.runCmd(command, { timeout: 0 });

      // Store the child process reference so EntryAbility can kill it
      // when the app is destroyed.
      NodeProcessState.set(child, child.pid);
      hilog.info(DOMAIN, TAG, `Node.js backend started, PID: ${child.pid}`);

      // Monitor the process in the background — if it exits unexpectedly,
      // update the status message so the user knows something went wrong.
      // We don't await this; it runs as a fire-and-forget promise.
      child.wait().then((exitCode: number) => {
        hilog.error(DOMAIN, TAG, `Node.js backend exited with code ${exitCode}`);
        NodeProcessState.clear();
        // Only update state if we haven't already loaded the WebView
        if (!this.serverReady) {
          this.statusMessage = `Backend exited (code ${exitCode}). Check logs.`;
        }
      }).catch((err: BusinessError) => {
        hilog.error(DOMAIN, TAG, `Node.js backend wait error: ${err.message}`);
        NodeProcessState.clear();
      });

      // Read stderr for debugging (non-blocking)
      child.getErrorOutput().then((stderr: string) => {
        if (stderr && stderr.length > 0) {
          hilog.warn(DOMAIN, TAG, `Node.js stderr: ${stderr.substring(0, 2000)}`);
        }
      }).catch(() => {});

      // --- Step 4: Load the loading page ---------------------------------
      // loading.html polls http://127.0.0.1:5577 and redirects to the
      // backend once it's responding. This gives the Node.js process
      // a few seconds to boot before the WebView tries to connect.
      //
      // Verify loading.html exists before setting serverReady.
      const loadingHtmlPath = `${this.electermDir}/loading.html`;
      if (!this.fileExists(loadingHtmlPath)) {
        throw new Error(`loading.html not found at ${loadingHtmlPath}`);
      }

      this.statusMessage = 'Loading...';
      this.serverReady = true;

      hilog.info(DOMAIN, TAG, `Loading page: file://${loadingHtmlPath}`);
      hilog.info(DOMAIN, TAG, `electermDir: ${this.electermDir}`);
      hilog.info(DOMAIN, TAG, `nodeBin: ${nodeBin}, exists: ${this.fileExists(nodeBin)}`);
      hilog.info(DOMAIN, TAG, `entryScript: ${entryScript}, exists: ${this.fileExists(entryScript)}`);

    } catch (err) {
      const msg = this.getErrorMessage(err as object);
      hilog.error(DOMAIN, TAG, `Failed to start: ${msg}`);
      this.statusMessage = `Error: ${msg}`;
    }
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
        // Load loading.html — it polls the backend and redirects to
        // http://127.0.0.1:5577/ once the server is ready.
        Web({ src: `file://${this.electermDir}/loading.html`, controller: this.controller })
          .width('100%')
          .height('100%')
          .backgroundColor('#15171a')
          .javaScriptAccess(true)
          .domStorageAccess(true)
          .fileAccess(true)
          .imageAccess(true)
          .onlineImageAccess(true)
          .geolocationAccess(false)
          // MixedMode.All allows loading HTTP content (the backend at
          // 127.0.0.1:5577) from a file:// origin (loading.html).
          .mixedMode(MixedMode.All)
          // Allow the WebView to make fetch() requests to the backend.
          .onControllerAttached(() => {
            hilog.info(DOMAIN, TAG, 'WebView attached');
          })
          .onPageEnd(() => {
            hilog.info(DOMAIN, TAG, 'WebView page ended loading');
          })
          .onErrorReceive(() => {
            hilog.error(DOMAIN, TAG, 'WebView error: failed to load page');
            this.webError = 'WebView failed to load loading.html';
          })
      } else {
        Column() {
          Text('Electerm')
            .fontSize(32)
            .fontWeight(FontWeight.Bold)
            .margin({ bottom: 20 })
          Text(this.statusMessage)
            .fontSize(16)
            .fontColor(Color.Gray)
            .textAlign(TextAlign.Center)
            .padding({ left: 20, right: 20 })
          if (this.webError.length > 0) {
            Text(this.webError)
              .fontSize(12)
              .fontColor(Color.Red)
              .textAlign(TextAlign.Center)
              .padding({ left: 20, right: 20, top: 10 })
          }
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      }
    }
    .width('100%')
    .height('100%')
  }
}
