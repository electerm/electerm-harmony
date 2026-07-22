#!/usr/bin/env bash
# prepare-electron-runtime.sh — Extract the pre-built Electron 鸿蒙 runtime
# from a tarball and install it into the project.
#
# The Electron 鸿蒙 runtime is provided as a pre-built tarball by the
# openharmony-sig/electron project. It contains:
#
#   - web_engine/  — A complete HarmonyOS HAR module (ArkTS source + resfile
#                    resources + libadapter.so type definitions). This module
#                    provides WebAbility, WebAbilityStage, WebWindow, and
#                    JsBindingUtils — the ArkTS API for the Electron runtime.
#   - electron/libs/arm64-v8a/ — Native .so libraries:
#                    libelectron.so (Chromium + Node.js + V8),
#                    libadapter.so (HarmonyOS ↔ Electron bridge),
#                    libffmpeg.so, libc++_shared.so, libvk_swiftshader.so,
#                    vscode-sqlite3.node
#
# After extraction:
#   - web_engine/ is placed at the project root (as a sibling of entry/)
#   - .so files are placed in entry/libs/arm64-v8a/
#
# Usage:
#   ./scripts/prepare-electron-runtime.sh
#
# Environment variables (ONE of these must be set):
#   ELECTRON_RUNTIME_URL  — URL to the tarball (e.g. .tar.gz or .zip)
#                           Used in CI. The tarball must extract to a directory
#                           containing web_engine/ and electron/libs/.
#   ELECTRON_RUNTIME_DIR  — Path to an already-extracted tarball directory
#                           (for local development)
#   ELECTRON_RUNTIME_FILE — Path to a local tarball file
#                           (for local development)
#
# Example tarball:
#   electron40_hap_electron_v40.0.0_20260629.tar.gz
#   → extracts to electron144_ohos_hap/
#     ├── electron/libs/arm64-v8a/*.so
#     └── web_engine/ (complete HAR module)

set -euo pipefail

# --- Config -----------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

LIBS_DIR="${PROJECT_ROOT}/entry/libs/arm64-v8a"
WEB_ENGINE_DIR="${PROJECT_ROOT}/web_engine"
DOWNLOAD_DIR="${PROJECT_ROOT}/.cache"

# --- Functions --------------------------------------------------------------

die() {
  echo "    ERROR: $*" >&2
  exit 1
}

info() {
  echo "    $*"
}

ok() {
  echo "    [OK] $*"
}

# Find the top-level extracted directory (e.g. electron144_ohos_hap/)
find_extracted_root() {
  local dir="$1"
  # Check if web_engine/ is directly in the directory
  if [ -d "${dir}/web_engine" ]; then
    echo "${dir}"
    return 0
  fi
  # Search one level deep
  local found
  found=$(find "${dir}" -maxdepth 2 -name "web_engine" -type d 2>/dev/null | head -1)
  if [ -n "${found}" ]; then
    dirname "${found}"
  else
    echo ""
  fi
}

