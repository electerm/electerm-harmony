/**
 * bootstrap.js — HarmonyOS entry point.
 *
 * AbilityStage.ets writes the data path (the user's pre-authorized
 * Documents directory) to a marker file before the Electron runtime
 * starts. This file reads that marker and sets process.env.DATA_PATH
 * so all downstream modules use the correct path.
 *
 * Resolution order:
 *   1. Marker file (written by AbilityStage.ets, contains Documents/electerm)
 *   2. Derive from os.homedir() + '/Documents/electerm'
 *      (os.homedir() returns /storage/Users/currentUser on HarmonyOS)
 *   3. Sandbox filesDir (derived from __dirname) — unreliable, last resort
 *   4. /data/local/tmp or os.tmpdir() — absolute last resort
 */
const fs = require('fs')
const path = require('path')
const os = require('os')

// Minimal inline logger for bootstrap — debug-logger.js depends on DATA_PATH
// which isn't set yet at this point, so we write to a fixed early-stage path.
function blog (...args) {
  try {
    const line = `[${new Date().toISOString()}] [bootstrap] ${args.join(' ')}\n`
    // Write to both stderr (visible in HiLog) and a temp file for early-stage logs
    process.stderr.write(line)
  } catch (e) { /* ignore */ }
}

function deriveSandboxFilesDir () {
  // __dirname is like: /data/storage/el1/bundle/entry/resources/resfile/resources/app
  // sandbox filesDir is like: /data/storage/el2/base/haps/entry/files
  const m = __dirname.match(/^(.+?)\/el1\/bundle\/([^/]+)/)
  if (m) {
    return `${m[1]}/el2/base/haps/${m[2]}/files`
  }
  return null
}

function getDataPath () {
  const derivedDir = deriveSandboxFilesDir()
  blog('derivedDir:', derivedDir)

  if (derivedDir) {
    // 1. Try reading the marker file written by AbilityStage.ets
    const markerPath = path.join(derivedDir, '.electerm-data-path')
    try {
      const data = fs.readFileSync(markerPath, 'utf8').trim()
      if (data) {
        blog('got data path from marker file:', data)
        return data
      }
      blog('marker file empty at', markerPath)
    } catch (e) {
      blog('marker file not found at', markerPath, '-', e.code || e.message)
    }
  }

  // 2. Use the user's pre-authorized Documents directory.
  // os.homedir() returns /storage/Users/currentUser on HarmonyOS.
  // The READ_WRITE_DOCUMENTS_DIRECTORY permission (declared in
  // module.json5) grants reliable read/write access to Documents/.
  const docsPath = path.join(os.homedir(), 'Documents', 'electerm')
  try {
    fs.mkdirSync(docsPath, { recursive: true })
    // Verify write access
    const testFile = path.join(docsPath, '.write-test')
    fs.writeFileSync(testFile, 'ok')
    fs.unlinkSync(testFile)
    blog('using Documents dir:', docsPath)
    return docsPath
  } catch (e) {
    blog('Documents dir not writable:', docsPath, '-', e.message)
  }

  // 3. Try sandbox filesDir (unreliable — may lose data on restart)
  if (derivedDir) {
    try {
      fs.mkdirSync(derivedDir, { recursive: true })
      blog('using derived sandbox path (unreliable):', derivedDir)
      return derivedDir
    } catch (e) {
      blog('derived path not writable:', derivedDir, '-', e.message)
    }
  }

  // 4. Final fallback — try /data/local/tmp, then os.tmpdir()
  const fallbacks = ['/data/local/tmp', os.tmpdir()]
  for (const dir of fallbacks) {
    try {
      fs.mkdirSync(dir, { recursive: true })
      blog('using fallback temp dir:', dir)
      return dir
    } catch (e) {
      blog('fallback dir not writable:', dir, '-', e.message)
    }
  }

  blog('all fallbacks failed, returning os.tmpdir():', os.tmpdir())
  return os.tmpdir()
}

process.env.DATA_PATH = getDataPath()
blog('DATA_PATH set to:', process.env.DATA_PATH)

// ── Override os.homedir() ──────────────────────────────────────────
// On HarmonyOS the default os.homedir() returns an inaccessible path
// (e.g. /storage/Users/currentUser). bootstrap.js is the very first
// module to run, so patching os.homedir() here guarantees that every
// downstream call — whether in our own code or in third-party
// dependencies — returns the unified sandbox data directory.
const _originalHomedir = os.homedir.bind(os)
os.homedir = function homedir () {
  return process.env.DATA_PATH || _originalHomedir()
}
blog('os.homedir() overridden to return:', os.homedir())

blog('require app.js...')
require('./app.js')
