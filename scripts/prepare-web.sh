#!/usr/bin/env bash
# prepare-web.sh — Clone, install, build, and bundle electerm-web
# into the HarmonyOS app's rawfile resources.
#
# Usage:
#   ./scripts/prepare-web.sh [repo] [ref]
#
# Defaults:
#   repo = electerm/electerm-web
#   ref  = main
#
# Environment variables:
#   OHOS_SERVER_SECRET  — sets SERVER_SECRET in .env (required for production)
#   ELECTERM_WEB_REPO   — GitHub repo (default: electerm/electerm-web)
#   ELECTERM_WEB_REF    — branch/tag (default: main)

set -euo pipefail

# --- Config -----------------------------------------------------------------

ELECTERM_WEB_REPO="${1:-${ELECTERM_WEB_REPO:-electerm/electerm-web}}"
ELECTERM_WEB_REF="${2:-${ELECTERM_WEB_REF:-main}}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

RAWFILE_WEB_DIR="${PROJECT_ROOT}/entry/src/main/resources/rawfile/electerm-web"
CLONE_DIR="${PROJECT_ROOT}/.cache/electerm-web"

# Files/folders in electerm-web that are NOT needed at runtime — never copy to rawfile
# (after npm run build, the compiled output is in node_modules/ and the build artifacts
#  are self-contained; these source/docs/config files are useless in the HAP)
SKIP_FROM_BUNDLE="
LICENSE
README_cn.md
README.md
config.sample.js
package-lock.json
run-electerm-web.sh
build
examples
src
"

# --- Main -------------------------------------------------------------------

echo "==> Preparing electerm-web (${ELECTERM_WEB_REPO}@${ELECTERM_WEB_REF})"

# Clone or update
if [ -d "${CLONE_DIR}/.git" ]; then
  echo "    Updating existing clone ..."
  git -C "${CLONE_DIR}" fetch --all --prune
  git -C "${CLONE_DIR}" checkout "${ELECTERM_WEB_REF}"
  git -C "${CLONE_DIR}" pull --ff-only
else
  echo "    Cloning ${ELECTERM_WEB_REPO} ..."
  rm -rf "${CLONE_DIR}"
  mkdir -p "$(dirname "${CLONE_DIR}")"
  git clone --depth 1 --branch "${ELECTERM_WEB_REF}" \
    "https://github.com/${ELECTERM_WEB_REPO}.git" \
    "${CLONE_DIR}"
fi

cd "${CLONE_DIR}"

# Install dependencies
echo "    Installing dependencies ..."
npm install

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
npm prune --production

# --- Bundle into rawfile ----------------------------------------------------

echo "    Bundling into ${RAWFILE_WEB_DIR}/ ..."

# Clean previous
rm -rf "${RAWFILE_WEB_DIR}"
mkdir -p "${RAWFILE_WEB_DIR}"

# Only copy what's needed at runtime:
#   dist/         — compiled static assets (frontend build output)
#   node_modules/ — runtime dependencies (after npm prune --production)
#   package.json  — module resolution
#   .env          — server configuration (with SERVER_SECRET set)
#   config.js     — user customizations (if exists)
# The following are NOT copied (useless after build):
#   LICENSE, README.md, README_cn.md, config.sample.js, package-lock.json,
#   run-electerm-web.sh, build/, examples/, src/

cp -r dist "${RAWFILE_WEB_DIR}/"
cp -r node_modules "${RAWFILE_WEB_DIR}/"
cp package.json "${RAWFILE_WEB_DIR}/"
cp .env "${RAWFILE_WEB_DIR}/"

if [ -f config.js ]; then
  cp config.js "${RAWFILE_WEB_DIR}/"
fi

echo "    ✓ Bundled size: $(du -sh "${RAWFILE_WEB_DIR}" | cut -f1)"
echo "==> electerm-web preparation complete."
