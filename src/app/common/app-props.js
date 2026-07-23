/**
 * app path — HarmonyOS only.
 *
 * On HarmonyOS, appData (filesDir) serves as both the app data directory
 * and the home directory. There is no separate home concept or portable mode.
 *
 * bootstrap.js sets process.env.DATA_PATH before loading app.js.
 */
const { resolve } = require('path')
const constants = require('./runtime-constants')

const appDataPath = process.env.DATA_PATH

module.exports = {
  appPath: appDataPath,
  isPortable: false,
  exePath: '',
  sshKeysPath: resolve(appDataPath, '.ssh'),
  homeOrTmp: appDataPath,
  ...constants
}
