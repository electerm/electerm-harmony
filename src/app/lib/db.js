/**
 * db loader
 * Provides electron-related environment to nedb/sqlite modules
 * Falls back to nedb (pure JS) if node:sqlite is not available (e.g. HarmonyOS)
 */

const { appPath, defaultUserName } = require('../common/app-props')
const { safeEncrypt, safeDecrypt } = require('./safe-storage')
const dlog = require('../common/debug-logger')

const encOpts = { enc: safeEncrypt, dec: safeDecrypt }

function trySqlite () {
  dlog('db.js: trying node:sqlite...')
  try {
    require('node:sqlite')
    const { createDb } = require('./sqlite')
    dlog('db.js: node:sqlite available, creating db...')
    const result = createDb(appPath, defaultUserName, encOpts)
    dlog('db.js: sqlite db created')
    return result
  } catch (e) {
    dlog('db.js: node:sqlite not available:', e?.message || e)
    console.warn('node:sqlite not available, falling back to nedb:', e?.message || e)
    return null
  }
}

let db = null
dlog('db.js: node version:', process.versions.node)
if (process.versions.node >= '22.0.0') {
  db = trySqlite()
}
if (!db) {
  dlog('db.js: using nedb...')
  const { createDb } = require('./nedb')
  db = createDb(appPath, defaultUserName, encOpts)
  dlog('db.js: nedb db created')
}
module.exports = db
