/**
 * server init script
 *
 * Starts the Express server in-process (no child process).
 * Returns a promise that resolves when the server reports ready.
 */

const createChildServer = require('../server/child-process')
const globalState = require('./glob-state')
const log = require('../common/log')

const SERVER_TIMEOUT = 15000 // 15 seconds

module.exports = async (config, env, sysLocale) => {
  return new Promise((resolve, reject) => {
    let resolved = false
    let timer = null

    const child = createChildServer(config, env, sysLocale)

    timer = setTimeout(() => {
      if (!resolved) {
        resolved = true
        log.error('Server init timed out after', SERVER_TIMEOUT, 'ms')
        try { child.kill() } catch {}
        reject(new Error('Server init timed out'))
      }
    }, SERVER_TIMEOUT)

    child.on('exit', (code, signal) => {
      if (!resolved) {
        resolved = true
        if (timer) clearTimeout(timer)
        reject(new Error(`Server exited with code ${code} signal ${signal}`))
      }
    })

    child.on('error', (err) => {
      if (!resolved) {
        resolved = true
        if (timer) clearTimeout(timer)
        reject(err)
      }
    })

    globalState.set('childPid', child.pid)
    globalState.set('child', child)

    child.on('message', (m) => {
      if (m && m.serverInited && !resolved) {
        resolved = true
        if (timer) clearTimeout(timer)
        resolve(child)
      }
    })
  })
}
