#!/usr/bin/env bash
# gen-secrets.sh — Generate GitHub Secrets values from signing materials
#
# Reads app info from temp/.env (gitignored) and signing/ directory.
# Outputs to temp/github-secrets.txt (gitignored).
#
# Usage:
#   ./scripts/gen-secrets.sh
#
# NOTE: This script does NOT contain any secrets itself.
#       All values are read from temp/.env and signing/ at runtime.

set -euo pipefail

cd "$(dirname "$0")/.."

# --- Read app info from temp/.env (gitignored) -------------------------------

ENV_FILE="temp/.env"
if [ ! -f "${ENV_FILE}" ]; then
  echo "✗ ${ENV_FILE} not found. Create it first with:"
  echo '  echo "appid: <your-app-id>" > temp/.env'
  echo '  echo "name: electerm" >> temp/.env'
  echo '  echo "应用包名：org.electerm.electerm" >> temp/.env'
  echo '  echo "password: <your-password>" >> temp/.env'
  exit 1
fi

# Parse key: value format from temp/.env
PASS=$(grep -i '^password:' "${ENV_FILE}" | sed 's/^password:[[:space:]]*//')
BUNDLE=$(grep -i '应用包名' "${ENV_FILE}" | sed 's/.*：//')
APPID=$(grep -i '^appid:' "${ENV_FILE}" | sed 's/^appid:[[:space:]]*//')
ALIAS="electerm_key"

if [ -z "${PASS}" ]; then
  echo "✗ password not found in ${ENV_FILE}"
  exit 1
fi
if [ -z "${BUNDLE}" ]; then
  echo "✗ bundle name not found in ${ENV_FILE}"
  exit 1
fi
if [ -z "${APPID}" ]; then
  echo "✗ appid not found in ${ENV_FILE}"
  exit 1
fi

# --- Generate base64 values from signing materials --------------------------

KEYSTORE_B64=$(base64 -i signing/electerm.p12 | tr -d '\n')
CERT_B64=$(base64 -i signing/electerm_publish.cer | tr -d '\n')
PROFILE_B64=$(base64 -i signing/electermRelease.p7b | tr -d '\n')

# Generate a random server secret for electerm-web
SERVER_SECRET=$(openssl rand -base64 32 | tr -d '\n')

# --- Write output (to gitignored temp/) --------------------------------------

OUT="temp/github-secrets.txt"

{
  echo "# ============================================"
  echo "# GitHub Secrets — electerm-harmony"
  echo "# 复制每个 value 到 GitHub → Settings → Secrets → Actions → New repository secret"
  echo "# ============================================"
  echo ""
  echo "# 1. OHOS_KEYSTORE_B64 (from signing/electerm.p12)"
  echo "OHOS_KEYSTORE_B64=${KEYSTORE_B64}"
  echo ""
  echo "# 2. OHOS_CERT_B64 (from signing/electerm_publish.cer)"
  echo "OHOS_CERT_B64=${CERT_B64}"
  echo ""
  echo "# 3. OHOS_PROFILE_B64 (from signing/electermRelease.p7b)"
  echo "OHOS_PROFILE_B64=${PROFILE_B64}"
  echo ""
  echo "# 4. OHOS_KEYSTORE_PASSWORD"
  echo "OHOS_KEYSTORE_PASSWORD=${PASS}"
  echo ""
  echo "# 5. OHOS_KEY_PASSWORD"
  echo "OHOS_KEY_PASSWORD=${PASS}"
  echo ""
  echo "# 6. OHOS_KEY_ALIAS"
  echo "OHOS_KEY_ALIAS=${ALIAS}"
  echo ""
  echo "# 7. OHOS_BUNDLE_NAME"
  echo "OHOS_BUNDLE_NAME=${BUNDLE}"
  echo ""
  echo "# 8. OHOS_APP_ID"
  echo "OHOS_APP_ID=${APPID}"
  echo ""
  echo "# 9. OHOS_CMDLINE_TOOLS_URL"
  echo "# → 从 https://developer.huawei.com/consumer/cn/download/ 获取 Linux 版下载链接"
  echo "# OHOS_CMDLINE_TOOLS_URL=https://contentcenter-vali-drcn.dbankcdn.cn/..."
  echo ""
  echo "# 10. OHOS_SERVER_SECRET (electerm-web server secret)"
  echo "OHOS_SERVER_SECRET=${SERVER_SECRET}"
} > "${OUT}"

echo "✓ Written to ${OUT}"
echo "  File size: $(wc -c < "${OUT}") bytes"
echo "  Lines: $(wc -l < "${OUT}")"
