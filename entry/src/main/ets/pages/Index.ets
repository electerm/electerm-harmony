import { webview } from '@kit.ArkWeb';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { http } from '@kit.NetworkKit';
import { processKit } from '@kit.ArkTS';
import { util } from '@kit.ArkTS';

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
  private childProc: processKit.ChildProcess | null = null;

  aboutToAppear(): void {
    this.startBackend();
  }

  aboutToDisappear(): void {
    this.killBackend();
  }

  /**
   * Check if a file exists without throwing.
   * HarmonyOS fs.accessSync() throws BusinessError when path doesn't exist,
   * so we wrap it in try-catch.
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
   * JSON.stringify(BusinessError) returns "{}" because its properties
   * (code, message, stack) are non-enumerable.
   */
  getErrorMessage(err: object): string {
    const businessErr = err as BusinessError;
    if (businessErr && businessErr.message) {
      return `[${businessErr.code}] ${businessErr.message}`;
    }
    // Fallback for plain Error objects
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
   * Extract bundled node binary and electerm-web files from rawfile
   * to the app sandbox, spawn the Node.js server, and wait for it to be ready.
   */
  async startBackend(): Promise<void> {
    try {
      const context = getContext(this) as common.Context;
      const sandboxDir = context.filesDir;
      const nodeDir = `${sandboxDir}/node`;
      const webDir = `${sandboxDir}/electerm-web`;
      const nodeBin = `${nodeDir}/bin/node`;

      // Extract resources if not already done
      if (!this.fileExists(nodeBin) || !this.fileExists(`${webDir}/package.json`)) {
        hilog.info(DOMAIN, TAG, 'Extracting bundled resources from rawfile...');
        this.statusMessage = 'Extracting bundled resources...';
        await this.extractAllRawfiles(context, sandboxDir);
        hilog.info(DOMAIN, TAG, 'All resources extracted.');
      }

      // Verify node binary exists after extraction
      if (!this.fileExists(nodeBin)) {
        throw new Error(`Node binary not found at ${nodeBin} after extraction. ` +
          'The rawfile may not contain the node binary.');
      }
      hilog.info(DOMAIN, TAG, `Node binary found: ${nodeBin}`);

      // Note: fs.chmodSync is not available in HarmonyOS fileIo
      // The node binary should already be executable in the bundle
      hilog.info(DOMAIN, TAG, 'Node binary is ready (chmod not available).');

      // Start the Node.js backend
      this.statusMessage = 'Starting Node.js backend...';
      this.spawnNodeBackend(nodeBin, webDir);

      // Poll server until ready
      this.statusMessage = 'Waiting for backend to respond...';
      await this.waitForServer();
      this.serverReady = true;
      hilog.info(DOMAIN, TAG, 'Backend ready, loading web UI...');

    } catch (err) {
      const msg = this.getErrorMessage(err as object);
      hilog.error(DOMAIN, TAG, `Failed to start backend: ${msg}`);
      this.statusMessage = `Error: ${msg}`;
    }
  }

  /**
   * Extract all rawfile resources to the sandbox using the manifest.json
   * that is generated at build time by scripts/gen-manifest.sh.
   *
   * HarmonyOS resourceManager has no recursive directory listing API,
   * so the manifest lists every file path relative to rawfile/.
   */
  async extractAllRawfiles(context: common.Context, sandboxDir: string): Promise<void> {
    const resourceMgr = context.resourceManager;

    // Read manifest.json from rawfile
    const manifestBytes = await resourceMgr.getRawFileContent('manifest.json');
    const decoder = util.TextDecoder.create('utf-8');
    const manifestText = decoder.decodeInto(manifestBytes, { stream: false });
    const manifest = JSON.parse(manifestText) as Record<string, string[]>;
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
        this.statusMessage = `Extracting resources... (${count}/${files.length})`;
        hilog.info(DOMAIN, TAG, `Extracted ${count}/${files.length} files`);
      }
    }

    hilog.info(DOMAIN, TAG, `Extraction complete: ${count} files`);
  }

  /**
   * Spawn the Node.js backend process using child_process.spawn().
   * The server reads its configuration (PORT, HOST, SERVER_SECRET) from
   * the .env file in the electerm-web directory.
   */
  spawnNodeBackend(nodeBin: string, webDir: string): void {
    const appJs = `${webDir}/src/app/app.js`;
    if (!this.fileExists(appJs)) {
      throw new Error(`electerm-web entry point not found: ${appJs}`);
    }

    hilog.info(DOMAIN, TAG, `Spawning: ${nodeBin} ${appJs}`);
    hilog.info(DOMAIN, TAG, `Working directory: ${webDir}`);

    this.childProc = processKit.spawn(nodeBin, [appJs], {
      cwd: webDir,
    });

    if (!this.childProc) {
      throw new Error('Failed to spawn Node.js backend process');
    }

    hilog.info(DOMAIN, TAG, `Node.js backend spawned, PID: ${this.childProc.pid}`);

    // Capture stdout for debugging
    this.childProc.on('stdout', (data: string) => {
      hilog.info(DOMAIN, TAG, `[node stdout] ${data}`);
    });

    // Capture stderr for debugging
    this.childProc.on('stderr', (data: string) => {
      hilog.error(DOMAIN, TAG, `[node stderr] ${data}`);
    });

    // Handle process exit
    this.childProc.on('exit', (code: number) => {
      hilog.info(DOMAIN, TAG, `Node.js backend exited with code ${code}`);
      this.childProc = null;
    });
  }

  /**
   * Kill the Node.js backend process if it's running.
   */
  killBackend(): void {
    if (this.childProc) {
      hilog.info(DOMAIN, TAG, 'Killing Node.js backend process...');
      try {
        this.childProc.kill();
      } catch (e) {
        hilog.warn(DOMAIN, TAG, `Failed to kill backend: ${this.getErrorMessage(e as object)}`);
      }
      this.childProc = null;
    }
  }

  /**
   * Poll the localhost server until it responds.
   */
  async waitForServer(): Promise<void> {
    const maxAttempts = 60;
    const intervalMs = 1000;
    for (let i = 0; i < maxAttempts; i++) {
      const ok = await this.httpGet(SERVER_URL);
      if (ok) {
        hilog.info(DOMAIN, TAG, `Server ready after ${i + 1} attempts.`);
        return;
      }
      this.statusMessage = `Waiting for backend... (${i + 1}/${maxAttempts})`;
      await new Promise<void>(resolve => setTimeout(resolve, intervalMs));
    }
    throw new Error(
      'Backend did not respond within 60 seconds. ' +
      'Check hilog (tag: electerm-web) for Node.js output.'
    );
  }

  /**
   * Simple HTTP GET check using NetworkKit
   */
  async httpGet(url: string): Promise<boolean> {
    const httpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await httpRequest.request(url, {
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
            .textAlign(TextAlign.Center)
            .padding({ left: 20, right: 20 })
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
