/**
 * EntryAbility — main ability for the electerm-harmony web app.
 *
 * Plain UIAbility (no electron/web_engine): loads pages/Index, which boots
 * the on-device Node.js backend as a native child process and renders the
 * UI in an ArkWeb Web component pointed at http://127.0.0.1:5577.
 *
 * Responsibilities:
 *  - request user-grant permissions at startup (Download/Documents directory
 *    access for SFTP local paths);
 *  - on destroy, terminate the Node.js child process so port 5577 is freed.
 */

import window from '@ohos.window';
import Want from '@ohos.app.ability.Want';
import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import { Configuration } from '@ohos.app.ability.Configuration';
import { abilityAccessCtrl, common, Permissions, PermissionRequestResult, UIAbility } from '@kit.AbilityKit';
import { Environment } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BackendManager } from '../BackendManager';
import { launchInProcessEarly } from '../BackendLauncher';

const TAG: string = 'ElectermEntryAbility';
const DOMAIN: number = 0xE1EC;

// Every user-grant permission declared in module.json5 — keep the two lists in
// sync. All of these are apl `normal`.
//
// READ_PASTEBOARD and READ_WRITE_DESKTOP_DIRECTORY used to be here and were
// removed: both are apl `system_basic`, and the app's signing profile is
// `apl: normal` / `hos_normal_app`, so merely DECLARING them makes the
// installer reject the HAP:
//   安装失败。应用等级为normal，只能使用normal等级的权限。
// A normal app cannot be granted them (the ACL list lives in the profile), and
// neither is needed: only normal-level, system-grant permissions (INTERNET,
// GET_NETWORK_INFO, ACCESS_CERT_MANAGER, PRINT, GYROSCOPE, ACCELEROMETER) are
// declared alongside these and none of them need a runtime request.
const ALL_USER_PERMISSIONS: Permissions[] = [
  'ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY',
  'ohos.permission.READ_WRITE_DOCUMENTS_DIRECTORY'
];

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam) {

    // Fire the node backend NOW — before loadContent, before the ArkWeb
    // engine spins up. The dlopen + node::Start bootstrap (~0.9s) then
    // overlaps UI init instead of serialising behind it. startBackend
    // returns immediately (background thread); the fs probing inside is
    // ~1ms and any failure is swallowed — Index falls back to the native
    // child-process path.
    launchInProcessEarly(this.context as common.UIAbilityContext);
  }

  onConfigurationUpdate(config: Configuration) {
  }

  /**
   * Re-launch of an already-running app (launchType = singleton).
   *
   * Tap the icon again, or open an ssh://…/electerm://… link while electerm
   * is in the background: the system reuses THIS instance instead of starting
   * a second one, so onCreate/onWindowStageCreate do NOT run again — which is
   * exactly what we want, because a second instance would try to bind
   * 127.0.0.1:5577 a second time and fight the first one over the nedb data
   * dir. Nothing to do here beyond logging: the window is brought back to the
   * foreground by the system.
   */
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    const uri: string = want.uri ? want.uri : '(none)';
    hilog.info(DOMAIN, TAG, 'onNewWant: reusing running instance uri=%{public}s', uri);
  }

  onWindowStageCreate(windowStage: window.WindowStage) {
    // loadContent FIRST, permissions AFTER.
    //
    // Awaiting requestPermissionsFromUser() before loadContent() means the
    // window shows nothing but its splash until the user answers the dialog.
    // On an unattended device (cloud debugging / 云调试, CI smoke runs) nobody
    // taps "Allow", so the app sat on the splash screen indefinitely and the
    // input-dispatch watchdog eventually killed it as APP_INPUT_BLOCK.
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
        return;
      }
      // ArkWeb engine init + ArkUI tree are done; Index.aboutToAppear() has run
      // (or is running) by now — its own milestone follows immediately after.
    });

    // Request permissions in the background. Index requests them again via
    // its own context when it needs to write user-visible files; a granted
    // permission here just avoids the dialogs appearing later.
    this.requestAllPermissions();
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
