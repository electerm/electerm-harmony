/**
 * run time contants
 */

const os = require('os')
const fs = require('fs')
const { resolve } = require('path')

const platform = os.platform()
const arch = os.arch()
const isWin = platform === 'win32'
const isMac = platform === 'darwin'
const isLinux = platform === 'linux'
const isArm = arch.includes('arm')

const { NODE_ENV, NODE_TEST } = process.env
const isDev = NODE_ENV === 'development'
const iconPath = resolve(
  __dirname,
  (
    isDev
      ? '../../../node_modules/@electerm/electerm-resource/res/imgs/electerm-round-128x128.png'
      : '../assets/images/electerm-round-128x128.png'
  )
)
const trayIconPath = resolve(
  __dirname,
  (
    isDev
      ? '../../../node_modules/@electerm/electerm-resource/tray-icons/electerm-tray.png'
      : '../assets/images/electerm-tray.png'
  )
)
const extIconPath = isDev
  ? '/node_modules/electerm-icons/icons/'
  : 'icons/'

const defaultUserName = require('./default-user-name')

/**
 * bootstrap.js overrides os.homedir() to return the app's sandbox data
 * directory (DATA_PATH), so getHomeDir() simply delegates to it.
 * os.tmpdir() may still point outside the sandbox, so getTempDir()
 * derives a writable tmp/ subdirectory under DATA_PATH.
 */
function getHomeDir () {
  return os.homedir()
}

function getTempDir () {
  if (process.env.DATA_PATH) {
    const dir = resolve(process.env.DATA_PATH, 'tmp')
    // Create immediately so downstream writes never fail on a missing dir.
    try { fs.mkdirSync(dir, { recursive: true }) } catch {}
    return dir
  }
  return os.tmpdir()
}

module.exports = {
  isTest: !!NODE_TEST,
  isDev,
  isWin,
  isMac,
  isArm,
  isLinux,
  iconPath,
  trayIconPath,
  extIconPath,
  defaultUserName,
  minWindowWidth: 590,
  minWindowHeight: 400,
  defaultLang: 'en_us',
  homeDir: getHomeDir(),
  tempDir: getTempDir(),
  packInfo: require(isDev ? '../../../package.json' : '../package.json')
}
