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
      js: '// electerm-web backend bundle (CJS) for Electron 鸿蒙\n'
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
const { app, BrowserWindow } = require('electron')
const path = require('path')
const http = require('http')

const __d = __dirname

// --- Runtime configuration for the on-device electerm server ---
process.env.NODE_ENV = 'production'
process.env.HOST = '127.0.0.1'
process.env.PORT = '5577'
process.env.SERVER_SECRET = 'electerm-harmony-local-dev-secret'
// No local shell on HarmonyOS without HNP — disable local terminal.
process.env.DISABLE_LOCAL_TERMINAL = '1'
process.env.VIEW_FOLDER = path.resolve(__d, 'views')

// --- Stable, app-private user-data directory ---
const fs = require('fs')
const userDataDir = path.resolve(__d, '..', '..', '..', 'electerm-data')
try { fs.mkdirSync(userDataDir, { recursive: true }) } catch {}
process.env.DB_PATH = userDataDir

// Create .ssh directory for SSH key storage
const sshDir = path.resolve(userDataDir, '.ssh')
try { fs.mkdirSync(sshDir, { recursive: true }) } catch {}
process.env.HOME = userDataDir

// --- Start the backend ---
let backendReady = false
let mainWindow = null

// The backend bundle starts the Express server on import.
try {
  require('./app.bundle.cjs')
} catch (err) {
  console.error('Failed to start backend:', err)
}

// --- Poll the backend until it's ready, then create the window ---
function pollBackend () {
  const req = http.get('http://127.0.0.1:5577', () => {
    backendReady = true
    createWindow()
  })
  req.on('error', () => {
    if (!backendReady) {
      setTimeout(pollBackend, 1000)
    }
  })
  req.setTimeout(2000, () => {
    req.destroy()
    if (!backendReady) {
      setTimeout(pollBackend, 1000)
    }
  })
}

function createWindow () {
  if (mainWindow) return

  mainWindow = new BrowserWindow({
    width: 1200,
    height: 800,
    webPreferences: {
      nodeIntegration: false,
      contextIsolation: true
    }
  })

  mainWindow.loadURL('http://127.0.0.1:5577')

  mainWindow.on('closed', () => {
    mainWindow = null
  })
}

app.whenReady().then(() => {
  console.log('Electron app ready, polling backend...')
  pollBackend()

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) {
      createWindow()
    }
  })
})

app.on('window-all-closed', () => {
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
