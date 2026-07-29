const {
  BrowserWindow, screen
} = require('electron')
const { resolve } = require('path')
const {
  isDev, packInfo, iconPath, isMac,
  minWindowWidth, minWindowHeight
} = require('../common/runtime-constants')
const {
  getWindowSize,
  setWindowPos
} = require('./window-control')
const { ensureWindowVisible } = require('./window-restore')
const { onClose } = require('./on-close')
const { initIpc, initAppServer } = require('./ipc')
const { disableShortCuts } = require('./key-bind')
const _ = require('./lodash.js')
const getPort = require('./get-port')
const globalState = require('./glob-state')
const webviewHandler = require('./webview-handler')
const log = require('../common/log')

exports.createWindow = async function (userConfig) {
  log.info('createWindow: starting...')
  globalState.set('closeAction', 'closeApp')
  globalState.set('requireAuth', !!userConfig.hashedPassword)
  const { width, height, x, y } = await getWindowSize()
  // HarmonyOS: `transparent: true` and `titleBarStyle: 'hidden'` are NOT
  // supported — they cause a double title bar (the OS title bar plus the
  // app's custom one). We therefore always use the system title bar,
  // mirroring the override in get-config.js.
  // `frame` IS supported, so once transparent/titleBarStyle are supported,
  // remove this line to respect the user's useSystemTitleBar setting.
  // useSystemTitleBar = true
  const win = new BrowserWindow({
    width,
    height,
    x,
    y,
    fullscreenable: true,
    minWidth: minWindowWidth,
    minHeight: minWindowHeight,
    title: packInfo.name,
    frame: true,
    backgroundColor: '#333333',
    autoHideMenuBar: true,
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      enableRemoteModule: false,
      preload: resolve(__dirname, '../preload/preload.js'),
      webviewTag: true,
      devTools: !userConfig.disableDeveloperTool,
      spellcheck: false
    },
    icon: iconPath
  })
  // Safety net: verify the window is actually visible on a connected
  // display and move it to the primary display if not.
  ensureWindowVisible(win, screen)

  // macOS: show the traffic-light buttons
  if (isMac) {
    win.setWindowButtonVisibility(true)
  }

  win.webContents.session.setSpellCheckerDictionaryDownloadURL('https://00.00/')

  webviewHandler.init(win)

  globalState.set('win', win)
  log.info('createWindow: BrowserWindow created, starting initAppServer...')

  try {
    await initAppServer()
    log.info('createWindow: initAppServer done')
  } catch (e) {
    log.error('createWindow: initAppServer failed:', e?.message || e, e?.stack || '')
    // Show error page in the window instead of leaving black screen
    const htmlContent = `<html><body style="background:#1e1e1e;color:#fff;font-family:monospace;padding:20px;"><h2>Server failed to start</h2><pre>${e?.message || e}</pre></body></html>`
    const dataUrl = `data:text/html;charset=utf-8,${encodeURIComponent(htmlContent)}`
    win.loadURL(dataUrl)
    return
  }

  initIpc()
  log.info('createWindow: initIpc done')
  const port = isDev
    ? process.env.devPort || 5570
    : await getPort()
  const opts = `http://127.0.0.1:${port}/index.html?v=${packInfo.version}`
  log.info('createWindow: loading URL:', opts)
  // If loading the URL fails (e.g. proxy/firewall interference), show error page
  win.webContents.once('did-fail-load', (event, errorCode, errorDescription) => {
    log.error('createWindow: did-fail-load:', errorCode, errorDescription)
    const htmlContent = require('./error-page')(port)
    const dataUrl = `data:text/html;charset=utf-8,${encodeURIComponent(htmlContent)}`
    win.loadURL(dataUrl)
  })
  win.loadURL(opts)
  win.webContents.once('dom-ready', () => {
    log.info('createWindow: dom-ready')
    if (isDev && !userConfig.disableDeveloperTool) {
      win.webContents.openDevTools()
    }
    win.on('unmaximize', () => {
      const { width, height } = win.getBounds()
      if (width < minWindowWidth || height < minWindowHeight) {
        win.setBounds({
          x: 0,
          y: 0,
          width: minWindowWidth,
          height: minWindowHeight
        })
        win.center()
      }
    })
    win.on('resize', _.debounce(() => {
      if (!win.isMaximized()) {
        globalState.set('oldRectangle', win.getBounds())
      }
    }, 200))
    win.on('move', _.debounce(() => {
      const { x, y } = win.getBounds()
      setWindowPos({ x, y })
    }, 100))

    win.on('focus', () => {
      win.webContents.send('focused', null)
    })
    win.on('blur', () => {
      win.webContents.send('blur', null)
    })
    disableShortCuts(win)
  })
  win.on('close', onClose)
}
