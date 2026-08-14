/**
 * session-server.js — factory for creating in-process session servers.
 *
 * Each call to createSessionServer() creates a new Express app listening
 * on its own port, with WebSocket routes for terminal/sftp/transfer.
 * Communication with the parent (session-process.js) is via an
 * EventEmitter channel instead of process IPC.
 */

const EventEmitter = require('events')
const express = require('express')
const { Sftp } = require('./session-sftp')
const { instSftpKeys } = require('../common/constants')
const { Ftp } = require('./session-ftp')
const {
  sftp,
  transfer,
  onDestroySftp,
  onDestroyTransfer,
  terminals
} = require('./remote-common')
const { Transfer, transferKeys } = require('./transfer')
const { Transfer: FtpTransfer } = require('./ftp-transfer')
const log = require('../common/log')
const appDec = require('./app-wrap')
const {
  createTerm,
  testTerm,
  resize,
  runCmd,
  execCmd,
  toggleTerminalLog,
  toggleTerminalLogTimestamp,
  setTerminalLogPath,
  startTerminalLogFile
} = require('./session-api')
const wsDec = require('./ws-dec')
const { zmodemManager } = require('./zmodem')
const { trzszManager } = require('./trzsz')
const { xmodemManager } = require('./xmodem')

// True when the buffered data ends mid-way through a multi-byte UTF-8
// sequence (CJK chars are 3 bytes). Slow SSH servers (embedded router CLIs)
// often deliver one char split across TCP segments; flushing such a buffer
// right away would push a partial char to the client. Only the tail of the
// last buffer is inspected (at most 4 bytes), so this is O(1).
function hasIncompleteTrailingUtf8 (bufs) {
  const last = bufs[bufs.length - 1]
  if (!last) {
    return false
  }
  const buf = Buffer.isBuffer(last) ? last : Buffer.from(last)
  const len = buf.length
  if (!len) {
    return false
  }
  // Count trailing continuation bytes (10xxxxxx), at most 3
  let cont = 0
  while (cont < 3 && cont < len && (buf[len - 1 - cont] & 0xc0) === 0x80) {
    cont++
  }
  const leadIdx = len - 1 - cont
  if (leadIdx < 0) {
    // Whole buffer is continuation bytes; the lead byte was in a chunk that
    // was already flushed, so holding can not reassemble anything.
    return false
  }
  const lead = buf[leadIdx]
  if (lead < 0xc0) {
    // ASCII last byte, or stray continuations after ASCII: nothing to wait for
    return false
  }
  // Expected continuation count for this lead byte:
  // 110xxxxx -> 1, 1110xxxx -> 2, 11110xxx -> 3
  const needed = lead < 0xe0 ? 1 : lead < 0xf0 ? 2 : 3
  return cont < needed
}

let _pidCounter = 100001

/**
 * Create a session server running in-process.
 *
 * @param {string} type - session type: terminal, rdp, vnc, spice, etc.
 * @param {number} wsPort - port to listen on
 * @param {string} electermHost - host to bind to
 * @returns {{ channel: EventEmitter, kill: Function, pid: number, port: number }}
 */
