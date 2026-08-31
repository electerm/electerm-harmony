#!/usr/bin/env bash
# build-web-app.sh — Build and sign the HarmonyOS APP package (web variant:
# ArkWeb + on-device Node.js, no electron runtime).
#
# Adapted from build-app.sh with the electron runtime steps removed:
#   - only the `entry` module is built (no web_engine HAR)
#   - prerequisites are entry/libs/arm64-v8a/libnode.so (from prepare-node.sh)
#     and entry/src/main/resources/resfile/electerm (from prepare-web.sh)
#
# Builds an UNSIGNED .app with hvigorw assembleApp, then signs it directly
# with hap-sign-tool.jar using plaintext passwords.
#
# Prerequisites:
#   - HarmonyOS Command Line Tools installed (ohpm, hvigorw in PATH)
#   - Signing materials in signing/ directory
#   - prepare-node.sh and prepare-web.sh already run
#
# Usage:
#   ./scripts/build-web-app.sh [--debug|--release]
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

KEYSTORE_PATH="${SIGNING_DIR}/${KEYSTORE_FILE}"
CERT_PATH="${SIGNING_DIR}/${CERT_FILE}"
PROFILE_PATH="${SIGNING_DIR}/${PROFILE_FILE}"

OHPM="${OHPM:-ohpm}"
HVIGORW="${HVIGORW:-hvigorw}"

# --- Read version from package.json -----------------------------------------

echo "==> Reading version from package.json ..."

APP_VERSION=$(python3 -c "import json; print(json.load(open('${PROJECT_ROOT}/package.json'))['version'])")
echo "    ✓ version: ${APP_VERSION}"

# Compute versionCode from semver: major * 10000000 + minor * 100000 + patch
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

# --- Verify build prerequisites ---------------------------------------------

echo "==> Verifying build prerequisites ..."

LIBS_DIR="${PROJECT_ROOT}/entry/libs/arm64-v8a"
RESFILE_APP_DIR="${PROJECT_ROOT}/entry/src/main/resources/resfile/electerm"

if [ ! -f "${LIBS_DIR}/libnode.so" ]; then
  echo "    ✗ Missing: ${LIBS_DIR}/libnode.so"
  echo "    Run ./scripts/prepare-node.sh first."
  exit 1
fi
echo "    ✓ Found: libnode.so ($(du -h "${LIBS_DIR}/libnode.so" | cut -f1))"

for f in index.js app.bundle.mjs views/index.pug; do
  if [ ! -f "${RESFILE_APP_DIR}/${f}" ]; then
    echo "    ✗ Missing: ${RESFILE_APP_DIR}/${f}"
    echo "    Run ./scripts/prepare-web.sh first."
    exit 1
  fi
  echo "    ✓ Found: ${f}"
done

for f in "${KEYSTORE_PATH}" "${CERT_PATH}" "${PROFILE_PATH}"; do
  if [ ! -s "${f}" ]; then
    echo "    ✗ Missing signing material: ${f}"
    exit 1
  fi
done
echo "    ✓ Signing materials present"

# Informational (WARNING, non-fatal): note the cert identity.
# The same electerm_publish.cer is used by the main (electron) branch for
# `hap-sign-tool sign-app` and that branch builds fine, so for *HAP package
# signing* this cert is acceptable. The one place a root/CA cert is genuinely
# wrong — per-.so binary-sign-tool code-signing — is no longer done by this
# script (see the libnode.so code-signing section). Left as INFO only.
if command -v openssl >/dev/null 2>&1; then
  CERT_SUBJECT=$(openssl x509 -in "${CERT_PATH}" -noout -subject 2>/dev/null || true)
  echo "    • App cert (appCertFile for hap-sign-tool): ${CERT_SUBJECT}"
  echo "      (Same cert the main/electron branch uses for HAP signing; fine for sign-app.)"
fi

# --- Fix permissions for SDK compatibility ----------------------------------

