/**
 * Safe storage wrapper using Node.js crypto (AES-256-GCM).
 *
 * Replaces Electron's safeStorage API which relies on OS-level key
 * services (macOS Keychain, Windows DPAPI, Linux libsecret) — none of
 * which are available on HarmonyOS.
 *
 * The encryption key is derived (via SHA-256) from STORAGE_SECRET:
 *   - In CI builds: build/harmony/build.js replaces the placeholder
 *     string with secrets.OHOS_SERVER_SECRET at build time
 *   - In local dev:  uses the static placeholder string below
 *
 * Encrypted values are stored as base64 strings prefixed with SAFE_PREFIX
 * so they can be distinguished from plain-text or legacy-encrypted values.
 *
 * Format:  v2:safe:<base64(iv):<base64(ciphertext):<base64(authTag)>
 */

const crypto = require('crypto')

const SAFE_PREFIX = 'v2:safe:'
const ALGO = 'aes-256-gcm'
const IV_LEN = 12 // 96-bit IV recommended for GCM

// Default fallback secret for local development.
// At build time, build/harmony/build.js replaces this string with
// the value of process.env.SERVER_SECRET (sourced from .env which
// prepare-web.sh sets from GitHub Secret OHOS_SERVER_SECRET).
const STORAGE_SECRET = 'static-secret-string-safe-storage'

/**
 * Derive a 32-byte key from the secret string via SHA-256.
 * @returns {Buffer}
 */
function getKey () {
  return crypto.createHash('sha256').update(STORAGE_SECRET).digest()
}

/**
 * Encrypt a string using AES-256-GCM.
 * Returns the original string unchanged on error.
 * @param {string} str
 * @returns {string}
 */
exports.safeEncrypt = function (str) {
  if (typeof str !== 'string' || !str) return str
  try {
    const key = getKey()
    const iv = crypto.randomBytes(IV_LEN)
    const cipher = crypto.createCipheriv(ALGO, key, iv)
    const encrypted = Buffer.concat([
      cipher.update(str, 'utf8'),
      cipher.final()
    ])
    const authTag = cipher.getAuthTag()
    return SAFE_PREFIX + [
      iv.toString('base64'),
      encrypted.toString('base64'),
      authTag.toString('base64')
    ].join(':')
  } catch (e) {
    console.error('[safe-storage] encrypt error:', e.message)
    return str
  }
}

/**
 * Decrypt a string that was encrypted with safeEncrypt.
 * Returns the original string unchanged when it was not produced by safeEncrypt.
 * @param {string} str
 * @returns {string}
 */
exports.safeDecrypt = function (str) {
  if (typeof str !== 'string' || !str) return str
  if (!str.startsWith(SAFE_PREFIX)) return str
  try {
    const payload = str.slice(SAFE_PREFIX.length)
    const parts = payload.split(':')
    if (parts.length !== 3) return str
    const [ivB64, encB64, tagB64] = parts
    const key = getKey()
    const decipher = crypto.createDecipheriv(
      ALGO,
      key,
      Buffer.from(ivB64, 'base64')
    )
    decipher.setAuthTag(Buffer.from(tagB64, 'base64'))
    const decrypted = Buffer.concat([
      decipher.update(Buffer.from(encB64, 'base64')),
      decipher.final()
    ])
    return decrypted.toString('utf8')
  } catch (e) {
    console.error('[safe-storage] decrypt error:', e.message)
    return str
  }
}
