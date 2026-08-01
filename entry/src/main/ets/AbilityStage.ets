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

// Resolve the HarmonyOS system locale. Returns "<lang>-<REGION>" (e.g.
// "zh-CN"), or "" when detection fails — the empty string is intentional:
// downstream then falls back to defaultLang (zh_cn), which is the right
// default for this app. Do NOT add an Intl.Locale fallback here: on Huawei
// cloud-debug devices it returns a bogus default "en" locale even on Chinese
// systems, which forced the UI into English.
function resolveSystemLocale (): string {
  let raw: string = '';
  let region: string = '';

  // 1. Preferred: @ohos.i18n.System static API (@since 9).
  try {
    raw = i18n.System.getSystemLanguage() || '';
    if (raw) {
      try {
        region = (i18n.System.getSystemRegion() || '').toUpperCase();
      } catch (e) { /* region optional */ }
    }
  } catch (e) {
    // 2. Fallback: namespace-level i18n API (deprecated alias, @since 7).
    try {
      raw = i18n.getSystemLanguage() || '';
      if (raw) {
        try {
          region = (i18n.getSystemRegion() || '').toUpperCase();
        } catch (e2) { /* region optional */ }
      }
    } catch (e2) { /* fall through */ }
  }

  // getSystemLanguage() returns a BCP-47 tag such as "zh-Hans-CN". Take only
  // the primary language subtag — drop the script ("Hans") because
  // "zh_Hans_CN" would not match the "zh(_|-)cn" regex downstream.
  const lang: string = raw.split(/[-_]/)[0].toLowerCase();
  console.info(`[${TAG}] system language raw="${raw}", region="${region}"`);

  if (!lang) {
    return '';
  }

  // Chinese: the downstream zh_cn matcher ("zh(-|_)cn|mo|sg") requires a
  // region subtag, and cloud-debug devices often report a missing or odd
  // region. Any Chinese-language system defaults to Simplified Chinese; only
  // an explicit Traditional-Chinese region (TW/HK) gets zh-TW.
  if (lang === 'zh') {
    return ['TW', 'HK'].includes(region) ? `zh-${region}` : 'zh-CN';
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
    // When detection fails (empty string) we deliberately write NO marker so
    // the app falls back to defaultLang (zh_cn) instead of a wrong guess.
    try {
      const localeStr: string = resolveSystemLocale();
      if (localeStr) {
        const localeMarkerPath: string = `${filesDir}/.electerm-locale`;
        const lf = fs.openSync(localeMarkerPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
        fs.writeSync(lf.fd, localeStr);
        fs.closeSync(lf);
        console.info(`[${TAG}] wrote locale marker: ${localeMarkerPath} → ${localeStr}`);
      } else {
        console.warn(`[${TAG}] locale detection failed, no marker written (UI falls back to default zh_cn)`);
      }
    } catch (e) {
      console.error(`[${TAG}] failed to write locale marker: ${JSON.stringify(e)}`);
    }
  }
}
