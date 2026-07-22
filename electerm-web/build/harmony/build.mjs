/**
 * Build the electerm HarmonyOS web bundle for the Electron 鸿蒙 runtime.
 *
 * Produces `build/harmony/resfile/resources/app/`, which gets placed into
 * the HarmonyOS app's resfile resources:
 *
 *   resfile/resources/app/
 *     ├── main.js              Electron main process (starts backend + creates BrowserWindow)
 *     ├── app.bundle.cjs       the electerm Node.js backend (esbuild CJS bundle)
 *     ├── package.json         { name, version, main }
 *     ├── views/
 *     │   └── index.pug        pug template for the Express index route
 *     └── dist/
 *         └── assets/          vite-built frontend (js, css, images, chunks)
 *
 * The Electron 鸿蒙 runtime (libelectron.so + libadapter.so) runs main.js
 * when XComponent.onLoad() calls nativeContext.runBrowser(). main.js starts
 * the Express backend, then creates a BrowserWindow that loads
 * http://127.0.0.1:5577.
 *
 * Key differences from the old ohos-node build:
 *   - No child_process shim (Electron provides child_process natively)
 *   - CJS format (Electron main process uses require())
 *   - No loading.html (BrowserWindow replaces WebView + HTTP polling)
 *   - No index.js node entry script (main.js is the Electron entry)
 *   - Output goes to resfile/ (directly accessible) not rawfile/ (needs extraction)
 */
import { build as viteBuild } from 'vite'
import * as esbuild from 'esbuild'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)
const ROOT = path.resolve(__dirname, '..', '..') // build/harmony -> electerm-web root

// Make every path that reads process.cwd() resolve against the repo root,
// regardless of where this script is invoked from.
process.chdir(ROOT)

const OUTPUT_DIR = path.resolve(__dirname, 'resfile', 'resources', 'app')
const VERSION = JSON.parse(
  fs.readFileSync(path.resolve(ROOT, 'package.json'), 'utf8')
).version

// --------------------------------------------------------------------------
// 1. Frontend (Vite)
// --------------------------------------------------------------------------
async function runVite () {
  console.log('[harmony] building frontend (vite)…')
  await viteBuild({
    configFile: path.resolve(__dirname, 'vite.harmony.mjs'),
    root: ROOT,
    logLevel: 'warn'
  })
}

// --------------------------------------------------------------------------
// 2. Static assets for the node project
// --------------------------------------------------------------------------
function copyDir (from, to) {
  if (!fs.existsSync(from)) {
    console.warn('[harmony] skip missing source:', from)
    return
  }
  fs.mkdirSync(to, { recursive: true })
  for (const entry of fs.readdirSync(from, { withFileTypes: true })) {
    const s = path.join(from, entry.name)
    const d = path.join(to, entry.name)
    if (entry.isDirectory()) copyDir(s, d)
    else fs.copyFileSync(s, d)
  }
}

function copyFrontendAssets () {
  console.log('[harmony] copying static assets into node project…')
  const assets = path.resolve(OUTPUT_DIR, 'dist', 'assets')

  copyDir(path.resolve(ROOT, 'src/client/statics'), assets)
  copyDir(
    path.resolve(ROOT, 'node_modules/electerm-icons/icons'),
    path.resolve(assets, 'icons')
  )
  copyDir(
    path.resolve(ROOT, 'node_modules/@electerm/electerm-resource/res/imgs'),
    path.resolve(assets, 'images')
  )
  copyDir(
    path.resolve(ROOT, 'node_modules/@electerm/electerm-resource/tray-icons'),
    path.resolve(assets, 'images')
  )

  fs.mkdirSync(path.resolve(OUTPUT_DIR, 'views'), { recursive: true })
  fs.copyFileSync(
    path.resolve(ROOT, 'src/app/views/index.pug'),
    path.resolve(OUTPUT_DIR, 'views/index.pug')
  )

  // Copy tray icon — HarmonyOS requires a Tray before BrowserWindow can display
  const trayIconSrc = path.resolve(
    ROOT, 'node_modules/@electerm/electerm-resource/res/imgs/electerm-round-128x128.png'
  )
  if (fs.existsSync(trayIconSrc)) {
    fs.copyFileSync(trayIconSrc, path.resolve(OUTPUT_DIR, 'tray-icon.png'))
    console.log('[harmony] copied tray-icon.png')
  } else {
    console.warn('[harmony] tray icon not found at', trayIconSrc)
  }
}

// --------------------------------------------------------------------------
// 3. Backend (esbuild) — CJS format for Electron main process
// --------------------------------------------------------------------------

