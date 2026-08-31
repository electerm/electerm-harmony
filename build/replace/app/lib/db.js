/**
 * db loader
 */

let dbModule = null

async function getDbModule () {
  if (!dbModule) {
    dbModule = await import('./nedb.js')
  }
  return dbModule
}

export async function dbAction (...args) {
  const db = await getDbModule()
  return db.dbAction ? db.dbAction(...args) : db.default.dbAction(...args)
}
