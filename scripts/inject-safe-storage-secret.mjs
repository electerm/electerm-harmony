import fs from 'node:fs'

const file = process.env.SAFE_STORAGE_FILE || 'build/replace/app/lib/safe-storage.js'
const marker = "process.env.STORAGE_SECRET || 'static-secret-string-safe-storage'"
const secret = process.env.STORAGE_SECRET

if (!secret) {
  throw new Error('STORAGE_SECRET is not set')
}

const source = fs.readFileSync(file, 'utf8')
if (!source.includes(marker)) {
  throw new Error(`safe-storage marker not found in ${file}`)
}

fs.writeFileSync(file, source.replace(marker, JSON.stringify(secret)))
console.log('safe-storage secret injected')
