/**
 * db loader
 * Provides electron-related environment to nedb/sqlite modules
 * Falls back to nedb (pure JS) if node:sqlite is not available (e.g. HarmonyOS)
 */

const { appPath, defaultUserName } = require('../common/app-props')
const { safeEncrypt, safeDecrypt } = require('./safe-storage')

const encOpts = { enc: safeEncrypt, dec: safeDecrypt }

function trySqlite () {
  try {
    require('node:sqlite')
    const { createDb } = require('./sqlite')
    return createDb(appPath, defaultUserName, encOpts)
  } catch (e) {
    console.warn('node:sqlite not available, falling back to nedb:', e?.message || e)
    return null
  }
}

let db = null
if (process.versions.node >= '22.0.0') {
  db = trySqlite()
}
if (!db) {
  const { createDb } = require('./nedb')
  db = createDb(appPath, defaultUserName, encOpts)
}
module.exports = db
