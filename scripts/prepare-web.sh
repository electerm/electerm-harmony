#!/usr/bin/env bash
# prepare-web.sh — Install, build, and bundle the electerm app
# from the project root into the HarmonyOS app's resfile resources.
#
# This script:
#   1. Installs npm dependencies in the project root (dev deps for build tools)
#   2. Runs build/harmony/build.mjs which:
#      - Vite-builds the React frontend → work/app/assets/
#      - Copies src/app/ source code → work/app/ (NOT bundled, runs directly)
#      - Installs production deps in work/app/ (excludes native modules)
#      - Copies work/app/ → web_engine/src/main/resources/resfile/resources/app/
#
# Key difference from old electerm-web build:
#   - The electerm source code runs DIRECTLY from source (not esbuild-bundled)
#   - Native modules (node-pty, serialport) are excluded — source has try/catch guards
#   - The app entry is app.js (Electron main process), not a generated main.js wrapper
#
# Usage:
#   ./scripts/prepare-web.sh
#
# Environment variables:
#   OHOS_SERVER_SECRET  — sets SERVER_SECRET in .env (optional)

set -euo pipefail

# --- Config -----------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Web app source (project root)
WEB_SRC_DIR="${PROJECT_ROOT}"
# Output: web_engine/src/main/resources/resfile/resources/app/
# (Electron app directory in the web_engine HAR module's resfile)
RESFILE_APP_DIR="${PROJECT_ROOT}/web_engine/src/main/resources/resfile/resources/app"

# --- Main -------------------------------------------------------------------

echo "==> Preparing electerm app (from project root: ${WEB_SRC_DIR})"

if [ ! -f "${WEB_SRC_DIR}/package.json" ]; then
  echo "    ✗ package.json not found at ${WEB_SRC_DIR}/package.json"
  exit 1
fi

cd "${WEB_SRC_DIR}"

# Print version for traceability
APP_VERSION=$(python3 -c "import json; print(json.load(open('package.json'))['version'])" 2>/dev/null || echo "unknown")
echo "    Version: ${APP_VERSION}"

# Install dependencies (needed for vite, pug, shelljs, and static asset packages)
# --ignore-scripts prevents native module compilation (electron-rebuild etc.)
echo "    Installing dependencies ..."
npm install --legacy-peer-deps --ignore-scripts

# Create .env from .sample.env if it exists (needed by build/vite/common.js for dotenv)
if [ -f ".sample.env" ]; then
  echo "    Creating .env ..."
  cp .sample.env .env
fi

# Set SERVER_SECRET from CI env var (optional)
if [ -n "${OHOS_SERVER_SECRET:-}" ]; then
  echo "    Setting SERVER_SECRET from OHOS_SERVER_SECRET ..."
  sed -i.bak "s/^SERVER_SECRET=.*/SERVER_SECRET=${OHOS_SERVER_SECRET}/" .env 2>/dev/null || true
  rm -f .env.bak
fi

# Run the HarmonyOS build script (vite + copy source + install deps + copy to resfile)
echo "    Building HarmonyOS electerm app (direct source mode) ..."
npm run build:harmony

# --- Verify output ---

if [ ! -d "${RESFILE_APP_DIR}" ]; then
  echo "    ✗ Build output not found at ${RESFILE_APP_DIR}"
  echo "    Run node build/harmony/build.mjs manually to check for errors."
  exit 1
fi

# Verify app.js (Electron main process entry)
if [ ! -f "${RESFILE_APP_DIR}/app.js" ]; then
  echo "    ✗ Missing: ${RESFILE_APP_DIR}/app.js"
  exit 1
fi
echo "    ✓ Found: app.js"

# Verify package.json
if [ ! -f "${RESFILE_APP_DIR}/package.json" ]; then
  echo "    ✗ Missing: ${RESFILE_APP_DIR}/package.json"
  exit 1
fi
echo "    ✓ Found: package.json"

# Verify node_modules
if [ ! -d "${RESFILE_APP_DIR}/node_modules" ]; then
  echo "    ✗ Missing: node_modules/"
  exit 1
fi
echo "    ✓ Found: node_modules/"

# Remove any .env file — not needed in the Electron app
rm -f "${RESFILE_APP_DIR}/.env"

echo "    ✓ App size: $(du -sh "${RESFILE_APP_DIR}" | cut -f1)"
echo "==> Web app preparation complete."
