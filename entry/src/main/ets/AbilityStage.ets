/**
 * AbilityStage — app-level initialization.
 *
 * Extends WebAbilityStage from the web_engine module, which handles
 * initializing the Electron 鸿蒙 native context (libadapter.so / libelectron.so)
 * before any ability is created.
 *
 * Writes the sandbox filesDir path to a marker file BEFORE the Electron
 * runtime starts, so bootstrap.js can read it and set process.env.DATA_PATH.
 *
 * The sandbox filesDir is used as the DATA_PATH for reliable app data
 * storage (nedb databases, config, logs). It is always writable and
 * does not require runtime permission requests.
 *
 * For the user-visible home directory (os.homedir()), EntryAbility.ets
 * requests READ_WRITE_DOCUMENTS_DIRECTORY and writes a separate marker
 * (.electerm-documents-path) that bootstrap.js uses to override os.homedir()
 * to point at the Documents folder.
 */

import { WebAbilityStage } from 'web_engine';
import fs from '@ohos.file.fs';

const TAG: string = 'ElectermAbilityStage';

export default class ElectermAbilityStage extends WebAbilityStage {
  onCreate(): void {
    super.onCreate();

    // super.onCreate() schedules the Electron runtime start via setTimeout(0).
    // This synchronous code runs BEFORE that setTimeout fires, so the marker
    // files are guaranteed to exist when bootstrap.js loads.
    const filesDir: string = this.context.getApplicationContext().filesDir;

    try {
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
