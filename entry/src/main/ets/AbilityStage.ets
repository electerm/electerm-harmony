/**
 * AbilityStage — app-level initialization.
 *
 * Extends WebAbilityStage from the web_engine module, which handles
 * initializing the Electron 鸿蒙 native context (libadapter.so / libelectron.so)
 * before any ability is created.
 *
 * On HarmonyOS the app sandbox filesDir (/data/storage/el2/base/...)
 * is NOT reliably accessible from the Electron runtime — data may be
 * lost on restart and writes can fail silently.
 *
 * Instead, we use the user's pre-authorized Documents directory
 * (Environment.getUserDocumentDir(), API 11+), which is governed by
 * the READ_WRITE_DOCUMENTS_DIRECTORY permission declared in
 * module.json5. This directory is persistent, user-visible, and
 * reliably writable from the Electron process.
 *
 * The path is written to a marker file in filesDir BEFORE the Electron
 * runtime starts, so bootstrap.js can read it. If the marker is
 * unreadable, bootstrap.js falls back to deriving the path from
 * os.homedir() + '/Documents/electerm'.
 */

import { WebAbilityStage } from 'web_engine';
import { Environment } from '@kit.CoreFileKit';
import fs from '@ohos.file.fs';

const TAG: string = 'ElectermAbilityStage';

export default class ElectermAbilityStage extends WebAbilityStage {
  onCreate(): void {
    super.onCreate();

    // super.onCreate() schedules the Electron runtime start via setTimeout(0).
    // This synchronous code runs BEFORE that setTimeout fires, so the marker
    // file is guaranteed to exist when bootstrap.js loads.
    try {
      const filesDir: string = this.context.getApplicationContext().filesDir;

      // Use the pre-authorized Documents directory as the reliable data path.
      // Append '/electerm' to keep app data in a dedicated subdirectory.
      let dataPath: string;
      try {
        const documentsDir: string = Environment.getUserDocumentDir();
        dataPath = `${documentsDir}/electerm`;
        console.info(`[${TAG}] using Documents dir: ${dataPath}`);
      } catch (e) {
        // Fallback to sandbox filesDir if Environment API is unavailable.
        dataPath = filesDir;
        console.warn(`[${TAG}] getUserDocumentDir failed, falling back to filesDir: ${JSON.stringify(e)}`);
      }

      const markerPath: string = `${filesDir}/.electerm-data-path`;
      const file = fs.openSync(markerPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, dataPath);
      fs.closeSync(file);
      console.info(`[${TAG}] wrote data path marker: ${markerPath} → ${dataPath}`);
    } catch (e) {
      console.error(`[${TAG}] failed to write data path marker: ${JSON.stringify(e)}`);
    }
  }
}
