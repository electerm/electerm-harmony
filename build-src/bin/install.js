/**
 * install.js
 *
 * Runs automatically on `npm install` (npm "install" lifecycle script).
 *
 * electerm-harmony reuses the source tree of electerm-web. Instead of keeping a
 * duplicate copy in this repo, we download the latest source archive from
 * https://github.com/electerm/electerm-web and copy its `src/` directory into
 * ours. This repo only keeps its own package.json, build scripts and
 * HarmonyOS-specific build configuration.
 *
 * After the source sync we also copy the @electerm/electerm-react client
 * from node_modules (same as the original install step), then apply the tracked
 * HarmonyOS source replacements from build-src/replace on top of src/.
 *
 * The source repo was electerm/electerm-android until 2026-10-04: android's own
 * src/ is now generated, so its tarball no longer contains src/ and the old
 * download had nothing to copy.
 *
 * `install-records.ref` (repo root, gitignored) records what src/ was built
 * from: the upstream ref, the @electerm/electerm-react version, and a
 * fingerprint of the HarmonyOS delta. A run whose ref *and* version *and* delta
 * all match what is recorded — and whose src/ and client dir are present — skips
 * the download, the client copy and the replacements entirely, so a plain
 * `npm install` no longer has to wipe src/. Delete that file to force a full
 * re-install.
 *
 * All paths are cwd-relative: this is the npm `install` lifecycle script, so npm
 * runs it from the package root.
 */
import { copyFile, readdir, writeFile, mkdir } from 'node:fs/promises'
import { existsSync, readFileSync, readdirSync } from 'node:fs'
import { resolve, relative, join, sep } from 'node:path'
import { createHash } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import pkg from 'shelljs'
import { x as tarX } from 'tar'

const { echo, rm: shellRm, cp } = pkg

const REPO = 'electerm/electerm-web'
const BRANCH = 'main'
const URL = `https://codeload.github.com/${REPO}/tar.gz/refs/heads/${BRANCH}`

const RECORD = resolve('install-records.ref')
const REPLACE_DIR = resolve('build-src/replace')
const CLIENT_DIR = resolve('src/client/electerm-react')
const CLIENT_PKG_JSON = resolve('node_modules/@electerm/electerm-react/package.json')

const TMP = resolve('temp/electerm-web-src')
const TMP_FILE = resolve(TMP, 'electerm-web.tar.gz')

echo('install required modules')

// ---------------------------------------------------------------------------
// What are we building from, and do we already have it?
// ---------------------------------------------------------------------------

/**
 * The commit at the tip of the source branch, via `git ls-remote`: one line, no
 * token, no API rate limit, and — unlike the tarball — nothing to download.
 *
 * Returns null when it cannot be resolved (offline, no git). That is not fatal
 * here: the run falls through to the download, which has its own fallback.
 */
function remoteRef () {
  try {
    const out = execFileSync(
      'git',
      ['ls-remote', `https://github.com/${REPO}.git`, `refs/heads/${BRANCH}`],
      { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], timeout: 30000 }
    )
    return (out.split('\n')[0] || '').split('\t')[0].trim() || null
  } catch (e) {
    return null
  }
}

/**
 * Fingerprint of the HarmonyOS delta: every file under build-src/replace (path +
 * contents).
 *
 * The skip needs this, not just the ref. The replacement step only ever copies,
 * it never removes — so deleting a file from build-src/replace leaves the
 * upstream ref unchanged, a ref-only check would skip, and the stale replacement
 * would sit in src/ forever. Hashing the delta makes that deletion force a real
 * re-sync.
 *
 * `.DS_Store` is excluded because copyReplacements skips it, so it cannot change
 * what lands in src/.
 */
function deltaHash () {
  if (!existsSync(REPLACE_DIR)) {
    return 'none'
  }
  const files = []
  const walk = (dir) => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      if (entry.name === '.DS_Store') {
        continue
      }
      const full = join(dir, entry.name)
      if (entry.isDirectory()) {
        walk(full)
      } else if (entry.isFile()) {
        files.push(relative(REPLACE_DIR, full).split(sep).join('/'))
      }
    }
  }
  walk(REPLACE_DIR)

  const h = createHash('sha256')
  for (const rel of files.sort()) {
    h.update(rel).update('\0')
    h.update(createHash('sha256').update(readFileSync(join(REPLACE_DIR, rel))).digest('hex'))
    h.update('\n')
  }
  return h.digest('hex')
}

/** Version of the @electerm/electerm-react package sitting in node_modules. */
function clientVersion () {
  try {
    return JSON.parse(readFileSync(CLIENT_PKG_JSON, 'utf8')).version || null
  } catch (e) {
    return null
  }
}

/** What install-records.ref currently says, or null. */
function readRecord () {
  try {
    return JSON.parse(readFileSync(RECORD, 'utf8'))
  } catch (e) {
    return null
  }
}

const ref = remoteRef()
const delta = deltaHash()
const client = clientVersion()
const recorded = readRecord()

