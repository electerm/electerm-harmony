#!/usr/bin/env bash
# build-app.sh — Build and sign the HarmonyOS APP package.
#
# This script builds an UNSIGNED .app using hvigorw assembleApp, then signs
# it directly using hap-sign-tool.jar with plaintext passwords.
#
# The .app package is a ZIP containing the HAP(s) + pack.info, and is the
# format required by AppGallery Connect for uploading.
#
# Prerequisites:
#   - HarmonyOS Command Line Tools installed (ohpm, hvigorw in PATH)
#   - Signing materials in signing/ directory
#   - prepare-electron-runtime.sh and prepare-web.sh already run
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

APP_ARCH="${APP_ARCH:-arm64}"

# --- Read version from package.json -----------------------------------------

echo "==> Reading version from package.json ..."

ELECTERM_WEB_PKG="${PROJECT_ROOT}/package.json"

if [ ! -f "${ELECTERM_WEB_PKG}" ]; then
  echo "    ✗ package.json not found at ${ELECTERM_WEB_PKG}"
  echo "    Run ./scripts/prepare-web.sh first."
  exit 1
fi

APP_VERSION=$(python3 -c "import json; print(json.load(open('${ELECTERM_WEB_PKG}'))['version'])")
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
WEB_ENGINE_DIR="${PROJECT_ROOT}/web_engine"
RESFILE_DIR="${WEB_ENGINE_DIR}/src/main/resources/resfile"
APP_DIR="${RESFILE_DIR}/resources/app"

# Check .so libraries
for lib in libelectron.so libadapter.so libffmpeg.so; do
  if [ ! -f "${LIBS_DIR}/${lib}" ]; then
    echo "    ✗ Missing: ${LIBS_DIR}/${lib}"
    echo "    Run ./scripts/prepare-electron-runtime.sh first."
    exit 1
  fi
  echo "    ✓ Found: ${lib}"
done

# Check app code (electerm uses app.js as Electron main process entry, not main.js)
if [ ! -f "${APP_DIR}/app.js" ]; then
  echo "    ✗ Missing: ${APP_DIR}/app.js"
  echo "    Run ./scripts/prepare-electron-runtime.sh then ./scripts/prepare-web.sh first."
  exit 1
fi
echo "    ✓ Found: app.js"

# Check web_engine module
if [ ! -f "${WEB_ENGINE_DIR}/Index.ets" ]; then
  echo "    ✗ Missing: ${WEB_ENGINE_DIR}/Index.ets"
  echo "    Run ./scripts/prepare-electron-runtime.sh first."
  exit 1
fi
echo "    ✓ Found: web_engine/Index.ets"

# --- Fix permissions for SDK compatibility ------------------------------------

echo "==> Fixing permissions for SDK compatibility ..."

# Permissions unsupported by the target SDK — must be removed from both
# entry and web_engine module.json5 at build time.
# NOTE: Restricted ACL permissions (READ_WRITE_DOWNLOAD_DIRECTORY,
# READ_WRITE_DOCUMENTS_DIRECTORY, READ_WRITE_DESKTOP_DIRECTORY, READ_PASTEBOARD)
# are NOT removed here — they must be granted in the Profile (.p7b) file
# via AppGallery Connect. See docs/ENV_SETUP.md §2.6 for details.
UNSUPPORTED_PERMS="SET_ABILITY_INSTANCE_INFO GET_FILE_ICON PRIVACY_WINDOW LOCK_WINDOW_CURSOR ACCESS_BIOMETRIC SYSTEM_FLOAT_WINDOW FILE_ACCESS_PERSIST PREPARE_APP_TERMINATE CUSTOM_SCREEN_CAPTURE"

# Fix entry module.json5
ENTRY_MODULE_JSON="${PROJECT_ROOT}/entry/src/main/module.json5"
if [ -f "${ENTRY_MODULE_JSON}" ]; then
  for perm in ${UNSUPPORTED_PERMS}; do
    if grep -q "ohos.permission.${perm}" "${ENTRY_MODULE_JSON}" 2>/dev/null; then
      echo "    entry: removing unsupported permission ohos.permission.${perm}"
      perl -i -0pe "s/\\{[^{}]*ohos\\.permission\\.${perm}[^{}]*\\}[\\s,]*//g" "${ENTRY_MODULE_JSON}"
    fi
  done
  echo "    entry permissions cleaned"
