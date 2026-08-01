/**
 * bootstrap.js — HarmonyOS entry point.
 *
 * AbilityStage.ets writes the sandbox filesDir path to a marker file
 * (.electerm-data-path) before the Electron runtime starts. This file
 * reads that marker and sets process.env.DATA_PATH so all downstream
 * modules use the sandbox directory for data storage (nedb, config, logs).
 *
 * EntryAbility.ets requests READ_WRITE_DOCUMENTS_DIRECTORY at runtime,
 * then writes the Documents directory path to a second marker file
 * (.electerm-documents-path). This file reads that marker and overrides
 * os.homedir() to return the Documents folder — so that file save
 * dialogs, SFTP local paths, and other home-directory-based operations
 * default to the user-visible Documents folder.
 *
 * DATA_PATH resolution order:
 *   1. Marker file (.electerm-data-path, written by AbilityStage.ets → sandbox filesDir)
 *   2. Derived sandbox filesDir (from __dirname)
 *   3. /data/local/tmp or os.tmpdir() — absolute last resort
 *
 * HOMEDIR_PATH resolution order:
 *   1. Marker file (.electerm-documents-path, written by EntryAbility.ets → Documents dir)
 *   2. Original os.homedir() (system default)
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

/**
 * Resolve DATA_PATH — the sandbox filesDir used for app data storage.
 * This is always the sandbox directory, NOT the user-visible Documents
 * folder. The sandbox is always writable and doesn't require runtime
 * permission requests.
 */
function getDataPath () {
  const derivedDir = deriveSandboxFilesDir()

  if (derivedDir) {
    // 1. Try reading the marker file written by AbilityStage.ets
    const markerPath = path.join(derivedDir, '.electerm-data-path')
    try {
      const data = fs.readFileSync(markerPath, 'utf8').trim()
      if (data) {
        return data
      }
    } catch (e) { /* ignore */ }

    // 2. Use the derived sandbox filesDir directly
    try {
      fs.mkdirSync(derivedDir, { recursive: true })
      return derivedDir
    } catch (e) { /* ignore */ }
  }

  // 3. Final fallback — try /data/local/tmp, then os.tmpdir()
  const fallbacks = ['/data/local/tmp', os.tmpdir()]
  for (const dir of fallbacks) {
    try {
      fs.mkdirSync(dir, { recursive: true })
      return dir
    } catch (e) { /* ignore */ }
  }

  return os.tmpdir()
}

/**
 * Resolve HOMEDIR_PATH — the user-visible Documents directory.
 * This is used to override os.homedir() so that file save dialogs,
 * SFTP local paths, and other home-directory-based operations default
 * to the Documents folder visible to users.
 *
 * If the Documents path marker is not available (permission denied),
 * falls back to the original os.homedir() value.
 */
function getHomedirPath () {
  const derivedDir = deriveSandboxFilesDir()

  if (derivedDir) {
    const markerPath = path.join(derivedDir, '.electerm-documents-path')
    try {
      const data = fs.readFileSync(markerPath, 'utf8').trim()
      if (data) {
        return data
      }
    } catch (e) { /* ignore */ }
  }

  // Fallback: try os.homedir() + '/Documents'
  const docsPath = path.join(os.homedir(), 'Documents')
  try {
    fs.mkdirSync(docsPath, { recursive: true })
    const testFile = path.join(docsPath, '.write-test')
    fs.writeFileSync(testFile, 'ok')
    fs.unlinkSync(testFile)
    return docsPath
  } catch (e) { /* ignore */ }

  // Final fallback: original os.homedir()
  return os.homedir()
}

process.env.DATA_PATH = getDataPath()

// ── Resolve system locale from native marker ──────────────────────
// AbilityStage.ets detects the HarmonyOS system locale via @ohos.i18n
// (System.getSystemLanguage / getSystemRegion) and writes it to
// .electerm-locale before the Electron runtime starts.
// os-locale-s's shell-based detection does not work in the HarmonyOS
// sandbox, so we expose the locale through the environment instead —
// src/app/lib/locales.js reads process.env.LANG directly. Format written
// by native is "<lang>-<REGION>" (e.g. "zh-CN"); we append ".UTF-8" so the
// value is also a valid LANG for the SSH child-process environment.
function getSystemLocale () {
  const markerPath = path.join(process.env.DATA_PATH, '.electerm-locale')
  try {
    const data = fs.readFileSync(markerPath, 'utf8').trim()
    if (data) {
      return data
    }
  } catch (e) { /* ignore */ }
  return ''
}

const _systemLocale = getSystemLocale()
if (_systemLocale) {
  process.env.LANG = `${_systemLocale}.UTF-8`
}

// ── Override os.homedir() ──────────────────────────────────────────
// On HarmonyOS the default os.homedir() returns an inaccessible path
// (e.g. /storage/Users/currentUser). We override it to return the
// user-visible Documents directory, so that file save dialogs, SFTP
// local paths, and other home-directory-based operations work
// correctly for the user.
//
// DATA_PATH (sandbox filesDir) is used for internal app data storage
// and is NOT exposed as the home directory.
const _originalHomedir = os.homedir.bind(os)
const _homedirPath = getHomedirPath()
os.homedir = function homedir () {
  return _homedirPath || _originalHomedir()
}

require('./app.js')
