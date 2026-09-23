#!/usr/bin/env bash
# prepare-node-pty.sh — stage the OHOS-patched node-pty native addon.
#
# The upstream node-pty cannot build for OHOS with a desktop toolchain: the
# binary must be produced on an OHOS device (aarch64-linux-ohos + musl libc).
# @FiveHair's patched build is published as a GitHub release asset on THIS
# repository so CI can fetch it from a stable, public URL:
#
#   https://github.com/electerm/electerm-harmony/releases/tag/node-pty-ohos-v1
#
# This script downloads that asset, ELF-patches the addon so it can resolve
# symbols against our in-process libnode.so, and installs it where OHOS will
# actually map native code from.
#
# TWO OHOS-SPECIFIC FACTS THIS SCRIPT ENCODES
# -------------------------------------------
# 1. A dlopen()ed addon cannot see the host process's symbols on OHOS: the
#    relocation only searches the addon's own DT_NEEDED closure, so
#    `require('pty.node')` dies with
#      Error relocating ...: napi_fatal_error: symbol not found
#    (preloading with RTLD_GLOBAL does not help). Fix: rewrite the addon's
#    existing DT_NEEDED `libc++_shared.so` -> `libnode.so`, making the host an
#    explicit dependency. Use the FILENAME, never the SONAME `libnode.so.137`.
#    libnode.so re-exports the libc++ symbols, so dropping libc++_shared.so is
#    safe.
#
# 2. OHOS refuses to mmap native code out of the HAP's resources/resfile tree
#    (it fails at load with musl's useless "No error information"). Only the
#    app's libs dir may hold loadable native code, so the addon is installed to
#    entry/libs/<abi>/libpty.node, which the HAP packs as libs/arm64/libpty.node
#    (build-profile.json5 sets `collectAllLibs: true`).
#
# node_ctl.c derives that same path from the resolved libnode.so and exports it
# as ELECTERM_PTY_ADDON; node-pty's lib/unixTerminal.js + lib/utils.js read it
# first. The JS side of node-pty (including its OHOS Duplex-stream patch) is
# copied into the resfile app by build-src/web/build.mjs from
# build-src/node-pty-ohos/.
#
# Usage:
#   ./scripts/prepare-node-pty.sh
#
# Environment:
#   PTY_RELEASE_TAG     release tag to pull (default: node-pty-ohos-v1)
#   PTY_SKIP_CHECKSUM   set to 1 to skip the pty.node md5 verification
#   PTY_FORCE_DOWNLOAD  set to 1 to re-download even if the zip is cached
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PTY_RELEASE_TAG="${PTY_RELEASE_TAG:-node-pty-ohos-v1}"
PTY_ASSET_NAME="pty_ohos_modifications.zip"
PTY_URL="${PTY_URL:-https://github.com/electerm/electerm-harmony/releases/download/${PTY_RELEASE_TAG}/${PTY_ASSET_NAME}}"

# md5 of the pty.node shipped by node-pty-ohos-v1, as documented in the release
# asset's own OHOS_PTY_CHANGES.md. Guards against a silently re-uploaded asset.
PTY_NODE_MD5="bd6da61b3a096c5c041ab991b6e3b236"

# Rewrite the addon's DT_NEEDED so it can see libnode.so's symbols.
PTY_NEEDED_PATCH="libc++_shared.so=libnode.so"

ABI="${PTY_ABI:-arm64-v8a}"
CACHE_DIR="${PROJECT_ROOT}/build-download/pty-ohos"
EXTRACT_DIR="${CACHE_DIR}/pty_ohos_modifications"
WORK_DIR="${PROJECT_ROOT}/temp/pty-ohos"
LIBS_DIR="${PROJECT_ROOT}/entry/libs/${ABI}"

echo "==> Staging OHOS node-pty addon (${PTY_RELEASE_TAG}, abi=${ABI})"

mkdir -p "${CACHE_DIR}" "${WORK_DIR}"

# --- 1. download (cached) ---------------------------------------------------
ZIP="${CACHE_DIR}/${PTY_ASSET_NAME}"
if [ "${PTY_FORCE_DOWNLOAD:-0}" = "1" ]; then
  rm -f "${ZIP}"
fi
if [ ! -f "${ZIP}" ]; then
  echo "    downloading ${PTY_URL}"
  curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 -o "${ZIP}.part" "${PTY_URL}"
  mv "${ZIP}.part" "${ZIP}"
else
  echo "    using cached ${ZIP}"
fi

if ! unzip -tq "${ZIP}" >/dev/null 2>&1; then
  echo "    ✗ cached archive is corrupt — re-downloading once"
  rm -f "${ZIP}"
  curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 -o "${ZIP}" "${PTY_URL}"
  unzip -tq "${ZIP}" >/dev/null 2>&1 || { echo "    ✗ still corrupt"; exit 1; }
fi

# --- 2. extract -------------------------------------------------------------
rm -rf "${EXTRACT_DIR}"
mkdir -p "${EXTRACT_DIR}"
unzip -oq "${ZIP}" -d "${CACHE_DIR}"

for f in pty.node unixTerminal.js pty.cc binding.gyp OHOS_PTY_CHANGES.md; do
  if [ ! -f "${EXTRACT_DIR}/${f}" ]; then
    echo "    ✗ release asset is missing ${f}"
    exit 1
  fi
done
echo "    ✓ extracted ${EXTRACT_DIR}"

# --- 3. verify the binary ---------------------------------------------------
if [ "${PTY_SKIP_CHECKSUM:-0}" != "1" ]; then
  got="$(md5 -q "${EXTRACT_DIR}/pty.node" 2>/dev/null || md5sum "${EXTRACT_DIR}/pty.node" | cut -d' ' -f1)"
  if [ "${got}" != "${PTY_NODE_MD5}" ]; then
    echo "    ✗ pty.node md5 mismatch: expected ${PTY_NODE_MD5}, got ${got}"
    echo "      (set PTY_SKIP_CHECKSUM=1 to override)"
    exit 1
  fi
  echo "    ✓ pty.node md5 ${got}"
fi

# --- 4. ELF-patch DT_NEEDED -------------------------------------------------
# Patch a scratch copy: the .orig backup the patcher writes must not end up in
# entry/libs (the HAP packs everything under it).
rm -f "${WORK_DIR}/libpty.node.orig"
cp "${EXTRACT_DIR}/pty.node" "${WORK_DIR}/libpty.node"
echo "    before:"
python3 "${SCRIPT_DIR}/elf-patch-dynamic.py" --print "${WORK_DIR}/libpty.node" | sed 's/^/      /'
python3 "${SCRIPT_DIR}/elf-patch-dynamic.py" \
  --needed "${PTY_NEEDED_PATCH}" "${WORK_DIR}/libpty.node" || true
echo "    after:"
python3 "${SCRIPT_DIR}/elf-patch-dynamic.py" --print "${WORK_DIR}/libpty.node" | sed 's/^/      /'

# --- 5. install into the app libs dir --------------------------------------
mkdir -p "${LIBS_DIR}"
rm -f "${LIBS_DIR}/libpty.node.orig"
install -m 0755 "${WORK_DIR}/libpty.node" "${LIBS_DIR}/libpty.node"

if [ ! -f "${LIBS_DIR}/libnode.so" ]; then
  echo "    ! ${LIBS_DIR}/libnode.so is absent — run scripts/prepare-node.sh too"
fi

size=$(wc -c < "${LIBS_DIR}/libpty.node" | tr -d ' ')
echo "    ✓ ${LIBS_DIR}/libpty.node (${size} bytes)"
echo "==> node-pty addon ready."