else
  echo "    (entry module.json5 not found, skipping)"
fi

# Fix web_engine module.json5
WEB_ENGINE_MODULE_JSON="${WEB_ENGINE_DIR}/src/main/module.json5"
if [ -f "${WEB_ENGINE_MODULE_JSON}" ]; then
  for perm in ${UNSUPPORTED_PERMS}; do
    if grep -q "ohos.permission.${perm}" "${WEB_ENGINE_MODULE_JSON}" 2>/dev/null; then
      echo "    web_engine: removing unsupported permission ohos.permission.${perm}"
      perl -i -0pe "s/\\{[^{}]*ohos\\.permission\\.${perm}[^{}]*\\}[\\s,]*//g" "${WEB_ENGINE_MODULE_JSON}"
    fi
  done
  echo "    web_engine permissions cleaned"
else
  echo "    (web_engine module.json5 not found, skipping)"
fi

# --- Patch NativeMessagingAdapter.ets for API compatibility ------------------

echo "==> Patching web_engine NativeMessagingAdapter for API compatibility ..."

NATIVE_MSG_ADAPTER="${WEB_ENGINE_DIR}/src/main/ets/adapter/NativeMessagingAdapter.ets"
if [ -f "${NATIVE_MSG_ADAPTER}" ]; then
  # The Electron runtime imports APIs (dataShare from @kit.ArkData,
  # webNativeMessagingExtensionManager from @kit.ArkWeb) that don't exist
  # in the target SDK. Replacing the entire file with a minimal stub is
  # the safest approach — line-by-line patching breaks code structure.
  echo "    Replacing NativeMessagingAdapter.ets with minimal stub"
  cat > "${NATIVE_MSG_ADAPTER}" <<'NMASTUB'
// NativeMessagingAdapter.ets — Stubbed for API compatibility
// Original file uses dataShare (@kit.ArkData) and webNativeMessagingExtensionManager
// (@kit.ArkWeb) which are not available in the target SDK.
export class NativeMessagingAdapter {
  connectNative(name: Object, commands: Object, callback: Object): void {
  }
  disconnectNative(connectionId: number): void {
  }
  getManifestConfig(name: string, callback: Object): void {
  }
}
NMASTUB
  echo "    NativeMessagingAdapter replaced with stub"
else
  echo "    (NativeMessagingAdapter.ets not found, skipping)"
fi

# --- Patch AppWindowAdapter.ets for API compatibility ------------------------

echo "==> Patching web_engine AppWindowAdapter for API compatibility ..."

APP_WINDOW_ADAPTER="${WEB_ENGINE_DIR}/src/main/ets/adapter/AppWindowAdapter.ets"
if [ -f "${APP_WINDOW_ADAPTER}" ]; then
  # shiftAppWindowTouchEvent may not exist on window in the target SDK.
  # window is a namespace in ArkTS, so casting doesn't work.
  # Replace the entire call expression with void(0) to avoid type errors.
  if grep -q 'shiftAppWindowTouchEvent' "${APP_WINDOW_ADAPTER}" 2>/dev/null; then
    echo "    Patching: neutralizing 'shiftAppWindowTouchEvent' calls"
    # Replace window.shiftAppWindowTouchEvent(...) with Promise.resolve()
    # so that any .then() chained calls still work
    perl -i -0777 -pe 's/window\.shiftAppWindowTouchEvent\s*\([^)]*\)/Promise.resolve()/g' "${APP_WINDOW_ADAPTER}"
    echo "    AppWindowAdapter patched"
  else
    echo "    AppWindowAdapter: no patches needed"
  fi
else
  echo "    (AppWindowAdapter.ets not found, skipping)"
fi

