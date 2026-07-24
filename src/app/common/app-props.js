/**
 * app path — HarmonyOS + desktop fallback.
 *
 * On HarmonyOS, bootstrap.js sets process.env.DATA_PATH before loading app.js.
 * On desktop dev/prod, we fall back to Electron's appData path or os.homedir().
 */
const { resolve } = require('path')
const os = require('os')
const fs = require('fs')
const constants = require('./runtime-constants')

function getAppDataPath () {
  // 1. DATA_PATH env var (set by bootstrap.js on HarmonyOS)
  if (process.env.DATA_PATH) {
    return process.env.DATA_PATH
  }
  // 2. Electron's app.getPath('appData') — available in main process
  try {
    const { app } = require('electron')
    const p = app.getPath('appData')
    return p
  } catch (e) {
    // 3. Fallback: ~/.electerm
    const home = os.homedir()
    const p = resolve(home, '.electerm')
    try { fs.mkdirSync(p, { recursive: true }) } catch {}
    return p
  }
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
