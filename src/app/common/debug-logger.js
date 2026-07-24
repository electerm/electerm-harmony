/**
 * debug-logger.js — standalone file logger for HarmonyOS debugging.
 *
 * Writes directly to the sandbox directory via fs.appendFileSync, bypassing
 * electron-log entirely. This ensures we can see every step of the startup
 * flow even when electron-log's file path resolution is broken.
 *
 * Usage:
 *   const dlog = require('./common/debug-logger')
 *   dlog('something happened')
 *   dlog('step A done')
 *
 * Log file: $DATA_PATH/electerm-debug.log
 */

const fs = require('fs')
const path = require('path')

let logPath = null

function getLogPath () {
  if (logPath) return logPath
  const base = process.env.DATA_PATH || '/tmp'
  try {
    if (!fs.existsSync(base)) {
      fs.mkdirSync(base, { recursive: true })
    }
  } catch (e) {
    // ignore
  }
  logPath = path.join(base, 'electerm-debug.log')
  return logPath
}

function formatMsg (args) {
  return args.map(a => {
    if (a instanceof Error) {
      return a.stack || a.message || String(a)
    }
    if (typeof a === 'object') {
      try {
        return JSON.stringify(a)
      } catch (e) {
        return String(a)
      }
    }
    return String(a)
  }).join(' ')
}

function dlog (...args) {
  try {
    const now = new Date()
    const ts = now.toISOString().replace('T', ' ').replace('Z', '')
    const ms = String(now.getMilliseconds()).padStart(3, '0')
    const line = `[${ts}.${ms}] ${formatMsg(args)}\n`
    fs.appendFileSync(getLogPath(), line)
  } catch (e) {
    // If even this fails, there's nothing we can do
    try {
      console.error('[debug-logger] failed to write:', e.message)
    } catch (ee) {
      // give up silently
    }
  }
}

module.exports = dlog
