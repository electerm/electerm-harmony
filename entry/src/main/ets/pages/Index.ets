import { webview } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { http } from '@kit.NetworkKit';
import { process } from '@kit.ArkTS';

const DOMAIN = 0x0001;
const TAG = 'electerm-web';

// electerm-web server configuration
const SERVER_HOST = '127.0.0.1';
const SERVER_PORT = 5577;
const SERVER_URL = `http://${SERVER_HOST}:${SERVER_PORT}`;

@Entry
@Component
struct Index {
  controller: webview.WebviewController = new webview.WebviewController();
  @State serverReady: boolean = false;
  @State statusMessage: string = 'Starting electerm backend...';
  private childProcess: process.ChildProcess | null = null;

  aboutToAppear(): void {
    this.startBackend();
  }

  aboutToDisappear(): void {
    this.killBackend();
  }

  /**
   * Kill the Node.js child process if it is still running.
   */
  killBackend(): void {
    if (this.childProcess) {
      hilog.info(DOMAIN, TAG, 'Killing Node.js backend...');
      this.childProcess.kill(9).then(() => {
        hilog.info(DOMAIN, TAG, 'Node.js backend killed.');
      }).catch((err: Error) => {
        hilog.error(DOMAIN, TAG, `Failed to kill backend: ${err.message}`);
      });
      this.childProcess = null;
    }
  }

