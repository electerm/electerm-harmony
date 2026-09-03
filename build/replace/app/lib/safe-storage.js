/**
 * Safe storage compatible with legacy HarmonyOS NeDB records.
 */

import crypto from 'crypto'

const SAFE_PREFIX = 'v2:safe:'
const ALGORITHM = 'aes-256-gcm'
const IV_LENGTH = 12
const STORAGE_SECRET = process.env.STORAGE_SECRET || 'static-secret-string-safe-storage'

function getKey () {
  return crypto.createHash('sha256').update(STORAGE_SECRET).digest()
}

export function safeEncrypt (value) {
  if (typeof value !== 'string' || !value) return value
  try {
    const iv = crypto.randomBytes(IV_LENGTH)
    const cipher = crypto.createCipheriv(ALGORITHM, getKey(), iv)
    const encrypted = Buffer.concat([cipher.update(value, 'utf8'), cipher.final()])
    return SAFE_PREFIX + [
      iv.toString('base64'),
      encrypted.toString('base64'),
      cipher.getAuthTag().toString('base64')
    ].join(':')
  } catch (err) {
    console.error('[safe-storage] encrypt error:', err.message)
    return value
  }
}

export function safeDecrypt (value) {
  if (typeof value !== 'string' || !value || !value.startsWith(SAFE_PREFIX)) return value
  try {
    const [iv, encrypted, authTag] = value.slice(SAFE_PREFIX.length).split(':')
    if (!iv || !encrypted || !authTag) return value
    const decipher = crypto.createDecipheriv(ALGORITHM, getKey(), Buffer.from(iv, 'base64'))
    decipher.setAuthTag(Buffer.from(authTag, 'base64'))
    return Buffer.concat([
      decipher.update(Buffer.from(encrypted, 'base64')),
      decipher.final()
    ]).toString('utf8')
  } catch (err) {
    console.error('[safe-storage] decrypt error:', err.message)
    return value
  }
}
