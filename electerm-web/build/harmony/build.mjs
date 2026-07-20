/**
 * Build the electerm HarmonyOS web bundle.
 *
 * Produces `build/harmony/rawfile/electerm/`, which gets copied into the
 * HarmonyOS app's rawfile resources:
 *
 *   rawfile/electerm/
 *     ├── loading.html            local "loading" page (waits for the Node backend)
 *     ├── index.js                node entry script (sets env, imports app.bundle.mjs)
 *     ├── app.bundle.mjs          the electerm Node.js backend (esbuild bundle)
*     ├── package.json            { name, version, main, type:module }
*     ├── views/
 *     │   └── index.pug           pug template for the Express index route
 *     └── dist/
 *         └── assets/             vite-built frontend (js, css, images, chunks)
 *
 * The HarmonyOS app extracts these from rawfile to its sandbox at runtime,
 * then spawns the ohos-node binary to run `index.js`.
 *
 * Key differences from the Android build (build/android/build.mjs):
 *   - Target: node24 (not node18) — ohos-node is Node 24
 *   - No node:sqlite shim — Node 24 has it built-in
 *   - No path-to-regexp regex patch — Node 24 has full ICU
 *   - child_process is aliased to a no-op shim (see child-process-shim.mjs)
 *   - Native modules (node-pty, serialport, node-bash, font-list) kept external
 */
import { build as viteBuild } from 'vite'
import * as esbuild from 'esbuild'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)
const ROOT = path.resolve(__dirname, '..', '..') // build/harmony -> electerm-web root

// Make every path that reads process.cwd() resolve against the repo root,
// regardless of where this script is invoked from.
process.chdir(ROOT)

