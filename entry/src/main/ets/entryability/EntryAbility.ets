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
import { BusinessError } from '@kit.BasicServicesKit';
import { Environment } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BackendManager } from '../BackendManager';
import { launchInProcessEarly } from '../BackendLauncher';

const TAG: string = 'ElectermEntryAbility';
const DOMAIN: number = 0xE1EC;

/**
 * Window chrome colours — must stay in sync with the app's dark default theme
 * (the boot overlay in pages/Index.ets uses the same #15171a).
 *
 * Why this is needed at all: HarmonyOS lays the app content out inside the
 * *safe area* only, so the status-bar strip (top) and the navigation-bar strip
 * (bottom) are not part of the app's layout box. Those two strips are painted
 * by the WINDOW background, whose default is '#FFF0F0F0' in light system mode
 * (see @ohos.window.d.ts, setWindowBackgroundColor) — and it follows the
 * *system* colour mode, not the app theme. On a light-mode phone that renders
 * as two blank white bars around the dark electerm UI. The system-bar content
 * (clock, battery, gesture bar) defaults to '#E5FFFFFF', i.e. near-white, so it
 * is invisible against that light strip — which is why the bars look empty.
 */
const WINDOW_BG_COLOR: string = '#FF15171A';
/** System-bar foreground: light, so clock/battery/gesture bar read on dark. */
const SYSTEM_BAR_CONTENT_COLOR: string = '#FFFFFFFF';

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
      //
      // Window chrome is applied HERE, not before loadContent: in the stage
      // model setWindowBackgroundColor() does not take effect until
      // loadContent() has taken effect.
      this.applyDarkWindowChrome(windowStage);
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
   * Paint the two system avoid areas to match the app's dark UI.
   *
   * HarmonyOS lays the app content out inside the safe area only, so the
   * status-bar strip (top) and the navigation-bar strip (bottom) are painted by
   * the window background — default '#FFF0F0F0' in light system mode, following
   * the *system* colour mode rather than the app theme. On a light-mode phone
   * that is two blank white bars around the dark terminal. The system-bar
   * foreground defaults to near-white ('#E5FFFFFF'), so the clock/battery are
   * invisible against that strip and the bars read as completely empty.
   *
   * Must run AFTER loadContent has taken effect (stage model requirement for
   * setWindowBackgroundColor).
   */
  private applyDarkWindowChrome(windowStage: window.WindowStage): void {
    try {
      this.paintWindowChrome(windowStage.getMainWindowSync());
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'window chrome: getMainWindowSync failed: %{public}s', JSON.stringify(e));
    }
  }

  private paintWindowChrome(mainWindow: window.Window): void {
    // 1. Window background — this is the layer that shows through the
    //    status-bar and navigation-bar strips, so it is the one that actually
    //    removes the white bars.
    try {
      mainWindow.setWindowBackgroundColor(WINDOW_BG_COLOR);
      hilog.info(DOMAIN, TAG, 'window background set to %{public}s', WINDOW_BG_COLOR);
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'setWindowBackgroundColor failed: %{public}s', JSON.stringify(e));
    }

    // 2. System bars: dark background to match, light foreground so the clock,
    //    battery and gesture bar stay readable. Without the content colours the
    //    bars would be dark-on-dark and would still look empty.
    mainWindow.setWindowSystemBarProperties({
      statusBarColor: WINDOW_BG_COLOR,
      navigationBarColor: WINDOW_BG_COLOR,
      statusBarContentColor: SYSTEM_BAR_CONTENT_COLOR,
      navigationBarContentColor: SYSTEM_BAR_CONTENT_COLOR
    }).then(() => {
      hilog.info(DOMAIN, TAG, 'system bar properties applied');
    }).catch((e: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'setWindowSystemBarProperties failed: %{public}s', JSON.stringify(e));
    });
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
