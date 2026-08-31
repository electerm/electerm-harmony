/**
 * NeDB API wrapper compatible with legacy electerm user data.
 */

import fs from 'fs'
import { resolve } from 'path'
import Datastore from '@electerm/nedb'
import nedbStorage from '@electerm/nedb/lib/storage.js'
import { cwd, defaultUserName } from '../common/runtime-constants.js'
import { safeDecrypt, safeEncrypt } from './safe-storage.js'

const originalFlush = nedbStorage.flushToStorage
const encryptedTables = new Set(['bookmarks', 'profiles', 'data', 'history', 'terminalCommandHistory', 'aiChatHistory'])
const encryptedDataId = 'userConfig'
const encryptedPrefix = 'enc:'

nedbStorage.flushToStorage = function (options, callback) {
  originalFlush.call(nedbStorage, options, () => callback(null))
}

export const tables = [
  'bookmarks',
  'bookmarkGroups',
  'addressBookmarks',
  'terminalThemes',
  'lastStates',
  'data',
  'quickCommands',
  'log',
  'dbUpgradeLog',
  'profiles',
  'workspaces',
  'history',
  'terminalCommandHistory',
  'aiChatHistory',
  'autoRunWidgets'
]

const dbPath = process.env.DB_PATH || resolve(cwd, 'data')
const dbDir = resolve(dbPath, 'users', defaultUserName)
fs.mkdirSync(dbDir, { recursive: true })

const db = Object.fromEntries(tables.map(table => [
  table,
  new Datastore({
    filename: resolve(dbDir, `electerm.${table}.nedb`),
    autoload: true,
    onload: (err) => {
      if (err && !db[table].executor.ready) {
        db[table].executor.processBuffer()
      }
    }
  })
]))

function needsEncryption (dbName, id) {
  return dbName === 'data'
    ? id === encryptedDataId
    : encryptedTables.has(dbName)
}

function encryptDoc (dbName, doc) {
  if (!needsEncryption(dbName, doc._id)) return doc
  const { _id, ...payload } = doc
  return {
    ...(_id === undefined ? {} : { _id }),
    _encdata: encryptedPrefix + safeEncrypt(JSON.stringify(payload))
  }
}

function decryptDoc (dbName, doc) {
  if (!doc || !needsEncryption(dbName, doc._id) || !doc._encdata) return doc
  try {
    const decrypted = doc._encdata.startsWith(encryptedPrefix)
      ? safeDecrypt(doc._encdata.slice(encryptedPrefix.length))
      : doc._encdata
    const { _encdata, ...rest } = doc
    return { ...rest, ...JSON.parse(decrypted) }
  } catch {
    return doc
  }
}

export function dbAction (dbName, op, ...args) {
  if (!db[dbName]) {
    throw new Error(`Table ${dbName} does not exist`)
  }
  if (op === 'compactDatafile') {
    db[dbName].persistence.compactDatafile()
    return
  }
  return new Promise((resolve, reject) => {
    const callback = (err, result) => {
      if (err) return reject(err)
      if (op === 'find') return resolve((result || []).map(doc => decryptDoc(dbName, doc)))
      if (op === 'findOne') return resolve(decryptDoc(dbName, result))
      resolve(result)
    }
    if (op === 'insert') {
      const original = args[0]
      const encrypted = Array.isArray(original)
        ? original.map(doc => encryptDoc(dbName, doc))
        : encryptDoc(dbName, original)
      db[dbName].insert(encrypted, (err, inserted) => {
        if (err) return reject(err)
        if (Array.isArray(original)) {
          return resolve(inserted.map((doc, index) => ({ ...original[index], _id: doc._id })))
        }
        resolve({ ...original, _id: inserted._id })
      })
      return
    }
    if (op === 'update' && needsEncryption(dbName, args[0]._id || args[0].id)) {
      const [query, update, options] = args
      const payload = update.$set || update
      const encrypted = encryptDoc(dbName, { _id: query._id || query.id, ...payload })
      db[dbName].update(query, update.$set ? { $set: encrypted } : encrypted, options || {}, callback)
      return
    }
    db[dbName][op](...args, callback)
  })
}
