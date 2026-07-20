#!/usr/bin/env bash
# prepare-node.sh — Download and extract the ohos-node prebuilt binary
# into the HarmonyOS app's rawfile resources.
#
# Usage:
#   ./scripts/prepare-node.sh [version]
#
# Defaults:
#   version = v24.2.0 (latest release from hqzing/ohos-node)

set -euo pipefail

# --- Config -----------------------------------------------------------------

OHOS_NODE_VERSION="${1:-${OHOS_NODE_VERSION:-v24.2.0}}"
OHOS_NODE_REPO="hqzing/ohos-node"

# Resolve project root (parent of scripts/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

RAWFILE_NODE_DIR="${PROJECT_ROOT}/entry/src/main/resources/rawfile/electerm"
DOWNLOAD_DIR="${PROJECT_ROOT}/.cache"
TARBALL_NAME="node-${OHOS_NODE_VERSION}-openharmony-arm64.tar.gz"
DOWNLOAD_URL="https://github.com/${OHOS_NODE_REPO}/releases/download/${OHOS_NODE_VERSION}/${TARBALL_NAME}"

# --- Main -------------------------------------------------------------------

echo "==> Preparing ohos-node ${OHOS_NODE_VERSION}"

mkdir -p "${DOWNLOAD_DIR}"
mkdir -p "${RAWFILE_NODE_DIR}"

# Download if not cached
if [ ! -f "${DOWNLOAD_DIR}/${TARBALL_NAME}" ]; then
  echo "    Downloading from ${DOWNLOAD_URL} ..."
  curl -L --fail -o "${DOWNLOAD_DIR}/${TARBALL_NAME}" "${DOWNLOAD_URL}"
else
  echo "    Using cached tarball: ${DOWNLOAD_DIR}/${TARBALL_NAME}"
fi

# Clean previous node binary extraction (only bin/,
# NOT the entire electerm/ directory — prepare-web.sh puts web files there too)
rm -rf "${RAWFILE_NODE_DIR}/bin"

# Extract only bin/ from the tarball.
# We skip lib/node_modules (npm, corepack) because:
#   1. The app uses app.bundle.mjs (esbuild bundle) — all deps are inlined
#   2. lib/node_modules adds ~12MB to the HAP unnecessarily
#   3. Some dotfiles in npm's node_modules cause getRawFileDescriptor failures
echo "    Extracting bin/ to ${RAWFILE_NODE_DIR}/ ..."
# The tarball has a top-level directory (e.g. node-v24.2.0-openharmony-arm64/),
# so we use --wildcards to match '*/bin/' and --strip-components=1 to flatten.
tar -zxf "${DOWNLOAD_DIR}/${TARBALL_NAME}" \
  --strip-components=1 \
  -C "${RAWFILE_NODE_DIR}" \
  --wildcards '*/bin/'

# Verify the node binary exists
NODE_BIN="${RAWFILE_NODE_DIR}/bin/node"
if [ -f "${NODE_BIN}" ]; then
  echo "    ✓ Node.js binary: ${NODE_BIN}"
  echo "    ✓ Size: $(du -h "${NODE_BIN}" | cut -f1)"
else
  echo "    ✗ ERROR: node binary not found at ${NODE_BIN}"
  exit 1
fi

echo "==> ohos-node preparation complete."
