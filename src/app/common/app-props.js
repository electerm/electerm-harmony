/**
 * app path — HarmonyOS only.
 *
 * On HarmonyOS, appData (filesDir) serves as both the app data directory
 * and the home directory. There is no separate home concept or portable mode.
 */
const { app } = require('electron')
const { resolve } = require('path')
const constants = require('./runtime-constants')

const appDataPath = app.getPath('appData')

module.exports = {
  appPath: appDataPath,
  isPortable: false,
  exePath: '',
  sshKeysPath: resolve(appDataPath, '.ssh'),
  homeOrTmp: appDataPath,
  ...constants
}
