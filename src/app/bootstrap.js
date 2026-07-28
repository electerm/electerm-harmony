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

// ── File logger ────────────────────────────────────────────────────
// Writes to $DATA_PATH/electerm-debug.log once DATA_PATH is set.
// Before that, lines are buffered in memory and flushed after.
const _logBuffer = []
let _logPath = null

function blog (...args) {
  try {
    const now = new Date()
    const ts = now.toISOString().replace('T', ' ').replace('Z', '')
    const ms = String(now.getMilliseconds()).padStart(3, '0')
    const line = `[${ts}.${ms}] [bootstrap] ${args.join(' ')}\n`
    process.stderr.write(line)
    if (_logPath) {
      fs.appendFileSync(_logPath, line)
    } else {
      _logBuffer.push(line)
    }
  } catch (e) { /* ignore */ }
}

function flushLogBuffer () {
  if (!_logPath || _logBuffer.length === 0) return
  try {
    const block = _logBuffer.join('')
    fs.appendFileSync(_logPath, block)
    _logBuffer.length = 0
  } catch (e) { /* ignore */ }
}

function initFileLog () {
  try {
    _logPath = path.join(process.env.DATA_PATH, 'electerm-debug.log')
    flushLogBuffer()
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

/**
 * Resolve DATA_PATH — the sandbox filesDir used for app data storage.
 * This is always the sandbox directory, NOT the user-visible Documents
 * folder. The sandbox is always writable and doesn't require runtime
 * permission requests.
 */
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

    // 2. Use the derived sandbox filesDir directly
    try {
      fs.mkdirSync(derivedDir, { recursive: true })
      blog('using derived sandbox path:', derivedDir)
      return derivedDir
    } catch (e) {
      blog('derived path not writable:', derivedDir, '-', e.message)
    }
  }

  // 3. Final fallback — try /data/local/tmp, then os.tmpdir()
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
        blog('got homedir path from documents marker:', data)
        return data
      }
    } catch (e) {
      blog('documents marker not found at', markerPath, '-', e.code || e.message)
    }
  }

  // Fallback: try os.homedir() + '/Documents'
  const docsPath = path.join(os.homedir(), 'Documents')
  try {
    fs.mkdirSync(docsPath, { recursive: true })
    const testFile = path.join(docsPath, '.write-test')
    fs.writeFileSync(testFile, 'ok')
    fs.unlinkSync(testFile)
    blog('using derived Documents dir for homedir:', docsPath)
    return docsPath
  } catch (e) {
    blog('Documents dir not accessible for homedir:', docsPath, '-', e.message)
  }

  // Final fallback: original os.homedir()
  const orig = os.homedir()
  blog('using original os.homedir() for homedir:', orig)
  return orig
}

process.env.DATA_PATH = getDataPath()
blog('DATA_PATH set to:', process.env.DATA_PATH)
initFileLog()

// ── Diagnostic: log existing data files ────────────────────────────
// Helps diagnose data persistence issues by showing what files exist
// at startup and their sizes.
try {
  const dbDir = path.join(process.env.DATA_PATH, 'users', 'default_user')
  if (fs.existsSync(dbDir)) {
    const files = fs.readdirSync(dbDir)
    blog(`[diag] db dir: ${dbDir}, ${files.length} files`)
    for (const f of files) {
      const stat = fs.statSync(path.join(dbDir, f))
      blog(`[diag]   ${f}: ${stat.size} bytes`)
    }
  } else {
    blog(`[diag] db dir does not exist yet: ${dbDir}`)
  }
} catch (e) {
  blog('[diag] failed to list db dir:', e.message)
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
blog('os.homedir() overridden to return:', os.homedir())

blog('require app.js...')
require('./app.js')
