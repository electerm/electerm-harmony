const {
  app
} = require('electron')
const { createWindow } = require('./create-window')
const {
  packInfo
} = require('../common/runtime-constants')
const { initCommandLine } = require('./command-line')
const globalState = require('./glob-state')
const { getUserConfigNoEnc, getDbConfig } = require('./get-config')
const {
  setupDeepLinkHandlers
} = require('./deep-link')
const { handleSingleInstance } = require('./single-instance')
const log = require('../common/log')
const dlog = require('../common/debug-logger')

let conf = {}

// GPU error suggestion message
const GPU_ERROR_SUGGESTION = `
================================================================================
⚠️  GPU Process Error Detected
================================================================================
If you encounter GPU process crashes (exit_code=-2147483645 or similar),
try running electerm with one of these flags:

  1. --no-sandbox          (Recommended - run without sandbox)
  2. --disable-gpu        (Disable GPU rendering)
  3. --disable-gpu-sandbox (Disable GPU sandbox)
  4. --disable-hardware-acceleration

Or set environment variable:
  DISABLE_GPU=1         (Disable GPU)
  DISABLE_GPU_SANDBOX=1 (Disable GPU + sandbox, use SwiftShader)
  ENABLE_GPU=1          (Linux only: force-enable hardware GPU)

Example:
  electerm --no-sandbox
  or
  DISABLE_GPU=1 electerm
================================================================================
`

// Handle GPU process crashes
app.on('gpu-process-crashed', (event, killed) => {
  log.error(`GPU process crashed, killed: ${killed}`)
  console.error(GPU_ERROR_SUGGESTION)
})

// Handle render process gone events
app.on('render-process-gone', (event, webContents, details) => {
  if (details.reason === 'crashed' || details.reason === 'abnormal-exit') {
    log.error(`Render process gone: ${details.reason}`, details)
    console.error(GPU_ERROR_SUGGESTION)
  }
})

// Handle uncaught exceptions
process.on('uncaughtException', (error) => {
  dlog('!!! uncaughtException:', error?.message || error, error?.stack || '')
  log.error('uncaughtException:', error?.message || error, error?.stack || '')
  const errorMsg = error?.message || ''
  // Check if it's GPU related
  if (
    errorMsg.includes('GPU') ||
    errorMsg.includes('gpu') ||
    errorMsg.includes('graphics') ||
    errorMsg.includes('Vulkan') ||
    errorMsg.includes('DXGI')
  ) {
    console.error(GPU_ERROR_SUGGESTION)
  }
})

// Handle unhandled promise rejections
process.on('unhandledRejection', (reason, promise) => {
  dlog('!!! unhandledRejection:', reason?.message || reason, reason?.stack || '')
  log.error('unhandledRejection:', reason?.message || reason, reason?.stack || '')
})

exports.createApp = async function () {
  dlog('createApp: start')
  app.setName(packInfo.name)
  // Disable GPU for stability — the HarmonyOS Electron runtime does not
  // support hardware-accelerated rendering reliably.
  app.commandLine.appendSwitch('disable-gpu')
  app.commandLine.appendSwitch('disable-gpu-compositing')
  app.commandLine.appendSwitch('disable-gpu-rasterization')
  app.commandLine.appendSwitch('use-gl', 'swiftshader')
  app.disableHardwareAcceleration()
  if (process.env.DISABLE_GPU_SANDBOX) {
    app.disableHardwareAcceleration()
    app.commandLine.appendSwitch('disable-gpu')
    app.commandLine.appendSwitch('disable-gpu-compositing')
    app.commandLine.appendSwitch('disable-gpu-rasterization')
    app.commandLine.appendSwitch('disable-gpu-sandbox')
    app.commandLine.appendSwitch('disable-software-rasterizer')
    app.commandLine.appendSwitch('use-gl', 'swiftshader')
  }
  // Handle proxy-related command-line arguments
  if (process.env.NO_PROXY_SERVER) {
    app.commandLine.appendSwitch('no-proxy-server')
  }
  if (process.env.PROXY_BYPASS_LIST) {
    app.commandLine.appendSwitch('proxy-bypass-list', process.env.PROXY_BYPASS_LIST)
  }
  if (process.env.PROXY_PAC_URL) {
    app.commandLine.appendSwitch('proxy-pac-url', process.env.PROXY_PAC_URL)
  }
  if (process.env.PROXY_SERVER) {
    app.commandLine.appendSwitch('proxy-server', process.env.PROXY_SERVER)
  }

  const progs = initCommandLine()
  const opts = progs?.options
  globalState.set('serverPort', opts?.serverPort)
  dlog('createApp: initCommandLine done, serverPort:', opts?.serverPort)

  dlog('createApp: calling getUserConfigNoEnc...')
  const { allowMultiInstance = false } = await getUserConfigNoEnc()
  dlog('createApp: getUserConfigNoEnc done, allowMultiInstance:', allowMultiInstance)

  // Setup deep link handlers (open-url for macOS, etc.)
  setupDeepLinkHandlers()
  dlog('createApp: setupDeepLinkHandlers done')
  // Only request single instance lock if multi-instance is not allowed
  if (!allowMultiInstance) {
    // Use socket-based single instance lock for compatibility with Electron 22
    // where additionalData doesn't work in the second-instance event
    dlog('createApp: calling handleSingleInstance...')
    const isPrimaryInstance = await handleSingleInstance(progs)
    dlog('createApp: handleSingleInstance done, isPrimaryInstance:', isPrimaryInstance)

    if (!isPrimaryInstance) {
      dlog('createApp: not primary instance, quitting')
      app.quit()
      return app
    }

    // Also use Electron's built-in lock as a fallback
    app.requestSingleInstanceLock()
  }
  dlog('createApp: setting up event handlers...')

  app.on('second-instance', (event, commandLine) => {
    const newWindowFlag = commandLine.includes('--new-window')
    if (newWindowFlag) {
      createWindow(conf)
      return
    }
    const win = globalState.get('win')
    if (win) {
      if (win.isMinimized()) {
        win.restore()
      }
      win.focus()
    }
  })
  app.whenReady().then(async () => {
    dlog('createApp: app.whenReady() fired')
    try {
      dlog('createApp: calling getDbConfig...')
      conf = await getDbConfig()
      dlog('createApp: getDbConfig done, calling createWindow...')
      await createWindow(conf)
      dlog('createApp: createWindow done')
    } catch (e) {
      dlog('createApp: ERROR in whenReady:', e?.message || e, e?.stack || '')
      log.error('Failed to create window:', e?.message || e, e?.stack || '')
    }
  })
  app.on('activate', () => {
    // On macOS it's common to re-create a window in the app when the
    // dock icon is clicked and there are no other windows open.
    if (globalState.get('win') === null) {
      app.once('ready', () => createWindow(conf))
    }
  })
  return app
}
