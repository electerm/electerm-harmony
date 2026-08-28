/**
 * Build the electerm HarmonyOS (ArkWeb) web bundle.
 *
 * Modelled on build/android/build.mjs from electerm-android. Produces the
 * Node.js project that runs on-device inside the HarmonyOS app:
 *
 *   entry/src/main/resources/resfile/electerm/
 *     ├── index.js         entry started by the on-device node binary; sets
 *                          env (HOST/PORT/SERVER_SECRET/data dirs) then
 *                          imports app.bundle.mjs
 *     ├── app.bundle.mjs   esbuild-bundled electerm backend (pure node,
 *                          no electron APIs)
 *     ├── package.json     read by runtime-constants.js via process.cwd()
 *     ├── views/index.pug  server-rendered shell for the UI
 *     └── dist/assets/     vite-built frontend + static assets
 *
 * The resfile directory is packaged into the HAP as-is and is directly
 * readable by the Node.js child process at
 * /data/storage/el1/bundle/entry/resource/resfile/electerm — no runtime
 * extraction needed.
 *
 * Differences vs the Android build:
 *   - No Capacitor www/ layout; output goes straight into the entry module.
 *   - No sql.js shim: the on-device runtime is hqzing/ohos-node v24 LTS
 *     (node:sqlite available without flags).
 *   - No path-to-regexp regex patch: that worked around nodejs-mobile's
 *     stripped ICU; ohos-node is a full build.
 *   - SERVER_SECRET is baked in at build time (from SERVER_SECRET /
 *     OHOS_SERVER_SECRET env; CI must provide it).
 *   - User data dir is passed at runtime via ELECTERM_DATA_DIR (the resfile
 *     install dir is read-only), so nothing about it is baked here.
 */
import { build as viteBuild } from 'vite'
import * as esbuild from 'esbuild'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)
const ROOT = path.resolve(__dirname, '..', '..') // build/web -> repo root

process.chdir(ROOT)

const OUT_DIR = path.resolve(ROOT, 'entry/src/main/resources/resfile/electerm')
const VERSION = JSON.parse(
  fs.readFileSync(path.resolve(ROOT, 'package.json'), 'utf8')
).version

// JWT secret for the on-device server.
// In CI this MUST come from the SERVER_SECRET / OHOS_SERVER_SECRET Action
// secret. Local development falls back to a fixed value.
const LOCAL_DEV_SECRET = 'electerm-harmony-local-dev-secret'
const SERVER_SECRET = process.env.SERVER_SECRET || process.env.OHOS_SERVER_SECRET || LOCAL_DEV_SECRET
if (process.env.CI && SERVER_SECRET === LOCAL_DEV_SECRET) {
  console.error(
    '[web] FATAL: SERVER_SECRET is not set. Add it to the repository GitHub Actions secrets (gh secret set SERVER_SECRET).'
  )
  process.exit(1)
}

