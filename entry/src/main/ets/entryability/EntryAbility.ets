/**
 * EntryAbility — main ability for the electerm-harmony app.
 *
 * Extends WebAbility from the web_engine module, which handles window
 * creation, XComponent setup, and Electron runtime startup.
 *
 * Key responsibility: request ALL declared user-grant permissions at
 * startup, BEFORE the Electron runtime starts.  This is done in
 * onWindowStageCreate() before calling super.onWindowStageCreate(),
 * because super.onWindowStageCreate() loads the WebWindow page which
 * triggers the Electron runtime to load bootstrap.js.
 *
 * After permissions are granted, writes a second marker file
 * (.electerm-documents-path) containing the Documents directory path,
 * which bootstrap.js uses to override os.homedir() so that file save
 * dialogs and SFTP local paths default to the user-visible Documents
 * folder.
 */

import window from '@ohos.window';
import Want from '@ohos.app.ability.Want';
import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import { Configuration } from '@ohos.app.ability.Configuration';
import { abilityAccessCtrl, common, Permissions, PermissionRequestResult } from '@kit.AbilityKit';
import { Environment } from '@kit.CoreFileKit';
import fs from '@ohos.file.fs';

import { WebAbility } from 'web_engine';

const TAG: string = 'ElectermEntryAbility';

// All user-grant permissions declared in module.json5.
// Permissions without "reason"/"usedScene" (INTERNET, GET_NETWORK_INFO,
// ACCESS_CERT_MANAGER, PRINT, GYROSCOPE, ACCELEROMETER) are normal or
// system-grant permissions that don't need runtime request.
// Removed LOCATION, MICROPHONE, CAMERA, ACCESS_BLUETOOTH — a terminal/SSH
// app has no use for geolocation, audio/video capture, or Bluetooth.
const ALL_USER_PERMISSIONS: Permissions[] = [
  'ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY',
  'ohos.permission.READ_WRITE_DOCUMENTS_DIRECTORY',
  'ohos.permission.READ_WRITE_DESKTOP_DIRECTORY',
  'ohos.permission.READ_PASTEBOARD'
];

export default class EntryAbility extends WebAbility {
  onConfigurationUpdate(config: Configuration) {
    super.onConfigurationUpdate(config);
  }

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam) {
    super.onCreate(want, launchParam);
  }

  async onPrepareToTerminateAsync(): Promise<boolean> {
    return await super.onPrepareToTerminateAsync();
  }

  async onDestroy(): Promise<void> {
    await super.onDestroy();
  }

  async onWindowStageCreate(windowStage: window.WindowStage) {
    // Request ALL declared user-grant permissions BEFORE the Electron
    // runtime starts.  super.onWindowStageCreate() loads the WebWindow
    // page which triggers the Electron runtime to load bootstrap.js.
    //
    // If a permission is already granted, requestPermissionsFromUser
    // returns immediately without showing a dialog for that permission.
    await this.requestAllPermissions();
    this.writeDocumentsPathMarker();

    super.onWindowStageCreate(windowStage);
  }

  onWindowStageDestroy() {
    super.onWindowStageDestroy();
  }

  onForeground() {
    super.onForeground();
  }

  onBackground() {
    super.onBackground();
  }

  /**
   * Request all declared user-grant permissions at runtime.
   * If already granted, returns immediately without showing a dialog.
   */
  private async requestAllPermissions(): Promise<void> {
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const context = this.context as common.UIAbilityContext;
      const result: PermissionRequestResult =
        await atManager.requestPermissionsFromUser(context, ALL_USER_PERMISSIONS);
      const authResults: number[] = result.authResults;
      for (let i = 0; i < authResults.length; i++) {
        if (authResults[i] === 0) {
          console.info(`[${TAG}] Permission granted: ${ALL_USER_PERMISSIONS[i]}`);
        } else {
          console.warn(`[${TAG}] Permission denied: ${ALL_USER_PERMISSIONS[i]} (status=${authResults[i]})`);
        }
      }
    } catch (e) {
      console.error(`[${TAG}] Failed to request permissions: ${JSON.stringify(e)}`);
    }
  }

  /**
   * Write the documents-path marker file.
   *
   * After permissions are granted, Environment.getUserDocumentDir()
   * returns the user-visible Documents directory path. This is written
   * to a separate marker (.electerm-documents-path) which bootstrap.js
   * reads to override os.homedir() — so that file save dialogs, SFTP
   * local paths, and other home-directory-based operations default to
   * the user-visible Documents folder.
   *
   * If the permission was denied, the marker is not written and
   * bootstrap.js falls back to the original os.homedir() value.
   */
  private writeDocumentsPathMarker(): void {
    try {
      const filesDir: string = this.context.getApplicationContext().filesDir;

      try {
        const documentsDir: string = Environment.getUserDocumentDir();
        const markerPath: string = `${filesDir}/.electerm-documents-path`;
        const file = fs.openSync(markerPath,
          fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
        fs.writeSync(file.fd, documentsDir);
        fs.closeSync(file);
        console.info(`[${TAG}] wrote documents path marker: ${markerPath} → ${documentsDir}`);
      } catch (e) {
        console.warn(`[${TAG}] getUserDocumentDir failed, skipping documents marker: ${JSON.stringify(e)}`);
      }
    } catch (e) {
      console.error(`[${TAG}] Failed to write documents path marker: ${JSON.stringify(e)}`);
    }
  }
}
