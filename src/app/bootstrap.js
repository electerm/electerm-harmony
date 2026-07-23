/**
 * bootstrap.js — HarmonyOS entry point.
 *
 * On HarmonyOS, the Electron 鸿蒙 runtime starts the Node.js process before
 * the ArkTS layer has finished calling JsBindingUtils.SetContextPaths().
 * If app.js (which transitively loads app-props.js) is loaded too early,
 * app.getPath('appData') throws "Failed to get 'appData' path" and crashes
 * the main process.
 *
 * This bootstrap polls app.getPath('appData') until it succeeds, then loads
 * app.js. This guarantees that all downstream modules (db.js, ipc.js, etc.)
 * can safely call app.getPath() at module load time.
 *
 * On non-HarmonyOS platforms, app.getPath('appData') works immediately and
 * app.js is loaded without delay.
 */
const { app } = require('electron')

const POLL_INTERVAL = 50 // ms
const MAX_WAIT = 10000 // 10 seconds

function isPathReady () {
  try {
    app.getPath('appData')
    return true
  } catch {
    return false
  }
}

function startApp () {
  require('./app.js')
}

if (isPathReady()) {
  startApp()
} else {
  console.log('[bootstrap] waiting for app.getPath("appData") to become available...')
  const startTime = Date.now()
  const timer = setInterval(() => {
    if (isPathReady()) {
      clearInterval(timer)
      console.log(`[bootstrap] app.getPath("appData") ready after ${Date.now() - startTime}ms`)
      startApp()
    } else if (Date.now() - startTime > MAX_WAIT) {
      clearInterval(timer)
      console.error(`[bootstrap] timed out after ${MAX_WAIT}ms waiting for app.getPath("appData")`)
      // Start anyway — app-props.js has a try/catch fallback
      startApp()
    }
  }, POLL_INTERVAL)
}
