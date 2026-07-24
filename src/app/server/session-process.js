/**
 * session-process.js — manages terminal session servers in-process.
 *
 * Each session is an Express app on its own port, created by
 * createSessionServer() from session-server.js. No child processes.
 * Communication is via EventEmitter channels.
 */

const dlog = require('../common/debug-logger')
const { createSessionServer } = require('./session-server')

// Map to store active terminal processes (pid -> {session, port, ws})
const activeTerminals = new Map()

// Track the last port assigned
let lastPort = 30975
const MIN_PORT = 30975
const MAX_PORT = 65534
// Add a set to track ports that are currently being assigned
const pendingPorts = new Set()

function getPort (fromPort = MIN_PORT) {
  // Use the last port + 1 or start over if we've reached MAX_PORT
  let startPort = lastPort >= MAX_PORT ? MIN_PORT : lastPort + 1

  // Skip ports that are currently being assigned
  while (pendingPorts.has(startPort)) {
    startPort = startPort >= MAX_PORT ? MIN_PORT : startPort + 1
  }

  // Mark this port as pending
  pendingPorts.add(startPort)

  return new Promise((resolve, reject) => {
    require('find-free-port')(startPort, '127.0.0.1', function (err, freePort) {
      if (err) {
        pendingPorts.delete(startPort)
        reject(err)
      } else {
        lastPort = freePort
        pendingPorts.delete(startPort)
        resolve(freePort)
      }
    })
  })
}

const electermHost = process.env.electermHost || '127.0.0.1'

async function runSessionServer (type, port) {
  return new Promise((resolve, reject) => {
    dlog('session-process: creating session server, type:', type, 'port:', port)
    const session = createSessionServer(type, port, electermHost)

    session.channel.on('ready', () => {
      dlog('session-process: session server ready, pid:', session.pid)
      resolve(session)
    })

    session.channel.on('exit', (code) => {
      dlog('session-process: session server exit, code:', code)
    })

    // Timeout: if server doesn't start within 10s, reject
    setTimeout(() => {
      if (!session.server.listening) {
        dlog('session-process: session server startup TIMEOUT')
        session.kill()
        reject(new Error('Session server startup timed out'))
      }
    }, 10000)
  })
}

/**
 * Send a command to a session and wait for the response.
 * Works the same as the old sendMsgToChildProcess but via channel.
 */
async function sendMsgToSession (session, msg) {
  return new Promise((resolve, reject) => {
    const responseHandler = (response) => {
      // Only match command responses (not SSH data relay which has type:'common')
      if (response.id === msg.id && !response.type) {
        session.channel.removeListener('to-parent', responseHandler)
        if (response.error) {
          reject(response.error)
        } else {
          resolve(response.data)
        }
      }
    }

    session.channel.on('to-parent', responseHandler)
    session.channel.toChild({
      type: 'common',
      data: msg
    })
  })
}

exports.terminal = async function (initOptions, ws, uid) {
  const type = initOptions.termType || initOptions.type || 'terminal'
  const port = await getPort()
  const session = await runSessionServer(type, port)
  const pid = initOptions.uid
  const isSsh = ![
    'telnet',
    'serial',
    'local',
    'rdp',
    'vnc',
    'spice',
    'ftp'
  ].includes(type)

  if (isSsh) {
    // Relay SSH data between session and client WebSocket
    session.channel.on('to-parent', (m) => {
      if (m.type === 'common') {
        ws.s(m.data)
        ws.once((data) => {
          session.channel.toChild(data)
        }, m.data.id)
      }
    })
  }

  session.channel.on('exit', () => {
    session.channel.removeAllListeners('to-parent')
    activeTerminals.delete(pid)
  })

  if (type !== 'ftp') {
    try {
      await sendMsgToSession(session, {
        id: uid,
        action: 'create-terminal',
        body: initOptions
      })
    } catch (err) {
      session.kill()
      throw err
    }
  }

  // Kill any existing session for this pid before overwriting
  const existingEntry = activeTerminals.get(pid)
  if (existingEntry) {
    existingEntry.session.kill()
    activeTerminals.delete(pid)
  }

  activeTerminals.set(pid, {
    session,
    port,
    ws
  })

  return {
    pid,
    port
  }
}

exports.testConnection = async function (initOptions, ws, uid) {
  const type = initOptions.termType || initOptions.type || 'terminal'
  const port = await getPort()
  const session = await runSessionServer(type, port)

  const isSsh = ![
    'telnet',
    'serial',
    'local',
    'rdp',
    'vnc',
    'spice',
    'ftp'
  ].includes(type)
  if (isSsh && ws) {
    session.channel.on('to-parent', (m) => {
      if (m.type === 'common') {
        ws.s(m.data)
        ws.once((respData) => {
          session.channel.toChild(respData)
        }, m.data.id)
      }
    })
  }

  const res = await sendMsgToSession(session, {
    id: uid,
    action: 'test-terminal',
    body: initOptions
  })

  session.kill()
  return res
}

/**
 * Get terminal instance by pid
 * @param {string} pid - Process ID of the terminal
 * @returns {object|null} Terminal instance or null if not found
 */
exports.terminals = function (pid) {
  const terminal = activeTerminals.get(pid)
  if (!terminal) {
    return null
  }

  return {
    runCmd: async (cmd, id) => {
      return sendMsgToSession(terminal.session, {
        id,
        action: 'run-cmd',
        body: { cmd, pid }
      })
    },
    resize: (cols, rows, id) => {
      sendMsgToSession(terminal.session, {
        id,
        action: 'resize-terminal',
        body: { cols, rows, pid }
      })
    },
    toggleTerminalLog: (id) => {
      sendMsgToSession(terminal.session, {
        id,
        action: 'toggle-terminal-log',
        body: { pid }
      })
    },
    toggleTerminalLogTimestamp: (id) => {
      sendMsgToSession(terminal.session, {
        id,
        action: 'toggle-terminal-log-timestamp',
        body: { pid }
      })
    },
    setTerminalLogPath: (id, logPath) => {
      sendMsgToSession(terminal.session, {
        id,
        action: 'set-terminal-log-path',
        body: { pid, logPath }
      })
    },
    startTerminalLogFile: (id, logFilePath, addTimeStampToTermLog) => {
      sendMsgToSession(terminal.session, {
        id,
        action: 'start-terminal-log-file',
        body: { pid, logFilePath, addTimeStampToTermLog }
      })
    }
  }
}

/**
 * Clean up all active terminals
 */
exports.cleanupTerminals = function () {
  for (const [pid, terminal] of activeTerminals) {
    terminal.session.kill()
    activeTerminals.delete(pid)
  }
}

// Clean up on process exit
process.on('SIGINT', () => {
  exports.cleanupTerminals()
  process.exit()
})
process.on('SIGTERM', () => {
  exports.cleanupTerminals()
  process.exit()
})
