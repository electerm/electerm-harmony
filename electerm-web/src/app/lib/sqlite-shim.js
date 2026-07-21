/**
 * SQLite shim for HarmonyOS — provides a DatabaseSync-compatible API
 * backed by JSON files instead of native node:sqlite.
 *
 * All electerm tables use the same simple schema:
 *   (_id TEXT PRIMARY KEY, data TEXT)
 *
 * So we can store each table as a JSON object { _id: data } and
 * implement prepare/all/get/run with trivial key-value lookups.
 */

import fs from 'fs'
import { resolve } from 'path'

/**
 * @param {string} dbPath  path to the .db file (we use .json extension instead)
 */
export class DatabaseSync {
  constructor (dbPath) {
    // Replace .db with .json for the shim file
    this._jsonPath = dbPath.replace(/\.db$/, '.json')
    this._tables = {} // { tableName: { _id: dataString } }

    // Load existing data
    if (fs.existsSync(this._jsonPath)) {
      try {
        const raw = fs.readFileSync(this._jsonPath, 'utf8')
        this._tables = JSON.parse(raw) || {}
      } catch (e) {
        this._tables = {}
      }
    }
  }

  /**
   * Execute SQL (only CREATE TABLE is used in electerm — it's a no-op for us
   * since we store everything as JSON objects).
   */
  exec (sql) {
    // CREATE TABLE IF NOT EXISTS `xxx` (_id TEXT PRIMARY KEY, data TEXT)
    // — no-op, tables are created on demand
  }

  /**
   * Prepare a statement. We parse the SQL to determine the operation type
   * and table name.
   */
  prepare (sql) {
    return new Statement(this, sql)
  }

  /**
   * Persist the in-memory data to disk.
   */
  _save () {
    try {
      // Ensure directory exists
      const dir = resolve(this._jsonPath, '..')
      if (!fs.existsSync(dir)) {
        fs.mkdirSync(dir, { recursive: true })
      }
      fs.writeFileSync(this._jsonPath, JSON.stringify(this._tables))
    } catch (e) {
      // Best effort — don't crash the backend
    }
  }
}

/**
 * Prepared statement — parses SQL to determine the operation.
 */
class Statement {
  constructor (db, sql) {
    this._db = db
    this._sql = sql.trim()
    this._parse()
  }

  _parse () {
    const sql = this._sql

    // Extract table name from backticks or plain
    const tableMatch = sql.match(/`([^`]+)`/) || sql.match(/FROM\s+(\S+)/i) || sql.match(/INTO\s+(\S+)/i)
    this._table = tableMatch ? tableMatch[1] : null

    // Determine operation
    const upper = sql.toUpperCase().trim()
    if (upper.startsWith('SELECT')) {
      this._op = 'select'
      // Check if there's a WHERE _id = ? clause
      if (/WHERE\s+_id\s*=\s*\?/i.test(sql)) {
        this._whereId = true
      }
    } else if (upper.startsWith('INSERT') || upper.startsWith('REPLACE')) {
      this._op = 'upsert'
    } else if (upper.startsWith('UPDATE')) {
      this._op = 'update'
      // UPDATE `table` SET data = ? WHERE _id = ?
      if (/WHERE\s+_id\s*=\s*\?/i.test(sql)) {
        this._whereId = true
      }
    } else if (upper.startsWith('DELETE')) {
      this._op = 'delete'
      if (/WHERE\s+_id\s*=\s*\?/i.test(sql)) {
        this._whereId = true
      }
    } else {
      this._op = 'unknown'
    }
  }

  _ensureTable () {
    if (!this._table) return null
    if (!this._db._tables[this._table]) {
      this._db._tables[this._table] = {}
    }
    return this._db._tables[this._table]
  }

  /**
   * Return all rows as an array of { _id, data } objects.
   */
  all (...params) {
    const table = this._ensureTable()
    if (!table) return []

    if (this._whereId && params[0]) {
      const row = table[params[0]]
      return row ? [{ _id: params[0], data: row }] : []
    }

    return Object.entries(table).map(([_id, data]) => ({ _id, data }))
  }

  /**
   * Return a single row or undefined.
   */
  get (...params) {
    const rows = this.all(...params)
    return rows[0] || undefined
  }

  /**
   * Execute the statement and return { changes }.
   */
  run (...params) {
    const table = this._ensureTable()
    if (!table) return { changes: 0 }

    if (this._op === 'upsert') {
      // INSERT OR REPLACE INTO `table` (_id, data) VALUES (?, ?)
      // params: [_id, data]
      const _id = params[0]
      const data = params[1]
      table[_id] = data
      this._db._save()
      return { changes: 1 }
    } else if (this._op === 'update') {
      // UPDATE `table` SET data = ? WHERE _id = ?
      // params: [data, _id]
      const data = params[0]
      const _id = params[1]
      if (table[_id] !== undefined) {
        table[_id] = data
        this._db._save()
        return { changes: 1 }
      }
      return { changes: 0 }
    } else if (this._op === 'delete') {
      // DELETE FROM `table` WHERE _id = ?
      // params: [_id]
      const _id = params[0]
      if (table[_id] !== undefined) {
        delete table[_id]
        this._db._save()
        return { changes: 1 }
      }
      return { changes: 0 }
    }

    return { changes: 0 }
  }
}
