/**
 * fix-lock-integrity.js
 *
 * Repair stale `integrity` hashes in package-lock.json for direct deps.
 *
 * The failure this exists for: a dependency version bumped by hand in
 * package.json + package-lock.json (the `Ver -> x.y.z` commits) only moves
 * the lock entry's `version` and `resolved` URL. `integrity` keeps the OLD
 * version's hash, and then BOTH install paths abort:
 *
 *   npm error code EINTEGRITY
 *   npm error integrity checksum failed when using sha512:
 *     wanted sha512-<old 5.5.15 hash> but got sha512-<the real 5.5.25 hash>
 *
 * `npm install --package-lock-only` (our `npm run lock`) does NOT repair it —
 * with no node_modules present npm trusts the lockfile as-is. Only
 * re-resolving the package from the registry does.
 *
 * Usage:
 *   node build-src/bin/fix-lock-integrity.js
 *
 * Called automatically by scripts/prepare-web.sh when `npm ci` fails.
 * Idempotent: prints "already correct" and touches nothing when in sync.
 * Exits non-zero only if a registry lookup itself failed.
 */
import { readFile, writeFile } from 'node:fs/promises'
import { resolve, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..')
const pkgPath = resolve(root, 'package.json')
const lockPath = resolve(root, 'package-lock.json')

const pkg = JSON.parse(await readFile(pkgPath, 'utf8'))
const lock = JSON.parse(await readFile(lockPath, 'utf8'))

const direct = {
  ...pkg.dependencies,
  ...pkg.devDependencies,
  ...pkg.optionalDependencies
}

let patched = 0
let failed = 0

for (const [name, range] of Object.entries(direct)) {
  const entry = lock.packages?.[`node_modules/${name}`]
  if (!entry?.version || !entry.resolved?.includes('registry.npmjs.org')) {
    continue
  }
  const version = entry.version
  let dist
  try {
    const res = await fetch(
      `https://registry.npmjs.org/${name.replace('/', '%2f')}/${version}`
    )
    if (!res.ok) {
      throw new Error(`HTTP ${res.status}`)
    }
    dist = (await res.json()).dist
  } catch (err) {
    console.log(`    ! ${name}@${version}: registry lookup failed (${err.message})`)
    failed++
    continue
  }
  if (!dist?.integrity) {
    console.log(`    ! ${name}@${version}: registry has no dist.integrity`)
    failed++
    continue
  }
  if (entry.integrity === dist.integrity && entry.resolved === dist.tarball) {
    continue
  }
  console.log(`    ~ ${name}@${version} (wanted ${range})`)
  console.log(`        resolved:  ${entry.resolved}`)
  console.log(`                -> ${dist.tarball}`)
  console.log(`        integrity: ${entry.integrity}`)
  console.log(`                -> ${dist.integrity}`)
  entry.integrity = dist.integrity
  entry.resolved = dist.tarball
  patched++
}

if (patched > 0) {
  await writeFile(lockPath, `${JSON.stringify(lock, null, 2)}\n`)
  console.log(`    fixed ${patched} lockfile entry/entries`)
} else if (failed === 0) {
  console.log('    lockfile integrity already correct for all direct deps')
}

if (failed > 0) {
  console.log(`    ${failed} direct dep(s) could not be verified`)
  process.exit(1)
}