const OUTPUT_DIR = path.resolve(__dirname, 'rawfile', 'electerm')
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
// 3. Loading page (tiny HTML that polls the backend, then redirects)
// --------------------------------------------------------------------------
function writeLoadingPage () {
  const html = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover" />
  <title>electerm</title>
  <style>
    html, body { height: 100%; margin: 0; background: #15171a; color: #cfd6e4;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
    .wrap { height: 100%; display: flex; flex-direction: column; align-items: center;
      justify-content: center; gap: 18px; padding: 20px; box-sizing: border-box; }
    .logo { font-size: 22px; font-weight: 600; letter-spacing: .5px; }
    .spin { width: 34px; height: 34px; border: 3px solid rgba(255,255,255,.15);
      border-top-color: #4aa3ff; border-radius: 50%; animation: r 1s linear infinite; }
    @keyframes r { to { transform: rotate(360deg); } }
    .msg { font-size: 13px; opacity: .7; text-align: center; max-width: 320px; word-break: break-word; }
    .err { color: #ff6b6b; display: none; }
    .retry { display: none; margin-top: 10px; padding: 8px 20px; background: #4aa3ff;
      color: #fff; border: none; border-radius: 6px; font-size: 14px; cursor: pointer; }
  </style>
</head>
<body>
  <div class="wrap">
    <div class="logo">electerm</div>
    <div class="spin" id="spin"></div>
    <div class="msg" id="msg">Starting engine…</div>
    <div class="msg err" id="err"></div>
    <button class="retry" id="retry" onclick="location.reload()">Retry</button>
  </div>
  <script>
    var PORT = 5577;
    var BASE = 'http://127.0.0.1:' + PORT + '/';
    var done = false;
    var attempts = 0;
    var startTime = Date.now();
    var MAX_WAIT = 60000; // 60 seconds before showing error

    function go () {
      if (done) return;
      done = true;
      location.replace(BASE);
    }

    function tryLoad () {
      if (done) return;
      attempts++;
      var elapsed = Date.now() - startTime;

      fetch(BASE, { mode: 'no-cors' })
        .then(function () {
          document.getElementById('msg').textContent = 'Engine ready, loading…';
          go();
        })
        .catch(function () {
          if (done) return;
          if (elapsed > MAX_WAIT) {
            document.getElementById('spin').style.display = 'none';
            document.getElementById('msg').textContent = 'Backend unreachable after ' + Math.round(elapsed / 1000) + 's';
            document.getElementById('err').textContent =
              'The Node.js engine failed to start. Possible causes:\\n' +
              '• process.runCmd not available on this device\\n' +
              '• Node binary architecture mismatch\\n' +
              '• Backend crashed during startup\\n' +
              'Attempts: ' + attempts;
            document.getElementById('err').style.display = 'block';
            document.getElementById('retry').style.display = 'block';
            return;
          }
          document.getElementById('msg').textContent =
            'Waiting for engine… (' + Math.round(elapsed / 1000) + 's)';
          setTimeout(tryLoad, 1000);
        });
    }
    tryLoad();
  </script>
</body>
</html>
`
  fs.writeFileSync(path.resolve(OUTPUT_DIR, 'loading.html'), html)
}

// --------------------------------------------------------------------------
// 4. Backend (esbuild) with child_process shim + native module externals
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
  const shimPath = path.resolve(__dirname, 'child-process-shim.mjs')

  await esbuild.build({
    entryPoints: [path.resolve(ROOT, 'src/app/app.js')],
    bundle: true,
    format: 'esm',
    platform: 'node',
    target: 'node24',
    outfile: path.resolve(OUTPUT_DIR, 'app.bundle.mjs'),
    alias: {
      // Replace child_process with our no-op shim. Every import of
      // 'child_process' in the backend resolves to the shim instead of the
      // real Node.js built-in. The shim fails gracefully (callbacks receive
      // an Error, spawn returns a dummy EventEmitter that emits 'error').
      'child_process': shimPath
    },
    // Native modules that are not built for HarmonyOS yet. Keep them external
    // so esbuild never tries to resolve them; the guarded import() calls in
    // the source fall back gracefully at runtime (see DISABLE_LOCAL_TERMINAL).
    external: [
      'node-pty',
      'serialport',
      'node-bash',
      'font-list'
    ],
    // Some bundled CJS deps reference __dirname / __filename, which don't
    // exist in an ESM bundle. Define them from import.meta.url.
    // NOTE: do NOT `import { dirname } from "path"` here — the bundle already
    // imports `dirname` at top level, which would collide. Alias fileURLToPath
    // to a private name for the same reason, and derive __dirname from a
    // directory URL.
    banner: {
      js: "import { createRequire } from 'module'; import { fileURLToPath as __etu } from 'url'; const require = createRequire(import.meta.url); const __filename = __etu(import.meta.url); const __dirname = __etu(new URL('.', import.meta.url));"
    },
    plugins: [nativeNodePlugin],
    // keep node built-ins external; everything else is bundled
    logLevel: 'info'
  })
}

// --------------------------------------------------------------------------
// 5. Runtime .env — SKIPPED
// --------------------------------------------------------------------------
// All env vars are set directly in index.js via process.env.* assignments.
// .env is not needed, and HarmonyOS resourceManager cannot handle dotfile
// names (files starting with ".") — getRawFileContent returns ENOENT.
// dotenv.config() in app.bundle.mjs will silently skip if .env is absent.

// --------------------------------------------------------------------------
// 6. Node entry script (index.js)
// --------------------------------------------------------------------------
function writeNodeEntry () {
  const entry = `import { resolve } from 'node:path'
import { mkdirSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

const __d = fileURLToPath(new URL('.', import.meta.url))

// The Node.js engine may start with cwd "/" or some other directory.
// electerm's runtime-constants.js reads "package.json" via
// resolve(process.cwd(), 'package.json'), so without chdir it tries to open
// "/package.json" -> ENOENT -> uncaught exception.
// Switch cwd to the project directory before loading the backend bundle.
process.chdir(__d)

// Runtime configuration for the on-device electerm server.
process.env.NODE_ENV = 'production'
process.env.HOST = '127.0.0.1'
process.env.PORT = '5577'
// Local-only app: a fixed secret is fine. ENABLE_AUTH is not set, so the
// web UI auto-logs-in without a JWT challenge.
process.env.SERVER_SECRET = 'electerm-harmony-local-dev-secret'
// No real pty on HarmonyOS -> disable the local terminal feature.
process.env.DISABLE_LOCAL_TERMINAL = '1'
// Tell the server where the pug views live (cwd is now the node project dir).
process.env.VIEW_FOLDER = resolve(__d, 'views')

// Stable, app-private user-data directory.
// The Node.js project is extracted by the HarmonyOS app into its internal
// storage (filesDir/electerm/). If we keep user data inside that extracted
// project it can be wiped when the bundled node project is refreshed on an
// app update. Putting it in a sibling directory keeps the database, uploads
// and logs safe across updates.
const userDataDir = (() => {
  try {
    const dir = resolve(__d, '..', 'electerm-data')
    mkdirSync(dir, { recursive: true })
    return dir
  } catch (e) {
    const fallback = resolve(__d, 'data')
    mkdirSync(fallback, { recursive: true })
    return fallback
  }
})()
process.env.DB_PATH = userDataDir

// HarmonyOS may not set a meaningful HOME directory. Point HOME at the
// writable user-data directory so that:
//   - os.homedir() returns a path the app can read/write
//   - SSH keys stored in <userDataDir>/.ssh are found automatically
//   - The .ssh dir is created once on first launch
const sshDir = resolve(userDataDir, '.ssh')
mkdirSync(sshDir, { recursive: true })
process.env.HOME = userDataDir

await import('./app.bundle.mjs')
`
  fs.writeFileSync(path.resolve(OUTPUT_DIR, 'index.js'), entry)
  fs.writeFileSync(
    path.resolve(OUTPUT_DIR, 'package.json'),
    JSON.stringify(
      { name: 'electerm-node', version: VERSION, main: 'index.js', type: 'module' },
      null,
      2
    )
  )
}

// --------------------------------------------------------------------------
// Pre-build: copy @electerm/electerm-react client into src/client/
// --------------------------------------------------------------------------
// The frontend source imports from '../electerm-react/...' which resolves
// to src/client/electerm-react/. This directory is a copy of the
// @electerm/electerm-react npm package's client/ folder. The Android build
// does the same thing via build/bin/install.js (which uses shelljs).
// We use Node's built-in fs.cpSync to avoid the shelljs dependency.
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
  console.log('[harmony] building electerm HarmonyOS bundle…')
  console.log('[harmony] version:', VERSION)
  console.log('[harmony] output:', OUTPUT_DIR)

  // Pre-build: ensure src/client/electerm-react/ exists
  installElectermReact()

  fs.rmSync(OUTPUT_DIR, { recursive: true, force: true })
  fs.mkdirSync(OUTPUT_DIR, { recursive: true })

  await runVite()
  copyFrontendAssets()
  writeLoadingPage()

  await bundleBackend()
  writeNodeEntry()
  // copyEnv() — skipped, env vars are set in index.js

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