function copyDir (from, to) {
  if (!fs.existsSync(from)) {
    console.warn('[web] skip missing source:', from)
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

// --------------------------------------------------------------------------
// 1. Frontend (vite)
// --------------------------------------------------------------------------
async function runVite () {
  console.log('[web] building frontend (vite)…')
  await viteBuild({
    configFile: path.resolve(__dirname, 'vite.web.mjs'),
    root: ROOT,
    logLevel: 'warn'
  })
}

// --------------------------------------------------------------------------
// 2. Static assets for the node project
// --------------------------------------------------------------------------
function copyFrontendAssets () {
  console.log('[web] copying static assets into node project…')
  const assets = path.resolve(OUT_DIR, 'dist/assets')

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

  fs.mkdirSync(path.resolve(OUT_DIR, 'views'), { recursive: true })
  fs.copyFileSync(
    path.resolve(ROOT, 'src/app/views/index.pug'),
    path.resolve(OUT_DIR, 'views/index.pug')
  )
}

// --------------------------------------------------------------------------
// 3. Backend (esbuild)
// --------------------------------------------------------------------------

// Mark all .node native-addon files external: the native binaries are not
// built for HarmonyOS and the libraries that use them have pure-JS fallbacks
// guarded by try/catch (see DISABLE_LOCAL_TERMINAL below).
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
  console.log('[web] bundling backend (esbuild)…')
  await esbuild.build({
    entryPoints: [path.resolve(ROOT, 'src/app/app.js')],
    bundle: true,
    format: 'esm',
    platform: 'node',
    // hqzing/ohos-node v24 LTS runs on device
    target: 'node22',
    outfile: path.resolve(OUT_DIR, 'app.bundle.mjs'),
    // Native modules that cannot be built for HarmonyOS. Kept external so
    // esbuild never resolves them; guarded imports fall back at runtime.
    external: [
      'node-pty',
      'serialport',
      'node-bash',
      'font-list'
    ],
    banner: {
      js: "import { createRequire } from 'module'; import { fileURLToPath as __etu } from 'url'; const require = createRequire(import.meta.url); const __filename = __etu(import.meta.url); const __dirname = __etu(new URL('.', import.meta.url));"
    },
    plugins: [nativeNodePlugin],
    // keep node built-ins external; everything else is bundled
    logLevel: 'info'
  })
}

// --------------------------------------------------------------------------
// 4. Entry script + package.json
// --------------------------------------------------------------------------

function writeNodeEntry () {
  const entry = `import { resolve } from 'node:path'
import { mkdirSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

const __d = fileURLToPath(new URL('.', import.meta.url))

// The node binary is exec'd by the native launcher with cwd inherited from
// the app process; electerm's runtime-constants.js reads "package.json" via
// resolve(process.cwd(), 'package.json'), so switch cwd to this directory
// before loading the backend bundle. NOTE: this directory (resfile inside the
// HAP install tree) is READ-ONLY — all writes go to ELECTERM_DATA_DIR.
process.chdir(__d)

process.env.NODE_ENV = 'production'
process.env.HOST = '127.0.0.1'
process.env.PORT = '5577'
// JWT secret baked in at build time. The web UI auto-logs-in because
// ENABLE_AUTH is not set.
process.env.SERVER_SECRET = ${JSON.stringify(SERVER_SECRET)}
// No pty on HarmonyOS -> disable the local terminal feature.
process.env.DISABLE_LOCAL_TERMINAL = '1'
// Where the pug views live (cwd is this directory, set above).
process.env.VIEW_FOLDER = resolve(__d, 'views')

// Writable user-data directory, created by the ArkTS side and passed in via
// ELECTERM_DATA_DIR (the app sandbox filesDir). This is where the database,
// ssh keys and logs live. Falls back to a sibling of this (read-only) dir —
// which will fail on writes, but keeps local dev on desktop working.
const userDataDir = process.env.ELECTERM_DATA_DIR || resolve(__d, 'data')
mkdirSync(userDataDir, { recursive: true })
process.env.DB_PATH = userDataDir
process.env.HOME = userDataDir

// SSH keys live under <userDataDir>/.ssh
mkdirSync(resolve(userDataDir, '.ssh'), { recursive: true })

await import('./app.bundle.mjs')
`
  fs.writeFileSync(path.resolve(OUT_DIR, 'index.js'), entry)

  fs.writeFileSync(
    path.resolve(OUT_DIR, 'package.json'),
    JSON.stringify({ name: 'electerm-web', version: VERSION, private: true, type: 'module' }, null, 2)
  )
  console.log('[web] wrote index.js + package.json')
}

// --------------------------------------------------------------------------
// main
// --------------------------------------------------------------------------

fs.rmSync(OUT_DIR, { recursive: true, force: true })
fs.mkdirSync(OUT_DIR, { recursive: true })

await runVite()
copyFrontendAssets()
await bundleBackend()
writeNodeEntry()

const outFiles = fs.readdirSync(OUT_DIR)
console.log('[web] done →', OUT_DIR)
console.log('[web] top-level:', outFiles.join(', '))
