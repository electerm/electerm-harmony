#!/usr/bin/env bash
# gen-manifest.sh — Generate a JSON manifest of all files in the rawfile directory.
#
# The manifest is used at runtime to know which files to extract from the app's
# rawfile resources to the sandbox. HarmonyOS resourceManager does not provide
# a recursive directory listing API, so we generate the file list at build time.
#
# Output: entry/src/main/resources/rawfile/manifest.json
#
# Prerequisites:
#   - prepare-node.sh and prepare-web.sh already run (rawfile/ populated)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RAWFILE_DIR="${PROJECT_ROOT}/entry/src/main/resources/rawfile"
MANIFEST_FILE="${RAWFILE_DIR}/manifest.json"

echo "==> Generating rawfile manifest..."

if [ ! -d "${RAWFILE_DIR}/node" ] || [ ! -d "${RAWFILE_DIR}/electerm-web" ]; then
  echo "    ✗ rawfile/node or rawfile/electerm-web not found."
  echo "    Run ./scripts/prepare-node.sh and ./scripts/prepare-web.sh first."
  exit 1
fi

export RAWFILE_DIR

python3 -c "
import os, json, sys
rawfile_dir = os.environ['RAWFILE_DIR']
files = []
for root, dirs, filenames in os.walk(rawfile_dir):
    for filename in filenames:
        full_path = os.path.join(root, filename)
        rel_path = os.path.relpath(full_path, rawfile_dir)
        if rel_path != 'manifest.json':
            files.append(rel_path.replace(os.sep, '/'))
files.sort()
json.dump(files, sys.stdout, indent=2)
" > "${MANIFEST_FILE}"

FILE_COUNT=$(python3 -c "import json; print(len(json.load(open('${MANIFEST_FILE}'))))")
echo "    ✓ Manifest: ${FILE_COUNT} files -> ${MANIFEST_FILE}"
echo "==> Manifest generation complete."
