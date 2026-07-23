/**
 * multi language support
 */

const { isDev, defaultLang } = require('../common/runtime-constants')
const { resolve } = require('path')
const dlog = require('../common/debug-logger')

function getOsLocale () {
  dlog('locales: calling os-locale-s...')
  return require('os-locale-s')
    .osLocale()
    .then(loc => {
      dlog('locales: os-locale-s returned:', loc)
      return loc
    })
    .catch((e) => {
      dlog('locales: os-locale-s failed:', e?.message || e)
      return ''
    })
}

async function loadLocales () {
  dlog('locales: loadLocales START')
  const sysLocale = await getOsLocale() || defaultLang
  dlog('locales: sysLocale:', sysLocale)
  const path = (isDev
    ? '../../'
    : '') +
    '../node_modules/@electerm/electerm-locales/dist/cjs'
  const localeFolder = resolve(__dirname, path)
  dlog('locales: localeFolder:', localeFolder)
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
  dlog('locales: loaded', langs.length, 'languages')
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
