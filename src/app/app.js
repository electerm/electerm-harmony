/**
 * app entry
 */
const log = require('./common/log')
const dlog = require('./common/debug-logger')
const { createApp } = require('./lib/create-app')
const globalState = require('./lib/glob-state')

globalState.set('initTime', Date.now())

dlog('=== app.js loaded, calling createApp() ===')
log.debug('electerm start')

const app = createApp()
globalState.set('app', app)
dlog('createApp() returned, app stored in globalState')
