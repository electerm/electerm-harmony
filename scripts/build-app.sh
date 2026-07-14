#!/usr/bin/env bash
# build-app.sh — Build and sign the HarmonyOS HAP package.
#
# Prerequisites:
#   - HarmonyOS Command Line Tools installed (ohpm, hvigorw in PATH)
#   - Signing materials in signing/ directory OR provided via env vars
#   - prepare-node.sh and prepare-web.sh already run
#
# Usage:
#   ./scripts/build-app.sh [--debug|--release]
#
# Environment variables (all optional, see defaults below):
#   OHOS_SDK_HOME       — path to HarmonyOS SDK
#   COMMANDLINE_TOOLS   — path to Command Line Tools
#   SIGNING_DIR         — directory with .p12, .cer, .p7b (default: signing/)
#   KEYSTORE_FILE       — keystore filename (default: electerm.p12)
#   CERT_FILE           — certificate filename (default: electerm_publish.cer)
#   PROFILE_FILE        — profile filename (default: electermRelease.p7b)
#   KEYSTORE_PASSWORD   — keystore password
#   KEY_PASSWORD        — key password
#   KEY_ALIAS           — key alias (default: electerm_key)

set -euo pipefail

# --- Parse args -------------------------------------------------------------

BUILD_MODE="release"
if [[ "${1:-}" == "--debug" ]]; then
  BUILD_MODE="debug"
elif [[ "${1:-}" == "--release" ]]; then
  BUILD_MODE="release"
fi

# --- Config -----------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SIGNING_DIR="${SIGNING_DIR:-${PROJECT_ROOT}/signing}"
KEYSTORE_FILE="${KEYSTORE_FILE:-electerm.p12}"
CERT_FILE="${CERT_FILE:-electerm_publish.cer}"
PROFILE_FILE="${PROFILE_FILE:-electermRelease.p7b}"
KEY_ALIAS="${KEY_ALIAS:-electerm_key}"

# --- Check signing materials ------------------------------------------------

echo "==> Checking signing materials ..."

KEYSTORE_PATH="${SIGNING_DIR}/${KEYSTORE_FILE}"
CERT_PATH="${SIGNING_DIR}/${CERT_FILE}"
PROFILE_PATH="${SIGNING_DIR}/${PROFILE_FILE}"

for f in "${KEYSTORE_PATH}" "${CERT_PATH}" "${PROFILE_PATH}"; do
  if [ ! -f "${f}" ]; then
    echo "    ✗ Missing: ${f}"
    echo "    See build/ENV_SETUP.md for instructions."
    exit 1
  fi
  echo "    ✓ Found: $(basename "${f}")"
done

if [ -z "${KEYSTORE_PASSWORD:-}" ] || [ -z "${KEY_PASSWORD:-}" ]; then
  echo "    ✗ KEYSTORE_PASSWORD and KEY_PASSWORD environment variables are required."
  exit 1
fi

# --- Locate build tools -----------------------------------------------------

echo "==> Locating HarmonyOS build tools ..."

# Try COMMANDLINE_TOOLS env var, then common paths
if [ -z "${COMMANDLINE_TOOLS:-}" ]; then
  for candidate in \
    "/opt/commandline-tools-linux-x64" \
    "${HOME}/commandline-tools-linux-x64" \
    "${PROJECT_ROOT}/.cache/commandline-tools"; do
    if [ -d "${candidate}" ]; then
      COMMANDLINE_TOOLS="${candidate}"
      break
    fi
  done
fi

if [ -z "${COMMANDLINE_TOOLS:-}" ]; then
  echo "    ✗ HarmonyOS Command Line Tools not found."
  echo "    Set COMMANDLINE_TOOLS env var or install to /opt/commandline-tools-linux-x64"
  exit 1
fi

echo "    Command Line Tools: ${COMMANDLINE_TOOLS}"

OHPM="${COMMANDLINE_TOOLS}/bin/ohpm"
HVIGORW="${COMMANDLINE_TOOLS}/bin/hvigorw"

if [ -z "${OHOS_SDK_HOME:-}" ]; then
  OHOS_SDK_HOME="${COMMANDLINE_TOOLS}/sdk"
fi

export OHOS_SDK_HOME
export PATH="${PATH}:${COMMANDLINE_TOOLS}/bin:${COMMANDLINE_TOOLS}/hvigor/bin"

echo "    OHOS_SDK_HOME: ${OHOS_SDK_HOME}"
echo "    ohpm: ${OHPM}"
echo "    hvigorw: ${HVIGORW}"

# --- Generate build-profile.json5 with signing config -----------------------

echo "==> Configuring signing in build-profile.json5 ..."

BUILD_PROFILE="${PROJECT_ROOT}/build-profile.json5"

cat > "${BUILD_PROFILE}" <<EOF
{
  "app": {
    "signingConfigs": [
      {
        "name": "default",
        "type": "HarmonyOS",
        "material": {
          "certpath": "${CERT_PATH}",
          "storePassword": "${KEYSTORE_PASSWORD}",
          "keyAlias": "${KEY_ALIAS}",
          "keyPassword": "${KEY_PASSWORD}",
          "profile": "${PROFILE_PATH}",
          "signAlg": "SHA256withECDSA",
          "storeFile": "${KEYSTORE_PATH}"
        }
      }
    ],
    "products": [
      {
        "name": "default",
        "signingConfig": "default",
        "compatibleSdkVersion": "5.0.0(12)",
        "runtimeOS": "HarmonyOS"
      }
    ]
  },
  "modules": [
    {
      "name": "entry",
      "srcPath": "./entry",
      "targets": [
        {
          "name": "default",
          "applyToProducts": ["default"]
        }
      ]
    }
  ]
}
EOF

echo "    ✓ build-profile.json5 generated"

# --- Install ohpm dependencies ----------------------------------------------

echo "==> Installing ohpm dependencies ..."
cd "${PROJECT_ROOT}"
"${OHPM}" install

# --- Build the HAP ----------------------------------------------------------

echo "==> Building HAP (${BUILD_MODE}) ..."

if [ "${BUILD_MODE}" = "debug" ]; then
  "${HVIGORW}" assembleHap --mode module -p product=default \
    -p buildMode=debug --no-daemon
else
  "${HVIGORW}" assembleHap --mode module -p product=default \
    -p buildMode=release --no-daemon
fi

# --- Locate output ----------------------------------------------------------

HAP_DIR="${PROJECT_ROOT}/entry/build/default/outputs/default"
HAP_FILE=$(find "${HAP_DIR}" -name "*.hap" -type f | head -1)

if [ -z "${HAP_FILE}" ]; then
  echo "    ✗ No .hap file found in ${HAP_DIR}"
  exit 1
fi

echo ""
echo "==> Build complete!"
echo "    Mode: ${BUILD_MODE}"
echo "    HAP:  ${HAP_FILE}"
echo "    Size: $(du -h "${HAP_FILE}" | cut -f1)"
echo ""
echo "    Install with: hdc install \"${HAP_FILE}\""
