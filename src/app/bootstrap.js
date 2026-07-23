/**
 * bootstrap.js — HarmonyOS entry point.
 *
 * On HarmonyOS, app.getPath('appData') does not work in the Electron runtime
 * due to a C++ binding issue (SetContextPaths is not effective). Instead,
 * AbilityStage.ets writes the sandbox filesDir to a marker file before the
 * Electron runtime starts. This file reads that marker and sets
 * process.env.DATA_PATH so all downstream modules (app-props.js, db.js, etc.)
 * use the correct sandbox path.
 *
 * Path derivation:
 *   __dirname = /data/storage/el1/bundle/entry/resources/resfile/resources/app
 *   filesDir  = /data/storage/el2/base/haps/entry/files
 *   Transform: replace "/el1/bundle/" with "/el2/base/haps/", strip the
 *   resources/resfile/... suffix, append "/files".
 */
const fs = require('fs')
const path = require('path')
const os = require('os')

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

  if (derivedDir) {
    // 1. Try reading the marker file written by AbilityStage.ets
    const markerPath = path.join(derivedDir, '.electerm-data-path')
    try {
      const data = fs.readFileSync(markerPath, 'utf8').trim()
      if (data) {
        console.log('[bootstrap] got data path from marker file:', data)
        return data
      }
    } catch (e) {
      console.log('[bootstrap] marker file not found at', markerPath)
    }

    // 2. Marker not found — try the derived path directly
    try {
      fs.mkdirSync(derivedDir, { recursive: true })
      console.log('[bootstrap] using derived sandbox path:', derivedDir)
      return derivedDir
    } catch (e) {
      console.warn('[bootstrap] derived path not writable:', derivedDir, e.message)
    }
  }

  // 3. Last resort: try app.getPath('appData')
  try {
    const { app } = require('electron')
    const p = app.getPath('appData')
    console.log('[bootstrap] using app.getPath("appData"):', p)
    return p
  } catch (e) {
    console.warn('[bootstrap] app.getPath("appData") failed:', e.message)
  }

  // 4. Final fallback
  console.warn('[bootstrap] falling back to os.tmpdir():', os.tmpdir())
  return os.tmpdir()
}

process.env.DATA_PATH = getDataPath()
require('./app.js')