echo "==> Cleaning unsupported permissions ..."

UNSUPPORTED_PERMS="SET_ABILITY_INSTANCE_INFO GET_FILE_ICON PRIVACY_WINDOW LOCK_WINDOW_CURSOR ACCESS_BIOMETRIC SYSTEM_FLOAT_WINDOW FILE_ACCESS_PERSIST PREPARE_APP_TERMINATE CUSTOM_SCREEN_CAPTURE"

ENTRY_MODULE_JSON="${PROJECT_ROOT}/entry/src/main/module.json5"

remove_module_perms() {
  local file="${1}"
  local label="${2}"
  shift 2

  if [ ! -f "${file}" ]; then
    echo "    (${label} module.json5 not found, skipping)"
    return
  fi

  python3 - "${file}" "${label}" "$@" <<'PYEOF'
import re, sys

file_path = sys.argv[1]
label = sys.argv[2]
perms = sys.argv[3:]

with open(file_path, 'r') as f:
    content = f.read()

for perm in perms:
    if f'"ohos.permission.{perm}"' not in content:
        continue
    pattern = (
        r'\{[^{}]*"ohos\.permission\.' + re.escape(perm) + r'"'
        r'[^{}]*(?:\{[^{}]*\}[^{}]*)*\}[\s,]*'
    )
    new_content = re.sub(pattern, '', content)
    if new_content != content:
        print(f'    {label}: removed ohos.permission.{perm}')
        content = new_content
    else:
        print(f'    {label}: WARNING — could not remove ohos.permission.{perm}')

with open(file_path, 'w') as f:
    f.write(content)
PYEOF
}

remove_module_perms "${ENTRY_MODULE_JSON}" "entry" ${UNSUPPORTED_PERMS}

# --- Generate build-profile.json5 (entry module only, unsigned) --------------

echo "==> Configuring build-profile.json5 ..."

BUILD_PROFILE="${PROJECT_ROOT}/build-profile.json5"

SDK_PKG_JSON="${OHOS_SDK_HOME}/default/sdk-pkg.json"
if [ -f "${SDK_PKG_JSON}" ]; then
  # Extract both fields with python (portable — BSD sed lacks \+ quantifiers)
  read -r SDK_API_VERSION SDK_VERSION SDK_DISPLAY_NAME <<SDKINFO || true
