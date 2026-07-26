/**
 * Start the main Express server in-process.
 *
 * No child process — everything runs in the same Node.js/Electron process.
 * Returns a mock "child" object with EventEmitter interface for compatibility
 * with init-server.js.
 */

const EventEmitter = require('events')
const log = require('../common/log')
const dlog = require('../common/debug-logger')

// --use-system-ca is supported since Node.js 24.3.0
function supportsSystemCa () {
  const [major, minor] = process.versions.node.split('.').map(Number)
  return major > 24 || (major === 24 && minor >= 3)
}

module.exports = (config, env, sysLocale) => {
  dlog('child-process: START, port:', config.port, 'host:', config.host)

  // Set environment variables that server.js reads
  process.env.electermPort = String(config.port)
  process.env.electermHost = config.host || '127.0.0.1'
  process.env.requireAuth = config.requireAuth || ''
  process.env.tokenElecterm = config.tokenElecterm
  process.env.sshKeysPath = env.sshKeysPath
  process.env.LANG = `${sysLocale.replace(/-/, '_')}.UTF-8`

  // Handle system CAs
  const nodeOpts = [env.NODE_OPTIONS, supportsSystemCa() ? '--use-system-ca' : '']
    .filter(Boolean).join(' ').trim()
  if (nodeOpts) {
    process.env.NODE_OPTIONS = nodeOpts
  }

  // Create a mock child object for init-server.js compatibility
  const child = new EventEmitter()
  child.pid = process.pid
  child.killed = false
  child.stdout = { on: () => {} }
  child.stderr = { on: () => {} }
  child.kill = () => {
    child.killed = true
    dlog('child-process: kill() called')
    child.emit('exit', 0, 'SIGTERM')
    return true
  }
  child.send = (msg) => {
    child.emit('message', msg)
    return true
  }

  // Require server.js (auto-starts) and wait for it to be ready
  dlog('child-process: requiring server.js...')
  try {
    const { startServer } = require('./server')
    startServer().then(() => {
      dlog('child-process: server started, emitting serverInited')
      child.emit('message', { serverInited: true })
    }).catch(err => {
      dlog('child-process: server start error:', err.message)
      child.emit('error', err)
    })
  } catch (err) {
    dlog('child-process: require server.js ERROR:', err.message, err.stack)
    setImmediate(() => {
      child.emit('error', err)
    })
  }

  log.info('Server starting in-process, port:', config.port)
  return child
}
