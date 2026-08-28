/**
 * EntryAbility — main ability for the electerm-harmony web app.
 *
 * Plain UIAbility (no electron/web_engine): loads pages/Index, which boots
 * the on-device Node.js backend as a native child process and renders the
 * UI in an ArkWeb Web component pointed at http://127.0.0.1:5577.
 *
 * Responsibilities:
 *  - request user-grant permissions at startup (Documents/Desktop/Download
 *    directory access for SFTP local paths, pasteboard for copy/paste);
 *  - on destroy, terminate the Node.js child process so port 5577 is freed.
 */

import window from '@ohos.window';
import Want from '@ohos.app.ability.Want';
import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import { Configuration } from '@ohos.app.ability.Configuration';
import { abilityAccessCtrl, common, Permissions, PermissionRequestResult, UIAbility } from '@kit.AbilityKit';
import { Environment } from '@kit.CoreFileKit';
import { BackendManager } from '../BackendManager';

const TAG: string = 'ElectermEntryAbility';

// All user-grant permissions declared in module.json5.
// Permissions without "reason"/"usedScene" (INTERNET, GET_NETWORK_INFO,
// ACCESS_CERT_MANAGER, PRINT, GYROSCOPE, ACCELEROMETER) are normal or
// system-grant permissions that don't need runtime request.
const ALL_USER_PERMISSIONS: Permissions[] = [
  'ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY',
  'ohos.permission.READ_WRITE_DOCUMENTS_DIRECTORY',
  'ohos.permission.READ_WRITE_DESKTOP_DIRECTORY',
  'ohos.permission.READ_PASTEBOARD'
];

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam) {
  }

  onConfigurationUpdate(config: Configuration) {
  }

  async onWindowStageCreate(windowStage: window.WindowStage) {
    // Request permissions up front. Index requests them again via
    // its own context when it needs to write user-visible files; a
    // granted permission here just avoids the dialogs appearing later.
    await this.requestAllPermissions();

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        console.error(`[${TAG}] Failed to load content: ${JSON.stringify(err)}`);
        return;
      }
      console.info(`[${TAG}] content loaded`);
    });
  }

  onWindowStageDestroy() {
  }

  onForeground() {
  }

  onBackground() {
  }

  async onDestroy(): Promise<void> {
    // Terminate the node child process so port 5577 is freed. If the child
    // is already dead (crashed / exec failed) killNode just returns -1.
    BackendManager.killBackend();
  }

  /**
   * Request all declared user-grant permissions at runtime.
   * If already granted, returns immediately without showing a dialog.
   */
  private async requestAllPermissions(): Promise<void> {
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const context = this.context as common.UIAbilityContext;
      const result: PermissionRequestResult = await atManager.requestPermissionsFromUser(context, ALL_USER_PERMISSIONS);
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
}
