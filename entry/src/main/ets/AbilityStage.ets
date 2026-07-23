/**
 * AbilityStage — app-level initialization.
 *
 * Extends WebAbilityStage from the web_engine module, which handles
 * initializing the Electron 鸿蒙 native context (libadapter.so / libelectron.so)
 * before any ability is created.
 *
 * On HarmonyOS, app.getPath('appData') does not work reliably in the
 * Electron runtime (SetContextPaths C++ binding has a race condition).
 * To work around this, we write the sandbox filesDir to a marker file
 * BEFORE the Electron runtime starts, so bootstrap.js can read it.
 */

import { WebAbilityStage } from 'web_engine';
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
      const markerPath: string = `${filesDir}/.electerm-data-path`;
      const file = fs.openSync(markerPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, filesDir);
      fs.closeSync(file);
      console.info(`[${TAG}] wrote data path marker: ${markerPath} → ${filesDir}`);
    } catch (e) {
      console.error(`[${TAG}] failed to write data path marker: ${JSON.stringify(e)}`);
    }
  }
}
