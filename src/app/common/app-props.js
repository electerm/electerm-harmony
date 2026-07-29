/**
 * app path — HarmonyOS only.
 *
 * bootstrap.js sets process.env.DATA_PATH (the app's sandbox data
 * directory) and overrides os.homedir() before loading app.js,
 * so this module simply uses it as the base for all derived paths.
 */
const { resolve } = require('path')
const fs = require('fs')
const constants = require('./runtime-constants')

function getAppDataPath () {
  return process.env.DATA_PATH || resolve(__dirname, '../../data')
}

const appDataPath = getAppDataPath()
const sshKeysPath = resolve(appDataPath, '.ssh')
// Create immediately so SSH key reads/writes never fail on a missing dir.
try { fs.mkdirSync(sshKeysPath, { recursive: true, mode: 0o700 }) } catch {}

module.exports = {
  appPath: appDataPath,
  isPortable: false,
  exePath: '',
  sshKeysPath,
  homeOrTmp: constants.homeDir,
  ...constants
}
