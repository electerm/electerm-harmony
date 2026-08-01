/**
 * multi language support
 */

const { isDev, defaultLang } = require('../common/runtime-constants')
const { resolve } = require('path')
const fs = require('fs')

function getOsLocale () {
  // On HarmonyOS the only meaningful source of the system locale is the
  // native marker file (.electerm-locale) written by AbilityStage.ets via
  // @ohos.i18n before the Electron runtime starts. The Node/Electron
  // process.env.LANG is NOT a reliable indicator here: when native detection
  // has not populated it, the runtime leaves an English default ("en_US"/"C")
  // that would force the wrong language even on a Chinese system. So read the
  // marker file directly — a missing marker falls through to the empty string
  // (and then to defaultLang), never to a misleading English env value.
  if (process.env.DATA_PATH) {
    try {
      const marker = resolve(process.env.DATA_PATH, '.electerm-locale')
      const data = fs.readFileSync(marker, 'utf8').trim()
      if (data) {
        // lowercase + strip the codeset suffix, e.g. "zh-CN.UTF-8" → "zh-cn".
        // Must be lowercase to match the regexes in @electerm/electerm-locales
        // (e.g. "zh(_|-)cn").
        return data.split('.')[0].trim().toLowerCase()
      }
    } catch (e) { /* marker absent — fall through */ }
  }
  // Dev / non-HarmonyOS fallback: conventional POSIX env vars.
  const envLocale = process.env.LC_ALL || process.env.LC_MESSAGES || process.env.LANG || process.env.LANGUAGE || ''
  return envLocale ? envLocale.split('.')[0].trim().toLowerCase() : ''
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
