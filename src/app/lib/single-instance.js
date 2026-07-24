/**
 * Single instance lock with socket-based IPC
 */

const net = require('net')
const fs = require('fs')
const path = require('path')
const { app } = require('electron')
const globalState = require('./glob-state')
const { tempDir } = require('../common/runtime-constants')

function getSocketPath () {
  return path.join(tempDir, `${app.getName()}-instance.sock`)
}

// Clean up stale socket file
function cleanupSocket () {
  const socketPath = getSocketPath()
  if (fs.existsSync(socketPath)) {
    try {
      fs.unlinkSync(socketPath)
    } catch (e) {
      // Ignore errors
    }
  }
}

/**
 * Start socket server to receive data from second instances
 * @param {Function} onSecondInstance - Callback when second instance sends data
 */
function startSocketServer (onSecondInstance) {
  const socketPath = getSocketPath()
  cleanupSocket()

  const server = net.createServer((socket) => {
    let data = ''
    socket.on('data', (chunk) => {
      data += chunk.toString()
    })
    socket.on('end', () => {
      try {
        const parsed = JSON.parse(data)
        onSecondInstance(parsed)
      } catch (e) {
        console.error('Failed to parse second instance data:', e)
      }
    })
  })

  server.on('error', (err) => {
    console.error('Socket server error:', err)
  })

  server.listen(socketPath)

  // Clean up on app quit
  app.on('will-quit', () => {
    server.close()
    cleanupSocket()
  })

  return server
}

/**
 * Send data to primary instance via socket
 * @param {Object} data - Data to send
 * @returns {Promise<boolean>} - True if sent successfully
 */
function sendToFirstInstance (data) {
  const socketPath = getSocketPath()
  return new Promise((resolve) => {
    let settled = false
    const done = (result) => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      resolve(result)
    }

    // Timeout: if we can't connect or get a response within 3 seconds,
    // the primary instance is likely dead (e.g. crashed). Clean up the
    // stale socket and proceed as the primary instance.
    const timer = setTimeout(() => {
      try { client.destroy() } catch (e) {}
      cleanupSocket()
      done(false)
    }, 3000)

    const client = net.createConnection(socketPath, () => {
      client.write(JSON.stringify(data))
      client.end()
    })

    client.on('error', () => {
      // No server listening, we are the first instance
      cleanupSocket()
      done(false)
    })

    client.on('close', () => {
      done(true)
    })
  })
}

/**
 * Handle second instance connection
 * @param {Object} progs - Parsed command line options
 * @returns {Promise<boolean>} - True if this is the primary instance
 */
async function handleSingleInstance (progs) {
  // Try to send to existing instance first via socket
  const sent = await sendToFirstInstance(progs)
  if (sent) {
    // Successfully sent to primary instance, quit this one
    return false
  }

  // We are the primary instance, start socket server
  startSocketServer((data) => {
    const win = globalState.get('win')
    if (win) {
      if (win.isMinimized()) {
        win.restore()
      }
      win.focus()
      win.webContents.send('add-tab-from-command-line', data)
    }
  })

  return true
}

module.exports = {
  handleSingleInstance,
  sendToFirstInstance,
  startSocketServer
}