const upToDate = Boolean(
  ref &&
  client &&
  recorded &&
  recorded.repo === REPO &&
  recorded.branch === BRANCH &&
  recorded.ref === ref &&
  recorded.electermReact === client &&
  recorded.delta === delta &&
  existsSync('src') &&
  existsSync(CLIENT_DIR)
)

if (upToDate) {
  echo(`up to date: ${REPO}@${ref.slice(0, 7)} (${BRANCH}), electerm-react ${client}, delta unchanged — skipping download`)
} else {
  if (!ref) {
    echo('WARNING: could not resolve the source ref — cannot skip, downloading')
  }

  // -------------------------------------------------------------------------
  // 1. Download the latest source archive
  // -------------------------------------------------------------------------
  echo(`downloading latest ${REPO} (${BRANCH} branch)…`)

  shellRm('-rf', TMP)
  await mkdir(TMP, { recursive: true })

  let downloaded = false
  try {
    const res = await fetch(URL)
    if (!res.ok) {
      throw new Error(`HTTP ${res.status} ${res.statusText}`)
    }
    const buf = Buffer.from(await res.arrayBuffer())
    await writeFile(TMP_FILE, buf)
    echo('download complete')
    downloaded = true
  } catch (e) {
    echo(`WARNING: failed to download source — ${e.message}`)
    if (existsSync('src')) {
      echo('keeping existing src/ folder')
    } else {
      echo('ERROR: src/ does not exist and download failed — cannot continue')
      process.exit(1)
    }
  }

  // -------------------------------------------------------------------------
  // 2. Extract archive and replace src/
  // -------------------------------------------------------------------------
  if (downloaded) {
    echo('extracting…')
    await tarX({
      file: TMP_FILE,
      cwd: TMP,
      strip: 1 // remove the top-level "<repo>-<branch>/" directory
    })

    echo('syncing src/ from the source archive…')
    shellRm('-rf', 'src')
    // shelljs `rm -rf` reports failure only as a warning, so an intercepted
    // delete (a bulk-delete guard, a read-only mount) leaves src/ in place and
    // the copy below would land *inside* it — producing src/src and a tree that
    // is silently half old, half new. Refuse instead: no record is written, so
    // the next run tries again.
    if (existsSync('src')) {
      echo('ERROR: could not remove src/ — refusing to copy into it (that would nest the tree at src/src)')
      echo('       a bulk-delete guard or read-only mount can cause this; remove src/ by hand and retry')
      process.exit(1)
    }
    cp('-r', resolve(TMP, 'src'), resolve('src'))
    if (!existsSync(resolve('src/app')) || !existsSync(resolve('src/client'))) {
      echo('ERROR: src/ does not look like a source tree after the copy — not recording it as installed')
      process.exit(1)
    }
  }

  // -------------------------------------------------------------------------
  // 3. Copy @electerm/electerm-react client from node_modules
  // -------------------------------------------------------------------------
  echo('installing electerm-react module')
  shellRm('-rf', 'src/client/electerm-react')
  cp('-r', 'node_modules/@electerm/electerm-react/client', 'src/client/electerm-react')

  // -------------------------------------------------------------------------
  // 4. Apply tracked HarmonyOS source replacements
  //    (runs last, so it also covers the electerm-react folder copied above)
  // -------------------------------------------------------------------------
  if (existsSync(REPLACE_DIR)) {
    echo('applying HarmonyOS source replacements…')
    await copyReplacements(REPLACE_DIR, resolve('src'))
  }

  // -------------------------------------------------------------------------
  // 5. Record what src/ was built from, so the next run can skip all of the
  //    above. Written last, and only after a real download: recording a ref we
  //    never materialised would make the next run skip a sync that never
  //    happened. No timestamp, so re-running does not churn the file.
  // -------------------------------------------------------------------------
  if (downloaded && ref && client) {
    await writeFile(
      RECORD,
      JSON.stringify({
        repo: REPO,
        branch: BRANCH,
        ref,
        electermReact: client,
        delta
      }, null, 2) + '\n'
    )
    echo(`wrote install-records.ref: ${REPO}@${ref.slice(0, 7)}, electerm-react ${client}`)
  } else if (downloaded) {
    echo('WARNING: not writing install-records.ref (missing ref or client version) — the next run will download again')
  }

  // -------------------------------------------------------------------------
  // 6. Cleanup temp files
  // -------------------------------------------------------------------------
  shellRm('-rf', TMP)
}

echo('done install required modules')

/**
 * Copy build-src/replace over src/, recursively.
 *
 * `.DS_Store` is skipped: it is Finder metadata, not source, and it must not
 * reach src/ (nor the delta hash, which is computed over exactly what this
 * function copies).
 */
async function copyReplacements (from, to) {
  await mkdir(to, { recursive: true })
  for (const entry of await readdir(from, { withFileTypes: true })) {
    if (entry.name === '.DS_Store') {
      continue
    }
    const source = resolve(from, entry.name)
    const destination = resolve(to, entry.name)
    if (entry.isDirectory()) {
      await copyReplacements(source, destination)
    } else {
      await copyFile(source, destination)
    }
  }
}
