/**
 * Window chrome — the two system-bar strips that live OUTSIDE the app layout.
 *
 * HarmonyOS lays the app content out inside the safe area only, so the
 * status-bar strip (top) and the navigation-bar strip (bottom) are painted by
 * the *window* background, not by the app UI. Left unset that background
 * follows the **system** light/dark mode (`#FFF0F0F0` / `#FF1A1A1A` per
 * @ohos.window.d.ts), and the system-bar foreground defaults to near-white
 * `#E5FFFFFF` — so a dark electerm theme on a light-mode phone shows two blank
 * white bars with an invisible clock.
 *
 * Two callers paint it:
 *   - EntryAbility, once at startup, with BOOT_* below (a placeholder that
 *     matches the splash, so cold start has no colour jump);
 *   - NativeBridge.setWindowChrome, whenever the web UI reports a new theme
 *     (see build-src/replace/client/web-components/window-chrome.js), which is
 *     what makes the bars actually follow the theme.
 */

import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'ElectermWindowChrome';
const DOMAIN: number = 0xE1EC;

/**
 * Used until the UI theme reports its own colours.
 * `#15171a` is electerm's "dark slate" splash colour — the same value as
 * rawfile/loading.html and the boot overlay in pages/Index.ets — so the window
 * does not change colour between the splash and the first paint.
 */
export const BOOT_BACKGROUND_COLOR: string = '#FF15171A';
export const BOOT_FOREGROUND_COLOR: string = '#FFFFFFFF';

/** '#RRGGBB' or '#AARRGGBB' — the only forms the window APIs accept. */
const COLOR_PATTERN: RegExp = new RegExp('^#(?:[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$');

/** True when `value` is a colour string the window APIs will accept. */
export function isWindowColor(value: string): boolean {
  return !!value && COLOR_PATTERN.test(value);
}

/**
 * Paint both strips: `background` for the strip itself, `foreground` for the
 * clock / battery / gesture pill drawn on it.
 *
 * `setWindowBackgroundColor` is the call that actually removes the white bars
 * (the strips are part of the window, not of the Web component);
 * `setWindowSystemBarProperties` recolours the content and the bar backgrounds
 * so the two layers agree. It is documented as having no effect on 2-in-1
 * devices, which is harmless here — the window background still applies.
 */
export function paintWindowChrome(win: window.Window, background: string, foreground: string): void {
  try {
    win.setWindowBackgroundColor(background);
  } catch (e) {
    hilog.error(DOMAIN, TAG, 'setWindowBackgroundColor(%{public}s) failed: %{public}s',
      background, JSON.stringify(e));
  }
  win.setWindowSystemBarProperties({
    statusBarColor: background,
    navigationBarColor: background,
    statusBarContentColor: foreground,
    navigationBarContentColor: foreground
  }).then(() => {
    hilog.info(DOMAIN, TAG, 'window chrome painted: bg=%{public}s fg=%{public}s', background, foreground);
  }).catch((e: BusinessError) => {
    hilog.warn(DOMAIN, TAG, 'setWindowSystemBarProperties failed: %{public}s', JSON.stringify(e));
  });
}
