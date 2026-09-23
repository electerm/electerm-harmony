/**
 * Local-terminal (PTY) capability probe.
 *
 * WHY THIS FILE EXISTS
 * --------------------
 * Whether this device can run a local shell is a sandbox question, not a
 * form-factor one, and it must be measured. HarmonyOS retail ROMs hand the app
 * a devfs with no devpts and refuse /dev/ptmx to the normal_hap domain — a MAC
 * (SELinux) denial, not a mode-bit one, so nothing inside the app can lift it.
 * The DevEco emulator image, by contrast, has a plain Linux /dev and works. A
 * device-type gate therefore gets it wrong in both directions; a probe gets it
 * right on purpose.
 *
 * The probe makes the real calls once at boot, then memoizes:
 *
 *   pty.native.open(80, 24)                 openpty, NO fork
 *     → fails when the sandbox exposes no usable /dev/ptmx or devpts
 *   pty.spawn(<shell>, ['-c', 'exit 0'])    openpty + fork + exec
 *     → fails when openpty was fine but the fork/exec was refused
 *
 * Deliberately pty.native.open and not the public pty.open(): pty.open() hands
 * the fds to libuv for tty.ReadStream, which returns `uv_tty_init EINVAL` on
 * OHOS even where the pty is demonstrably healthy. A probe that cries wolf is
 * worse than no probe.
 *
 * <shell> is not a fixed path. resolveShell() walks the session's own PATH plus
 * /system/bin for bash/sh, then $SHELL, then absolute fallbacks, and the chosen
 * path is reported. A session forks a bare name (exec=bash on the default
 * bookmark) and resolves it at exec time, so hardcoding /bin/sh would test the
 * probe's assumption rather than the session's behaviour. Note the OHOS ptys
 * also have a shell fallback chain in the child (zsh → bash → sh → /bin/sh), so
 * a missing shell does not make pty.spawn throw; the chosen path is about the
 * whole chain.
 *
 * CONSUMERS — one answer for everybody
 * ------------------------------------
 *   app/lib/view.js          → hasNodePty, supportSessionTypes ('local')
 *   app/server/session-local.js → terminalLocal, testConnectionLocal
 * DISABLE_LOCAL_TERMINAL overrides everything and is checked first, inside the
 * probe, so no consumer can see a different answer.
 *
 * WHERE THE ANSWER IS PUBLISHED
 * -----------------------------
 *   <dataDir>/local-terminal.json   full report incl. diagnostics
 *   log (mirrored to hilog as [io] …)  one-line verdict
 * On a sealed ROM the sandbox is unreadable from outside and, once the feature
 * is disabled, there is no terminal pane to print into — hilog is the only
 * channel that survives.
 */

import fs from 'fs'
import { spawnSync } from 'child_process'
import { dirname, join } from 'path'
import log from '../common/log.js'

let nodePtyPromise = null

/**
 * Load node-pty lazily and tolerate its absence: the server must still start
 * when the OHOS addon is missing or cannot be mapped.
 */
export function loadNodePty () {
  if (!nodePtyPromise) {
    nodePtyPromise = import('node-pty')
      .then(m => m.default)
      .catch(err => {
        log.warn('node-pty is not available, local terminal disabled:', err.message)
        return null
      })
  }
  return nodePtyPromise
}

/**
 * ELECTERM_PTY_ADDON is exported by entry/src/main/cpp/node_ctl.c and points at
 * the addon's copy in the app libs dir (OHOS will not map native code out of
 * the HAP's resources/resfile tree). Its presence is our marker for "this is
 * the on-device backend", and the JS side of node-pty reads it too.
 */
const isOhos = !!process.env.ELECTERM_PTY_ADDON

export function describe (err) {
  if (!err) {
    return 'ok'
  }
  const code = typeof err.code === 'string'
    ? err.code
    : typeof err.errno === 'number' ? `errno ${err.errno}` : ''
  return [code, err.message].filter(Boolean).join(' ')
}

export function dataDir () {
  return process.env.ELECTERM_DATA_DIR || process.cwd()
}

