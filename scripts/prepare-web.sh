#!/usr/bin/env bash
# prepare-web.sh — Install deps and build the electerm web app (frontend +
# pure-node backend) into the entry module's resfile directory.
#
# Runs build-src/web/build.mjs which:
#   1. vite-builds the frontend  -> resfile/electerm/dist/assets
#   2. copies static assets + views/index.pug
#   3. esbuild-bundles the backend -> resfile/electerm/app.bundle.mjs
#   4. writes resfile/electerm/index.js (runtime env setup) + package.json
#
# The resfile directory is packaged into the HAP and read directly by the
# on-device node process — no runtime extraction.
#
# Usage:
#   ./scripts/prepare-web.sh
#
# Environment variables:
#   SERVER_SECRET / OHOS_SERVER_SECRET — JWT secret baked into the build
#                                        (required in CI, optional locally)
set -euo pipefail

# --- Config -----------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

RESFILE_APP_DIR="${PROJECT_ROOT}/entry/src/main/resources/resfile/electerm"

# --- Main -------------------------------------------------------------------

echo "==> Preparing electerm web app (from project root: ${PROJECT_ROOT})"

cd "${PROJECT_ROOT}"

APP_VERSION=$(python3 -c "import json; print(json.load(open('package.json'))['version'])" 2>/dev/null || echo "unknown")
echo "    Version: ${APP_VERSION}"

# Install dependencies (frontend build tools + backend runtime deps).
# --ignore-scripts avoids native module compilation for the host platform
# (node-pty, serialport — not needed, they are esbuild externals).
echo "    Installing dependencies ..."
if ! npm ci --legacy-peer-deps --ignore-scripts; then
  # A version bumped by hand in package.json + package-lock.json keeps the OLD
  # integrity hash on the lock entry, which makes BOTH `npm ci` and a plain
  # `npm install` die with EINTEGRITY. Re-resolve the direct deps from the
  # registry, then retry. See build-src/bin/fix-lock-integrity.js.
  echo "    npm ci failed, re-resolving lockfile integrity ..."
  node build-src/bin/fix-lock-integrity.js
  npm ci --legacy-peer-deps --ignore-scripts || {
    echo "    npm ci failed again, falling back to npm install ..."
    npm install --legacy-peer-deps --ignore-scripts
  }
fi

# Copy @electerm/electerm-react's client sources into src/client/electerm-react
# (gitignored generated dir the vite build imports from). This is the android
# repo's build-src/bin/install.js step; run it directly — `npm run install` would
# collide with npm's install lifecycle script.
echo "    Installing electerm-react client sources ..."
node build-src/bin/install.js

# Stage the OHOS-patched node-pty native addon into entry/libs/<abi>/ so the
# local terminal has a loadable PTY implementation on device. Must run before
# build:web — build-src/web/build.mjs copies the node-pty JS layer into the
# resfile bundle and refuses to build the local terminal without it.
echo "    Staging OHOS node-pty addon ..."
"${SCRIPT_DIR}/prepare-node-pty.sh"

# Build frontend + backend into entry resfile
echo "    Building electerm web app ..."
npm run build:web

# --- Verify output ---

if [ ! -d "${RESFILE_APP_DIR}" ]; then
  echo "    ✗ Build output not found at ${RESFILE_APP_DIR}"
  echo "    Run node build-src/web/build.mjs manually to check for errors."
  exit 1
fi

for f in "index.js" "app.bundle.mjs" "package.json" "views/index.pug"; do
  if [ ! -f "${RESFILE_APP_DIR}/${f}" ]; then
    echo "    ✗ Missing: ${RESFILE_APP_DIR}/${f}"
    exit 1
  fi
  echo "    ✓ Found: ${f}"
done

JS_COUNT=$(find "${RESFILE_APP_DIR}/dist/assets/js" -name "*.js" 2>/dev/null | wc -l | tr -d ' ')
CSS_COUNT=$(find "${RESFILE_APP_DIR}/dist/assets/css" -name "*.css" 2>/dev/null | wc -l | tr -d ' ')
echo "    ✓ dist/assets/js: ${JS_COUNT} files, dist/assets/css: ${CSS_COUNT} files"
if [ "${JS_COUNT}" = "0" ] || [ "${CSS_COUNT}" = "0" ]; then
  echo "    ✗ Frontend assets missing"
  exit 1
fi

echo "    ✓ App size: $(du -sh "${RESFILE_APP_DIR}" | cut -f1)"
echo "==> Web app preparation complete."
