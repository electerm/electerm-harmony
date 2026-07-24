const { exec } = require('shelljs')
const os = require('os')
const platform = os.platform()
console.log('platform:', platform)

// Clear ELECTRON_RUN_AS_NODE so electron runs in full Electron mode
// (not pure Node.js mode where require('electron').app is undefined)
delete process.env.ELECTRON_RUN_AS_NODE

const cmd = platform.startsWith('win')
  ? 'node_modules\\.bin\\cross-env NODE_ENV=development node_modules\\.bin\\electron -r dotenv/config src\\app\\app'
  : 'node_modules/.bin/cross-env NODE_ENV=development node_modules/.bin/electron -r dotenv/config src/app/app'
exec(cmd, { env: process.env })
