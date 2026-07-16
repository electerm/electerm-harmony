#!/usr/bin/env bash
# build-app.sh — Build and sign the HarmonyOS APP package.
#
# This script builds an UNSIGNED .app using hvigorw assembleApp, then signs
# it directly using hap-sign-tool.jar with plaintext passwords.
# This bypasses the hvigor plugin's password encryption requirement
# (which needs DevEco Studio's encrypted passwords + material/ key dirs).
#
# The .app package is a ZIP containing the HAP(s) + pack.info, and is the
# format required by AppGallery Connect for uploading.
#
# Prerequisites:
#   - HarmonyOS Command Line Tools installed (ohpm, hvigorw in PATH)
#   - Signing materials in signing/ directory
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
#   KEYSTORE_PASSWORD   — keystore password (plaintext)
#   KEY_PASSWORD        — key password (plaintext)
#   KEY_ALIAS           — key alias (default: electerm_key)
#   APP_ARCH            — target architecture for artifact name (default: arm64)

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

# Target architecture (ohos-node is arm64; override with APP_ARCH env var)
APP_ARCH="${APP_ARCH:-arm64}"

# --- Read version from electerm-web -----------------------------------------
# The version is read from the local electerm-web source directory.
# This ensures the app version always tracks the bundled electerm-web.

echo "==> Reading version from electerm-web ..."

ELECTERM_WEB_DIR="${PROJECT_ROOT}/electerm-web"
ELECTERM_WEB_PKG="${ELECTERM_WEB_DIR}/package.json"

if [ ! -f "${ELECTERM_WEB_PKG}" ]; then
  echo "    ✗ electerm-web package.json not found at ${ELECTERM_WEB_PKG}"
  echo "    Run ./scripts/prepare-web.sh first."
  exit 1
fi

APP_VERSION=$(python3 -c "import json; print(json.load(open('${ELECTERM_WEB_PKG}'))['version'])")
echo "    ✓ electerm-web version: ${APP_VERSION}"

