import { webview } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { process } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';

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

  aboutToAppear(): void {
    this.startBackend();
  }

  /**
   * Extract bundled node binary and electerm-web files from rawfile
   * to the app sandbox, then spawn the Node.js process.
   */
  async startBackend(): Promise<void> {
    try {
      const context = getContext(this) as common.Context;
      const sandboxDir = context.filesDir;
      const nodeDir = `${sandboxDir}/node`;
      const webDir = `${sandboxDir}/electerm-web`;
      const nodeBin = `${nodeDir}/bin/node`;

      // Check if already extracted
      if (!fs.accessSync(nodeBin)) {
        hilog.info(DOMAIN, TAG, 'Extracting node binary from rawfile...');
        await this.extractRawfile(context, 'node', nodeDir);
        // Make the binary executable
        fs.chmodSync(nodeBin, 0o755);
        hilog.info(DOMAIN, TAG, 'Node binary extracted.');
      }

      // Extract electerm-web if not present
      if (!fs.accessSync(`${webDir}/package.json`)) {
        hilog.info(DOMAIN, TAG, 'Extracting electerm-web from rawfile...');
        await this.extractRawfile(context, 'electerm-web', webDir);
        hilog.info(DOMAIN, TAG, 'electerm-web extracted.');
      }

      // Start the Node.js server as a child process
      hilog.info(DOMAIN, TAG, `Starting node: ${nodeBin} src/app/app.js`);
      const child = process.spawn(nodeBin, ['src/app/app.js'], {
        cwd: webDir,
        env: {
          NODE_ENV: 'production',
          HOST: SERVER_HOST,
          PORT: String(SERVER_PORT),
          PATH: '/data/local/usr/bin:/system/bin',
        },
      });

      // Listen for process exit
      child.on('exit', (code: number) => {
        hilog.error(DOMAIN, TAG, `Node process exited with code ${code}`);
        this.statusMessage = `Backend exited (code ${code})`;
      });

      // Poll server until ready
      await this.waitForServer();
      this.serverReady = true;
      hilog.info(DOMAIN, TAG, 'Backend ready, loading web UI...');

    } catch (err) {
      hilog.error(DOMAIN, TAG, `Failed to start backend: ${JSON.stringify(err)}`);
      this.statusMessage = `Error: ${JSON.stringify(err)}`;
    }
  }

  /**
   * Extract a rawfile subdirectory to the sandbox.
   * Uses ResourceManager to read rawfile contents.
   */
  async extractRawfile(
    context: common.Context,
    rawfileSubDir: string,
    destDir: string
  ): Promise<void> {
    if (!fs.accessSync(destDir)) {
      fs.mkdirSync(destDir, true);
    }
    hilog.info(DOMAIN, TAG, `Extracting ${rawfileSubDir} → ${destDir}`);
    // Full recursive extraction implementation goes here.
    // In production, use resourceManager.getRawFileContent() to read each
    // file from the rawfile directory and write it to the sandbox.
    // For the node binary (large file), consider chunked extraction.
  }

  /**
   * Poll the localhost server until it responds.
   */
  async waitForServer(): Promise<void> {
    const maxAttempts = 60;
    const intervalMs = 1000;
    for (let i = 0; i < maxAttempts; i++) {
      try {
        const response = await fetch(SERVER_URL);
        if (response.ok) {
          hilog.info(DOMAIN, TAG, `Server ready after ${i + 1} attempts.`);
          return;
        }
      } catch {
        this.statusMessage = `Waiting for backend... (${i + 1}/${maxAttempts})`;
      }
      await new Promise<void>(resolve => setTimeout(resolve, intervalMs));
    }
    throw new Error('Backend did not start within timeout.');
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
