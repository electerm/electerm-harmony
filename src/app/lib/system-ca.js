/**
 * Load system-trusted CA certificates into Node.js TLS store.
 * Node.js uses its own bundled CA store and does not trust OS-level
 * certificates by default. This module exports those certs so they
 * can be passed to https.Agent as additional trusted CAs.
 */

const { existsSync, readdirSync, readFileSync } = require('fs')
const { join } = require('path')

let _certs = null

function loadLinux () {
  const dirs = [
    '/etc/ssl/certs',
    '/etc/pki/tls/certs',
    '/etc/pki/ca-trust/extracted/pem',
    '/usr/local/share/certs'
  ]
  const files = []
  for (const dir of dirs) {
    if (existsSync(dir)) {
      try {
        for (const f of readdirSync(dir)) {
          if (f.endsWith('.crt') || f.endsWith('.pem')) {
            files.push(join(dir, f))
          }
        }
        break
      } catch { /* skip */ }
    }
  }
  if (!files.length) {
    // fallback: try the ca-certificates bundle
    const bundlePaths = [
      '/etc/ssl/certs/ca-certificates.crt',
      '/etc/pki/tls/certs/ca-bundle.crt',
      '/etc/ssl/ca-bundle.pem'
    ]
    for (const p of bundlePaths) {
      if (existsSync(p)) {
        return readFileSync(p, 'utf8')
      }
    }
    return ''
  }
  return files.map(f => {
    try { return readFileSync(f, 'utf8') } catch { return '' }
  }).join('\n')
}

function getSystemCAs () {
  if (_certs !== null) {
    return _certs
  }
  _certs = loadLinux()
  return _certs
}

module.exports = getSystemCAs