# Compute versionCode from semver: major * 10000000 + minor * 100000 + patch
# e.g. 4.15.121 → 41500121
VERSION_CODE=$(python3 -c "
import re
v = '${APP_VERSION}'
m = re.match(r'(\d+)\.(\d+)\.(\d+)', v)
if m:
    major, minor, patch = int(m.group(1)), int(m.group(2)), int(m.group(3))
    print(major * 10000000 + minor * 100000 + patch)
else:
    print(1)
")

if [ "${VERSION_CODE}" -gt 2147483647 ] || [ "${VERSION_CODE}" -lt 1 ]; then
  echo "    ✗ versionCode ${VERSION_CODE} is out of range (1–2147483647)"
  exit 1
fi

echo "    ✓ versionCode: ${VERSION_CODE}"

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

# Locate hap-sign-tool.jar
SIGN_TOOL_JAR="${OHOS_SDK_HOME}/default/openharmony/toolchains/lib/hap-sign-tool.jar"
if [ ! -f "${SIGN_TOOL_JAR}" ]; then
  # Try alternative path
  SIGN_TOOL_JAR=$(find "${OHOS_SDK_HOME}" -name "hap-sign-tool.jar" -type f 2>/dev/null | head -1)
fi
if [ -z "${SIGN_TOOL_JAR:-}" ] || [ ! -f "${SIGN_TOOL_JAR}" ]; then
  echo "    ✗ hap-sign-tool.jar not found in SDK"
  exit 1
fi

echo "    OHOS_SDK_HOME: ${OHOS_SDK_HOME}"
echo "    ohpm: ${OHPM}"
echo "    hvigorw: ${HVIGORW}"
echo "    sign tool: ${SIGN_TOOL_JAR}"

# --- Generate build-profile.json5 (without signing config) ------------------
# We build an UNSIGNED APP and sign it separately with hap-sign-tool.jar.
# This avoids the hvigor plugin's password encryption requirement.

echo "==> Configuring build-profile.json5 ..."

BUILD_PROFILE="${PROJECT_ROOT}/build-profile.json5"

cat > "${BUILD_PROFILE}" <<EOF
{
  "app": {
    "signingConfigs": [],
    "products": [
      {
        "name": "default",
        "compatibleSdkVersion": "5.0.1(13)",
        "compileSdkVersion": "5.0.1(13)",
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

echo "    ✓ build-profile.json5 generated (unsigned build)"

# --- Update app version from electerm-web -----------------------------------
# Sync versionName/versionCode in app.json5 and version in oh-package.json5
# files so the built package carries the electerm-web version.

echo "==> Updating app version to ${APP_VERSION} ..."

APP_JSON5="${PROJECT_ROOT}/AppScope/app.json5"
sed -i.bak "s/\"versionName\": \"[^\"]*\"/\"versionName\": \"${APP_VERSION}\"/" "${APP_JSON5}"
sed -i.bak "s/\"versionCode\": [0-9]*/\"versionCode\": ${VERSION_CODE}/" "${APP_JSON5}"
rm -f "${APP_JSON5}.bak"

ROOT_PKG="${PROJECT_ROOT}/oh-package.json5"
sed -i.bak "s/\"version\": \"[^\"]*\"/\"version\": \"${APP_VERSION}\"/" "${ROOT_PKG}"
rm -f "${ROOT_PKG}.bak"

ENTRY_PKG="${PROJECT_ROOT}/entry/oh-package.json5"
sed -i.bak "s/\"version\": \"[^\"]*\"/\"version\": \"${APP_VERSION}\"/" "${ENTRY_PKG}"
rm -f "${ENTRY_PKG}.bak"

echo "    ✓ app.json5:        versionName=${APP_VERSION}, versionCode=${VERSION_CODE}"
echo "    ✓ oh-package.json5: version=${APP_VERSION}"
echo "    ✓ entry/oh-package.json5: version=${APP_VERSION}"

# --- Generate hvigor-config.json5 using bundled hvigor version ----------------

echo "==> Configuring hvigor-config.json5 ..."

HVIGOR_CONFIG="${PROJECT_ROOT}/hvigor/hvigor-config.json5"

# Read the bundled hvigor version from the command line tools
BUNDLED_HVIGOR_DIR="${COMMANDLINE_TOOLS}/hvigor/hvigor"
BUNDLED_PLUGIN_DIR="${COMMANDLINE_TOOLS}/hvigor/hvigor-ohos-plugin"

if [ -f "${BUNDLED_HVIGOR_DIR}/package.json" ]; then
  BUNDLED_HVIGOR_VERSION=$(python3 -c "import json; print(json.load(open('${BUNDLED_HVIGOR_DIR}/package.json'))['version'])" 2>/dev/null || echo "5.10.3")
else
  BUNDLED_HVIGOR_VERSION="5.10.3"
fi
echo "    Bundled @ohos/hvigor version: ${BUNDLED_HVIGOR_VERSION}"

# Use file: protocol to reference the bundled plugin directly.
# This avoids version mismatch between the plugin and the hvigor engine,
# and avoids relying on the npm registry for the plugin.
if [ -d "${BUNDLED_PLUGIN_DIR}" ]; then
  cat > "${HVIGOR_CONFIG}" <<HVIGORCFG
{
  "modelVersion": "5.0.0",
  "dependencies": {
    "@ohos/hvigor-ohos-plugin": "file:${BUNDLED_PLUGIN_DIR}"
  },
  "execution": {},
  "logging": {
    "level": "info"
  },
  "debugging": {
    "quiet": false
  }
}
HVIGORCFG
  echo "    ✓ hvigor-config.json5 generated (using bundled plugin via file: protocol)"
else
  echo "    ⚠ Bundled plugin directory not found, keeping existing hvigor-config.json5"
fi

# --- Configure npm registry for hvigor (uses pnpm internally) ----------------

echo "==> Configuring npm registry for hvigor ..."

NPMRC_FILE="${HOME}/.npmrc"
cat > "${NPMRC_FILE}" <<'NPMRC'
@ohos:registry=https://repo.harmonyos.com/npm/
registry=https://registry.npmjs.org/
NPMRC
echo "    ✓ Created ${NPMRC_FILE} with scoped HarmonyOS + npmjs registry"

# --- Generate rawfile manifest ----------------------------------------------
# Creates a JSON file listing all files in rawfile/ so the app can extract them
# to the sandbox at runtime (HarmonyOS resourceManager has no recursive listing API).

echo "==> Generating rawfile manifest ..."
bash "${SCRIPT_DIR}/gen-manifest.sh"

# --- Install ohpm dependencies ----------------------------------------------

echo "==> Installing ohpm dependencies ..."
cd "${PROJECT_ROOT}"
"${OHPM}" install

# --- Build the unsigned APP -------------------------------------------------

echo "==> Building unsigned APP (${BUILD_MODE}) ..."

# Build with enableSignTask=false to skip the hvigor signing step.
# We sign separately using hap-sign-tool.jar with plaintext passwords.
# assembleApp produces a .app package (ZIP containing HAP + pack.info).
if [ "${BUILD_MODE}" = "debug" ]; then
  "${HVIGORW}" assembleApp -p product=default \
    -p buildMode=debug -p enableSignTask=false --no-daemon
else
  "${HVIGORW}" assembleApp -p product=default \
    -p buildMode=release -p enableSignTask=false --no-daemon
fi

# --- Locate the unsigned APP ------------------------------------------------

# assembleApp outputs to build/outputs/default/*.app (project root level)
APP_DIR="${PROJECT_ROOT}/build/outputs/default"
UNSIGNED_APP=$(find "${APP_DIR}" -name "*.app" -type f 2>/dev/null | head -1)

if [ -z "${UNSIGNED_APP}" ]; then
  echo "    ✗ No .app file found in ${APP_DIR}"
  echo "    Searching entire build tree ..."
  UNSIGNED_APP=$(find "${PROJECT_ROOT}/build" -name "*.app" -type f 2>/dev/null | head -1)
  if [ -z "${UNSIGNED_APP}" ]; then
    echo "    ✗ No .app file found anywhere in build/"
    exit 1
  fi
fi

echo "    ✓ Unsigned APP: ${UNSIGNED_APP} ($(du -h "${UNSIGNED_APP}" | cut -f1))"

# --- Sign the APP with hap-sign-tool.jar ------------------------------------

echo "==> Signing APP with hap-sign-tool.jar ..."

# Show Java version for debugging (PKCS12 keystore compatibility)
JAVA_VERSION=$(java -version 2>&1 | head -1)
echo "    Java: ${JAVA_VERSION}"

SIGNED_APP="${UNSIGNED_APP%.app}-signed.app"

# Sign the APP package.
# hap-sign-tool.jar can sign both .hap and .app files.
# NOTE: -mode localSign is required (COMMAND_ERROR code 101 if missing).
# NOTE: -compatibleVersion, -signCode, -pwdInputMode are NOT supported by
# this SDK version (COMMAND_PARAM_ERROR code 110). They were added later.
java -jar "${SIGN_TOOL_JAR}" sign-app \
  -mode localSign \
  -keyAlias "${KEY_ALIAS}" \
  -keyPwd "${KEY_PASSWORD}" \
  -appCertFile "${CERT_PATH}" \
  -profileFile "${PROFILE_PATH}" \
  -inFile "${UNSIGNED_APP}" \
  -signAlg SHA256withECDSA \
  -keystoreFile "${KEYSTORE_PATH}" \
  -keystorePwd "${KEYSTORE_PASSWORD}" \
  -outFile "${SIGNED_APP}"

if [ ! -f "${SIGNED_APP}" ]; then
  echo "    ✗ Signing failed — no signed APP produced"
  exit 1
fi

# Replace the unsigned APP with the signed one
mv -f "${SIGNED_APP}" "${UNSIGNED_APP}"
APP_FILE="${UNSIGNED_APP}"

echo "    ✓ Signed APP: ${APP_FILE} ($(du -h "${APP_FILE}" | cut -f1))"

# --- Rename artifact with proper name ---------------------------------------
# Final artifact name: electerm-{arch}-{version}.app

FINAL_APP_NAME="electerm-${APP_ARCH}-${APP_VERSION}.app"
FINAL_APP="$(dirname "${APP_FILE}")/${FINAL_APP_NAME}"

echo "==> Renaming artifact to ${FINAL_APP_NAME} ..."
mv -f "${APP_FILE}" "${FINAL_APP}"
APP_FILE="${FINAL_APP}"

# Export for CI (if GITHUB_ENV is available, e.g. GitHub Actions)
if [ -n "${GITHUB_ENV:-}" ]; then
  echo "APP_VERSION=${APP_VERSION}" >> "${GITHUB_ENV}"
  echo "APP_ARCH=${APP_ARCH}" >> "${GITHUB_ENV}"
  echo "APP_ARTIFACT_NAME=${FINAL_APP_NAME}" >> "${GITHUB_ENV}"
fi

# --- Done -------------------------------------------------------------------

echo ""
echo "==> Build complete!"
echo "    Mode:    ${BUILD_MODE}"
echo "    Version: ${APP_VERSION} (versionCode ${VERSION_CODE})"
echo "    Arch:    ${APP_ARCH}"
echo "    APP:     ${APP_FILE}"
echo "    Size:    $(du -h "${APP_FILE}" | cut -f1)"
echo ""
echo "    Upload to AppGallery Connect, or install with: hdc install \"${APP_FILE}\""