# --- Patch WebAbilityStage.ets for startup timing fix ------------------------

echo "==> Patching web_engine WebAbilityStage for SetContextPaths timing ..."

WEB_ABILITY_STAGE="${WEB_ENGINE_DIR}/src/main/ets/application/WebAbilityStage.ets"
if [ -f "${WEB_ABILITY_STAGE}" ]; then
  python3 -c "
import sys

with open('${WEB_ABILITY_STAGE}', 'r') as f:
    content = f.read()

original = content

# 1. Add synchronous DI init + SetContextPaths to onCreate(), before
#    runTaskAsync() is called. This ensures the native module has the
#    HarmonyOS directory paths BEFORE the Electron runtime starts and
#    tries to call app.getPath('appData').
old_oncreate = '''  onCreate(): void {
    LogUtil.info(TAG, '[ohoswindow] in WebAbilityStage onCreate.');
    this.runTaskAsync();
  }'''

new_oncreate = '''  onCreate(): void {
    LogUtil.info(TAG, '[ohoswindow] in WebAbilityStage onCreate.');
    // Initialize DI container and set context paths synchronously,
    // before the Electron runtime starts. This ensures app.getPath()
    // works when the Electron main process loads app-props.js.
    // (Moved from runTaskAsync to fix race condition on slower devices.)
    if (!GlobalThisHelper.isLaunched()) {
      let appContext = this.context.getApplicationContext();
      GlobalThisHelper.appInit(new CommonDependencyProvider(appContext));
    }
    JsBindingUtils.SetContextPaths();
    this.runTaskAsync();
  }'''

content = content.replace(old_oncreate, new_oncreate)

# 2. Remove the appInit block from runTaskAsync() (now done in onCreate)
old_appinit = '''      if (!GlobalThisHelper.isLaunched()) {
        let appContext = this.context.getApplicationContext();
        GlobalThisHelper.appInit(new CommonDependencyProvider(appContext));
      }
      import'''

new_appinit = '''      import'''

content = content.replace(old_appinit, new_appinit)

# 3. Remove SetContextPaths from the async import().then() callback
#    (now done synchronously in onCreate)
old_setpaths = '''        this.nativeThemeAdapter = Inject.get(NativeThemeAdapter);
        JsBindingUtils.SetContextPaths();
      }).catch'''

new_setpaths = '''        this.nativeThemeAdapter = Inject.get(NativeThemeAdapter);
      }).catch'''

content = content.replace(old_setpaths, new_setpaths)

if content == original:
    print('    WARNING: WebAbilityStage.ets pattern not found — file may already be patched or structure changed')
    sys.exit(0)

with open('${WEB_ABILITY_STAGE}', 'w') as f:
    f.write(content)

print('    WebAbilityStage patched: SetContextPaths moved to synchronous onCreate()')
"
else
  echo "    (WebAbilityStage.ets not found, skipping)"
fi

# --- Check signing materials ------------------------------------------------

echo "==> Checking signing materials ..."

KEYSTORE_PATH="${SIGNING_DIR}/${KEYSTORE_FILE}"
CERT_PATH="${SIGNING_DIR}/${CERT_FILE}"
PROFILE_PATH="${SIGNING_DIR}/${PROFILE_FILE}"

for f in "${KEYSTORE_PATH}" "${CERT_PATH}" "${PROFILE_PATH}"; do
  if [ ! -f "${f}" ]; then
    echo "    ✗ Missing: ${f}"
    echo "    See docs/ENV_SETUP.md for instructions."
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

# Fix: The project root package.json has "type": "module", which causes
# Node.js to treat hvigorw.js (and other .js files in the Command Line Tools)
# as ES modules. Since hvigorw.js uses CommonJS require(), this breaks with
# "ReferenceError: require is not defined in ES module scope".
# Adding a package.json with "type": "commonjs" in the Command Line Tools
# directory prevents Node.js from traversing up to the project root.
HVIGOR_DIR="${COMMANDLINE_TOOLS}/hvigor"
if [ -d "${HVIGOR_DIR}" ] && [ ! -f "${HVIGOR_DIR}/package.json" ]; then
  echo '{"type":"commonjs"}' > "${HVIGOR_DIR}/package.json"
  echo "    ✓ Added CommonJS package.json to hvigor/ dir (fixes ESM conflict)"
