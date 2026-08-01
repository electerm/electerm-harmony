/**
 * multi language support
 */

const { isDev, defaultLang } = require('../common/runtime-constants')
const { resolve } = require('path')

function getOsLocale () {
  // os-locale-s relies on shell commands (`locale`, `defaults`, PowerShell)
  // that are unavailable in the HarmonyOS sandbox, so it always fell back to
  // "en_US". Instead, bootstrap.js exports the HarmonyOS system locale
  // detected natively (@ohos.intl) through process.env.LANG — read the locale
  // environment directly here. The order matches the POSIX convention that
  // os-locale-s itself used.
  const envLocale = process.env.LC_ALL || process.env.LC_MESSAGES || process.env.LANG || process.env.LANGUAGE || ''
  // lowercase + strip the codeset suffix, e.g. "zh_CN.UTF-8" → "zh_cn".
  // Must be lowercase to match the regexes in @electerm/electerm-locales
  // (e.g. "zh(_|-)cn").
  return envLocale.split('.')[0].trim().toLowerCase()
}

async function loadLocales () {
  const sysLocale = await getOsLocale() || defaultLang
  const path = (isDev
    ? '../../'
    : '') +
    '../node_modules/@electerm/electerm-locales/dist/cjs'
  const localeFolder = resolve(__dirname, path)
  // languages array
  const langs = require(resolve(localeFolder, 'list.json'))
    .map(fileName => {
      const filePath = resolve(localeFolder, fileName)
      const lang = require(filePath)
      return {
        path: filePath,
        id: fileName.replace('.js', ''),
        name: lang.name,
        reg: lang.match,
        lang: lang.lang
      }
    })
  const langMap = langs.reduce((prev, l) => {
    prev[l.id] = l
    return prev
  }, {})
  return {
    langs,
    langMap,
    sysLocale
  }
}

function findLang (langs, la) {
  let res = false
  for (const l of langs) {
    res = new RegExp(l.reg).test(la)
    if (res) {
      res = l.id
      break
    }
  }
  return res
}

const getLang = (config, sysLocale, langs) => {
  if (config.language) {
    return config.language
  }
  let l = sysLocale
  l = l ? l.toLowerCase().replace('-', '_') : defaultLang
  return findLang(langs, l) || defaultLang
}

exports.getLang = getLang
exports.loadLocales = loadLocales
