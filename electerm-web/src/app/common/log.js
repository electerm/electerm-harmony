/**
 * Pure Node.js log replacement for electron-log.
 * Provides the same API (info, error, warn, debug, log, transports)
 * but uses console methods instead of Electron-specific APIs.
 */
import { config } from 'dotenv'

config()

function formatArgs (args) {
  const now = new Date()
  const h = String(now.getHours()).padStart(2, '0')
  const m = String(now.getMinutes()).padStart(2, '0')
  const s = String(now.getSeconds()).padStart(2, '0')
  return [`${h}:${m}:${s} ›`, ...args]
}

const log = {
  transports: {
    console: {
      format: '{h}:{i}:{s} {level} › {text}'
    },
    file: {
      format: '{h}:{i}:{s} {level} › {text}'
    }
  },
  info (...args) {
    console.log(...formatArgs(args))
  },
  warn (...args) {
    console.warn(...formatArgs(args))
  },
  error (...args) {
    console.error(...formatArgs(args))
  },
  debug (...args) {
    if (process.env.DEBUG) {
      console.debug(...formatArgs(args))
    }
  },
  log (...args) {
    console.log(...formatArgs(args))
  },
  verbose (...args) {
    if (process.env.VERBOSE) {
      console.log(...formatArgs(args))
    }
  },
  silly (...args) {
    // no-op
  }
}

export default log
