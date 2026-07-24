/**
 * on close app
 */

const { dbAction } = require('./db')
const log = require('../common/log')
const globalState = require('./glob-state')

exports.getExitStatus = async () => {
  const res = await dbAction('data', 'findOne', {
    _id: 'exitStatus'
  })
  return res && res.value ? res.value : ''
}

exports.onClose = async function (e) {
  const config = globalState.get('config')
  if (config.confirmBeforeExit && globalState.get('closeAction')) {
    const win = globalState.get('win')
    win?.webContents.send(
      'confirm-exit',
      globalState.get('closeAction')
    )
    globalState.set('closeAction', '')
    return e.preventDefault()
  }
  log.debug('Closing app')
  // Clean up all terminal sessions
  try {
    const { cleanupTerminals } = require('../server/session-process')
    cleanupTerminals()
  } catch (e) {}
  // Kill the main server mock
  const child = globalState.get('child')
  if (child && typeof child.kill === 'function') {
    try { child.kill() } catch (e) {}
  }
  globalState.set('serverInited', false)
  log.debug('Sessions and server cleaned up')
  // await dbAction('data', 'update', {
  //   _id: 'exitStatus'
  // }, {
  //   value: 'ok',
  //   _id: 'exitStatus'
  // }, {
  //   upsert: true
  // })
  // await dbAction('data', 'update', {
  //   _id: 'sessions'
  // }, {
  //   value: null,
  //   _id: 'sessions'
  // }, {
  //   upsert: true
  // })
  // log.debug('session saved')
  clearTimeout(globalState.get('timer'))
  globalState.set('win', null)
  const app = globalState.get('app')
  app.quit && app.quit()
}
