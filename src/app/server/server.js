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

const runServer = function () {
  const { electermPort, electermHost } = process.env
  dlog('server.js: app.listen on', electermHost, electermPort)
  app.listen(electermPort, electermHost, () => {
    dlog('server.js: LISTENING on', electermHost, electermPort)
    log.info('server', 'runs on', electermHost, electermPort)
    process.send({ serverInited: true })
    dlog('server.js: sent serverInited message to parent')
  })
}

// start
dlog('server.js: calling runServer()')
runServer()

process.on('uncaughtException', (err) => {
  dlog('server.js: uncaughtException:', err.message || err, err.stack || '')
  log.error('uncaughtException', err)
})
process.on('unhandledRejection', (err) => {
  dlog('server.js: unhandledRejection:', err?.message || err)
  log.error('unhandledRejection', err)
})

process.on('SIGTERM', () => {
  dlog('server.js: received SIGTERM, exiting')
  process.exit(0)
})