/**
 * Everything we can learn about the sandbox without external commands. Runs on
 * the failure path only, and its output is attached to the thrown error so the
 * terminal pane explains itself instead of showing a bare "forkpty(3) failed.".
 */
export function ptyDiagnostics (baseDir, pty) {
  const out = []
  const push = (key, value) => out.push(`${key} = ${value}`)
  const why = describe
  const stat = (p) => {
    try {
      const st = fs.statSync(p)
      return `mode=${st.mode.toString(8)} dev=${st.dev}` +
        (st.isCharacterDevice() ? ' chardev' : '')
    } catch (err) {
      return `FAIL ${why(err)}`
    }
  }
  const list = (p) => {
    try {
      const names = fs.readdirSync(p)
      return `${names.length} entries [${names.slice(0, 40).join(' ')}]`
    } catch (err) {
      return `FAIL ${why(err)}`
    }
  }
  const openTest = (p) => {
    let fd = -1
    try {
      fd = fs.openSync(p, fs.constants.O_RDWR | fs.constants.O_NOCTTY)
      return `OK fd=${fd}`
    } catch (err) {
      return `FAIL ${why(err)} (${err.message})`
    } finally {
      if (fd >= 0) {
        try {
          fs.closeSync(fd)
        } catch (_) {}
      }
    }
  }
  const grep = (p, re) => {
    try {
      const hits = fs.readFileSync(p, 'utf8')
        .split('\n')
        .filter(l => re.test(l))
      return hits.length
        ? hits.slice(0, 20).map(l => l.trim()).join(' | ')
        : '(no match)'
    } catch (err) {
      return `FAIL ${why(err)}`
    }
  }
  const tail = (p) => {
    try {
      const lines = fs.readFileSync(p, 'utf8').replace(/\s+$/, '').split('\n')
      return lines.slice(-12).map(l => l.trim()).join(' | ')
    } catch (err) {
      return `FAIL ${why(err)}`
    }
  }
  const openpty = () => {
    const nat = pty && pty.native
    if (!nat || typeof nat.open !== 'function') {
      return 'unavailable'
    }
    let fds = null
    try {
      fds = nat.open(80, 24)
      return `OK master=${fds.master} slave=${fds.slave} pty=${fds.pty}`
    } catch (err) {
      return `FAIL ${why(err)} (${err.message})`
    } finally {
      for (const fd of fds ? [fds.master, fds.slave] : []) {
        try {
          fs.closeSync(fd)
        } catch (_) {}
      }
    }
  }
  const spawnTest = () => {
    try {
      const r = spawnSync('/bin/sh', ['-c', 'exit 0'], { timeout: 5000 })
      return r.error
        ? `FAIL ${why(r.error)} (${r.error.message})`
        : `OK status=${r.status}`
    } catch (err) {
      return `FAIL ${why(err)} (${err.message})`
    }
  }

  push('platform', `${process.platform} ${process.arch} node=${process.version}`)
  push('pty addon', process.env.ELECTERM_PTY_ADDON || '(unset)')
  push('selinux domain', tail('/proc/self/attr/current'))
  push('pty_debug.log', tail(join(dirname(dirname(baseDir)), 'pty_debug.log')))
  push('native openpty (no fork)', openpty())
  push('spawnSync /bin/sh (no fork)', spawnTest())
  push('/dev stat', stat('/dev'))
  push('/dev list', list('/dev'))
  push('/dev/ptmx stat', stat('/dev/ptmx'))
  push('/dev/ptmx open', openTest('/dev/ptmx'))
  push('/dev/pts stat', stat('/dev/pts'))
  push('/dev/pts list', list('/dev/pts'))
  push('/dev/pts/ptmx stat', stat('/dev/pts/ptmx'))
  push('/dev/tty stat', stat('/dev/tty'))
  push('mountinfo /dev', grep('/proc/self/mountinfo', / devpts | \/dev /))
  push('limits address/procs/files',
    grep('/proc/self/limits', /Max (address space|processes|open files)/))
  push('status Threads/VmSize/VmRSS',
    grep('/proc/self/status', /^(Threads|VmSize|VmRSS):/))
  return out.join('\n')
}

