#!/usr/bin/env bash
# prepare-web.sh — Install, build, and bundle electerm-web
# from the local electerm-web/ directory into the HarmonyOS app's rawfile resources.
#
# This script:
#   1. Installs npm dependencies in electerm-web/
#   2. Runs build/harmony/build.mjs which:
#      - Vite-builds the React frontend → dist/assets/
#      - esbuild-bundles the Node.js backend → app.bundle.mjs
#      - Generates loading.html, index.js, package.json
#      - Aliases child_process to a no-op shim
#   3. Copies the output into the HarmonyOS rawfile directory
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

# electerm-web source (copied from electerm-android, now in the repo)
WEB_SRC_DIR="${PROJECT_ROOT}/electerm-web"
# Output: rawfile/electerm/ (node binary + web project + backend bundle)
RAWFILE_ELECTERM_DIR="${PROJECT_ROOT}/entry/src/main/resources/rawfile/electerm"

# --- Main -------------------------------------------------------------------

echo "==> Preparing electerm-web (from local source: ${WEB_SRC_DIR})"

if [ ! -f "${WEB_SRC_DIR}/package.json" ]; then
  echo "    ✗ electerm-web source not found at ${WEB_SRC_DIR}/package.json"
  exit 1
fi

cd "${WEB_SRC_DIR}"

# Print version for traceability
WEB_VERSION=$(python3 -c "import json; print(json.load(open('package.json'))['version'])" 2>/dev/null || echo "unknown")
echo "    Version: ${WEB_VERSION}"

# Install dependencies (needed for esbuild, vite, and static asset packages)
# On Windows, native modules (node-pty, serialport) may fail to compile.
# Use --ignore-scripts if that happens — these modules are marked as
# external in the esbuild bundle and use guarded dynamic imports, so
# their compiled binaries are not needed for the build.
echo "    Installing dependencies ..."
npm install --legacy-peer-deps

# Create .env from .sample.env
echo "    Creating .env ..."
cp .sample.env .env

# Set SERVER_SECRET from CI env var (optional — the entry script sets a
# default if this is not provided)
if [ -n "${OHOS_SERVER_SECRET:-}" ]; then
  echo "    Setting SERVER_SECRET from OHOS_SERVER_SECRET ..."
  sed -i.bak "s/^SERVER_SECRET=.*/SERVER_SECRET=${OHOS_SERVER_SECRET}/" .env
  rm -f .env.bak
else
  echo "    ⚠ OHOS_SERVER_SECRET not set, using default from .sample.env"
fi

# Run the HarmonyOS build script (vite + esbuild + loading page + node entry)
echo "    Building HarmonyOS bundle ..."
npm run build:harmony

# --- Copy output into rawfile ----------------------------------------------

HARMONY_OUTPUT="${WEB_SRC_DIR}/build/harmony/rawfile/electerm"

if [ ! -d "${HARMONY_OUTPUT}" ]; then
  echo "    ✗ Build output not found at ${HARMONY_OUTPUT}"
  echo "    Run node build/harmony/build.mjs manually to check for errors."
  exit 1
fi

echo "    Copying into ${RAWFILE_ELECTERM_DIR}/ ..."

# Clean previous
rm -rf "${RAWFILE_ELECTERM_DIR}"
mkdir -p "${RAWFILE_ELECTERM_DIR}"

# Copy the entire electerm/ output (loading.html, index.js, app.bundle.mjs,
# package.json, .env, views/, dist/) into rawfile/electerm/
cp -r "${HARMONY_OUTPUT}/." "${RAWFILE_ELECTERM_DIR}/"

echo "    ✓ Bundled size: $(du -sh "${RAWFILE_ELECTERM_DIR}" | cut -f1)"
echo "==> electerm-web preparation complete."
