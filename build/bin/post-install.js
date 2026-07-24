/**
 * post install script
 * Modified for electerm-harmony: no electron-rebuild (we use prebuilt HarmonyOS Electron runtime)
 */
const { cp, rm } = require('shelljs')
const { existsSync } = require('fs')
const { resolve } = require('path')
const prePushPath = resolve(__dirname, '../../.git/hooks/pre-push')
const prePushPathFrom = resolve(__dirname, 'pre-push')

// Remove optional native module that may fail to rebuild
try {
  // Check multiple potential locations for cpu-features
  const cpuFeaturesPaths = [
    resolve(__dirname, '../../node_modules/cpu-features'),
    resolve(__dirname, '../../work/app/node_modules/cpu-features')
  ]

  cpuFeaturesPaths.forEach(cpuFeaturesPath => {
    if (existsSync(cpuFeaturesPath)) {
      rm('-rf', cpuFeaturesPath)
      console.log('Removed optional module:', cpuFeaturesPath)
    }
  })
} catch (e) {
  console.warn('Failed to remove cpu-features:', e?.message || e)
}

// Remove native modules that are not available on HarmonyOS
// (node-pty and serialport are not in dependencies, but clean up any leftovers)
try {
  const nativeModules = [
    resolve(__dirname, '../../node_modules/node-pty'),
    resolve(__dirname, '../../node_modules/serialport'),
    resolve(__dirname, '../../work/app/node_modules/node-pty'),
    resolve(__dirname, '../../work/app/node_modules/serialport')
  ]
  nativeModules.forEach(p => {
    if (existsSync(p)) {
      rm('-rf', p)
      console.log('Removed native module:', p)
    }
  })
} catch (e) {
  console.warn('Failed to clean native modules:', e?.message || e)
}

if (!existsSync(prePushPath)) {
  cp(prePushPathFrom, prePushPath)
}
