// build html
/**
 * build common files with react module in it
 */
const fs = require('fs')
const pug = require('pug')
const { resolve } = require('path')
const pack = require('../../package.json')
const deepCopy = require('json-deep-copy')

const entryPug = resolve(
  __dirname,
  '../../src/client/views/index.pug'
)
const targetFilePath = resolve(
  __dirname,
  '../../work/app/assets/index.html'
)
const pugContent = fs.readFileSync(entryPug, 'utf-8')
const defaultAIPreset = {
  baseURLAI: 'https://ai.electerm.org/api/ai',
  apiPathAI: '/chat/completions',
  modelAI: 'mistral-small-latest',
  authHeaderNameAI: 'Authorization: Bearer',
  id: 'ai.electerm.org',
  nameAI: 'ai.electerm.org(default free)'
}

// const AIDisclamer = 'AI-generated terminal commands can be inaccurate or unsafe, be careful'

const data = {
  version: pack.version,
  siteName: pack.name,
  isDev: false,
  disableUpgradeCheck: true,
  hideLocalTerminal: true,
  defaultAIPreset
}

// Allow builds (e.g. HarmonyOS) to inject extra data via env var
if (process.env.PUG_EXTRA_DATA) {
  try {
    Object.assign(data, JSON.parse(process.env.PUG_EXTRA_DATA))
  } catch (e) {
    console.warn('Warning: Failed to parse PUG_EXTRA_DATA:', e.message)
  }
}

const htmlContent = pug.render(pugContent, {
  filename: entryPug,
  ...data,
  _global: deepCopy(data)
})
fs.writeFileSync(targetFilePath, htmlContent, 'utf8')
