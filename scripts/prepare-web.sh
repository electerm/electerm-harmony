#!/usr/bin/env bash
# prepare-web.sh — Install, build, and bundle the web app
# from the project root into the HarmonyOS app's resfile resources.
#
# This script:
#   1. Installs npm dependencies in the project root
#   2. Runs build/harmony/build.mjs which:
#      - Vite-builds the React frontend → dist/assets/
#      - esbuild-bundles the Node.js backend → app.bundle.cjs (CJS format)
#      - Generates main.js (Electron main process)
#      - Generates package.json
#   3. Copies the output into the HarmonyOS resfile directory
#
# Usage:
#   ./scripts/prepare-web.sh
#
# Environment variables:
#   OHOS_SERVER_SECRET  — sets SERVER_SECRET in .env (optional, defaults to a local constant)

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

echo "==> Preparing web app (from project root: ${WEB_SRC_DIR})"

if [ ! -f "${WEB_SRC_DIR}/package.json" ]; then
  echo "    ✗ package.json not found at ${WEB_SRC_DIR}/package.json"
  exit 1
fi

cd "${WEB_SRC_DIR}"

# Print version for traceability
WEB_VERSION=$(python3 -c "import json; print(json.load(open('package.json'))['version'])" 2>/dev/null || echo "unknown")
echo "    Version: ${WEB_VERSION}"

# Install dependencies (needed for esbuild, vite, and static asset packages)
echo "    Installing dependencies ..."
npm install --legacy-peer-deps

# Create .env from .sample.env (needed by the backend, though main.js
# overrides most env vars at runtime)
echo "    Creating .env ..."
cp .sample.env .env

# Set SERVER_SECRET from CI env var (optional)
if [ -n "${OHOS_SERVER_SECRET:-}" ]; then
  echo "    Setting SERVER_SECRET from OHOS_SERVER_SECRET ..."
  sed -i.bak "s/^SERVER_SECRET=.*/SERVER_SECRET=${OHOS_SERVER_SECRET}/" .env
  rm -f .env.bak
fi

# Run the HarmonyOS build script (vite + esbuild + Electron main.js)
echo "    Building HarmonyOS Electron bundle ..."
npm run build:harmony

# --- Copy output into resfile -----------------------------------------------

HARMONY_OUTPUT="${WEB_SRC_DIR}/build/harmony/resfile/resources/app"

if [ ! -d "${HARMONY_OUTPUT}" ]; then
  echo "    ✗ Build output not found at ${HARMONY_OUTPUT}"
  echo "    Run node build/harmony/build.mjs manually to check for errors."
  exit 1
fi

# Verify web_engine exists (should have been prepared by prepare-electron-runtime.sh)
if [ ! -d "${PROJECT_ROOT}/web_engine" ]; then
  echo "    ✗ web_engine/ not found. Run ./scripts/prepare-electron-runtime.sh first."
  exit 1
fi

echo "    Copying into ${RESFILE_APP_DIR}/ ..."

# Clean previous
rm -rf "${RESFILE_APP_DIR}"
mkdir -p "${RESFILE_APP_DIR}"

# Copy the entire app/ output (main.js, app.bundle.cjs, package.json,
# views/, dist/) into resfile/resources/app/
cp -r "${HARMONY_OUTPUT}/." "${RESFILE_APP_DIR}/"

# Remove any .env file — not needed in the Electron app (main.js sets env vars)
rm -f "${RESFILE_APP_DIR}/.env"

echo "    ✓ Bundled size: $(du -sh "${RESFILE_APP_DIR}" | cut -f1)"
echo "==> Web app preparation complete."
