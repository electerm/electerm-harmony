/**
 * db loader
 * Uses nedb (pure JS, no native dependencies).
 */

const { appPath, defaultUserName } = require('../common/app-props')
const { safeEncrypt, safeDecrypt } = require('./safe-storage')
const dlog = require('../common/debug-logger')

const encOpts = { enc: safeEncrypt, dec: safeDecrypt }

dlog('db.js: using nedb')
const { createDb } = require('./nedb')
const db = createDb(appPath, defaultUserName, encOpts)
dlog('db.js: nedb db created')
module.exports = db