// esbuild plugin: mark all .node native-addon files as external.
// Native binaries (cpufeatures.node, sshcrypto.node, etc.) are not present
// on the device; the libraries that use them have pure-JS fallbacks guarded
// by try/catch.
const nativeNodePlugin = {
  name: 'native-node-files',
  setup (build) {
    build.onResolve({ filter: /\.node$/ }, (args) => ({
      path: args.path,
      external: true
    }))
  }
}

async function bundleBackend () {
  console.log('[harmony] bundling backend (esbuild)…')

  await esbuild.build({
    entryPoints: [path.resolve(ROOT, 'src/app/app.js')],
    bundle: true,
    format: 'cjs',
    platform: 'node',
    target: 'node20',
    outfile: path.resolve(OUTPUT_DIR, 'app.bundle.cjs'),
    // Native modules that are not built for HarmonyOS yet. Keep them external
    // so esbuild never tries to resolve them; the guarded import() calls in
    // the source fall back gracefully at runtime.
    external: [
      'node-pty',
      'serialport',
      'node-bash',
      'font-list',
      // Electron built-in modules — provided by the Electron runtime
      'electron'
    ],
    // In CJS, __dirname and __filename are already defined by Node.js.
    // We only need to provide `require` for modules that check for it.
    banner: {
      js: '// electerm-web backend bundle (CJS) for Electron 鸿蒙\n' +
          'var __import_meta_url = (typeof require !== "undefined" && require("url").pathToFileURL(__filename).href) || "";\n'
    },
    define: {
      'import.meta.url': '__import_meta_url'
    },
    plugins: [nativeNodePlugin],
    // keep node built-ins external; everything else is bundled
    logLevel: 'info'
  })
}

// --------------------------------------------------------------------------
// 4. Electron main process (main.js)
// --------------------------------------------------------------------------
// This is the Electron main process entry point. It:
//   1. Sets environment variables for the electerm-web backend
//   2. Starts the Express backend (app.bundle.cjs)
//   3. Polls the backend until it's ready
//   4. Creates a BrowserWindow that loads http://127.0.0.1:5577
//
// No child_process shim needed — Electron provides child_process natively.
// Local terminal is disabled via DISABLE_LOCAL_TERMINAL=1 since HarmonyOS
// doesn't have a local shell accessible without HNP packaging.

