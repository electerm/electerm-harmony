const { dbAction } = require('./db')
const defaultSetting = require('../common/config-default')
const getPort = require('./get-port')
const { userConfigId, userNoEncryptConfigId } = require('../common/constants')
const generate = require('../common/uid')
const globalState = require('./glob-state')
const dlog = require('../common/debug-logger')
const { isHarmony } = require('../common/runtime-constants')

exports.getConfig = async (inited) => {
  dlog('get-config: getConfig START, inited:', inited)
  dlog('get-config: calling dbAction findOne userConfig...')
  const userConfig = await dbAction('data', 'findOne', {
    _id: userConfigId
  }) || {}
  dlog('get-config: dbAction findOne done, keys:', Object.keys(userConfig).length)
  const requireAuth = userConfig.hashedPassword
  delete userConfig._id
  delete userConfig.host
  delete userConfig.terminalTypes
  delete userConfig.tokenElecterm
  delete userConfig.hashedPassword
  delete userConfig.salt
  const port = inited
    ? globalState.get('config').port
    : await getPort()
  dlog('get-config: port resolved:', port)
  const config = {
    ...defaultSetting,
    ...userConfig,
    requireAuth,
    port,
    tokenElecterm: inited ? globalState.get('config').tokenElecterm : generate()
  }
  // On HarmonyOS, always use the system title bar to avoid:
  // 1. Double title bar (HarmonyOS system title bar + web app custom title bar)
  // 2. SIGSEGV crash from transparent window (not supported by HarmonyOS compositor)
  if (isHarmony) {
    config.useSystemTitleBar = true
  }
  return {
    userConfig,
    config
  }
}

exports.getDbConfig = async () => {
  const userConfig = await dbAction('data', 'findOne', {
    _id: userConfigId
  }) || {}
  return userConfig
}

exports.getUserConfigNoEnc = async () => {
  const userConfig = await dbAction('data', 'findOne', {
    _id: userNoEncryptConfigId
  }) || {}
  return userConfig
}
