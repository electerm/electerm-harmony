import { webview } from '@kit.ArkWeb';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';

const DOMAIN = 0x0001;
const TAG = 'electerm-web';

@Entry
@Component
struct Index {
  controller: webview.WebviewController = new webview.WebviewController();
  @State serverReady: boolean = false;
  @State statusMessage: string = 'Starting electerm...';
  private webDir: string = '';

  aboutToAppear(): void {
    this.startBackend();
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
   * Extract bundled electerm-web files from rawfile to the app sandbox,
   * then load the static web content directly in WebView.
   *
   * Note: HarmonyOS does not support spawning child processes (no
   * child_process.spawn), so we cannot run a Node.js server.
   * Instead, we pre-render the pug template to static HTML at build time
   * and load it from the sandbox via WebView with file:// URL.
   */
  async startBackend(): Promise<void> {
    try {
      const context = getContext(this) as common.Context;
      const sandboxDir = context.filesDir;
      this.webDir = `${sandboxDir}/electerm-web`;

      // Extract resources if not already done
      if (!this.fileExists(`${this.webDir}/dist/index.html`)) {
        hilog.info(DOMAIN, TAG, 'Extracting bundled resources from rawfile...');
        this.statusMessage = 'Extracting bundled resources...';
        await this.extractAllRawfiles(context, sandboxDir);
        hilog.info(DOMAIN, TAG, 'All resources extracted.');
      }

      // Verify index.html exists after extraction
      if (!this.fileExists(`${this.webDir}/dist/index.html`)) {
        throw new Error(
          `index.html not found after extraction. ` +
          'The rawfile may not contain the web content.');
      }

      // WebView will load the file in build() via serverReady state
      this.statusMessage = 'Loading web UI...';
      hilog.info(DOMAIN, TAG, `Web content ready at ${this.webDir}/dist/index.html`);
      this.serverReady = true;

    } catch (err) {
      const msg = this.getErrorMessage(err as object);
      hilog.error(DOMAIN, TAG, `Failed to start: ${msg}`);
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
    const manifest: Record<string, string[]> = JSON.parse(decoder.decodeToString(manifestBytes)) as Record<string, string[]>;
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

  build() {
    Column() {
      if (this.serverReady) {
        Web({ src: `file://${this.webDir}/dist/index.html`, controller: this.controller })
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
