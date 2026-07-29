const express = require('express')
const globalState = require('./global-state')
const app = express()
const log = require('../common/log')
const { initWs } = require('./dispatch-center')
const {
  isDev
} = require('../common/runtime-constants')
const initFileServer = require('../lib/file-server')
const appDec = require('./app-wrap')

appDec(app)

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
  initFileServer(app)
}
initWs(app)

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
    app.listen(electermPort, electermHost, () => {
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
