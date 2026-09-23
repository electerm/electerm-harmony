/**
 * Local shell session (PTY-backed).
 *
 * The PTY plumbing (node-pty loading, capability probe, sandbox diagnostics)
 * lives in ./local-terminal.js; this file only owns the session lifecycle.
 *
 * OHOS NOTES
 * ----------
 * appspawn gives the app no HOME, so without intervention `cd`, `cd ~` and
 * every tool that keeps state in a dotfile (~/.ssh, ~/.gitconfig, ~/.npmrc)
 * would have nowhere to go. We therefore set BOTH cwd and env.HOME to
 * ELECTERM_DATA_DIR — the app sandbox data dir — so `~` and the starting
 * directory agree. Deliberately not the real user home: that would need
 * READ_WRITE_USER_FILE and drag the terminal out of the sandbox.
 *
 * We also append (never prepend) /system/bin to PATH: the app's own PATH is
 * the HNP dirs, which are empty on a bare image, so `ls`/`cat`/`grep` would all
 * fail. Appending keeps /data/service/hnp/bin in front, so a public HNP's
 * richer binaries (busybox/git/openssh) still shadow toybox's basic ones.
 * Everything here is gated on ELECTERM_PTY_ADDON so other platforms no-op.
 */

import fs from 'fs'
import { resolve as pathResolve, join } from 'path'
import globalState from './global-state.js'
import { TerminalBase } from './session-base.js'
import log from '../common/log.js'
import {
  loadNodePty,
  ptyDiagnostics,
  localTerminalCapability
} from './local-terminal.js'

class TerminalLocal extends TerminalBase {
  async init () {
    const pty = await loadNodePty()
    if (!pty) {
      return Promise.reject(new Error('Local terminal is not available on this platform'))
    }
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
    const ohosHome = process.env.ELECTERM_PTY_ADDON
      ? process.env.ELECTERM_DATA_DIR || process.cwd()
      : ''
    const useOhosHome = ohosHome !== '' && fs.existsSync(ohosHome)
    const cwd = useOhosHome
      ? ohosHome
      : process.env[platform === 'win32' ? 'USERPROFILE' : 'HOME']
    const argv = platform.startsWith('darwin') ? ['--login', ...(arg || [])] : arg
    const env = Object.assign({}, process.env)
    delete env.ELECTRON_RUN_AS_NODE
    delete env.NODE_OPTIONS
    delete env.ELECTRON_NO_ATTACH_CONSOLE
    // temp PEM of system CAs for the server process (WebDAV sync, #4347) —
    // not meant for user shells, and a bad keychain cert makes any Node/bun
    // tool in the terminal print "ignoring extra certs ... load failed"
    delete env.NODE_EXTRA_CA_CERTS
    if (useOhosHome) {
      env.HOME = ohosHome
    }
    // See the header note: append, never prepend.
    if (
      process.env.ELECTERM_PTY_ADDON &&
      fs.existsSync('/system/bin') &&
      !(env.PATH || '').split(':').includes('/system/bin')
    ) {
      env.PATH = `${env.PATH || ''}:/system/bin`
    }
    const spawnOptions = {
      name: term,
      encoding: null,
      cols: cols || 80,
      rows: rows || 24,
      cwd,
      env,
      // Use the OpenConsole conpty.dll shipped with node-pty instead of the
      // legacy Windows Console Host (kernel32 CreatePseudoConsole) conpty.
      // The legacy console-host conpty can stall output and deliver Ctrl+C to
      // the whole process group (killing the shell too) after a full-screen
      // TUI like opencode exits, leaving the terminal tab unresponsive.
      // The OpenConsole conpty.dll does not have this problem.
      useConptyDll: true
    }
    let spawned
    try {
      spawned = pty.spawn(exec, argv, spawnOptions)
    } catch (err) {
      if (!process.env.ELECTERM_PTY_ADDON) {
        throw err
      }
      // On device a bare "forkpty(3) failed." is useless: it is thrown from
      // native code, so it only proves the addon loaded and forkpty() returned
      // -1. Attach the whole sandbox diagnosis and make the pane self-explaining.
      const diag = `exec = ${exec}\ncwd = ${cwd}\n${ptyDiagnostics(cwd, pty)}`
      log.error('ohos local terminal: pty.spawn failed:', err.message)
      log.error(diag)
      try {
        fs.writeFileSync(
          join(cwd, 'local-term-diag.log'),
          `${new Date().toISOString()} ${err.message}\n${diag}\n`
        )
      } catch (_) {}
      // Send \r\n, not \n: a bare LF drops a line without returning to column 0
      // and the report arrives in the pane as one wrapped smear.
      throw new Error(`${err.message}\r\n${diag.replace(/\n/g, '\r\n')}`)
    }
    this.term = spawned
    log.info(`local terminal: pty up (exec=${exec} master=${this.term._pty} cwd=${cwd})`)
    // The OHOS Duplex socket buffers PTY output until the WebSocket is wired
    // up; flush that buffer now so the first prompt is not swallowed.
    const ohosSocket = this.term && this.term._socket
    if (ohosSocket && typeof ohosSocket.markConnected === 'function') {
      ohosSocket.markConnected()
    }
    this.term.termType = termType
    globalState.setSession(this.pid, this)
    return Promise.resolve(this)
  }

  resize (cols, rows) {
    this.term.resize(cols, rows)
  }

  on (event, cb) {
    this.term.on(event, cb)
  }

  off (event, cb) {
    try {
      if (!this.term) {
        return
      }
      if (typeof this.term.removeListener === 'function') {
        this.term.removeListener(event, cb)
      } else if (typeof this.term.off === 'function') {
        this.term.off(event, cb)
      }
    } catch (_) {
      // ignore removal errors during teardown
    }
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

/**
 * Re-check the memoized probe rather than only DISABLE_LOCAL_TERMINAL: on a
 * device whose sandbox refuses /dev/ptmx the feature has to be refused here
 * too, otherwise a stashed bookmark would produce a naked forkpty error.
 */
async function assertLocalTerminalAvailable () {
  const cap = await localTerminalCapability()
  if (!cap.available) {
    throw new Error(`Local terminal is disabled (${cap.reason}: ${cap.detail})`)
  }
}

export const terminalLocal = async function (initOptions, ws) {
  await assertLocalTerminalAvailable()
  return (new TerminalLocal(initOptions, ws)).init()
}

/**
 * test local terminal connection
 * @param {object} options
 */
export const testConnectionLocal = async (initOptions) => {
  await assertLocalTerminalAvailable()
  return true
}

export const terminal = terminalLocal
export const testConnection = testConnectionLocal