# Install runtime files from an extracted directory.
install_from_dir() {
  local extracted_root="$1"
  info "Installing runtime from: ${extracted_root}"

  # Verify structure
  if [ ! -d "${extracted_root}/web_engine" ]; then
    die "web_engine/ directory not found in: ${extracted_root}"
  fi

  local so_dir="${extracted_root}/electron/libs/arm64-v8a"
  if [ ! -d "${so_dir}" ]; then
    # Try alternative: some tarballs may have libs at a different path
    so_dir=$(find "${extracted_root}" -path "*/arm64-v8a/libelectron.so" -exec dirname {} \; 2>/dev/null | head -1)
    if [ -z "${so_dir}" ]; then
      die "Could not find arm64-v8a/ directory with libelectron.so"
    fi
  fi

  # --- Copy web_engine/ module to project root ---
  info "Installing web_engine module ..."
  rm -rf "${WEB_ENGINE_DIR}"
  cp -r "${extracted_root}/web_engine" "${WEB_ENGINE_DIR}"
  ok "web_engine/ installed ($(du -sh "${WEB_ENGINE_DIR}" | cut -f1))"

  # --- Copy .so libraries to entry/libs/arm64-v8a/ ---
  info "Installing native libraries ..."
  mkdir -p "${LIBS_DIR}"
  rm -f "${LIBS_DIR}"/*.so "${LIBS_DIR}"/*.node
  cp -f "${so_dir}"/*.so "${LIBS_DIR}/" 2>/dev/null || true
  cp -f "${so_dir}"/*.node "${LIBS_DIR}/" 2>/dev/null || true
  ok "Libraries installed to ${LIBS_DIR}/"
  for f in "${LIBS_DIR}"/*; do
    ok "  $(basename "${f}") ($(du -h "${f}" | cut -f1))"
  done
}

# Download and extract archive, then install.
download_and_install() {
  local url="$1"
  info "Downloading Electron runtime from: ${url}"

  mkdir -p "${DOWNLOAD_DIR}"

  local archive="${DOWNLOAD_DIR}/electron-runtime"
  local extract_dir="${DOWNLOAD_DIR}/electron-runtime-extracted"
  rm -rf "${extract_dir}"
  mkdir -p "${extract_dir}"

  case "${url}" in
    *.tar.gz|*.tgz)
      archive="${archive}.tar.gz"
      curl -L --fail --retry 3 --retry-delay 5 -o "${archive}" "${url}"
      tar -xzf "${archive}" -C "${extract_dir}"
      ;;
    *.zip)
      archive="${archive}.zip"
      curl -L --fail --retry 3 --retry-delay 5 -o "${archive}" "${url}"
      if command -v unzip &>/dev/null; then
        unzip -q -o "${archive}" -d "${extract_dir}"
      else
        die "unzip command not found — please install unzip"
      fi
      ;;
    *)
      die "Unsupported archive format. URL must end in .tar.gz or .zip"
      ;;
  esac

  if [ ! -s "${archive}" ]; then
    die "Download failed — archive is empty or missing"
  fi

  ok "Downloaded and extracted runtime archive"

  local extracted_root
  extracted_root=$(find_extracted_root "${extract_dir}")
  if [ -z "${extracted_root}" ]; then
    die "Could not find web_engine/ in extracted archive"
  fi
  info "Extracted root: ${extracted_root}"

  install_from_dir "${extracted_root}"

  # Clean up
  rm -f "${archive}"
  rm -rf "${extract_dir}"
}

# Extract a local tarball file and install.
extract_file_and_install() {
  local filepath="$1"
  info "Extracting local tarball: ${filepath}"

  if [ ! -f "${filepath}" ]; then
    die "File not found: ${filepath}"
  fi

  local extract_dir="${DOWNLOAD_DIR}/electron-runtime-extracted"
  rm -rf "${extract_dir}"
  mkdir -p "${extract_dir}"

  case "${filepath}" in
    *.tar.gz|*.tgz)
      tar -xzf "${filepath}" -C "${extract_dir}"
      ;;
    *.zip)
      if command -v unzip &>/dev/null; then
        unzip -q -o "${filepath}" -d "${extract_dir}"
      else
        die "unzip command not found — please install unzip"
      fi
      ;;
    *)
      die "Unsupported archive format. File must be .tar.gz or .zip"
      ;;
  esac

  ok "Extracted tarball"

  local extracted_root
  extracted_root=$(find_extracted_root "${extract_dir}")
  if [ -z "${extracted_root}" ]; then
    die "Could not find web_engine/ in extracted archive"
  fi
  info "Extracted root: ${extracted_root}"

  install_from_dir "${extracted_root}"

  # Clean up
  rm -rf "${extract_dir}"
}

# --- Main -------------------------------------------------------------------

echo "==> Preparing Electron runtime"

# Check that at least one source is provided
if [ -z "${ELECTRON_RUNTIME_URL:-}" ] && [ -z "${ELECTRON_RUNTIME_DIR:-}" ] && [ -z "${ELECTRON_RUNTIME_FILE:-}" ]; then
  echo ""
  echo "    ERROR: None of ELECTRON_RUNTIME_URL, ELECTRON_RUNTIME_DIR, or"
  echo "           ELECTRON_RUNTIME_FILE is set."
  echo ""
  echo "    The pre-built Electron 鸿蒙 runtime tarball must be obtained from:"
  echo ""
  echo "    1. openharmony-sig/electron project (Huawei Cloud CodeHub):"
  echo "       https://gitcode.com/openharmony-sig/electron"
  echo "       Download the latest release tarball (e.g."
  echo "       electron40_hap_electron_v40.0.0_20260629.tar.gz)"
  echo ""
  echo "    Then use ONE of:"
  echo "       export ELECTRON_RUNTIME_FILE=/path/to/electron40_hap_*.tar.gz"
  echo "       export ELECTRON_RUNTIME_DIR=/path/to/extracted/electron144_ohos_hap"
  echo "       export ELECTRON_RUNTIME_URL=https://your-host/electron40_hap_*.tar.gz  (for CI)"
  echo ""
  exit 1
fi

if [ -n "${ELECTRON_RUNTIME_FILE:-}" ]; then
  # Mode 1: Use a local tarball file
  extract_file_and_install "${ELECTRON_RUNTIME_FILE}"
elif [ -n "${ELECTRON_RUNTIME_DIR:-}" ]; then
  # Mode 2: Use an already-extracted directory
  if [ ! -d "${ELECTRON_RUNTIME_DIR}" ]; then
    die "ELECTRON_RUNTIME_DIR does not exist: ${ELECTRON_RUNTIME_DIR}"
  fi
  info "Using local directory: ${ELECTRON_RUNTIME_DIR}"
  install_from_dir "${ELECTRON_RUNTIME_DIR}"
elif [ -n "${ELECTRON_RUNTIME_URL:-}" ]; then
  # Mode 3: Download from a URL
  download_and_install "${ELECTRON_RUNTIME_URL}"
fi

# --- Verify ---
echo ""
echo "==> Verifying runtime files"

required_libs=("libelectron.so" "libadapter.so" "libffmpeg.so")
for lib in "${required_libs[@]}"; do
  if [ ! -f "${LIBS_DIR}/${lib}" ]; then
    die "Missing required library: ${LIBS_DIR}/${lib}"
  fi
  ok "Found ${lib}"
done

if [ ! -f "${WEB_ENGINE_DIR}/Index.ets" ]; then
  die "Missing web_engine/Index.ets"
fi
ok "Found web_engine/Index.ets"

if [ ! -f "${WEB_ENGINE_DIR}/oh-package.json5" ]; then
  die "Missing web_engine/oh-package.json5"
fi
ok "Found web_engine/oh-package.json5"

# Verify resfile resources exist
RESFILE_DIR="${WEB_ENGINE_DIR}/src/main/resources/resfile"
for res in icudtl.dat resources.pak chrome_100_percent.pak v8_context_snapshot.bin; do
  if [ ! -f "${RESFILE_DIR}/${res}" ]; then
    info "Note: ${res} not found (may be optional)"
  else
    ok "Found ${res}"
  fi
done

if [ -d "${RESFILE_DIR}/locales" ]; then
  ok "Found locales/ ($(ls "${RESFILE_DIR}/locales/" | wc -l) files)"
fi

echo ""
echo "==> Electron runtime preparation complete!"
echo "    web_engine module: ${WEB_ENGINE_DIR}/"
echo "    Native libraries:  ${LIBS_DIR}/"
echo ""
echo "    Next steps:"
echo "    1. ./scripts/prepare-web.sh   (build web app → web_engine resfile)"
echo "    2. ./scripts/build-app.sh     (build & sign the HAP)"
