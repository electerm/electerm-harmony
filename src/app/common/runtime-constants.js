/**
 * run time contants
 */

const os = require('os')
const { resolve } = require('path')

const platform = os.platform()
const arch = os.arch()
const isWin = platform === 'win32'
const isMac = platform === 'darwin'
const isLinux = platform === 'linux'
const isArm = arch.includes('arm')
// HarmonyOS detection: bootstrap.js (HarmonyOS entry point) sets process.env.DATA_PATH
// before requiring app.js. This env var is only set on HarmonyOS.
const isHarmony = !!process.env.DATA_PATH && process.platform === 'linux'

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

module.exports = {
  isTest: !!NODE_TEST,
  isDev,
  isWin,
  isMac,
  isArm,
  isLinux,
  isHarmony,
  iconPath,
  trayIconPath,
  extIconPath,
  defaultUserName,
  minWindowWidth: 590,
  minWindowHeight: 400,
  defaultLang: 'en_us',
  tempDir: require('os').tmpdir(),
  packInfo: require(isDev ? '../../../package.json' : '../package.json')
}
