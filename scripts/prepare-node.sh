#!/usr/bin/env bash
# prepare-node.sh — Download our own real shared libnode.so for OpenHarmony
# from the electerm/electerm-harmony GitHub release and install it into the
# entry module as the prebuilt Node.js native "library".
#
# WHY NOT hqzing/ohos-node (the old source):
#   hqzing ships a PIE executable (ET_DYN + PT_INTERP) named libnode.so.
#   dlopen()ing a PIE into the HarmonyOS app aliases local-exec %fs TLS to the
#   host app's TLS block, so V8's `thread_local current_per_thread_assert_data`
#   reads garbage and the release CHECK `AllowHeapAllocationInRelease`
#   fires on the very first heap allocation at Isolate::Initialize.
#   We build with `--shared` (scripts/build-node-ohos.sh, archived in
#   temp/bak/) to get a TRUE shared library (PIC + dynamic TLS, SONAME
#   libnode.so.<vernum>) that dlopen()s cleanly — exactly what that build
#   produces and this script downloads.
#
# The file lands in entry/libs/<abi>/ so hvigor packages it into the HAP's
# native libs dir (the app dlopens it from there at runtime).
#
# Usage:
#   ./scripts/prepare-node.sh [arch]
#     arch: arm64 (default) | x64
#
# Environment variables:
#   NODE_VERSION       — node.js version the release was built from (default 24.2.0)
#   RELEASE_TAG        — override the GitHub release tag (default auto-derived)
#   RELEASE_REPO       — repo hosting the release (default electerm/electerm-harmony)
set -euo pipefail

# --- Config -----------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

ARCH="${1:-${ARCH:-arm64}}"
case "${ARCH}" in
  arm64)    ABI="arm64-v8a"; ASSET_ARCH="arm64" ;;
  x64|x86_64) ABI="x86_64"; ASSET_ARCH="x64" ;;
  *) echo "    ✗ Unsupported arch: ${ARCH} (use arm64 or x64)"; exit 1 ;;
esac

NODE_VERSION="${NODE_VERSION:-24.2.0}"
RELEASE_REPO="${RELEASE_REPO:-electerm/electerm-harmony}"
RELEASE_TAG="${RELEASE_TAG:-ohos-node-shared-v${NODE_VERSION}}"

ASSET_NAME="libnode-${ASSET_ARCH}.so"
DOWNLOAD_URL="https://github.com/${RELEASE_REPO}/releases/download/${RELEASE_TAG}/${ASSET_NAME}"

CACHE_DIR="${PROJECT_ROOT}/.cache/node-runtime"
LIBS_DIR="${PROJECT_ROOT}/entry/libs/${ABI}"
OUT_BIN="${LIBS_DIR}/libnode.so"

# --- Main -------------------------------------------------------------------

echo "==> Preparing OpenHarmony Node.js shared lib (${ARCH} / ${ABI})"
echo "    Release: ${RELEASE_REPO} @ ${RELEASE_TAG}"

mkdir -p "${CACHE_DIR}" "${LIBS_DIR}"

MARKER_FILE="${CACHE_DIR}/installed-${ABI}-${RELEASE_TAG}.marker"

# Re-download if we have no libnode.so at all. The marker only short-circuits
# when both the file and marker exist — a half-installed state re-downloads.
if [ -f "${OUT_BIN}" ] && [ -f "${MARKER_FILE}" ]; then
  echo "    ✓ libnode.so already prepared (${RELEASE_TAG}), skipping."
  exit 0
fi

# 1. Download (cached per asset)
ARCHIVE_PATH="${CACHE_DIR}/${ASSET_NAME}"
if [ ! -s "${ARCHIVE_PATH}" ]; then
  echo "    Downloading ${DOWNLOAD_URL} ..."
  curl -fL --retry 5 --retry-all-errors --retry-delay 5 \
    -o "${ARCHIVE_PATH}.tmp" "${DOWNLOAD_URL}"
  mv "${ARCHIVE_PATH}.tmp" "${ARCHIVE_PATH}"
else
  echo "    ✓ Using cached archive: ${ARCHIVE_PATH}"
fi

# 2. Verify it's a REAL shared library — reject the broken PIE form
#    (ET_DYN + PT_INTERP). This is the whole point of the re-build.
echo "    Verifying ELF is a shared library (not a PIE) ..."
if python3 - "${ARCHIVE_PATH}" <<'PYEOF'
import struct, sys
path = sys.argv[1]
with open(path, 'rb') as f:
    data = f.read(64)
    if data[:4] != b'\x7fELF':
        sys.exit("not an ELF file")
    ei_class = data[4]          # 1=32bit 2=64bit
    ei_data  = data[5]          # 1=LE 2=BE
    machine  = struct.unpack('<H' if ei_data == 1 else '>H', data[18:20])[0]
    e_type   = struct.unpack('<H' if ei_data == 1 else '>H', data[16:18])[0]
    has_interp = False
    # read program headers (64-bit layout assumed like our builds)
    e_phoff   = struct.unpack('<Q' if ei_data == 1 else '>Q', data[32:40])[0]
    e_phentsize = struct.unpack('<H' if ei_data == 1 else '>H', data[54:56])[0]
    e_phnum   = struct.unpack('<H' if ei_data == 1 else '>H', data[56:58])[0]
    with open(path, 'rb') as f:
        for i in range(e_phnum):
            f.seek(e_phoff + i * e_phentsize)
            ph = f.read(e_phentsize)
            p_type = struct.unpack('<I' if ei_data == 1 else '>I', ph[0:4])[0]
            if p_type == 3:  # PT_INTERP
                has_interp = True
    ok = (e_type == 3) and not has_interp   # ET_DYN without PT_INTERP
    # ASCII-only output: Windows Python defaults to a non-UTF-8 stdout
    # encoding (GBK), so checkmark/cross glyphs would crash print() with
    # UnicodeEncodeError and wrongly fail the verification.
    if not ok:
        sys.exit(f"REJECTED: type=ET_DYN machine={machine} PT_INTERP={'YES' if has_interp else 'no'} (PIE! build with --shared instead, see temp/bak/build-node-ohos.sh)")
    print(f"OK: type=ET_DYN machine={machine} PT_INTERP=no (real shared lib)")
PYEOF
then
  :
else
  echo "    ✗ Downloaded libnode.so is not a usable shared library."
  echo "      Publish a release built with --shared (see temp/bak/build-node-ohos.sh)."
  exit 1
fi

# 3. Install into the entry module libs dir
echo "    Installing to ${OUT_BIN} ..."
cp "${ARCHIVE_PATH}" "${OUT_BIN}.tmp"
mv "${OUT_BIN}.tmp" "${OUT_BIN}"

echo "${RELEASE_TAG}" > "${MARKER_FILE}"
echo "${DOWNLOAD_URL}" > "${CACHE_DIR}/node-source-url.txt"

echo "    ✓ Installed: ${OUT_BIN} ($(du -h "${OUT_BIN}" | cut -f1))"
echo "==> Node.js runtime preparation complete."
