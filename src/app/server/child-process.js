/**
 * run server in child process
 *
 */

const { fork } = require('child_process')
const { resolve } = require('path')
const { writeFileSync, unlinkSync } = require('fs')
const { tmpdir } = require('os')
const { join } = require('path')
const log = require('../common/log')
const dlog = require('../common/debug-logger')
const getSystemCAs = require('../lib/system-ca')

// --use-system-ca is supported since Node.js 24.3.0
function supportsSystemCa () {
  const [major, minor] = process.versions.node.split('.').map(Number)
  return major > 24 || (major === 24 && minor >= 3)
}

module.exports = (config, env, sysLocale) => {
  dlog('child-process: START')
  const nodeOpts = [env.NODE_OPTIONS, supportsSystemCa() ? '--use-system-ca' : '']
    .filter(Boolean).join(' ').trim()
  dlog('child-process: nodeOpts:', nodeOpts)

  // Load system-trusted CA certificates and pass to child process
  // via NODE_EXTRA_CA_CERTS so Node.js extends its trust store natively.
  let extraCaFile
  const systemCAs = getSystemCAs()
  if (systemCAs) {
    extraCaFile = join(tmpdir(), `electerm-system-ca-${Date.now()}.pem`)
    writeFileSync(extraCaFile, systemCAs)
    dlog('child-process: wrote system CA file:', extraCaFile)
  }

  // Clean Electron-specific env vars from child process environment
  const cleanEnv = Object.assign({}, env)
  delete cleanEnv.ELECTRON_RUN_AS_NODE

  const serverPath = resolve(__dirname, './server.js')
  dlog('child-process: forking server:', serverPath, 'port:', config.port)
  log.info('Forking server:', serverPath, 'port:', config.port)

  // start server — fork() takes (modulePath, args, options), NOT a callback
  const child = fork(serverPath, [], {
    env: Object.assign(
      {
        LANG: `${sysLocale.replace(/-/, '_')}.UTF-8`,
        electermPort: config.port,
        electermHost: config.host || '127.0.0.1',
        requireAuth: config.requireAuth || '',
        tokenElecterm: config.tokenElecterm,
        sshKeysPath: env.sshKeysPath,
        NODE_OPTIONS: nodeOpts || undefined,
        NODE_EXTRA_CA_CERTS: extraCaFile || undefined
      },
      cleanEnv
    ),
    cwd: process.cwd(),
    stdio: ['pipe', 'pipe', 'pipe', 'ipc']
  })

  // Log child process output for debugging
  child.stdout.on('data', (data) => {
    const text = data.toString().trim()
    dlog('[server stdout]', text)
    log.info('[server]', text)
  })
  child.stderr.on('data', (data) => {
    const text = data.toString().trim()
    dlog('[server stderr]', text)
    log.error('[server stderr]', text)
  })

  dlog('child-process: child forked, pid:', child.pid)

  if (extraCaFile) {
    child.on('exit', () => {
      try { unlinkSync(extraCaFile) } catch {}
    })
  }

  return child
}
