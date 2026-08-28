#!/usr/bin/env bash
# prepare-node.sh — Download the OpenHarmony Node.js runtime (hqzing/ohos-node)
# and install it into the entry module as a native "library".
#
# The node binary is a musl PIE executable for aarch64-ohos. It is installed
# as entry/libs/arm64-v8a/libnode.so because:
#   - files in the HAP libs directory are installed to the app's (executable)
#     native lib dir, so a child process can execv() it without any runtime
#     extraction step — rawfile/resfile content would need copying to filesDir
#     first, and filesDir may be mounted noexec;
#   - hvigor packages entry/libs/<abi>/*.so into the HAP automatically.
#
# The binary is stripped (when an OHOS llvm-strip is available) to drop the
# ~60MB of debug info that hqzing builds ship with.
#
# Usage:
#   ./scripts/prepare-node.sh
#
# Environment variables:
#   NODE_VERSION       — which hqzing/ohos-node release to use (default 24.19.0)
#   OHOS_SDK_HOME      — SDK root (for llvm-strip; stripping is skipped if unset)
#   NODE_DIST_MIRROR   — override the download mirror (default: GitHub releases)
set -euo pipefail

# --- Config -----------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

NODE_VERSION="${NODE_VERSION:-24.19.0}"
NODE_DIST_MIRROR="${NODE_DIST_MIRROR:-https://github.com/hqzing/ohos-node/releases/download}"
ARCHIVE_NAME="node-v${NODE_VERSION}-openharmony-arm64.tar.xz"
DOWNLOAD_URL="${NODE_DIST_MIRROR}/v${NODE_VERSION}/${ARCHIVE_NAME}"

CACHE_DIR="${PROJECT_ROOT}/.cache/node-runtime"
ARCHIVE_PATH="${CACHE_DIR}/${ARCHIVE_NAME}"
LIBS_DIR="${PROJECT_ROOT}/entry/libs/arm64-v8a"
OUT_BIN="${LIBS_DIR}/libnode.so"

# --- Main -------------------------------------------------------------------

echo "==> Preparing OpenHarmony Node.js runtime (hqzing/ohos-node v${NODE_VERSION})"

mkdir -p "${CACHE_DIR}" "${LIBS_DIR}"

MARKER_FILE="${CACHE_DIR}/installed-v${NODE_VERSION}.marker"

if [ -f "${OUT_BIN}" ] && [ -f "${MARKER_FILE}" ]; then
  echo "    ✓ libnode.so already prepared (v${NODE_VERSION}), skipping."
  exit 0
fi

# 1. Download (cached)
if [ ! -s "${ARCHIVE_PATH}" ]; then
  echo "    Downloading ${DOWNLOAD_URL} ..."
  curl -fL --retry 5 --retry-all-errors --retry-delay 5 \
    -o "${ARCHIVE_PATH}.tmp" "${DOWNLOAD_URL}"
  mv "${ARCHIVE_PATH}.tmp" "${ARCHIVE_PATH}"
else
  echo "    ✓ Using cached archive: ${ARCHIVE_PATH}"
fi

# 2. Extract just the node binary (skip npm/corepack/man — not needed on device)
echo "    Extracting node binary ..."
rm -rf "${CACHE_DIR}/extract"
mkdir -p "${CACHE_DIR}/extract"
tar -xJf "${ARCHIVE_PATH}" -C "${CACHE_DIR}/extract" \
  --strip-components=1 "node-v${NODE_VERSION}-openharmony-arm64/bin/node"

NODE_EXTRACTED="${CACHE_DIR}/extract/bin/node"
if [ ! -f "${NODE_EXTRACTED}" ]; then
  echo "    ✗ node binary not found in archive"
  exit 1
fi

file "${NODE_EXTRACTED}" || true

# 3. Strip debug info with the OHOS toolchain's llvm-strip (optional)
STRIP_BIN=""
for candidate in \
  "${OHOS_SDK_HOME:-}/default/openharmony/native/llvm/bin/llvm-strip" \
  "${OHOS_SDK_HOME:-}/native/llvm/bin/llvm-strip"; do
  if [ -x "${candidate}" ]; then
    STRIP_BIN="${candidate}"
    break
  fi
done
# Fall back to PATH llvm-strip (same target-independence: strip only removes
# sections, it does not need to understand the target ABI).
if [ -z "${STRIP_BIN}" ]; then
  STRIP_BIN="$(command -v llvm-strip || true)"
fi

cp "${NODE_EXTRACTED}" "${OUT_BIN}.tmp"
if [ -n "${STRIP_BIN}" ]; then
  echo "    Stripping with ${STRIP_BIN} ..."
  "${STRIP_BIN}" "${OUT_BIN}.tmp" || echo "    ⚠ strip failed, keeping unstripped binary"
else
  echo "    ⚠ no llvm-strip found, keeping unstripped binary"
fi
mv "${OUT_BIN}.tmp" "${OUT_BIN}"

echo "${NODE_VERSION}" > "${MARKER_FILE}"
echo "${DOWNLOAD_URL}" > "${CACHE_DIR}/node-source-url.txt"
# NOTE: only the .so lives in entry/libs — hvigor strips every file there
# and rejects non-object files.

echo "    ✓ Installed: ${OUT_BIN} ($(du -h "${OUT_BIN}" | cut -f1))"
echo "==> Node.js runtime preparation complete."