  /**
   * Extract bundled node binary and electerm-web files from rawfile
   * to the app sandbox, spawn the Node.js server, then wait for it
   * to be ready before showing the Web UI.
   */
  async startBackend(): Promise<void> {
    try {
      const context = getContext(this) as common.Context;
      const sandboxDir = context.filesDir;
      const nodeDir = `${sandboxDir}/node`;
      const webDir = `${sandboxDir}/electerm-web`;
      const nodeBin = `${nodeDir}/bin/node`;
      const entryScript = `${webDir}/src/app/app.js`;

      // ── Step 1: Extract rawfiles to sandbox ──────────────────────────
      if (!this.fileExists(nodeBin) || !this.fileExists(`${webDir}/package.json`)) {
        this.statusMessage = 'Extracting files from app bundle...';
        hilog.info(DOMAIN, TAG, 'Extracting rawfiles to sandbox...');
        await this.extractAllRawfiles(context, sandboxDir);
        hilog.info(DOMAIN, TAG, 'All rawfiles extracted.');
      } else {
        hilog.info(DOMAIN, TAG, 'Files already extracted, skipping extraction.');
      }

      // ── Step 2: Make node binary executable ──────────────────────────
      hilog.info(DOMAIN, TAG, `Setting execute permission on: ${nodeBin}`);
      try {
        fs.chmodSync(nodeBin, 0o755);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, `chmodSync failed: ${JSON.stringify(e)}`);
      }

      // ── Step 3: Start the Node.js server ─────────────────────────────
      this.statusMessage = 'Starting Node.js backend...';
      hilog.info(DOMAIN, TAG, 'Starting Node.js backend...');
      hilog.info(DOMAIN, TAG, `  node:  ${nodeBin}`);
      hilog.info(DOMAIN, TAG, `  entry: ${entryScript}`);
      hilog.info(DOMAIN, TAG, `  cwd:   ${webDir}`);

      // Use shell to set NODE_ENV and chmod, then run node.
      // HOST/PORT/SERVER_SECRET etc. come from the .env file via dotenv.
      const command = `chmod 755 "${nodeBin}" 2>/dev/null; NODE_ENV=production "${nodeBin}" "${entryScript}"`;
      this.childProcess = await process.runCmd(command, { cwd: webDir });
      hilog.info(DOMAIN, TAG, 'Node.js backend process started.');

      // Capture stdout/stderr for debugging (non-blocking — resolves when
      // the process exits, which is fine for crash diagnostics).
      this.childProcess.getErrorOutput().then((stderr: string) => {
        if (stderr) {
          hilog.error(DOMAIN, TAG, `Node.js stderr:\n${stderr}`);
        }
      }).catch(() => {});

      this.childProcess.getOutput().then((stdout: string) => {
        if (stdout) {
          hilog.info(DOMAIN, TAG, `Node.js stdout:\n${stdout}`);
        }
      }).catch(() => {});

      // ── Step 4: Poll server until ready ──────────────────────────────
      this.statusMessage = 'Waiting for backend to be ready...';
      await this.waitForServer();
      this.serverReady = true;
      hilog.info(DOMAIN, TAG, 'Backend ready, loading web UI...');

    } catch (err) {
      hilog.error(DOMAIN, TAG, `Failed to start backend: ${JSON.stringify(err)}`);
      this.statusMessage = `Error: ${JSON.stringify(err)}`;
    }
  }

  /**
   * Check if a file or directory exists.
   * fs.accessSync throws if the path does not exist.
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
   * Extract all files listed in rawfile/manifest.json to the sandbox.
   *
   * The manifest is a JSON array of relative paths (e.g. "node/bin/node",
   * "electerm-web/package.json"). Each file is read via
   * resourceManager.getRawFileContent() and written to the sandbox.
   */
  async extractAllRawfiles(context: common.Context, sandboxDir: string): Promise<void> {
    const rm = context.resourceManager;

    // Read manifest
    hilog.info(DOMAIN, TAG, 'Reading manifest.json from rawfile...');
    const manifestData = await rm.getRawFileContent('manifest.json');
    const manifestText = new TextDecoder('utf-8').decode(manifestData);
    const files: string[] = JSON.parse(manifestText) as string[];
    hilog.info(DOMAIN, TAG, `Manifest contains ${files.length} files`);

    let extracted = 0;
    let failed = 0;

    for (let i = 0; i < files.length; i++) {
      const rawfilePath = files[i];
      const destPath = `${sandboxDir}/${rawfilePath}`;

      // Create parent directories
      const lastSlash = destPath.lastIndexOf('/');
      if (lastSlash > 0) {
        const parentDir = destPath.substring(0, lastSlash);
        if (!this.fileExists(parentDir)) {
          fs.mkdirSync(parentDir, true);
        }
      }

      // Read from rawfile and write to sandbox
      try {
        const content = await rm.getRawFileContent(rawfilePath);
        const file = fs.openSync(
          destPath,
          fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC
        );
        // Create a clean ArrayBuffer copy (avoids offset issues with views)
        const buffer = new ArrayBuffer(content.byteLength);
        const view = new Uint8Array(buffer);
        view.set(content);
        fs.writeSync(file.fd, buffer);
        fs.closeSync(file);
        extracted++;
      } catch (e) {
        failed++;
        hilog.warn(DOMAIN, TAG, `Failed to extract ${rawfilePath}: ${JSON.stringify(e)}`);
      }

      // Update progress periodically (every 50 files or first/last)
      if (i % 50 === 0 || i === files.length - 1) {
        this.statusMessage = `Extracting files... (${i + 1}/${files.length})`;
        if (i % 200 === 0 || i === files.length - 1) {
          hilog.info(DOMAIN, TAG, `Progress: ${i + 1}/${files.length} (${rawfilePath})`);
        }
      }
    }

    hilog.info(DOMAIN, TAG, `Extraction complete: ${extracted} ok, ${failed} failed out of ${files.length}`);
  }

  /**
   * Poll the localhost server until it responds with HTTP 200.
   * Times out after 60 seconds.
   */
  async waitForServer(): Promise<void> {
    const maxAttempts = 60;
    const intervalMs = 1000;
    for (let i = 0; i < maxAttempts; i++) {
      try {
        const ok = await this.httpGet(SERVER_URL);
        if (ok) {
          hilog.info(DOMAIN, TAG, `Server ready after ${i + 1} attempts.`);
          return;
        }
      } catch {
        // ignore — server not ready yet
      }
      this.statusMessage = `Waiting for backend... (${i + 1}/${maxAttempts})`;
      await new Promise<void>(resolve => setTimeout(resolve, intervalMs));
    }
    throw new Error('Backend did not start within timeout (60s). Check hilog (tag: electerm-web) for Node.js stderr.');
  }

  /**
   * Simple HTTP GET check using NetworkKit.
   * Returns true if the server responds with HTTP 200.
   */
  async httpGet(url: string): Promise<boolean> {
    const httpRequest = http.createHttp();
    try {
      const response = await httpRequest.request(url, {
        method: http.RequestMethod.GET,
        connectTimeout: 2000,
        readTimeout: 2000,
      });
      httpRequest.destroy();
      return response.responseCode === 200;
    } catch {
      httpRequest.destroy();
      return false;
    }
  }

  build() {
    Column() {
      if (this.serverReady) {
        Web({ src: SERVER_URL, controller: this.controller })
          .width('100%')
          .height('100%')
          .javaScriptAccess(true)
          .domStorageAccess(true)
          .fileAccess(true)
          .imageAccess(true)
          .onlineImageAccess(true)
          .geolocationAccess(false)
          .mixedMode(MixedMode.All)
      } else {
        Column() {
          Text('Electerm')
            .fontSize(32)
            .fontWeight(FontWeight.Bold)
            .margin({ bottom: 20 })
          Text(this.statusMessage)
            .fontSize(16)
            .fontColor(Color.Gray)
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
