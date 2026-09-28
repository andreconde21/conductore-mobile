'use strict'

// Herdr's socket API: newline-delimited JSON over a unix socket, one
// request per line ({id, method, params}), the reply echoing the id with
// `result` or `error: {code, message}`. Checked against Herdr 0.9.1
// (protocol 22). The CLI is a thin wrapper over the same requests; talking
// to the socket saves a process per call.
//
// Where the servers are: the default session's socket, the named sessions'
// sockets, and any socket a hook reported ($HERDR_SOCKET_PATH). Nothing
// here spawns herdr.

const fs = require('fs')
const net = require('net')
const os = require('os')
const path = require('path')
const crypto = require('crypto')

const REQUEST_TIMEOUT_MS = 5000

function configDir () {
  return path.join(os.homedir(), '.config', 'herdr')
}

// { id, socket, session, isDefault } for the default server, else null.
function defaultServer () {
  return { id: 'herdr', socket: path.join(configDir(), 'herdr.sock'), session: '', isDefault: true }
}

// Server id for a socket someone reported (null: the default server).
function idForSocket (socket) {
  if (!socket) return 'herdr'
  const abs = path.resolve(socket)
  const known = discover().find(s => path.resolve(s.socket) === abs)
  if (known) return known.id
  return `herdr#${crypto.createHash('sha1').update(abs).digest('hex').slice(0, 8)}`
}

// Every Herdr server that may run here: the default one, the named
// sessions (a directory each), and the extra sockets given. With
// CONDUCTORE_HERDR_SOCKETS (colon separated) only those, for tests.
function discover (extraSockets = []) {
  const override = process.env.CONDUCTORE_HERDR_SOCKETS
  const list = []
  const seen = new Set()
  const add = (socket, session = '', isDefault = false) => {
    const id = isDefault ? 'herdr' : session ? `herdr@${session}` : `herdr#${crypto.createHash('sha1').update(path.resolve(socket)).digest('hex').slice(0, 8)}`
    if (seen.has(id)) return
    seen.add(id)
    list.push({ id, socket, session, isDefault })
  }
  if (override !== undefined) {
    override.split(':').filter(Boolean).forEach((socket, i) => add(socket, '', i === 0))
    return list
  }
  add(defaultServer().socket, '', true)
  let names = []
  try { names = fs.readdirSync(path.join(configDir(), 'sessions')) } catch {}
  for (const name of names.sort()) {
    const socket = path.join(configDir(), 'sessions', name, 'herdr.sock')
    if (fs.existsSync(socket)) add(socket, name)
  }
  for (const socket of extraSockets) if (socket) add(socket)
  return list
}

// The server a target's id names, or null.
function serverById (id, extraSockets = []) {
  return discover(extraSockets).find(s => s.id === id) || null
}

let nextId = 0

// One request on a fresh connection; resolves the `result`, rejects with an
// Error carrying `code` (Herdr's, or ECONNREFUSED/ENOENT/timeout).
function request (socket, method, params = {}, { timeoutMs = REQUEST_TIMEOUT_MS } = {}) {
  return new Promise((resolve, reject) => {
    const id = `conductore:${process.pid}:${++nextId}`
    let buf = ''
    let done = false
    const c = net.createConnection(socket)
    const finish = (err, result) => {
      if (done) return
      done = true
      clearTimeout(timer)
      c.destroy()
      err ? reject(err) : resolve(result)
    }
    const timer = setTimeout(() => finish(Object.assign(new Error(`herdr ${method} timed out`), { code: 'timeout' })), timeoutMs)
    c.setEncoding('utf8')
    c.on('connect', () => c.write(JSON.stringify({ id, method, params }) + '\n'))
    c.on('data', chunk => {
      buf += chunk
      let i
      while ((i = buf.indexOf('\n')) !== -1) {
        const line = buf.slice(0, i)
        buf = buf.slice(i + 1)
        let msg
        try { msg = JSON.parse(line) } catch { continue }
        if (msg.error) return finish(Object.assign(new Error(msg.error.message || msg.error.code || 'herdr error'), { code: msg.error.code || 'error' }))
        if ('result' in msg) return finish(null, msg.result)
      }
    })
    c.on('error', err => finish(Object.assign(new Error(err.message), { code: err.code || 'error' })))
    c.on('close', () => finish(Object.assign(new Error('herdr closed the connection'), { code: 'closed' })))
  })
}

// Whether an error says the method does not exist in this Herdr.
function unknownMethod (err) {
  return !!err && err.code === 'invalid_request' && /unknown variant/.test(err.message || '')
}

// `session.snapshot` result -> the snapshot object ({workspaces, tabs,
// panes, agents, ...}), tolerating the envelope moving.
function snapshotOf (result) {
  if (!result || typeof result !== 'object') return null
  const snap = result.snapshot && typeof result.snapshot === 'object' ? result.snapshot : result
  return Array.isArray(snap.workspaces) ? snap : null
}

module.exports = { configDir, defaultServer, discover, serverById, idForSocket, request, unknownMethod, snapshotOf, REQUEST_TIMEOUT_MS }
