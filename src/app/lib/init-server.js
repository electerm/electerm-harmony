/**
 * server init script
 */

const createChildServer = require('../server/child-process')
const globalState = require('./glob-state')
const log = require('../common/log')
const dlog = require('../common/debug-logger')

const SERVER_TIMEOUT = 15000 // 15 seconds

module.exports = async (config, env, sysLocale) => {
  dlog('init-server: START, port:', config.port, 'host:', config.host)
  return new Promise((resolve, reject) => {
    let resolved = false
    let timer = null

    dlog('init-server: creating child process...')
    const child = createChildServer(config, env, sysLocale)
    dlog('init-server: child created, pid:', child.pid)

    timer = setTimeout(() => {
      if (!resolved) {
        resolved = true
        dlog('init-server: TIMEOUT after', SERVER_TIMEOUT, 'ms')
        log.error('Server init timed out after', SERVER_TIMEOUT, 'ms')
        try { child.kill() } catch {}
        reject(new Error('Server init timed out'))
      }
    }, SERVER_TIMEOUT)

    child.on('exit', (code, signal) => {
      dlog('init-server: child EXIT, code:', code, 'signal:', signal)
      log.error('Child server exited, code:', code, 'signal:', signal)
      globalState.set('childPid', null)
      if (!resolved) {
        resolved = true
        if (timer) clearTimeout(timer)
        reject(new Error(`Server process exited with code ${code} signal ${signal}`))
      }
    })

    child.on('error', (err) => {
      dlog('init-server: child ERROR:', err.message || err)
      log.error('Child server error:', err.message || err)
      if (!resolved) {
        resolved = true
        if (timer) clearTimeout(timer)
        reject(err)
      }
    })

    globalState.set('childPid', child.pid)
    child.on('message', (m) => {
      dlog('init-server: child message:', JSON.stringify(m))
      if (m && m.serverInited && !resolved) {
        resolved = true
        dlog('init-server: serverInited received, resolving')
        if (timer) clearTimeout(timer)
        resolve(child)
      }
    })
  })
}
