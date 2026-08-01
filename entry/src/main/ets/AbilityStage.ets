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
import i18n from '@ohos.i18n';
import Intl from '@ohos.intl';

const TAG: string = 'ElectermAbilityStage';

// Resolve the HarmonyOS system locale, trying every available API so that a
// single failing/deprecated API never leaves us without a value. Returns the
// locale in "<lang>-<REGION>" form (e.g. "zh-CN"), or "" if all sources fail.
function resolveSystemLocale (): string {
  let lang: string = '';
  let region: string = '';

  // 1. Preferred: @ohos.i18n.System static API (@since 9).
  try {
    const sysLang: string = i18n.System.getSystemLanguage() || '';
    if (sysLang) {
      // getSystemLanguage() returns a BCP-47 tag such as "zh-Hans-CN".
      // Take only the primary language subtag — drop the script ("Hans")
      // because "zh_Hans_CN" would not match the "zh(_|-)cn" regex downstream.
      lang = sysLang.split(/[-_]/)[0].toLowerCase();
      try {
        region = (i18n.System.getSystemRegion() || '').toUpperCase();
      } catch (e) { /* region optional */ }
    }
  } catch (e) {
    // 2. Fallback: namespace-level i18n API (deprecated alias, @since 7).
    try {
      const sysLang: string = i18n.getSystemLanguage() || '';
      if (sysLang) {
        lang = sysLang.split(/[-_]/)[0].toLowerCase();
        try {
          region = (i18n.getSystemRegion() || '').toUpperCase();
        } catch (e2) { /* region optional */ }
      }
    } catch (e2) { /* fall through */ }
  }

  // 3. Last resort: Intl.Locale with no argument.
  if (!lang) {
    try {
      const loc = new Intl.Locale();
      lang = (loc.language || '').toLowerCase();
      region = (loc.region || '').toUpperCase();
    } catch (e) { /* fall through */ }
  }

  return region ? `${lang}-${region}` : lang;
}

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

    // Detect the HarmonyOS system locale natively and write it to a marker
    // file BEFORE the Electron runtime starts. os-locale-s's shell-based
    // detection (`locale` command) does not work in the HarmonyOS sandbox, so
    // bootstrap.js / locales.js read this marker instead. Format written is
    // "<lang>-<REGION>" (e.g. "zh-CN"), which normalizes to "zh_cn" and
    // matches the language regexes — we omit the script subtag (e.g. "Hans")
    // on purpose, since "zh_Hans_CN" would not match the "zh(_|-)cn" pattern.
    try {
      const localeStr: string = resolveSystemLocale();
      if (localeStr) {
        const localeMarkerPath: string = `${filesDir}/.electerm-locale`;
        const lf = fs.openSync(localeMarkerPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
        fs.writeSync(lf.fd, localeStr);
        fs.closeSync(lf);
      }
    } catch (e) { /* ignore */ }
  }
}
