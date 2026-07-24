/**
 * Build the electerm HarmonyOS app.
 *
 * Step 0: Copy client source from @electerm/electerm-react npm package
 *         → src/client/ (gitignored, not in repo)
 * Step 1: Run complete electerm build (npm run b)
 *         clean → compile (vite + copy + pug) → prepare-file (deps install + cleanup)
 * Step 2: Apply HarmonyOS delta (main → bootstrap.js, remove native modules)
 * Step 3: Copy work/app → web_engine resfile
 * Step 4: Verify critical files
 *
 * This is a CJS file to stay consistent with build/bin/*.js.
 */
const { exec, cp, echo } = require('shelljs')
const { resolve, join, dirname } = require('path')
const fs = require('fs')
const pack = require('../../package.json')

// Ensure we run from project root (build/bin/*.js rely on cwd)
process.chdir(resolve(__dirname, '../..'))
const ROOT = process.cwd()
const WORK_APP = resolve(ROOT, 'work/app')
const OUTPUT_DIR = resolve(ROOT, 'web_engine/src/main/resources/resfile/resources/app')

const timeStart = Date.now()

// HarmonyOS-specific pug data — must be set before `npm run b` runs pug.js
process.env.PUG_EXTRA_DATA = JSON.stringify({
  supportSessionTypes: ['ssh', 'telnet', 'web', 'rdp', 'vnc', 'ftp', 'spice']
})

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function rmrf (p) {
  if (fs.existsSync(p)) {
    fs.rmSync(p, { recursive: true, force: true })
  }
}

function getDirSize (dir) {
  let size = 0
  try {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const p = join(dir, entry.name)
      if (entry.isDirectory()) size += getDirSize(p)
      else size += fs.statSync(p).size
    }
  } catch {}
  return size
}

function formatBytes (bytes) {
  if (bytes < 1024) return bytes + ' B'
  if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB'
  return (bytes / (1024 * 1024)).toFixed(1) + ' MB'
}

// ---------------------------------------------------------------------------
// Step 0: Copy client source from @electerm/electerm-react
// ---------------------------------------------------------------------------
// src/client/ is gitignored (moved to npm package in cbce701).
// Vite config and pug.js reference src/client/entry/*.jsx and
// src/client/views/index.pug, so we must populate src/client/ before
// running `npm run b`.
// ---------------------------------------------------------------------------
function prepareClientSource () {
  echo('[harmony] step 0: prepare client source from @electerm/electerm-react')
  const pkgClient = resolve(ROOT, 'node_modules/@electerm/electerm-react/client')
  const srcClient = resolve(ROOT, 'src/client')

  if (!fs.existsSync(pkgClient)) {
    throw new Error(
      'node_modules/@electerm/electerm-react/client not found. ' +
      'Run npm install first.'
    )
  }

  // Check if src/client/ already has the entry files (local dev)
  const entryExists = fs.existsSync(resolve(srcClient, 'entry/electerm.jsx'))
  if (entryExists) {
    echo('  ✓ src/client/ already populated, skip copy')
    return
  }

  // Copy client/ from npm package to src/client/
  rmrf(srcClient)
  fs.mkdirSync(resolve(ROOT, 'src'), { recursive: true })
  cp('-r', pkgClient, srcClient)
  echo('  ✓ copied @electerm/electerm-react/client → src/client')

  // Verify critical entry files
  const required = [
    'entry/electerm.jsx',
    'entry/basic.js',
    'entry/worker.js',
    'views/index.pug'
  ]
  for (const f of required) {
    if (!fs.existsSync(resolve(srcClient, f))) {
      throw new Error(`Missing required client file: src/client/${f}`)
    }
  }
  echo('  ✓ client source verified')
}

// ---------------------------------------------------------------------------
// Step 1: Run complete electerm build (npm run b)
// ---------------------------------------------------------------------------
// npm run b = npm run clean && npm run compile && npm run prepare-file
//   clean        → removes work/
//   compile      → vite-build + copy icons + pug → work/app/assets/
//   prepare-file → cp src/app → work/app, create package.json, npm install,
//                  cleanup (axios, node-pty, cpu-features, yarn autoclean,
//                  clean-empty-folders)
// ---------------------------------------------------------------------------
function buildElecterm () {
  echo('[harmony] step 1: run complete electerm build (npm run b)')
  const result = exec('npm run b')
  if (result.code !== 0) {
    throw new Error(`npm run b failed with exit code ${result.code}`)
  }
  echo('  ✓ electerm build complete')
}

// ---------------------------------------------------------------------------
// Step 2: Apply HarmonyOS-specific delta
// ---------------------------------------------------------------------------
// electerm's prepare.js produces work/app with:
//   - main: 'app.js'  → harmony needs 'bootstrap.js'
//   - node-pty, serialport, cpu-features installed → harmony excludes them
//   (source has try/catch guards for missing native modules)
// ---------------------------------------------------------------------------
function applyHarmonyDelta () {
  echo('[harmony] step 2: apply HarmonyOS delta')

  // 2a. Rewrite package.json for HarmonyOS
  const workPkg = JSON.parse(
    fs.readFileSync(resolve(WORK_APP, 'package.json'), 'utf8')
  )
  workPkg.main = 'bootstrap.js'
  delete workPkg.dependencies['node-pty']
  delete workPkg.dependencies.serialport
  delete workPkg.dependencies['cpu-features']
  fs.writeFileSync(
    resolve(WORK_APP, 'package.json'),
    JSON.stringify(workPkg, null, 2)
  )
  echo('  ✓ package.json: main = bootstrap.js, native modules excluded')

  // 2b. Remove native module directories (not usable on HarmonyOS)
  const nativeModules = ['node-pty', 'serialport', 'cpu-features']
  for (const mod of nativeModules) {
    const modPath = resolve(WORK_APP, 'node_modules', mod)
    if (fs.existsSync(modPath)) {
      rmrf(modPath)
      echo(`  ✓ removed node_modules/${mod}`)
    }
  }

  // 2c. Remove .env (not needed in the packed app)
  rmrf(resolve(WORK_APP, '.env'))
  rmrf(resolve(WORK_APP, '.env.bak'))

  echo('  ✓ HarmonyOS delta applied')
}

