/**
 * Deep link support for electerm
 * Handles protocol URLs like ssh://, telnet://, rdp://, vnc://, etc.
 */

const { app } = require('electron')
const log = require('../common/log')
const globalState = require('./glob-state')
const { parseQuickConnect, SUPPORTED_PROTOCOLS } = require('../common/parse-quick-connect')

// Protocols that should NOT be registered as system handlers.
// http/https are excluded because registering as a web URL handler
// triggers Huawei AppGallery's ArkWeb requirement review.
// The app can still parse and open these URLs (via web tabs), it just
// won't register as the system-level handler for them.
const EXCLUDED_PROTOCOLS = ['http', 'https']
const REGISTRABLE_PROTOCOLS = SUPPORTED_PROTOCOLS.filter(
  p => !EXCLUDED_PROTOCOLS.includes(p)
)
/**
 * Register electerm as a handler for supported protocols
 * Note: This makes electerm available as a handler but doesn't force it as default.
 * Users can still choose their preferred app in system settings.
 *
 * @param {boolean} force - If true, register even if not packaged (for testing)
 * @returns {object} - Status of registration for each protocol
 */
function registerDeepLink (force = false) {
  const protocols = REGISTRABLE_PROTOCOLS
  const results = {}

  // Only register in packaged app or when explicitly requested
  const shouldRegister = app.isPackaged ||
                        force ||
                        process.env.ELECTERM_REGISTER_PROTOCOLS === '1'

  if (!shouldRegister) {
    log.info('Skipping protocol registration in development mode')
    log.info('Set ELECTERM_REGISTER_PROTOCOLS=1 or pass force=true to enable')
    return { registered: false, reason: 'development-mode' }
  }

  protocols.forEach(protocol => {
    // Check if already registered
    const isDefault = app.isDefaultProtocolClient(protocol)

    if (isDefault) {
      log.info(`Already registered as handler for ${protocol}:// protocol`)
      results[protocol] = { success: true, alreadyDefault: true }
    } else {
      const registered = app.setAsDefaultProtocolClient(protocol)
      if (registered) {
        log.info(`Registered as handler for ${protocol}:// protocol`)
        results[protocol] = { success: true, alreadyDefault: false }
      } else {
        log.warn(`Failed to register ${protocol}:// protocol handler`)
        results[protocol] = { success: false, error: 'registration-failed' }
      }
    }
  })

  return { registered: true, protocols: results }
}

/**
 * Check which protocols are currently registered
 * @returns {object} - Status of each protocol
 */
function checkProtocolRegistration () {
  const protocols = REGISTRABLE_PROTOCOLS
  const status = {}

  protocols.forEach(protocol => {
    status[protocol] = app.isDefaultProtocolClient(protocol)
  })

  return status
}

/**
 * Unregister electerm as handler for protocols
 * @param {Array<string>} protocols - Optional array of specific protocols to unregister
 * @returns {object} - Status of unregistration
 */
function unregisterDeepLink (protocols = REGISTRABLE_PROTOCOLS) {
  const results = {}

  protocols.forEach(protocol => {
    const removed = app.removeAsDefaultProtocolClient(protocol)
    results[protocol] = removed
    if (removed) {
      log.info(`Unregistered as handler for ${protocol}:// protocol`)
    } else {
      log.warn(`Failed to unregister ${protocol}:// protocol handler`)
    }
  })

  return results
}

/**
 * Handle deep link URL by opening a new tab
 * @param {string} url - The protocol URL
 */
function handleDeepLink (url) {
  const parsed = parseQuickConnect(url)

  if (!parsed) {
    log.warn('Could not parse deep link URL:', url)
    return
  }

  const win = globalState.get('win')

  if (win) {
    // If window exists, send message to open new tab
    if (win.isMinimized()) {
      win.restore()
    }
    win.focus()
    win.webContents.send('open-tab', parsed)
  } else {
    // Store the URL to open when window is ready
    globalState.set('pendingDeepLink', parsed)
  }
}

/**
 * Check if there's a pending deep link to open
 * @returns {object|null} - Pending deep link in the same format as initCommandLine or null
 */
function getPendingDeepLink () {
  const pending = globalState.get('pendingDeepLink')
  if (pending) {
    globalState.set('pendingDeepLink', null)
    return pending
  }
  return null
}

/**
 * Setup deep link handlers for the app
 */
function setupDeepLinkHandlers () {
  // Note: second-instance and process.argv protocol URL handling is done by
  // single-instance.js (socket-based IPC → add-tab-from-command-line) and
  // command-line.js (initCommandLine → addTabFromCommandLine) respectively.
  // Handling them here too would cause duplicate tabs to open.
}

module.exports = {
  registerDeepLink,
  unregisterDeepLink,
  checkProtocolRegistration,
  handleDeepLink,
  getPendingDeepLink,
  setupDeepLinkHandlers
}
