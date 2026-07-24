/**
 * get first free open port
 */

const log = require('../common/log')
const dlog = require('../common/debug-logger')
const globalState = require('./glob-state')
let port = null

function getPort (fromPort = 30975) {
  const serverPort = globalState.get('serverPort')
  if (serverPort) {
    port = parseInt(serverPort, 10)
    dlog('get-port: using serverPort from globalState:', port)
    return Promise.resolve(
      port
    )
  }
  dlog('get-port: searching free port from', fromPort)
  return new Promise((resolve, reject) => {
    require('find-free-port')(fromPort, '127.0.0.1', function (err, freePort) {
      if (err) {
        dlog('get-port: find-free-port ERROR:', err.message || err)
        reject(err)
      } else {
        port = freePort
        dlog('get-port: found free port:', port)
        resolve(freePort)
      }
    })
  })
}

module.exports = () => {
  if (port) {
    dlog('get-port: returning cached port:', port)
    return port
  }
  return getPort()
    .catch(e => {
      dlog('get-port: failed to get free port:', e.message || e)
      log.error('failed to get free port')
      return 0
    })
}
