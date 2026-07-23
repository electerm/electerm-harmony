/**
 * Build the electerm HarmonyOS app for the Electron 鸿蒙 runtime.
 *
 * Unlike the old electerm-web build that bundled the backend with esbuild,
 * this script copies the electerm source code directly to the resfile directory,
 * allowing it to run unmodified with the Electron 鸿蒙 runtime.
 *
 * Steps:
 *   1. Vite-build the React frontend → work/app/assets/
 *   2. Copy static assets (icons, images, tray icons) → work/app/assets/
 *   3. Generate index.html from pug template → work/app/assets/index.html
 *   4. Copy src/app/ → work/app/ (source code, NOT bundled)
 *   5. Create work/app/package.json (production deps, main: "app.js")
 *   6. Install production deps in work/app/ (npm, excludes native modules)
 *   7. Clean up unnecessary files to reduce package size
 *   8. Copy work/app/ → web_engine/src/main/resources/resfile/resources/app/
 *
 * The electerm source code runs directly from source with the Electron 鸿蒙
 * runtime (libelectron.so). Native modules (node-pty, serialport) are not
 * installed — the source code has try/catch guards that handle their absence.
 */
import { execSync } from 'node:child_process'
import { createRequire } from 'node:module'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const require = createRequire(import.meta.url)
const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)
const ROOT = path.resolve(__dirname, '..', '..') // build/harmony → project root

// Make every path that reads process.cwd() resolve against the repo root
process.chdir(ROOT)

const WORK_APP = path.resolve(ROOT, 'work/app')
const OUTPUT_DIR = path.resolve(ROOT, 'web_engine/src/main/resources/resfile/resources/app')
const VERSION = JSON.parse(
  fs.readFileSync(path.resolve(ROOT, 'package.json'), 'utf8')
).version

// --------------------------------------------------------------------------
// Helpers
// --------------------------------------------------------------------------

function run (cmd, opts = {}) {
  console.log(`  $ ${cmd}`)
  execSync(cmd, { stdio: 'inherit', cwd: ROOT, ...opts })
}

