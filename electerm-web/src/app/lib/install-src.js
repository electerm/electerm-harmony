// install-src.js
// Determines the HarmonyOS architecture identifier at runtime.
// Used to match the correct release asset when checking/downloading upgrades.
//
// HarmonyOS HAP targets:
//   arm64-v8a      -> Node.js os.arch() === 'arm64'
//
// We resolve at runtime from os.arch() so the same bundled code works for
// the target ABI. Currently only arm64-v8a is supported on HarmonyOS.

import os from 'os'

const archMap = {
  arm64: 'arm64-v8a'
}

const arch = os.arch()
const installSrc = 'electerm-harmony-' + (archMap[arch] || 'arm64-v8a')

export default installSrc