fi
# Also add to the top-level Command Line Tools dir to cover ohpm and other tools
if [ ! -f "${COMMANDLINE_TOOLS}/package.json" ]; then
  echo '{"type":"commonjs"}' > "${COMMANDLINE_TOOLS}/package.json"
  echo "    ✓ Added CommonJS package.json to Command Line Tools root"
fi

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

echo "==> Configuring build-profile.json5 ..."

BUILD_PROFILE="${PROJECT_ROOT}/build-profile.json5"

# --- Detect SDK version from sdk-pkg.json ---
SDK_PKG_JSON="${OHOS_SDK_HOME}/default/sdk-pkg.json"
if [ -f "${SDK_PKG_JSON}" ]; then
  SDK_API_VERSION=$(python3 -c "import json; d=json.load(open('${SDK_PKG_JSON}')); print(d['data']['apiVersion'])" 2>/dev/null || echo "")
  SDK_DISPLAY_NAME=$(python3 -c "import json; d=json.load(open('${SDK_PKG_JSON}')); print(d['data']['displayName'])" 2>/dev/null || echo "")
  SDK_VERSION=$(echo "${SDK_DISPLAY_NAME}" | sed -n 's/.*\([0-9]\+\.[0-9]\+\.[0-9]\+\).*/\1/p')
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

# --- Create local.properties for hvigor ---
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
    },
    {
      "name": "web_engine",
      "srcPath": "./web_engine"
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
echo "    ✓ oh-package.json5: version=${APP_VERSION}"
echo "    ✓ entry/oh-package.json5: version=${APP_VERSION}"

# --- Generate hvigor-config.json5 -------------------------------------------

echo "==> Configuring hvigor-config.json5 ..."

HVIGOR_CONFIG="${PROJECT_ROOT}/hvigor/hvigor-config.json5"

BUNDLED_HVIGOR_DIR="${COMMANDLINE_TOOLS}/hvigor/hvigor"
BUNDLED_PLUGIN_DIR="${COMMANDLINE_TOOLS}/hvigor/hvigor-ohos-plugin"

if [ -f "${BUNDLED_HVIGOR_DIR}/package.json" ]; then
  BUNDLED_HVIGOR_VERSION=$(python3 -c "import json; print(json.load(open('${BUNDLED_HVIGOR_DIR}/package.json'))['version'])" 2>/dev/null || echo "5.10.3")
else
  BUNDLED_HVIGOR_VERSION="5.10.3"
fi
echo "    Bundled @ohos/hvigor version: ${BUNDLED_HVIGOR_VERSION}"

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

echo "==> Configuring npm registry for hvigor ..."

NPMRC_FILE="${HOME}/.npmrc"
cat > "${NPMRC_FILE}" <<'NPMRC'
@ohos:registry=https://repo.harmonyos.com/npm/
registry=https://registry.npmjs.org/
NPMRC
echo "    ✓ Created ${NPMRC_FILE} with scoped HarmonyOS + npmjs registry"

# --- Install ohpm dependencies ----------------------------------------------

echo "==> Installing ohpm dependencies ..."
cd "${PROJECT_ROOT}"
"${OHPM}" install

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

JAVA_VERSION=$(java -version 2>&1 | head -1)
echo "    Java: ${JAVA_VERSION}"

SIGNED_APP="${UNSIGNED_APP%.app}-signed.app"

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

FINAL_APP_NAME="electerm-${APP_ARCH}-${APP_VERSION}.app"
FINAL_APP="$(dirname "${APP_FILE}")/${FINAL_APP_NAME}"

echo "==> Renaming artifact to ${FINAL_APP_NAME} ..."
mv -f "${APP_FILE}" "${FINAL_APP}"
APP_FILE="${FINAL_APP}"

# Export for CI
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
