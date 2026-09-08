// install-src.js (HarmonyOS replacement)
// Determines the HarmonyOS release asset architecture identifier at runtime.
// Used to match the correct release asset when checking/downloading upgrades
// (see download-upgrade.js: `r.name.includes(installSrc)`).
//
// scripts/build-app.sh names release artifacts
// `electerm-harmony-${APP_ARCH}-${version}.app` with APP_ARCH being either
// `arm64` (arm64-v8a libs, real devices) or `x86_64` (emulator). We resolve
// at runtime from os.arch() so the same bundled code works for both without
// a build-time injection step.

import os from 'os'

const archMap = {
  arm64: 'arm64',
  x64: 'x86_64'
}

const arch = os.arch()
const installSrc = 'electerm-harmony-' + (archMap[arch] || 'arm64')

export default installSrc