/**
 * First runnable shell, in the order a session would actually find one.
 * PATH wins (the app's PATH is HNP dirs + whatever we appended), then $SHELL,
 * then the absolute fallbacks the native fallback chain uses.
 */
export function resolveShell () {
  const tried = []
  const dirs = (process.env.PATH || '').split(':').filter(Boolean)
  if (!dirs.includes('/system/bin')) {
    dirs.push('/system/bin')
  }
  const fromPath = ['bash', 'sh'].flatMap(name => dirs.map(dir => join(dir, name)))
  const candidates = [
    process.env.SHELL,
    ...fromPath,
    '/bin/bash',
    '/bin/sh',
    '/system/bin/bash',
    '/system/bin/sh'
  ]
  for (const p of candidates) {
    if (!p || tried.includes(p)) {
      continue
    }
    tried.push(p)
    try {
      fs.accessSync(p, fs.constants.X_OK)
      return { shell: p, tried }
    } catch (_) {}
  }
  return { shell: '', tried }
}

function fail (pty, reason, detail) {
  let context = ''
  try {
    context = ptyDiagnostics(dataDir(), pty)
  } catch (err) {
    context = `diagnostics failed: ${describe(err)}`
  }
  return { available: false, reason, detail, context }
}

async function probe () {
  if (process.env.DISABLE_LOCAL_TERMINAL) {
    return {
      available: false,
      reason: 'disabled-by-env',
      detail: 'DISABLE_LOCAL_TERMINAL is set'
    }
  }
  const pty = await loadNodePty()
  if (!pty) {
    return {
      available: false,
      reason: 'addon-missing',
      detail: 'node-pty could not be loaded'
    }
  }
  if (!isOhos) {
    return {
      available: true,
      reason: 'addon-loaded',
      detail: 'non-OHOS platform, not probed'
    }
  }
  const nat = pty.native
  if (nat && typeof nat.open === 'function') {
    let fds = null
    try {
      fds = nat.open(80, 24)
    } catch (err) {
      return fail(pty, 'openpty', describe(err))
    } finally {
      for (const fd of fds ? [fds.master, fds.slave] : []) {
        try {
          fs.closeSync(fd)
        } catch (_) {}
      }
    }
  }
  const cwd = dataDir()
  const found = resolveShell()
  if (!found.shell) {
    return fail(pty, 'no-shell', `no runnable shell (tried ${found.tried.join(' ')})`)
  }
  let term = null
  try {
    term = pty.spawn(found.shell, ['-c', 'exit 0'], {
      name: 'xterm-256color',
      cols: 80,
      rows: 24,
      cwd,
      env: { ...process.env, HOME: cwd }
    })
  } catch (err) {
    return fail(pty, 'forkpty', `${describe(err)} (shell=${found.shell})`)
  } finally {
    if (term) {
      try {
        term.kill()
      } catch (_) {}
    }
  }
  return {
    available: true,
    reason: 'ok',
    detail: `openpty + forkpty ok (shell=${found.shell})`
  }
}

function publish (result) {
  try {
    fs.writeFileSync(
      join(dataDir(), 'local-terminal.json'),
      JSON.stringify({ at: new Date().toISOString(), ...result }, null, 2)
    )
  } catch (_) {}
  return result
}

let cached = null

/**
 * Memoized capability report. Also the single place the verdict is logged.
 */
export function localTerminalCapability () {
  if (!cached) {
    cached = probe()
      .catch(err => ({
        available: false,
        reason: 'probe-failed',
        detail: describe(err)
      }))
      .then(result => {
        const line = `local terminal: ${result.available ? 'enabled' : 'disabled'} (${result.reason}: ${result.detail})`
        if (result.available) {
          log.info(line)
        } else {
          log.warn(line, result.context ? `\n${result.context}` : '')
        }
        return publish(result)
      })
  }
  return cached
}

export async function localTerminalAvailable () {
  const cap = await localTerminalCapability()
  return cap.available
}

// Warm the probe at import time so the first UI render and the first session
// attempt both hit a resolved promise instead of racing the openpty call.
if (isOhos && !process.env.DISABLE_LOCAL_TERMINAL) {
  localTerminalCapability()
}
