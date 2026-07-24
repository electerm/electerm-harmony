/**
 * RDP session using IronRDP WASM + RDCleanPath proxy
 *
 * Architecture:
 *   Browser (IronRDP WASM) <--WebSocket--> This Proxy <--TLS--> RDP Server
 *
 * The WASM client handles all RDP protocol logic.
 * This server-side code acts as a RDCleanPath proxy:
 *   1. Receives RDCleanPath Request from WASM client (ASN.1 DER binary)
 *   2. TCP connects to the RDP server (optionally through proxy)
 *   3. Performs X.224 handshake + TLS upgrade
 *   4. Sends RDCleanPath Response (with certs) back to WASM client
 *   5. Bidirectional relay: WebSocket <-> TLS
 */
const log = require('../common/log')
const { TerminalBase } = require('./session-base')
const globalState = require('./global-state')
const {
  handleConnection
} = require('./rdp-proxy')
const { createHopProxy } = require('./session-hop')

class TerminalRdp extends TerminalBase {
  init = async () => {
    globalState.setSession(this.pid, this)
    return Promise.resolve(this)
  }

  /**
   * Start the RDCleanPath proxy for this session.
   * Called when the WebSocket connects from the browser.
   * The WASM client will send an RDCleanPath Request as the first message.
   */
  start = async (width, height) => {
    if (!this.ws) {
      log.error(`[RDP:${this.pid}] No WebSocket available`)
      return
    }
    this.width = width
    this.height = height

    // Buffer any messages that arrive during the async hop setup so they
    // are not dropped before handleConnection sets up its own listener.
    const bufferedMessages = []
    const bufferMsg = (data) => bufferedMessages.push(data)
    this.ws.on('message', bufferMsg)

    const { readyTimeout } = this.initOptions

    const { proxyUrl, ssh } = await createHopProxy(this.initOptions)
    if (ssh) {
      this.ssh = ssh
    }

    // Hand off to the proxy handler, replaying any buffered messages.
    this.ws.off('message', bufferMsg)
    handleConnection(this.ws, {
      proxy: proxyUrl,
      readyTimeout
    }, bufferedMessages)
  }

  resize () {
    // IronRDP handles resize via the WASM session.resize() method
    // which sends resize PDUs through the existing relay
  }

  test = async () => {
    const net = require('net')
    const proxySock = require('./socks')
    const {
      host,
      port = 3389,
      readyTimeout = 10000
    } = this.initOptions

    const { proxyUrl, ssh } = await createHopProxy(this.initOptions)
    if (ssh) {
      this.ssh = ssh
    }

    try {
      if (proxyUrl) {
        const proxyResult = await proxySock({ readyTimeout, host, port, proxy: proxyUrl })
        proxyResult.socket.destroy()
        return true
      }

      return await new Promise((resolve, reject) => {
        const socket = net.createConnection({ host, port }, () => {
          socket.destroy()
          resolve(true)
        })
        socket.on('error', (err) => reject(err))
        socket.setTimeout(readyTimeout, () => {
          socket.destroy()
          reject(new Error('Connection timed out'))
        })
      })
    } finally {
      if (this.ssh) {
        this.ssh.kill()
        delete this.ssh
      }
    }
  }

  kill = () => {
    if (this.ws) {
      try {
        this.ws.close()
      } catch (e) {
        log.debug(`[RDP:${this.pid}] ws.close() error: ${e.message}`)
      }
      delete this.ws
    }
    if (this.ssh) {
      this.ssh.kill()
      delete this.ssh
    }
    if (this.sessionLogger) {
      this.sessionLogger.destroy()
    }
    const {
      pid
    } = this
    const inst = globalState.getSession(pid)
    if (!inst) {
      return
    }
    globalState.removeSession(pid)
  }
}

exports.session = async function (initOptions, ws) {
  const term = new TerminalRdp(initOptions, ws)
  await term.init()
  return term
}

/**
 * test RDP connection (TCP connectivity check)
 * @param {object} options
 */
exports.test = (options) => {
  return (new TerminalRdp(options, undefined, true))
    .test()
    .then(() => {
      return true
    })
    .catch(() => {
      return false
    })
}