$(python3 -c "
import json, re
d = json.load(open('${SDK_PKG_JSON}'))['data']
m = re.search(r'[0-9]+\.[0-9]+\.[0-9]+', d.get('platformVersion') or d.get('displayName') or '')
print(d.get('apiVersion', ''), m.group(0) if m else '', d.get('displayName', ''))
" 2>/dev/null || echo "   ")
SDKINFO
  if [ -n "${SDK_API_VERSION}" ] && [ -n "${SDK_VERSION}" ]; then
    COMPILE_SDK_VERSION="${SDK_VERSION}(${SDK_API_VERSION})"
    echo "    Detected SDK: ${SDK_DISPLAY_NAME} (API ${SDK_API_VERSION})"
  else
    COMPILE_SDK_VERSION="5.0.1(13)"
    echo "    Warning: Could not parse SDK version, using default 5.0.1(13)"
  fi
else
  COMPILE_SDK_VERSION="5.0.1(13)"
  echo "    Warning: sdk-pkg.json not found, using default 5.0.1(13)"
fi

cat > "${PROJECT_ROOT}/local.properties" <<LOCPROP
sdk.dir=${OHOS_SDK_HOME}/default/openharmony
ohos.sdk.dir=${OHOS_SDK_HOME}
LOCPROP
echo "    Created local.properties"

cat > "${BUILD_PROFILE}" <<EOF
{
  "app": {
    "signingConfigs": [],
    "products": [
      {
        "name": "default",
        "compatibleSdkVersion": "${COMPILE_SDK_VERSION}",
        "compileSdkVersion": "${COMPILE_SDK_VERSION}",
        "runtimeOS": "HarmonyOS",
        "buildOption": {
          "nativeLib": {
            "collectAllLibs": true
          }
        }
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

echo "    build-profile.json5 generated (unsigned build, SDK ${COMPILE_SDK_VERSION})"

# --- Update app version from package.json -----------------------------------

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

# --- Generate hvigor-config.json5 -------------------------------------------

echo "==> Configuring hvigor-config.json5 ..."

HVIGOR_CONFIG="${PROJECT_ROOT}/hvigor/hvigor-config.json5"

BUNDLED_HVIGOR_DIR="${COMMANDLINE_TOOLS}/hvigor/hvigor"
BUNDLED_PLUGIN_DIR="${COMMANDLINE_TOOLS}/hvigor/hvigor-ohos-plugin"

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

# --- Configure npm registry for hvigor --------------------------------------

NPMRC_FILE="${HOME}/.npmrc"
cat > "${NPMRC_FILE}" <<'NPMRC'
@ohos:registry=https://repo.harmonyos.com/npm/
registry=https://registry.npmjs.org/
NPMRC
echo "    ✓ Created ${NPMRC_FILE}"

# --- Install ohpm dependencies ----------------------------------------------

echo "==> Installing ohpm dependencies ..."
cd "${PROJECT_ROOT}"
"${OHPM}" install

# --- Code-sign libnode.so? NO, by default. ----------------------------------
# IMPORTANT (root-cause of the CI arm64 SIGTRAP crash):
#   The bundled libnode.so is loaded *in-process* by the app via dlopen().
#   A shared library that is dlopen()'d needs a TLS layout compatible with
#   the host app (dynamic/global-dynamic TLS). Running binary-sign-tool over
#   the .so rewrites the ELF to embed a code-signature section and, on arm64,
#   corrupts the TLS template — so when node::Start runs, V8's per-thread
#   TLS reads garbage and the release CHECK `AllowHeapAllocationInRelease`
#   fires at Isolate::Initialize (brk -> SIGTRAP, signal 5). The local
#   (unsigned, x64 emulator) build never code-signs libnode.so and works;
#   the CI build did, and crashed identically to the bug described in
#   prepare-node.sh. So we do NOT code-sign the bundled .so here.
#
#   For a properly *app-signed* HAP (hap-sign-tool below), the package
#   signature grants its bundled native libs execution permission — XPM does
#   not require a separate per-.so binary-sign-tool signature. The reference
#   5.3.15 signed HAP that proved the emulator path also ships an unsigned
#   (at the .so level) libnode.so.
#
#   Opt back in only if a specific device/enrollment truly requires it, and
#   only with a VALID app code-signing cert (NOT a root CA — see the guard
#   below). When enabled, restore the pristine copy afterwards with:
#     git checkout -- entry/libs/arm64-v8a/libnode.so
NODE_SIGNED=0
if [ "${CODE_SIGN_NODE:-0}" = "1" ]; then
  echo "==> Code-signing libnode.so (CODE_SIGN_NODE=1) ..."

  BINSIGN_JAR="${BINSIGN_JAR:-${PROJECT_ROOT}/build/tools/binary-sign-tool.jar}"
  BINSIGN_SHA256="d984474a09f6a1255ccde31f36e8a580be77aabd35b0ca2b3d94d1962ae3778d"
  if [ ! -f "${BINSIGN_JAR}" ]; then
    mkdir -p "$(dirname "${BINSIGN_JAR}")"
    echo "    Downloading binary-sign-tool.jar (developtools_hapsigner dist) ..."
    curl -fsSL --retry 5 --retry-delay 3 -o "${BINSIGN_JAR}" \
      "https://raw.githubusercontent.com/openharmony/developtools_hapsigner/master/dist/binary-sign-tool.jar"
  fi
  BINSIGN_ACTUAL=$(shasum -a 256 "${BINSIGN_JAR}" | cut -d' ' -f1)
  if [ "${BINSIGN_ACTUAL}" != "${BINSIGN_SHA256}" ]; then
    echo "    ✗ binary-sign-tool.jar checksum mismatch: ${BINSIGN_ACTUAL}"
    exit 1
  fi
  echo "    ✓ binary-sign-tool.jar ready"

  NODE_LIB="${PROJECT_ROOT}/entry/libs/arm64-v8a/libnode.so"
  NODE_LIB_SIGNED="$(mktemp).signed"

  if [ -n "${KEYSTORE_PASSWORD:-}" ] && [ -n "${KEY_PASSWORD:-}" ]; then
    echo "    Signing with the APP certificate ..."
    if java -jar "${BINSIGN_JAR}" sign \
        -keyAlias "${KEY_ALIAS}" \
        -keyPwd "${KEY_PASSWORD}" \
        -appCertFile "${CERT_PATH}" \
        -inFile "${NODE_LIB}" \
        -signAlg SHA256withECDSA \
        -keystoreFile "${KEYSTORE_PATH}" \
        -keystorePwd "${KEYSTORE_PASSWORD}" \
        -outFile "${NODE_LIB_SIGNED}" >/dev/null 2>&1; then
      mv -f "${NODE_LIB_SIGNED}" "${NODE_LIB}"
      NODE_SIGNED=1
      echo "    ✓ libnode.so cert-signed (APP identity)"
    else
      echo "    ⚠ cert-sign failed — falling back to self-sign"
      rm -f "${NODE_LIB_SIGNED}"
    fi
  fi

  if [ "${NODE_SIGNED}" = "0" ]; then
    if java -jar "${BINSIGN_JAR}" sign \
        -inFile "${NODE_LIB}" -outFile "${NODE_LIB_SIGNED}" \
        -selfSign 1 >/dev/null 2>&1; then
      mv -f "${NODE_LIB_SIGNED}" "${NODE_LIB}"
      NODE_SIGNED=1
      echo "    ✓ libnode.so self-signed"
    else
      echo "    ⚠ self-sign failed — shipping unsigned (device may refuse to exec)"
    fi
    rm -f "${NODE_LIB_SIGNED}"
  fi
else
  echo "==> Skipping libnode.so code-signing (bundled .so is covered by the app signature; code-signing corrupts the arm64 TLS template and crashes node::Start)."
fi

# --- Build the unsigned APP -------------------------------------------------

echo "==> Building unsigned APP (${BUILD_MODE}) ..."

if [ "${BUILD_MODE}" = "debug" ]; then
  "${HVIGORW}" assembleApp -p product=default \
    -p buildMode=debug -p enableSignTask=false --no-daemon
else
  "${HVIGORW}" assembleApp -p product=default \
    -p buildMode=release -p enableSignTask=false --no-daemon
fi

# --- Locate the unsigned APP ------------------------------------------------

APP_OUTPUT_DIR="${PROJECT_ROOT}/build/outputs/default"
UNSIGNED_APP=$(find "${APP_OUTPUT_DIR}" -name "*.app" -type f 2>/dev/null | head -1)

if [ -z "${UNSIGNED_APP}" ]; then
  echo "    ✗ No .app file found in ${APP_OUTPUT_DIR}"
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

SIGN_TOOL_JAR="${OHOS_SDK_HOME}/default/openharmony/toolchains/lib/hap-sign-tool.jar"
if [ ! -f "${SIGN_TOOL_JAR}" ]; then
  SIGN_TOOL_JAR=$(find "${OHOS_SDK_HOME}" -name "hap-sign-tool.jar" -type f 2>/dev/null | head -1)
fi
if [ ! -f "${SIGN_TOOL_JAR}" ]; then
  echo "    ✗ hap-sign-tool.jar not found in SDK"
  exit 1
fi

# Canonical web-build artifact name: electerm-harmony-<arch>-<ver>.app
# The web build only targets the on-device architecture (arm64-v8a), and
# <ver> is the package.json version, so the shipped file is e.g.
#   electerm-harmony-arm64-5.3.16.app
APP_ARCH="arm64"
CANONICAL_APP="${APP_OUTPUT_DIR}/electerm-harmony-${APP_ARCH}-${APP_VERSION}.app"

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
  -outFile "${CANONICAL_APP}"

if [ ! -f "${CANONICAL_APP}" ]; then
  echo "    ✗ Signing failed — no signed APP produced"
  exit 1
fi

# Keep only the canonical-named APP so artifact pickup (find … -name '*.app')
# can never grab a stray/unsigned one.
APP_FILE="${CANONICAL_APP}"
rm -f "${UNSIGNED_APP}"

echo "    ✓ Signed APP: ${APP_FILE} ($(du -h "${APP_FILE}" | cut -f1))"

# --- Verify APP contents ------------------------------------------------------

echo "==> Verifying APP contents ..."

VERIFY_TMPDIR=$(mktemp -d)
trap 'rm -rf "${VERIFY_TMPDIR}"' EXIT

unzip -q "${APP_FILE}" -d "${VERIFY_TMPDIR}"
HAP_IN_APP=$(find "${VERIFY_TMPDIR}" -name "*.hap" -type f | head -1)
if [ -z "${HAP_IN_APP}" ]; then
  echo "    ✗ No .hap inside the .app"
  exit 1
fi

HAP_DIR="${VERIFY_TMPDIR}/hap"
unzip -q "${HAP_IN_APP}" -d "${HAP_DIR}"

ERRORS=""
check_file() {
  if [ ! -f "$1" ]; then
    ERRORS="${ERRORS}\n  ✗ MISSING: $2"
  else
    echo "  ✓ $2 ($(du -h "$1" | cut -f1))"
  fi
}

check_file "${HAP_DIR}/libs/arm64-v8a/libnode.so" "libs/arm64-v8a/libnode.so"

# The code signature must survive packaging (hvigor strip could drop the
# non-alloc .codesign section — entry/build-profile.json5 disables strip).
if [ "${NODE_SIGNED}" = "1" ]; then
  if java -jar "${BINSIGN_JAR}" display-sign \
      -inFile "${HAP_DIR}/libs/arm64-v8a/libnode.so" 2>/dev/null \
      | grep -q "code signature is not found"; then
    ERRORS="${ERRORS}\n  ✗ libnode.so code signature lost during packaging"
  else
    echo "  ✓ libnode.so code signature present in packed HAP"
  fi
fi
check_file "${HAP_DIR}/libs/arm64-v8a/libnode_launcher.so" "libs/arm64-v8a/libnode_launcher.so"
check_file "${HAP_DIR}/libs/arm64-v8a/libnode_ctl.so" "libs/arm64-v8a/libnode_ctl.so"
check_file "${HAP_DIR}/resources/resfile/electerm/index.js" "resfile/electerm/index.js"
check_file "${HAP_DIR}/resources/resfile/electerm/app.bundle.mjs" "resfile/electerm/app.bundle.mjs"
check_file "${HAP_DIR}/resources/resfile/electerm/views/index.pug" "resfile/electerm/views/index.pug"

JS_COUNT=$(find "${HAP_DIR}/resources/resfile/electerm/dist/assets/js" -name "*.js" 2>/dev/null | wc -l | tr -d ' ')
echo "  ✓ resfile/electerm/dist/assets/js: ${JS_COUNT} files"
if [ "${JS_COUNT}" = "0" ]; then
  ERRORS="${ERRORS}\n  ✗ No frontend JS in resfile"
fi

if [ -n "${ERRORS}" ]; then
  echo -e "::error::APP content verification failed:${ERRORS}"
  exit 1
fi
echo "✓ All critical files verified in APP"

echo "==> Build complete: ${APP_FILE}"