function copyDir (from, to) {
  if (!fs.existsSync(from)) {
    console.warn(`  ! skip missing source: ${from}`)
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

function rmrf (p) {
  if (fs.existsSync(p)) {
    fs.rmSync(p, { recursive: true, force: true })
  }
}

function getDirSize (dir) {
  let size = 0
  try {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const p = path.join(dir, entry.name)
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

// --------------------------------------------------------------------------
// 1. Vite build (frontend)
// --------------------------------------------------------------------------
function buildFrontend () {
  console.log('[harmony] building frontend (vite)…')
  // Use the electerm vite-build script: cd build/vite && npm run build
  // This outputs to work/app/assets/
  run('node build/bin/vite-build.js')
}

// --------------------------------------------------------------------------
// 2. Copy static assets
// --------------------------------------------------------------------------
function copyAssets () {
  console.log('[harmony] copying static assets…')
  const assets = path.resolve(WORK_APP, 'assets')

  // Icons from electerm-icons
  copyDir(
    path.resolve(ROOT, 'node_modules/electerm-icons/icons'),
    path.resolve(assets, 'icons')
  )

  // Images from @electerm/electerm-resource
  copyDir(
    path.resolve(ROOT, 'node_modules/@electerm/electerm-resource/res/imgs'),
    path.resolve(assets, 'images')
  )

  // Tray icons
  copyDir(
    path.resolve(ROOT, 'node_modules/@electerm/electerm-resource/tray-icons'),
    path.resolve(assets, 'images')
  )
}

// --------------------------------------------------------------------------
// 3. Generate index.html from pug template
// --------------------------------------------------------------------------
function generateHtml () {
  console.log('[harmony] generating index.html…')
  const pug = require('pug')
  const pack = JSON.parse(
    fs.readFileSync(path.resolve(ROOT, 'package.json'), 'utf8')
  )
  const deepCopy = require('json-deep-copy')

  const entryPug = path.resolve(ROOT, 'src/client/views/index.pug')
  const targetFilePath = path.resolve(WORK_APP, 'assets/index.html')

  if (!fs.existsSync(entryPug)) {
    console.warn('  ! index.pug not found, skipping HTML generation')
    return
  }

  const pugContent = fs.readFileSync(entryPug, 'utf-8')
  const defaultAIPreset = {
    baseURLAI: 'https://ai.electerm.org/api/ai',
    apiPathAI: '/chat/completions',
    modelAI: 'mistral-small-latest',
    authHeaderNameAI: 'Authorization: Bearer',
    id: 'ai.electerm.org',
    nameAI: 'ai.electerm.org(default free)'
  }

  const data = {
    version: pack.version,
    siteName: pack.name,
    isDev: false,
    defaultAIPreset,
    // Hide local and serial bookmark types on HarmonyOS — node-pty and
    // serialport native modules are not available on this platform.
    supportSessionTypes: [
      'ssh',
      'telnet',
      'web',
      'rdp',
      'vnc',
      'ftp',
      'spice'
    ]
  }

  const htmlContent = pug.render(pugContent, {
    filename: entryPug,
    ...data,
    _global: deepCopy(data)
  })
  fs.writeFileSync(targetFilePath, htmlContent, 'utf8')
  console.log('  ✓ index.html generated')
}

// --------------------------------------------------------------------------
// 4. Copy src/app/ → work/app/ (source code, NOT bundled)
// --------------------------------------------------------------------------
function copySource () {
  console.log('[harmony] copying src/app/ → work/app/ (source, not bundled)…')
  const srcApp = path.resolve(ROOT, 'src/app')
  if (!fs.existsSync(srcApp)) {
    throw new Error('src/app/ not found')
  }

  // Remove any existing files in work/app/ except assets/ (which was built by vite)
  const assetsBackup = path.resolve(ROOT, 'work/assets-backup')
  if (fs.existsSync(path.resolve(WORK_APP, 'assets'))) {
    rmrf(assetsBackup)
    fs.renameSync(path.resolve(WORK_APP, 'assets'), assetsBackup)
  }
  rmrf(WORK_APP)
  fs.mkdirSync(WORK_APP, { recursive: true })
  if (fs.existsSync(assetsBackup)) {
    fs.renameSync(assetsBackup, path.resolve(WORK_APP, 'assets'))
  }

  // Copy src/app/ contents to work/app/
  copyDir(srcApp, WORK_APP)

  // Remove dev-only files
  rmrf(path.resolve(WORK_APP, 'user-config.json'))
  rmrf(path.resolve(WORK_APP, 'localstorage.json'))
  rmrf(path.resolve(WORK_APP, 'nohup.out'))

  console.log('  ✓ source code copied')
}

// --------------------------------------------------------------------------
// 5. Create work/app/package.json
// --------------------------------------------------------------------------
function createPackageJson () {
  console.log('[harmony] creating work/app/package.json…')
  const pack = JSON.parse(
    fs.readFileSync(path.resolve(ROOT, 'package.json'), 'utf8')
  )

  // Production package.json: keep only what's needed to run
  const prodPack = {
    name: pack.name,
    version: pack.version,
    description: pack.description,
    main: 'bootstrap.js',
    license: pack.license,
    author: pack.author,
    dependencies: { ...pack.dependencies }
  }

  // Remove native modules that are not available on HarmonyOS
  delete prodPack.dependencies['node-pty']
  delete prodPack.dependencies['serialport']
  // cpu-features is an optional dep of ssh2; remove it to avoid native build
  delete prodPack.dependencies['cpu-features']

  fs.writeFileSync(
    path.resolve(WORK_APP, 'package.json'),
    JSON.stringify(prodPack, null, 2)
  )
  console.log('  ✓ package.json created (native modules excluded)')
}

// --------------------------------------------------------------------------
// 6. Install production deps in work/app/
// --------------------------------------------------------------------------
function installDeps () {
  console.log('[harmony] installing production deps in work/app/…')
  run('npm install --omit=dev --no-audit --no-fund --ignore-scripts', {
    cwd: WORK_APP
  })

  // Remove .bin directory (not needed at runtime)
  rmrf(path.resolve(WORK_APP, 'node_modules/.bin'))

  // Remove cpu-features if it was installed as an optional dep
  rmrf(path.resolve(WORK_APP, 'node_modules/cpu-features'))

  // Remove node-pty and serialport if they somehow got installed
  rmrf(path.resolve(WORK_APP, 'node_modules/node-pty'))
  rmrf(path.resolve(WORK_APP, 'node_modules/serialport'))

  // Clean up npm metadata files
  rmrf(path.resolve(WORK_APP, 'package-lock.json'))

  console.log('  ✓ deps installed')
}

// --------------------------------------------------------------------------
// 7. Clean up unnecessary files to reduce package size
// --------------------------------------------------------------------------
function cleanup () {
  console.log('[harmony] cleaning up unnecessary files…')

  // Remove test files
  const patterns = [
    'node_modules/**/*.test.js',
    'node_modules/**/*.test.mjs',
    'node_modules/**/*.spec.js',
    'node_modules/**/test/**',
    'node_modules/**/tests/**',
    'node_modules/**/__tests__/**',
    'node_modules/**/docs/**',
    'node_modules/**/.github/**',
    'node_modules/**/LICENSE*',
    'node_modules/**/CHANGELOG*',
    'node_modules/**/README*',
    'node_modules/**/*.md',
    'node_modules/**/*.markdown',
    'node_modules/**/.eslintrc*',
    'node_modules/**/.editorconfig',
    'node_modules/**/.npmignore',
    'node_modules/**/yarn.lock',
    'node_modules/**/*.ts.map',
    'node_modules/**/*.d.ts',
    'node_modules/**/coverage/**',
    'node_modules/**/.nyc_output/**'
  ]

  // Remove TypeScript declaration files and source maps (not needed at runtime)
  function cleanDir (dir) {
    try {
      for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
        const p = path.join(dir, entry.name)
        if (entry.isDirectory()) {
          const name = entry.name
          if (name === 'test' || name === 'tests' || name === '__tests__' ||
              name === 'docs' || name === '.github' || name === 'coverage' ||
              name === '.nyc_output') {
            rmrf(p)
            continue
          }
          cleanDir(p)
        } else {
          if (entry.name.endsWith('.test.js') || entry.name.endsWith('.test.mjs') ||
              entry.name.endsWith('.spec.js') || entry.name.endsWith('.md') ||
              entry.name.endsWith('.markdown') || entry.name.endsWith('.d.ts') ||
              entry.name.endsWith('.ts.map') || entry.name.endsWith('.map') ||
              entry.name.startsWith('LICENSE') || entry.name.startsWith('CHANGELOG') ||
              entry.name.startsWith('README') || entry.name === '.eslintrc' ||
              entry.name === '.eslintrc.js' || entry.name === '.eslintrc.json' ||
              entry.name === '.editorconfig' || entry.name === '.npmignore' ||
              entry.name === 'yarn.lock') {
            try { fs.unlinkSync(p) } catch {}
          }
        }
      }
    } catch {}
  }

  cleanDir(path.resolve(WORK_APP, 'node_modules'))

  // Remove axios browser/ESM builds (keep only CJS)
  rmrf(path.resolve(WORK_APP, 'node_modules/axios/dist/esm'))
  rmrf(path.resolve(WORK_APP, 'node_modules/axios/dist/browser'))

  console.log('  ✓ cleanup done')
}

// --------------------------------------------------------------------------
// 8. Copy work/app/ → web_engine resfile
// --------------------------------------------------------------------------
function copyToResfile () {
  console.log('[harmony] copying work/app/ → web_engine resfile…')

  const webEngineDir = path.resolve(ROOT, 'web_engine')
  if (!fs.existsSync(webEngineDir)) {
    throw new Error(
      'web_engine/ not found. Run ./scripts/prepare-electron-runtime.sh first.'
    )
  }

  rmrf(OUTPUT_DIR)
  fs.mkdirSync(OUTPUT_DIR, { recursive: true })

  // Copy the entire work/app/ to the resfile directory
  copyDir(WORK_APP, OUTPUT_DIR)

  // Verify critical files
  const bootstrapJs = path.resolve(OUTPUT_DIR, 'bootstrap.js')
  if (!fs.existsSync(bootstrapJs)) {
    throw new Error('bootstrap.js not found in output directory')
  }
  console.log('  ✓ bootstrap.js found')

  const appJs = path.resolve(OUTPUT_DIR, 'app.js')
  if (!fs.existsSync(appJs)) {
    throw new Error('app.js not found in output directory')
  }
  console.log('  ✓ app.js found')

  const pkgJson = path.resolve(OUTPUT_DIR, 'package.json')
  if (!fs.existsSync(pkgJson)) {
    throw new Error('package.json not found in output directory')
  }
  console.log('  ✓ package.json found')

  console.log(`  ✓ bundled size: ${formatBytes(getDirSize(OUTPUT_DIR))}`)
}

// --------------------------------------------------------------------------
// Main
// --------------------------------------------------------------------------
async function main () {
  console.log('[harmony] building electerm HarmonyOS app…')
  console.log('[harmony] version:', VERSION)
  console.log('[harmony] mode: direct source (not bundled)')
  console.log('')

  // Ensure work/app/ exists
  fs.mkdirSync(WORK_APP, { recursive: true })

  // Step 1: Vite build
  buildFrontend()

  // Step 2: Copy static assets
  copyAssets()

  // Step 3: Generate index.html
  generateHtml()

  // Step 4: Copy source code
  copySource()

  // Step 5: Create package.json
  createPackageJson()

  // Step 6: Install deps
  installDeps()

  // Step 7: Cleanup
  cleanup()

  // Step 8: Copy to resfile
  copyToResfile()

  console.log('')
  console.log('[harmony] build complete!')
  console.log('[harmony] output:', OUTPUT_DIR)
  console.log('[harmony] total size:', formatBytes(getDirSize(OUTPUT_DIR)))
}

main().catch((e) => {
  console.error('[harmony] build failed:', e)
  process.exit(1)
})