function writeMainJs () {
  const main = `/**
 * Electron main process for electerm on HarmonyOS.
 *
 * This file is run by the Electron 鸿蒙 runtime (libelectron.so) when
 * the HarmonyOS app calls nativeContext.runBrowser().
 *
 * It starts the electerm-web Express backend, then opens a BrowserWindow
 * that loads the frontend from the backend's HTTP server.
 */
const { app, BrowserWindow, Tray, nativeImage } = require('electron')
const path = require('path')
const http = require('http')
const fs = require('fs')
const os = require('os')

const __d = __dirname

// --- File-based error logging (for cloud-test debugging) -------------------
// On cloud test devices console output is not visible. We write a log file
// to every writable directory we can find so the user can retrieve it.
var _logFds = []
function initLogFds () {
  var dirs = []
  try { dirs.push(app.getPath('userData')) } catch {}
  try { dirs.push(path.join(process.env.HOME || os.homedir(), 'electerm-logs')) } catch {}
  dirs.push(path.join(os.tmpdir(), 'electerm-logs'))
  dirs.push('/tmp/electerm-logs')
  dirs.push('/data/local/tmp/electerm-logs')
  for (var i = 0; i < dirs.length; i++) {
    if (!dirs[i]) continue
    try {
      fs.mkdirSync(dirs[i], { recursive: true })
      var fd = fs.openSync(path.join(dirs[i], 'main.log'), 'a')
      fs.writeSync(fd, '--- Log started ' + new Date().toISOString() + ' ---\\n')
      _logFds.push(fd)
    } catch {}
  }
}
function logMsg () {
  var msg = '[' + new Date().toISOString() + '] ' +
    Array.prototype.slice.call(arguments).map(function (a) {
      if (typeof a === 'string') return a
      if (a && a.stack) return a.stack
      try { return JSON.stringify(a) } catch (e) { return String(a) }
    }).join(' ') + '\\n'
  console.log(msg)
  for (var i = 0; i < _logFds.length; i++) {
    try { fs.writeSync(_logFds[i], msg) } catch {}
  }
}

initLogFds()
logMsg('=== electerm main.js starting ===')
logMsg('Node.js version:', process.versions.node || 'unknown')
logMsg('Electron version:', process.versions.electron || 'unknown')
logMsg('__dirname:', __d)

// Catch all uncaught errors so they appear in the log file
var backendError = null
process.on('uncaughtException', function (err) {
  logMsg('UNCAUGHT EXCEPTION:', err)
  if (!backendError) backendError = err
})
process.on('unhandledRejection', function (err) {
  logMsg('UNHANDLED REJECTION:', err)
  if (!backendError) backendError = err
})

// --- Runtime configuration for the on-device electerm server ---
process.env.NODE_ENV = 'production'
process.env.HOST = '127.0.0.1'
process.env.PORT = '5577'
process.env.SERVER_SECRET = 'electerm-harmony-local-dev-secret'
// No local shell on HarmonyOS without HNP — disable local terminal.
process.env.DISABLE_LOCAL_TERMINAL = '1'
process.env.VIEW_FOLDER = path.resolve(__d, 'views')

// Set cwd to the app directory so all relative paths in the backend resolve correctly.
// On HarmonyOS, process.cwd() may point to an unexpected location (e.g. /).
try { process.chdir(__d) } catch (e) { logMsg('chdir failed:', e.message) }
logMsg('cwd:', process.cwd())

// --- Determine a WRITABLE user-data directory -------------------------------
// resfile/ (where main.js lives) is read-only on HarmonyOS.
// We must find a writable directory for the SQLite database and SSH keys.
function findWritableDir () {
  var candidates = []
  // 1. app.getPath('userData') — Electron standard user data path
  try { var ud = app.getPath('userData'); if (ud) candidates.push(ud) } catch {}
  // 2. HOME / os.homedir()
  try { var home = process.env.HOME || os.homedir(); if (home) candidates.push(path.join(home, 'electerm-data')) } catch {}
  // 3. OS temp directory
  candidates.push(path.join(os.tmpdir(), 'electerm-data'))
  // 4. Common HarmonyOS writable paths
  candidates.push('/data/local/tmp/electerm-data')

  for (var i = 0; i < candidates.length; i++) {
    var dir = candidates[i]
    try {
      fs.mkdirSync(dir, { recursive: true })
      // Verify write permission
      var testFile = path.join(dir, '.write-test')
      fs.writeFileSync(testFile, 'ok')
      fs.unlinkSync(testFile)
      logMsg('Using data directory:', dir)
      return dir
    } catch (e) {
      logMsg('Directory not writable:', dir, '-', e.message)
    }
  }
  // Last resort — will likely fail but at least we tried
  logMsg('WARNING: No writable directory found!')
  return path.resolve(__d, '..', '..', '..', 'electerm-data')
}

var userDataDir = findWritableDir()
process.env.DB_PATH = userDataDir

// Create .ssh directory for SSH key storage
var sshDir = path.resolve(userDataDir, '.ssh')
try { fs.mkdirSync(sshDir, { recursive: true }) } catch (e) {
  logMsg('Failed to create .ssh dir:', e.message)
}
process.env.HOME = userDataDir

// --- Check node:sqlite availability -----------------------------------------
// electerm-web tries node:sqlite (Node.js 22+) first, then falls back to
// a JSON-based shim (sqlite-shim.js). This check is for logging only.
try {
  require('node:sqlite')
  logMsg('node:sqlite: available (native)')
} catch (e) {
  logMsg('node:sqlite: NOT available, using JSON shim fallback')
}

// --- Start the backend ---
var backendReady = false
var mainWindow = null
var pollCount = 0
var MAX_POLLS = 30 // 30 attempts x 1s = 30s timeout

logMsg('Requiring backend bundle...')
try {
  require('./app.bundle.cjs')
  logMsg('Backend bundle loaded successfully')
} catch (err) {
  backendError = err
  logMsg('FAILED to start backend:', err)
}

// --- Poll the backend until it's ready, then create the window ---
function pollBackend () {
  pollCount++
  if (pollCount > MAX_POLLS) {
    logMsg('Backend poll timeout after', MAX_POLLS, 'attempts. Backend did not start.')
    var errInfo = backendError
      ? ('Backend error: ' + (backendError.stack || backendError.message || String(backendError))).substring(0, 2000)
      : 'No error captured — backend loaded but never responded on port 5577.'
    createErrorWindow(
      'Backend failed to start within 30 seconds.\\n\\n' +
      'Node.js: ' + (process.versions.node || 'unknown') + '\\n' +
      'Electron: ' + (process.versions.electron || 'unknown') + '\\n' +
      'cwd: ' + process.cwd() + '\\n' +
      '__dirname: ' + __d + '\\n\\n' +
      errInfo + '\\n\\n' +
      'Check ~/electerm-logs/main.log for details.'
    )
    return
  }

  var req = http.get('http://127.0.0.1:5577', function (res) {
    logMsg('Backend responded:', res.statusCode)
    backendReady = true
    createWindow()
  })
  req.on('error', function (err) {
    if (!backendReady) {
      if (pollCount <= 3 || pollCount % 10 === 0) {
        logMsg('Backend not ready (attempt ' + pollCount + '):', err.message)
      }
      setTimeout(pollBackend, 1000)
    }
  })
  req.setTimeout(2000, function () {
    req.destroy()
    if (!backendReady) {
      setTimeout(pollBackend, 1000)
    }
  })
}

var tray = null

function createWindow () {
  if (mainWindow) return

  logMsg('Creating Tray...')
  // HarmonyOS requires a Tray before any BrowserWindow can be displayed.
  // Without a Tray, windows may not show or may show as blank.
  try {
    var iconPath = path.resolve(__d, 'tray-icon.png')
    if (fs.existsSync(iconPath)) {
      tray = new Tray(nativeImage.createFromPath(iconPath))
    } else {
      tray = new Tray(nativeImage.createEmpty())
    }
    logMsg('Tray created')
  } catch (e) {
    logMsg('Tray creation failed:', e.message)
  }

  logMsg('Creating BrowserWindow...')

  mainWindow = new BrowserWindow({
    width: 1200,
    height: 800,
    webPreferences: {
      nodeIntegration: false,
      contextIsolation: true
    }
  })

  mainWindow.loadURL('http://127.0.0.1:5577')
  logMsg('Loading URL: http://127.0.0.1:5577')

  mainWindow.webContents.on('did-fail-load', function (event, errorCode, errorDescription) {
    logMsg('Window did-fail-load:', errorCode, errorDescription)
  })
  mainWindow.webContents.on('did-finish-load', function () {
    logMsg('Window did-finish-load')
  })

  mainWindow.on('closed', function () {
    mainWindow = null
  })
}

function createErrorWindow (message) {
  if (mainWindow) return

  // Ensure tray exists before creating error window
  if (!tray) {
    try { tray = new Tray(nativeImage.createEmpty()) } catch (e) {}
  }

  mainWindow = new BrowserWindow({
    width: 800,
    height: 600,
    webPreferences: {
      nodeIntegration: false,
      contextIsolation: true
    }
  })

  var html = '<html><body style="font-family:monospace;padding:40px;background:#1e1e1e;color:#ff6b6b;">' +
    '<h2>Electerm Failed to Start</h2>' +
    '<pre style="white-space:pre-wrap;">' + message + '</pre>' +
    '</body></html>'

  mainWindow.loadURL('data:text/html;charset=utf-8,' + encodeURIComponent(html))
}

app.whenReady().then(function () {
  logMsg('Electron app ready, polling backend...')
  pollBackend()
})

app.on('window-all-closed', function () {
  // On HarmonyOS, quit when all windows are closed.
  app.quit()
})
`

  fs.writeFileSync(path.resolve(OUTPUT_DIR, 'main.js'), main)

  fs.writeFileSync(
    path.resolve(OUTPUT_DIR, 'package.json'),
    JSON.stringify(
      {
        name: 'electerm-electron',
        version: VERSION,
        main: 'main.js',
        description: 'electerm HarmonyOS Electron app'
      },
      null,
      2
    )
  )
}

