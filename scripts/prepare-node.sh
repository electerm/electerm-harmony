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

RAWFILE_NODE_DIR="${PROJECT_ROOT}/entry/src/main/resources/rawfile/node"
DOWNLOAD_DIR="${PROJECT_ROOT}/.cache"
TARBALL_NAME="node-${OHOS_NODE_VERSION}-openharmony-arm64.tar.gz"
DOWNLOAD_URL="https://github.com/${OHOS_NODE_REPO}/releases/download/${OHOS_NODE_VERSION}/${TARBALL_NAME}"

# --- Main -------------------------------------------------------------------

echo "==> Preparing ohos-node ${OHOS_NODE_VERSION}"

mkdir -p "${DOWNLOAD_DIR}" "${RAWFILE_NODE_DIR}"

# Download if not cached
if [ ! -f "${DOWNLOAD_DIR}/${TARBALL_NAME}" ]; then
  echo "    Downloading from ${DOWNLOAD_URL} ..."
  curl -L --fail -o "${DOWNLOAD_DIR}/${TARBALL_NAME}" "${DOWNLOAD_URL}"
else
  echo "    Using cached tarball: ${DOWNLOAD_DIR}/${TARBALL_NAME}"
fi

# Clean previous extraction
rm -rf "${RAWFILE_NODE_DIR:?}/"*

# Extract (strip top-level directory)
echo "    Extracting to ${RAWFILE_NODE_DIR}/ ..."
tar -zxf "${DOWNLOAD_DIR}/${TARBALL_NAME}" \
  --strip-components=1 \
  -C "${RAWFILE_NODE_DIR}"

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
