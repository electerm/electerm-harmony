#!/usr/bin/env bash
# prepare-web.sh — Install, build, and bundle electerm-web
# from the local electerm-web/ directory into the HarmonyOS app's rawfile resources.
#
# Usage:
#   ./scripts/prepare-web.sh
#
# Environment variables:
#   OHOS_SERVER_SECRET  — sets SERVER_SECRET in .env (required for production)

set -euo pipefail

# --- Config -----------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# electerm-web source is now bundled in the repo
WEB_SRC_DIR="${PROJECT_ROOT}/electerm-web"
RAWFILE_WEB_DIR="${PROJECT_ROOT}/entry/src/main/resources/rawfile/electerm-web"

# --- Main -------------------------------------------------------------------

echo "==> Preparing electerm-web (from local source: ${WEB_SRC_DIR})"

if [ ! -f "${WEB_SRC_DIR}/package.json" ]; then
  echo "    ✗ electerm-web source not found at ${WEB_SRC_DIR}/package.json"
  exit 1
fi

cd "${WEB_SRC_DIR}"

# Print version and commit for traceability
WEB_VERSION=$(python3 -c "import json; print(json.load(open('package.json'))['version'])" 2>/dev/null || echo "unknown")
echo "    Version: ${WEB_VERSION}"

# Install dependencies
echo "    Installing dependencies ..."
npm install --legacy-peer-deps

# Create .env from .sample.env
echo "    Creating .env ..."
cp .sample.env .env

# Set SERVER_SECRET from CI env var
if [ -n "${OHOS_SERVER_SECRET:-}" ]; then
  echo "    Setting SERVER_SECRET from OHOS_SERVER_SECRET ..."
  sed -i.bak "s/^SERVER_SECRET=.*/SERVER_SECRET=${OHOS_SERVER_SECRET}/" .env
  rm -f .env.bak
else
  echo "    ⚠ OHOS_SERVER_SECRET not set, using default from .sample.env"
fi

# Build production bundle
echo "    Building electerm-web ..."
NODE_ENV=production npm run build

# Prune dev dependencies to reduce size
echo "    Pruning devDependencies ..."
npm prune --production --legacy-peer-deps

# --- Bundle into rawfile ----------------------------------------------------

echo "    Bundling into ${RAWFILE_WEB_DIR}/ ..."

# Clean previous
rm -rf "${RAWFILE_WEB_DIR}"
mkdir -p "${RAWFILE_WEB_DIR}"

# Only copy what's needed at runtime:
#   dist/         — compiled static assets (frontend build output + pug views)
#   node_modules/ — runtime dependencies (after npm prune --production)
#   src/app/      — Express server code (app.js entry point, routes, lib, etc.)
#   package.json  — module resolution
#   .env          — server configuration (with SERVER_SECRET set)
#   config.js     — user customizations (if exists)

cp -r dist "${RAWFILE_WEB_DIR}/"
cp -r node_modules "${RAWFILE_WEB_DIR}/"
mkdir -p "${RAWFILE_WEB_DIR}/src"
cp -r src/app "${RAWFILE_WEB_DIR}/src/"
cp package.json "${RAWFILE_WEB_DIR}/"
cp .env "${RAWFILE_WEB_DIR}/"

if [ -f config.js ]; then
  cp config.js "${RAWFILE_WEB_DIR}/"
fi

echo "    ✓ Bundled size: $(du -sh "${RAWFILE_WEB_DIR}" | cut -f1)"
echo "==> electerm-web preparation complete."
