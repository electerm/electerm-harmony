/**
 * terminal/sftp/serial class
 *
 * node-pty is a native module that may not be available on all platforms
 * (e.g. HarmonyOS). It is loaded lazily so that the server can start
 * without it; local terminal sessions will fail gracefully if it is missing.
 */
import { resolve as pathResolve } from 'path'
import globalState from './global-state.js'
import { TerminalBase } from './session-base.js'
import log from '../common/log.js'

let _pty = null
async function getPty () {
  if (_pty) {
    return _pty
  }
  const mod = await import('node-pty')
  _pty = mod.default || mod
  return _pty
}

class TerminalLocal extends TerminalBase {
  async init () {
    const {
      cols,
      rows,
      execWindows,
      execMac,
      execLinux,
      execWindowsArgs,
      execMacArgs,
      execLinuxArgs,
      termType,
      term
    } = this.initOptions
    this.isLocal = true
    const { platform } = process
    const isWin = platform.startsWith('win')
    const exec = isWin
      ? pathResolve(
        process.env.windir,
        execWindows
      )
      : platform === 'darwin' ? execMac : execLinux
    if ((exec || '').includes('..')) {
      return Promise.reject(new Error('execWindows should not contain ".."'))
    }
    const arg = isWin
      ? execWindowsArgs
      : platform === 'darwin' ? execMacArgs : execLinuxArgs
    const cwd = process.env[platform === 'win32' ? 'USERPROFILE' : 'HOME']
    const argv = platform.startsWith('darwin') ? ['--login', ...(arg || [])] : arg
    const env = Object.assign({}, process.env)
    delete env.ELECTRON_RUN_AS_NODE
    delete env.NODE_OPTIONS
    delete env.ELECTRON_NO_ATTACH_CONSOLE
    const pty = await getPty()
    this.term = pty.spawn(exec, argv, {
      name: term,
      encoding: null,
      cols: cols || 80,
      rows: rows || 24,
      cwd,
      env
    })
    this.term.termType = termType
    globalState.setSession(this.pid, this)
    return this
  }

  resize (cols, rows) {
    this.term.resize(cols, rows)
  }

  on (event, cb) {
    this.term.on(event, cb)
  }

  write (data) {
    this.term.write(data)
  }

  kill () {
    if (this.sessionLogger) {
      this.sessionLogger.destroy()
    }
    this.term && this.term.kill()
    this.onEndConn()
  }
}

export const terminalLocal = async function (initOptions, ws) {
  if (process.env.DISABLE_LOCAL_TERMINAL) {
    throw new Error('Local terminal is disabled')
  }
  try {
    await getPty()
  } catch (e) {
    log.error('node-pty is not available on this platform:', e.message)
    throw new Error('Local terminal is not supported on this platform')
  }
  return (new TerminalLocal(initOptions, ws)).init()
}

/**
 * test ssh connection
 * @param {object} options
 */
export const testConnectionLocal = (initOptions) => {
  if (process.env.DISABLE_LOCAL_TERMINAL) {
    return Promise.reject(new Error('Local terminal is disabled'))
  }
  return Promise.resolve(true)
}

export const terminal = terminalLocal
export const testConnection = testConnectionLocal
