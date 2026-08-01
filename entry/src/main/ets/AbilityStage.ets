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

    // Detect the HarmonyOS system locale natively and write it to a marker
    // file BEFORE the Electron runtime starts. os-locale-s's shell-based
    // detection (`locale` command) does not work in the HarmonyOS sandbox, so
    // bootstrap.js reads this marker and exports it as process.env.LANG, which
    // locales.js consumes directly. Format is "<lang>-<REGION>" (e.g. "zh-CN")
    // so it normalizes to "zh_cn" and matches the language regexes — we omit
    // the script subtag (e.g. "Hans") on purpose, since "zh_Hans_CN" would not
    // match the "zh(_|-)cn" pattern.
    //
    // IMPORTANT: we read the system language/region via @ohos.i18n
    // (System.getSystemLanguage / getSystemRegion). The earlier approach using
    // `new Intl.Locale()` with no argument does NOT reliably reflect the
    // device's system language on real HarmonyOS devices — on cloud-debug
    // devices it returned an empty/default ("en") locale, so the UI stayed
    // English even when the device language was Chinese. @ohos.i18n.System is
    // the canonical, reliable API for the *system* (not app-process) locale.
    try {
      const sysLang: string = i18n.System.getSystemLanguage() || '';
      // getSystemLanguage() returns a BCP-47 tag such as "zh-Hans-CN" or
      // "en-US". Take only the primary language subtag (drop the script like
      // "Hans" so the value matches the "zh(_|-)cn" regex downstream).
      const lang: string = sysLang.split(/[-_]/)[0].toLowerCase();
      const region: string = (i18n.System.getSystemRegion() || '').toUpperCase();
      const localeStr: string = region ? `${lang}-${region}` : lang;
      if (localeStr) {
        const localeMarkerPath: string = `${filesDir}/.electerm-locale`;
        const lf = fs.openSync(localeMarkerPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
        fs.writeSync(lf.fd, localeStr);
        fs.closeSync(lf);
        console.info(`[${TAG}] wrote locale marker: ${localeMarkerPath} → ${localeStr} (from getSystemLanguage="${sysLang}", region="${region}")`);
      } else {
        console.warn(`[${TAG}] resolved empty locale (getSystemLanguage="${sysLang}"), skipping marker`);
      }
    } catch (e) {
      console.error(`[${TAG}] failed to write locale marker: ${JSON.stringify(e)}`);
    }
  }
}