// ---------------------------------------------------------------------------
// Step 3: Copy work/app → web_engine resfile
// ---------------------------------------------------------------------------
function copyToResfile () {
  echo('[harmony] step 3: copy work/app → web_engine resfile')

  const webEngineDir = resolve(ROOT, 'web_engine')
  if (!fs.existsSync(webEngineDir)) {
    throw new Error(
      'web_engine/ not found. Run ./scripts/prepare-electron-runtime.sh first.'
    )
  }

  rmrf(OUTPUT_DIR)
  const parentDir = dirname(OUTPUT_DIR)
  fs.mkdirSync(parentDir, { recursive: true })
  cp('-r', WORK_APP, parentDir)

  echo(`  ✓ copied to ${OUTPUT_DIR}`)
  echo(`  ✓ bundled size: ${formatBytes(getDirSize(OUTPUT_DIR))}`)
}

// ---------------------------------------------------------------------------
// Step 4: Verify critical files
// ---------------------------------------------------------------------------
function verify (label, dir) {
  echo(`[harmony] verify: ${label}`)

  const checks = [
    { path: 'assets/index.html', desc: 'index.html' },
    { path: 'bootstrap.js', desc: 'bootstrap.js' },
    { path: 'app.js', desc: 'app.js' },
    { path: 'package.json', desc: 'package.json' },
    { path: 'server/server.js', desc: 'server.js' },
    { path: 'lib/file-server.js', desc: 'file-server.js' }
  ]

  let failed = false
  for (const check of checks) {
    const fullPath = resolve(dir, check.path)
    if (!fs.existsSync(fullPath)) {
      echo(`  ✗ MISSING: ${check.path}`)
      failed = true
    } else {
      echo(`  ✓ ${check.desc}`)
    }
  }

  // Check assets/js/ has JS files
  const jsDir = resolve(dir, 'assets/js')
  if (!fs.existsSync(jsDir)) {
    echo('  ✗ MISSING: assets/js/ directory')
    failed = true
  } else {
    const jsFiles = fs.readdirSync(jsDir).filter(f => f.endsWith('.js'))
    if (jsFiles.length === 0) {
      echo('  ✗ MISSING: no .js files in assets/js/')
      failed = true
    } else {
      echo(`  ✓ assets/js/ (${jsFiles.length} files: ${jsFiles.join(', ')})`)
    }
  }

  // Check assets/css/ has CSS files
  const cssDir = resolve(dir, 'assets/css')
  if (!fs.existsSync(cssDir)) {
    echo('  ✗ MISSING: assets/css/ directory')
    failed = true
  } else {
    const cssFiles = fs.readdirSync(cssDir).filter(f => f.endsWith('.css'))
    if (cssFiles.length === 0) {
      echo('  ✗ MISSING: no .css files in assets/css/')
      failed = true
    } else {
      echo(`  ✓ assets/css/ (${cssFiles.length} files: ${cssFiles.join(', ')})`)
    }
  }

  // Check assets/chunk/ has chunk files
  const chunkDir = resolve(dir, 'assets/chunk')
  if (!fs.existsSync(chunkDir)) {
    echo('  ✗ MISSING: assets/chunk/ directory')
    failed = true
  } else {
    const chunkFiles = fs.readdirSync(chunkDir)
    echo(`  ✓ assets/chunk/ (${chunkFiles.length} files)`)
  }

  // Check package.json has main: bootstrap.js
  const pkgPath = resolve(dir, 'package.json')
  if (fs.existsSync(pkgPath)) {
    const pkg = JSON.parse(fs.readFileSync(pkgPath, 'utf8'))
    if (pkg.main !== 'bootstrap.js') {
      echo(`  ✗ package.json main should be "bootstrap.js", got "${pkg.main}"`)
      failed = true
    } else {
      echo('  ✓ package.json main = bootstrap.js')
    }
  }

  // Check node_modules exists
  if (!fs.existsSync(resolve(dir, 'node_modules'))) {
    echo('  ✗ MISSING: node_modules/')
    failed = true
  } else {
    echo('  ✓ node_modules/ exists')
  }

  if (failed) {
    echo(`\n[harmony] VERIFICATION FAILED for ${label}!`)
    throw new Error(`Verification failed for ${label}`)
  }

  echo(`  ✓ ${label} verification passed`)
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
function main () {
  echo('[harmony] building electerm HarmonyOS app...')
  echo(`[harmony] version: ${pack.version}`)
  echo('[harmony] mode: reuse electerm build (npm run b) + harmony delta')
  echo('')

  // Step 0: Prepare client source from npm package
  prepareClientSource()

  // Step 1: Complete electerm build
  buildElecterm()

  // Step 2: Apply HarmonyOS-specific changes
  applyHarmonyDelta()

  // Verify work/app before copying
  verify('work/app', WORK_APP)

  // Step 3: Copy to resfile
  copyToResfile()

  // Verify resfile after copying
  verify('resfile', OUTPUT_DIR)

  const elapsed = ((Date.now() - timeStart) / 1000).toFixed(1)
  echo('')
  echo(`[harmony] build complete in ${elapsed}s`)
  echo(`[harmony] output: ${OUTPUT_DIR}`)
  echo(`[harmony] total size: ${formatBytes(getDirSize(OUTPUT_DIR))}`)
}

main()