function createSessionServer (type, wsPort, electermHost) {
  const app = express()
  const channel = new EventEmitter()
  channel.setMaxListeners(100)

  // Helper methods on channel:
  // channel.toParent(msg) — child → parent (replaces process.send)
  // channel.toChild(msg) — parent → child (replaces process.on('message'))
  channel.toParent = (msg) => channel.emit('to-parent', msg)
  channel.toChild = (msg) => channel.emit('to-child', msg)

  const tokenElecterm = process.env.tokenElecterm

  // Track whether any WebSocket has connected to detect orphaned servers
  let firstWsConnected = false
  function markConnected () {
    firstWsConnected = true
  }

  function verify (req) {
    const { token: to } = req.query
    if (to !== tokenElecterm) {
      throw new Error('not valid request')
    }
  }

  appDec(app)

  // --- WebSocket routes (same logic as original, using local `app`) ---

  if (type === 'rdp') {
    app.ws('/rdp/:pid', function (ws, req) {
      const { width, height } = req.query
      verify(req)
      markConnected()
      const term = terminals(req.params.pid)
      term.ws = ws
      log.debug('ws: connected to rdp session ->', term.pid, 'width=', width, 'height=', height)
      term.start(width, height)
      ws.on('error', (err) => {
        log.error('rdp ws error:', err)
      })
      ws.on('close', () => {
        log.debug('ws: rdp session ws closed ->', term.pid)
        cleanup()
      })
    })
  } else if (type === 'vnc') {
    app.ws('/vnc/:pid', function (ws, req) {
      const { query } = req
      verify(req)
      markConnected()
      const { pid } = req.params
      const term = terminals(pid)
      term.ws = ws
      term.start(query)
      log.debug('ws: connected to vnc session ->', pid)
      ws.on('error', (err) => {
        log.error(err)
      })
      ws.on('close', () => {
        cleanup()
      })
    })
  } else if (type === 'spice') {
    app.ws('/spice/:pid', function (ws, req) {
      const { query } = req
      verify(req)
      markConnected()
      const { pid } = req.params
      const term = terminals(pid)
      log.debug('ws: connected to spice session ->', pid)
      term.start(query, ws)
      ws.on('error', (err) => {
        log.error(err)
      })
    })
  } else {
    app.ws('/terminals/:pid', function (ws, req) {
      verify(req)
      markConnected()
      const term = terminals(req.params.pid)
      const { pid } = term
      log.debug('ws: connected to terminal ->', pid)

      const dataBuffer = []
      let sendTimeout = null
      // Time of the last actual flush. Lets a chunk arriving after an idle gap
      // (keystroke echo, command result) skip the coalescing delay entirely,
      // so only chunks arriving inside an active burst (floods) pay the 10ms
      // wait. Mirrors the client-side coalescing fast path.
      let lastFlushTime = 0
      const flushIntervalMs = 10

      const flushBufferedData = () => {
        if (!dataBuffer.length) {
          sendTimeout = null
          return
        }
        lastFlushTime = Date.now()
        const combinedData = Buffer.concat(dataBuffer.splice(0).map(d => Buffer.isBuffer(d) ? d : Buffer.from(d)))

        term.writeLog(combinedData)

        const zmodemConsumed = zmodemManager.handleData(pid, combinedData, term, ws)
        if (zmodemConsumed) {
          sendTimeout = null
          return
        }

        const trzszConsumed = trzszManager.handleData(pid, combinedData, term, ws)
        if (trzszConsumed) {
          sendTimeout = null
          return
        }

        if (term.port) {
          detectXmodemMarker(combinedData.toString('utf8'))
        }

        const xmodemConsumed = xmodemManager.handleData(pid, combinedData, term, ws)
        if (xmodemConsumed) {
          sendTimeout = null
          return
        }

        ws.send(combinedData)
        sendTimeout = null
      }

      ws.s = (data) => {
        ws.send(JSON.stringify(data))
      }

      function detectXmodemMarker (text) {
        const txMatch = text.match(/\[XMODEM:TX:(.+?)\]/)
        if (txMatch) {
          ws.s({
            action: 'xmodem-event',
            event: 'auto-trigger-receive',
            name: txMatch[1]
          })
          return
        }
        const rxMatch = text.match(/\[XMODEM:RX\]/)
        if (rxMatch) {
          ws.s({
            action: 'xmodem-event',
            event: 'auto-trigger-send'
          })
        }
      }

      term.on('data', function (data) {
        if (zmodemManager.isActive(pid)) {
          term.writeLog(data)
          zmodemManager.handleData(pid, data, term, ws)
          return
        }

        if (trzszManager.isActive(pid)) {
          term.writeLog(data)
          trzszManager.handleData(pid, data, term, ws)
          return
        }

        if (term.port) {
          const text = Buffer.isBuffer(data) ? data.toString('utf8') : data
          detectXmodemMarker(text)
        }

        if (xmodemManager.isActive(pid)) {
          if (!term.port) {
            term.writeLog(data)
            xmodemManager.handleData(pid, data, term, ws)
          }
          return
        }

        const chunk = Buffer.isBuffer(data) ? data : Buffer.from(data)

        if (chunk.length > 16384) {
          if (sendTimeout) {
            clearTimeout(sendTimeout)
            sendTimeout = null
          }
          if (dataBuffer.length) {
            flushBufferedData()
          }
          term.writeLog(chunk)
          const zmodemConsumed = zmodemManager.handleData(pid, chunk, term, ws)
          if (zmodemConsumed) {
            return
          }
          const trzszConsumed = trzszManager.handleData(pid, chunk, term, ws)
          if (trzszConsumed) {
            return
          }
          const xmodemConsumed = xmodemManager.handleData(pid, chunk, term, ws)
          if (xmodemConsumed) {
            return
          }
          ws.send(chunk)
          return
        }

        dataBuffer.push(chunk)

        // Idle fast path: if nothing has been flushed within the coalescing
        // window, this is the start of a new burst (or a lone interactive
        // echo) rather than a continuation of a flood - send it right away
        // instead of paying the fixed delay. Only chunks arriving while a
        // burst is already in flight (elapsed < flushIntervalMs) get batched.
        const elapsed = Date.now() - lastFlushTime
        if (elapsed >= flushIntervalMs) {
          // Never fast-flush a buffer that ends mid-way through a multi-byte
          // UTF-8 char: a slow peer (router CLI) may deliver one char split
          // across TCP segments, and the remaining bytes usually land within a
          // few ms. Hold one coalescing window so they get concatenated first
          // (the completing chunk then flushes immediately via this same fast
          // path). Bounded by the timeout, so it can not stick.
          if (hasIncompleteTrailingUtf8(dataBuffer)) {
            if (!sendTimeout) {
              sendTimeout = setTimeout(flushBufferedData, flushIntervalMs)
            }
            return
          }
          if (sendTimeout) {
            clearTimeout(sendTimeout)
            sendTimeout = null
          }
          flushBufferedData()
          return
        }

        // If no timeout is pending, schedule a batched send
        if (!sendTimeout) {
          sendTimeout = setTimeout(flushBufferedData, flushIntervalMs - elapsed)
        }
      })

      if (term.port) {
        term.port.on('data', function (rawData) {
          if (xmodemManager.isActive(pid)) {
            term.writeLog(rawData)
            xmodemManager.handleData(pid, rawData, term, ws)
          }
        })
      }

      let onCloseCalled = false
      function onClose () {
        if (onCloseCalled) return
        onCloseCalled = true
        if (sendTimeout) {
          clearTimeout(sendTimeout)
          sendTimeout = null
        }
        dataBuffer.length = 0
        zmodemManager.destroySession(pid)
        trzszManager.destroySession(pid)
        xmodemManager.destroySession(pid)
        term.kill()
        log.debug('Closed terminal ' + pid)
        ws.close && ws.close()
        cleanup()
      }

      term.on('close', onClose)

      ws.on('message', function (msg) {
        try {
          if (typeof msg === 'string') {
            try {
              const parsed = JSON.parse(msg)
              if (parsed.action === 'zmodem-event') {
                zmodemManager.handleMessage(pid, parsed, term, ws)
                return
              }
              if (parsed.action === 'trzsz-event') {
                trzszManager.handleMessage(pid, parsed, term, ws)
                return
              }
              if (parsed.action === 'xmodem-event') {
                xmodemManager.handleMessage(pid, parsed, term, ws)
                return
              }
              if (parsed.action === 'keepalive') {
                term.write('\n\r\x1b[K')
                return
              }
            } catch (e) {
              // Not JSON, treat as regular terminal input
            }
          }
          term.write(msg)
        } catch (ex) {
          log.error(ex)
        }
      })

      ws.on('error', (err) => {
        log.error(err)
      })

      ws.on('close', onClose)
    })

    // sftp function
    app.ws('/sftp/:id', (ws, req) => {
      verify(req)
      wsDec(ws)
      const { id } = req.params
      ws.on('close', () => {
        onDestroySftp(id)
      })
      ws.on('message', (message) => {
        const msg = JSON.parse(message)
        const { action } = msg

        if (action === 'sftp-new') {
          const { id, terminalId, type } = msg
          const Cls = type === 'ftp' ? Ftp : Sftp
          sftp(id, new Cls({
            uid: id,
            terminalId,
            type
          }))
        } else if (action === 'sftp-func') {
          const { id, args, func, uid } = msg
          const inst = sftp(id)
          if (inst) {
            if (!instSftpKeys.includes(func) || typeof inst[func] !== 'function') {
              ws.s({
                id: uid,
                error: {
                  message: 'invalid sftp function: ' + func,
                  stack: ''
                }
              })
              return
            }
            inst[func](...args)
              .then(data => {
                ws.s({
                  id: uid,
                  data
                })
              })
              .catch(err => {
                ws.s({
                  id: uid,
                  error: {
                    message: err.message,
                    stack: err.stack
                  }
                })
              })
          }
        } else if (action === 'sftp-destroy') {
          const { id } = msg
          ws.close()
          onDestroySftp(id)
        }
      })
    })

    // transfer function
    app.ws('/transfer/:id', (ws, req) => {
      verify(req)
      wsDec(ws)
      const { id } = req.params
      const { sftpId } = req.query

      ws.on('close', () => {
        onDestroyTransfer(id, sftpId)
      })

      ws.on('message', (message) => {
        const msg = JSON.parse(message)
        const { action } = msg

        if (action === 'transfer-new') {
          const { sftpId, id, isFtp } = msg
          const session = sftp(sftpId)
          const encode = session.initOptions?.encode || 'utf8'
          const opts = Object.assign({}, msg, {
            sftp: session.sftp,
            conn: session.client,
            ftpSession: isFtp ? session : null,
            sftpId,
            ws,
            encode
          })
          const Cls = isFtp ? FtpTransfer : Transfer
          transfer(id, sftpId, new Cls(opts))
        } else if (action === 'transfer-func') {
          const { id, func, args, sftpId } = msg
          if (func === 'destroy') {
            return onDestroyTransfer(id, sftpId)
          }
          if (!transferKeys.includes(func)) {
            return
          }
          const tr = transfer(id, sftpId)
          if (!tr || typeof tr[func] !== 'function') {
            return
          }
          tr[func](...args)
        }
      })
    })
  }

  // --- Message handler (replaces process.on('message')) ---
  channel.on('to-child', async (message) => {
    if (message.type === 'common') {
      const msg = message.data
      const { action, id, body } = msg

      let promise

      // ws mock: s() sends to parent, once() waits for parent response
      const ws = {
        s: (data) => {
          channel.toParent({ type: 'common', data })
        },
        once: (callack, msgId) => {
          const func = (arg) => {
            if (msgId === arg.id) {
              callack(arg)
              channel.removeListener('to-child', func)
            }
          }
          channel.on('to-child', func)
        }
      }

      if (action === 'create-terminal') {
        promise = createTerm(body, ws)
      } else if (action === 'test-terminal') {
        promise = testTerm(body, ws)
      } else if (action === 'resize-terminal') {
        promise = resize(body)
      } else if (action === 'toggle-terminal-log') {
        promise = toggleTerminalLog(body)
      } else if (action === 'toggle-terminal-log-timestamp') {
        promise = toggleTerminalLogTimestamp(body)
      } else if (action === 'set-terminal-log-path') {
        promise = setTerminalLogPath(body)
      } else if (action === 'start-terminal-log-file') {
        promise = startTerminalLogFile(body)
      } else if (action === 'run-cmd') {
        promise = runCmd(body)
      } else if (action === 'exec-cmd') {
        promise = execCmd(body)
      }

      const result = await promise
        .then(r => {
          return {
            id,
            data: r
          }
        })
        .catch(err => {
          log.error('common message error', err)
          return {
            id,
            error: {
              message: err.message,
              stack: err.stack
            }
          }
        })

      channel.toParent(result)
    }
  })

  // --- Server lifecycle ---
  let httpServer = null
  let cleanupCalled = false

  function cleanup () {
    if (cleanupCalled) return
    cleanupCalled = true
    if (noConnectionTimer) {
      clearTimeout(noConnectionTimer)
    }
    if (httpServer) {
      try { httpServer.close() } catch {}
    }
    channel.emit('exit', 0)
  }

  // Start listening
  httpServer = app.listen(wsPort, electermHost, () => {
    log.info('session server', 'runs on', electermHost, wsPort)
    channel.toParent({ serverInited: true })
    channel.emit('ready')
  })

  // Self-terminate if no WebSocket connects within 2 minutes
  const noConnectionTimer = setTimeout(() => {
    if (!firstWsConnected) {
      log.warn('session-server: no WS connection within 2min timeout, terminating')
      cleanup()
    }
  }, 120000)
  if (noConnectionTimer.unref) noConnectionTimer.unref()

  const pid = _pidCounter++

  return {
    channel,
    kill: cleanup,
    pid,
    port: wsPort,
    server: httpServer
  }
}

module.exports = { createSessionServer }