// --------------------------------------------------------------------------
// Pre-build: copy @electerm/electerm-react client into src/client/
// --------------------------------------------------------------------------
function installElectermReact () {
  const src = path.resolve(ROOT, 'node_modules/@electerm/electerm-react/client')
  const dest = path.resolve(ROOT, 'src/client/electerm-react')
  if (!fs.existsSync(src)) {
    console.warn('[harmony] @electerm/electerm-react/client not found — run npm install first')
    return
  }
  fs.rmSync(dest, { recursive: true, force: true })
  fs.cpSync(src, dest, { recursive: true })
  console.log('[harmony] copied @electerm/electerm-react/client → src/client/electerm-react/')
}

// --------------------------------------------------------------------------
// Main
// --------------------------------------------------------------------------
async function main () {
  console.log('[harmony] building electerm HarmonyOS Electron bundle…')
  console.log('[harmony] version:', VERSION)
  console.log('[harmony] output:', OUTPUT_DIR)

  // Pre-build: ensure src/client/electerm-react/ exists
  installElectermReact()

  fs.rmSync(OUTPUT_DIR, { recursive: true, force: true })
  fs.mkdirSync(OUTPUT_DIR, { recursive: true })

  await runVite()
  copyFrontendAssets()

  await bundleBackend()
  writeMainJs()

  // Summary
  const size = getDirSize(OUTPUT_DIR)
  console.log('[harmony] build complete!')
  console.log('[harmony] output:', OUTPUT_DIR)
  console.log('[harmony] total size:', formatBytes(size))
}

function getDirSize (dir) {
  let size = 0
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, entry.name)
    if (entry.isDirectory()) {
      size += getDirSize(p)
    } else {
      size += fs.statSync(p).size
    }
  }
  return size
}

function formatBytes (bytes) {
  if (bytes < 1024) return bytes + ' B'
  if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB'
  return (bytes / (1024 * 1024)).toFixed(1) + ' MB'
}

main().catch((e) => {
  console.error(e)
  process.exit(1)
})
