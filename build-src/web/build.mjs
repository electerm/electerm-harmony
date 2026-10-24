/**
 * Build the electerm HarmonyOS (ArkWeb) web bundle.
 *
 * Modelled on build/android/build.mjs from electerm-android. Produces the
 * Node.js project that runs on-device inside the HarmonyOS app:
 *
 *   entry/src/main/resources/resfile/electerm/
 *     ├── index.js         entry started by the on-device node binary; sets
 *     │                    env (HOST/PORT/SERVER_SECRET/data dirs) then
 *     │                    imports app.bundle.mjs
 *     ├── app.bundle.mjs   esbuild-bundled electerm backend (pure node,
 *     │                    no electron APIs)
 *     ├── package.json     read by runtime-constants.js via process.cwd()
 *     └── dist/assets/     vite-built frontend, static assets, and the
 *                          precompiled homepage (index.html)
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
import { createConfig, entryNames } from './vite.web.mjs'
import * as esbuild from 'esbuild'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { generateIndexHtml } from '../bin/gen-index-html.js'

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)
const ROOT = path.resolve(__dirname, '..', '..') // build-src/web -> repo root

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
// The package.json the node project carries on the device. The server reads it
// as `packInfo`, so the build-time homepage must embed the same object — not
// this repo's package.json, which runtime-constants would otherwise pick up.
const NODE_PKG = {
  name: 'electerm-web',
  version: VERSION,
  private: true,
  type: 'module'
}

// Who the baked-in API token belongs to.
//
// The homepage is now rendered at BUILD time, so the token in it is signed
// here, on this machine — while `verifyWs` (server/dispatch-center.js) compares
// that id against the *device's* process.env.SERVER_USER. Those two must agree
// or every WebSocket call is rejected ("not valid request") and the UI hangs on
// its first runSync. They used to agree by accident: the page was rendered on
// the device, so both sides read the same (absent) variable.
//
// Read it here, explicitly, before anything imports src/app/common/log.js —
// that module runs dotenv, which would otherwise pull this machine's .env into
// a value the device can never have. It is baked into index.js below, so the
// runtime and the token are always the same string.
const SERVER_USER = process.env.SERVER_USER || 'default_user'

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

function rmrfMaybe (dir) {
  fs.rmSync(dir, { recursive: true, force: true })
}

// --------------------------------------------------------------------------
// 1. Frontend (vite)
// --------------------------------------------------------------------------
// The frontend is built once per entry with every dynamic import inlined
// (see vite.web.mjs): on the device each asset is an HTTP round trip through
// the single-threaded node server, so ~250 chunks cost seconds of launch time.
// 3 files cost ~0.
const VITE_TMP = path.resolve(__dirname, '.gen', 'vite')

async function runVite () {
  console.log('[web] building frontend (vite)…')
  rmrfMaybe(VITE_TMP)
  for (const name of entryNames) {
    const outDir = path.resolve(VITE_TMP, name, 'assets')
    await viteBuild({
      ...createConfig(name, outDir),
      logLevel: 'warn'
    })
  }

  // Assemble dist/assets from the per-entry outputs.
  const assets = path.resolve(OUT_DIR, 'dist', 'assets')
  // A stale chunk/ directory from an older build would still be packed into
  // the HAP even though nothing references it any more.
  for (const stale of ['js', 'chunk', 'css']) {
    rmrfMaybe(path.resolve(assets, stale))
  }
  fs.mkdirSync(assets, { recursive: true })
  const cssParts = []
  for (const name of entryNames) {
    const out = path.resolve(VITE_TMP, name, 'assets')
    if (!fs.existsSync(out)) {
      continue
    }
    for (const entry of fs.readdirSync(out)) {
      const from = path.join(out, entry)
      if (entry === 'css') {
        // cssCodeSplit:false gives one file per entry; the html only links
        // css/style-<version>.css, so the entries have to be concatenated.
        for (const file of fs.readdirSync(from).sort()) {
          cssParts.push(fs.readFileSync(path.join(from, file), 'utf8'))
        }
      } else if (fs.statSync(from).isDirectory()) {
        copyDir(from, path.resolve(assets, entry))
      } else {
        fs.copyFileSync(from, path.resolve(assets, entry))
      }
    }
  }
  if (cssParts.length) {
    fs.mkdirSync(path.resolve(assets, 'css'), { recursive: true })
    fs.writeFileSync(
      path.resolve(assets, 'css', `style-${VERSION}.css`),
      cssParts.join('\n')
    )
  }
  const jsDir = path.resolve(assets, 'js')
  const jsCount = fs.existsSync(jsDir)
    ? fs.readdirSync(jsDir).filter(f => f.endsWith('.js')).length
    : 0
  console.log(`[web] frontend: ${jsCount} js file(s), ${cssParts.length} css file(s) merged`)
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

  // No `views/` in the node project: the homepage is rendered to
  // dist/assets/index.html at build time (build-src/bin/gen-index-html.js) and
  // the runtime never reads a template from disk.
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
      'font-list',
      // Dev-only template engine (see server/server.js): the guarded
      // `if (isDev) await import('pug')` must not pull the compiler into the
      // device bundle — it is 1.5 MB of @babel/parser + @babel/types + acorn.
      'pug'
    ],
    banner: {
      // Every name the banner needs is aliased: src/app/widgets/user-widget.js
      // imports createRequire by name, and a banner that also declares it makes
      // the bundle fail to link ("Identifier 'createRequire' has already been
      // declared"), so the on-device server never starts.
      js: "import { createRequire as __cr } from 'module'; import { fileURLToPath as __etu } from 'url'; const require = __cr(import.meta.url); const __filename = __etu(import.meta.url); const __dirname = __etu(new URL('.', import.meta.url));"
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
import { mkdirSync, appendFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

const __d = fileURLToPath(new URL('.', import.meta.url))

// Boot milestones are appended DIRECTLY to the launcher's node-boot.log —
// file writes bypass stdout, so ArkWeb/chromium logging (which shares this
// process's fd 1/2 with node) can never bury them. This is the primary
// diagnostics channel on device.
const __bootLog = resolve(process.env.ELECTERM_DATA_DIR || __d, 'node-boot.log')
const boot = (msg) => {
  try { appendFileSync(__bootLog, \`[backend] \${msg}\\n\`) } catch {}
}
process.on('uncaughtException', (e) => boot(\`uncaughtException: \${(e && e.stack) || e}\`))
process.on('unhandledRejection', (e) => boot(\`unhandledRejection: \${(e && e.stack) || e}\`))
process.on('exit', (code) => boot(\`node process exit, code=\${code}\`))
boot('entry.js running')

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
// The id the baked-in token was signed for (see SERVER_USER in build.mjs).
// verifyWs() compares it against this variable on every WebSocket handshake.
process.env.SERVER_USER = ${JSON.stringify(SERVER_USER)}
// No pty on HarmonyOS -> disable the local terminal feature.
process.env.DISABLE_LOCAL_TERMINAL = '1'
// No VIEW_FOLDER: the one template is precompiled into dist/assets/index.html.

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
// The bundle's top-level init ends with express listen, so by the time the
// dynamic import resolves the HTTP server is (normally) already bound.
`
  fs.writeFileSync(path.resolve(OUT_DIR, 'index.js'), entry)

  fs.writeFileSync(
    path.resolve(OUT_DIR, 'package.json'),
    JSON.stringify(NODE_PKG, null, 2)
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
// Static homepage. Must run after runVite(), which recreates dist/assets.
const index = await generateIndexHtml({
  outDir: path.resolve(OUT_DIR, 'dist', 'assets'),
  secret: SERVER_SECRET,
  user: SERVER_USER,
  packInfo: NODE_PKG
})
console.log(
  `[web] homepage: ${path.relative(ROOT, index.outPath)} (${index.bytes} bytes)`
)
await bundleBackend()
writeNodeEntry()

const outFiles = fs.readdirSync(OUT_DIR)
console.log('[web] done →', OUT_DIR)
console.log('[web] top-level:', outFiles.join(', '))
