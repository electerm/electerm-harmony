/**
 * db loader
 * Uses nedb (pure JS, no native dependencies).
 */

const { appPath, defaultUserName } = require('../common/app-props')
const { safeEncrypt, safeDecrypt } = require('./safe-storage')

const encOpts = { enc: safeEncrypt, dec: safeDecrypt }

const { createDb } = require('./nedb')
const db = createDb(appPath, defaultUserName, encOpts)
module.exports = db
