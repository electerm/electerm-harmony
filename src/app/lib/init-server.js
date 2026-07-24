/**
 * server init script
 *
 * Starts the Express server in-process (no child process).
 * Returns a promise that resolves when the server reports ready.
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

    dlog('init-server: creating server...')
    const child = createChildServer(config, env, sysLocale)
    dlog('init-server: server created, pid:', child.pid)

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
      dlog('init-server: server EXIT, code:', code, 'signal:', signal)
      if (!resolved) {
        resolved = true
        if (timer) clearTimeout(timer)
        reject(new Error(`Server exited with code ${code} signal ${signal}`))
      }
    })

    child.on('error', (err) => {
      dlog('init-server: server ERROR:', err.message || err)
      if (!resolved) {
        resolved = true
        if (timer) clearTimeout(timer)
        reject(err)
      }
    })

    globalState.set('childPid', child.pid)
    globalState.set('child', child)

    child.on('message', (m) => {
      dlog('init-server: server message:', JSON.stringify(m))
      if (m && m.serverInited && !resolved) {
        resolved = true
        dlog('init-server: serverInited received, resolving')
        if (timer) clearTimeout(timer)
        resolve(child)
      }
    })
  })
}
