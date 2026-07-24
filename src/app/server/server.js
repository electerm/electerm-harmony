const express = require('express')
const globalState = require('./global-state')
const app = express()
const log = require('../common/log')
const dlog = require('../common/debug-logger')
const { initWs } = require('./dispatch-center')
const {
  isDev
} = require('../common/runtime-constants')
const initFileServer = require('../lib/file-server')
const appDec = require('./app-wrap')

appDec(app)

dlog('server.js: loaded, setting up routes...')

app.get('/run', function (req, res) {
  res.send('ok')
})
app.post('/auth', function (req, res) {
  const { token } = req.body
  if (token === process.env.requireAuth) {
    globalState.authed = true
  }
  res.send('ok')
})
if (!isDev) {
  dlog('server.js: initializing file server...')
  initFileServer(app)
  dlog('server.js: file server done')
}
dlog('server.js: initializing websocket...')
initWs(app)
dlog('server.js: websocket done')

// --- Server lifecycle ---
let _startPromise = null

/**
 * Start the Express server. Returns a Promise that resolves when
 * the server is listening. Safe to call multiple times — returns
 * the same Promise.
 */
function startServer () {
  if (_startPromise) return _startPromise
  _startPromise = new Promise((resolve, reject) => {
    const { electermPort, electermHost } = process.env
    dlog('server.js: app.listen on', electermHost, electermPort)
    app.listen(electermPort, electermHost, () => {
      dlog('server.js: LISTENING on', electermHost, electermPort)
      log.info('server', 'runs on', electermHost, electermPort)
      // process.send may not exist (in-process mode)
      try { process.send({ serverInited: true }) } catch {}
      resolve(app)
    })
  })
  return _startPromise
}

// Auto-start when required
startServer()

module.exports = { startServer, app }
