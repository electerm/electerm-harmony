/**
 * child_process shim for HarmonyOS.
 *
 * The electerm-web backend uses child_process in a handful of places that are
 * desktop-only / non-essential on a mobile device:
 *
 *   - system-ca.js     — execSync('security …') / execSync('powershell …')
 *   - show-item-in-folder.js — exec('open -R …') / exec('xdg-open …')
 *   - session-ssh.js   — exec('echo $DISPLAY') / exec('xauth list :0')  (X11)
 *   - file-transfer.js — spawn('tar', […])  (directory download as tar.gz)
 *   - fs.js            — exec / spawn for openFile, getFolderSize, Windows drives
 *
 * None of these are needed for SSH / SFTP / Telnet / FTP / RDP / VNC / Spice,
 * which are pure-JS / WASM network protocols.  Every call site already has
 * error handling (try/catch or callback error checks), so a shim that
 * **fails gracefully** — invoking callbacks with an Error, emitting 'error'
 * on the returned EventEmitter, or throwing for sync variants — is enough
 * to keep the server running.
 *
 * The shim is injected via esbuild's `alias` option:
 *
 *   alias: { child_process: '/path/to/child-process-shim.mjs' }
 *
 * so every `import { exec } from 'child_process'` in the bundled backend
 * resolves to this file instead of the real Node.js built-in.
 */

import { EventEmitter } from 'node:events'
import { Readable } from 'node:stream'

const TAG = '[child_process shim]'

function disabledError (command) {
  return new Error(
    `${TAG} child_process is disabled on HarmonyOS: attempted "${command}"`
  )
}

/**
 * exec(command, [options], callback)
 *
 * Real signature: returns a ChildProcess; callback receives (error, stdout, stderr).
 * We call the callback with an error and return a dummy EventEmitter so
 * .kill() / .pid accesses don't throw.
 */
export function exec (command, options, callback) {
  if (typeof options === 'function') {
    callback = options
    options = undefined
  }
  const err = disabledError(command)
  if (typeof callback === 'function') {
    // Match Node.js behaviour: callback is called on next tick.
    process.nextTick(() => callback(err, '', ''))
  } else {
    // No callback → caller expects a promise via promisify(exec).
    // promisify wraps the callback-style function, so it will receive the
    // error and reject.  But if someone calls exec() without a callback AND
    // without promisify, the error is silent (same as the real child_process
    // which would emit 'error' on the returned object).
    console.warn(`${TAG} exec called without callback: ${command}`)
  }
  const fake = new EventEmitter()
  fake.pid = -1
  fake.kill = () => true
  fake.stdout = new Readable({ read () {} })
  fake.stderr = new Readable({ read () {} })
  process.nextTick(() => {
    fake.emit('error', err)
    fake.emit('close', 1, null)
  })
  return fake
}

/**
 * execSync(command, [options])
 *
 * Real signature: returns Buffer | string.
 * We throw — every call site wraps this in try/catch already.
 */
export function execSync (command, _options) {
  throw disabledError(command)
}

/**
 * spawn(command, [args], [options])
 *
 * Real signature: returns a ChildProcess (EventEmitter with stdout/stderr
 * Readable streams, pid, kill, etc.).
 *
 * We return a properly-shaped object whose stdout / stderr are Readable
 * streams that end immediately, and emit 'error' + 'close' on next tick.
 * This matches the real behaviour when a binary is not found.
 */
export function spawn (command, args, _options) {
  const err = disabledError(command)
  const child = new EventEmitter()
  child.pid = -1
  child.kill = () => true
  child.unref = () => {}
  child.ref = () => {}
  child.stdin = new Readable({ read () {} })
  child.stdout = new Readable({ read () {} })
  child.stderr = new Readable({ read () {} })

  // Emit in the same order Node.js does:
  //   1. 'error'  (ENOENT)
  //   2. 'close'  (code 1)
  process.nextTick(() => {
    child.emit('error', err)
    child.stdout.push(null)  // end the stream
    child.stderr.push(null)
    child.emit('close', 1, null)
  })
  return child
}

/**
 * fork(modulePath, [args], [options])
 *
 * Same as spawn but for Node child processes.  Same graceful failure.
 */
export function fork (modulePath, args, options) {
  return spawn('node', [modulePath, ...(args || [])], options)
}

/**
 * execFile(file, [args], [options], callback)
 *
 * Same as exec but for a file instead of a shell command.
 */
export function execFile (file, args, options, callback) {
  // Normalise arguments (same logic as Node.js execFile)
  let args_ = []
  let options_ = {}
  let callback_ = undefined

  if (Array.isArray(args)) {
    args_ = args
    if (typeof options === 'function') {
      callback_ = options
    } else if (options) {
      options_ = options
      if (typeof callback === 'function') callback_ = callback
    }
  } else if (typeof args === 'function') {
    callback_ = args
  } else if (args) {
    options_ = args
    if (typeof options === 'function') callback_ = options
  }

  return exec(file, options_, callback_)
}

/**
 * promisify support: Node's util.promisify checks for
 * `exec[promisify.custom]` and `execFile[promisify.custom]`.
 * If not set, promisify wraps the callback-style function.
 * Our implementations already support callback-style, so promisify
 * will work out of the box — no custom symbol needed.
 */

// Re-export everything as default for CJS interop
export default {
  exec,
  execSync,
  spawn,
  fork,
  execFile
}
