'use strict'

// Socket client used by the CLI (the sh hook and statusline use the spool).
// Protocol: newline-delimited JSON, one request object per connection.
// The daemon answers with one or more JSON lines; the last line is the response
// unless the request is a stream (`events`), which ends when the daemon closes.

const fs = require('fs')
const net = require('net')
const path = require('path')
const { spawn } = require('child_process')
const paths = require('./paths')
const { log } = require('./log')

const START_TIMEOUT_MS = 4000

function assertSocketOwner (sock) {
  if (process.getuid === undefined) return
  const st = fs.lstatSync(sock)
  if (st.uid !== process.getuid()) throw new Error(`socket ${sock} is owned by uid ${st.uid}, not us`)
  if (!st.isSocket()) throw new Error(`${sock} is not a socket`)
}

function connect (sock = paths.socketPath()) {
  return new Promise((resolve, reject) => {
    try { assertSocketOwner(sock) } catch (err) { return reject(err) }
    const c = net.createConnection(sock)
    c.once('connect', () => resolve(c))
    c.once('error', reject)
  })
}

// Sends one request, resolves with the array of JSON lines the daemon returned.
// `onLine` (optional) receives each line as it arrives, for streaming.
function request (req, { socket, onLine, timeoutMs } = {}) {
  return connect(socket).then(c => new Promise((resolve, reject) => {
    const lines = []
    let buf = ''
    let done = false
    const finish = (err) => {
      if (done) return
      done = true
      c.destroy()
      err ? reject(err) : resolve(lines)
    }
    if (timeoutMs) c.setTimeout(timeoutMs, () => finish(new Error('daemon timeout')))
    c.setEncoding('utf8')
    c.on('data', chunk => {
      buf += chunk
      let i
      while ((i = buf.indexOf('\n')) !== -1) {
        const line = buf.slice(0, i)
        buf = buf.slice(i + 1)
        if (!line.trim()) continue
        let obj
        try { obj = JSON.parse(line) } catch (err) { return finish(new Error(`bad line from daemon: ${line}`)) }
        lines.push(obj)
        if (onLine) onLine(obj)
      }
    })
    c.on('error', finish)
    c.on('close', () => finish())
    c.write(JSON.stringify(req) + '\n')
  }))
}

function daemonScript () {
  return path.join(__dirname, '..', 'bin', 'conductore-hostd')
}

// Starts the daemon in its own session (setsid), with the memory flags.
// The sh clients get here through `conductore-hostd daemon --detach`.
// Its stderr goes to the log, so a fatal V8 error (no JS runs then) leaves
// a trace.
function spawnDaemon () {
  paths.ensureDirs()
  let err = 'ignore'
  try { err = fs.openSync(paths.logPath(), 'a', 0o600) } catch {}
  let child
  try {
    child = spawn(process.execPath, [...paths.DAEMON_NODE_FLAGS, daemonScript(), 'daemon'], {
      detached: true,
      stdio: ['ignore', 'ignore', err],
      env: process.env
    })
  } finally {
    if (typeof err === 'number') fs.closeSync(err)
  }
  child.unref()
  log('client', `spawned daemon pid ${child.pid}`)
}

const sleep = ms => new Promise(r => setTimeout(r, ms))

// Connects, starting the daemon if needed. Resolves with nothing; throws if it
// cannot be reached within START_TIMEOUT_MS.
async function ensureDaemon ({ start = true } = {}) {
  try {
    await request({ op: 'ping' }, { timeoutMs: 2000 })
    return true
  } catch (err) {
    if (!start) throw err
  }
  spawnDaemon()
  const deadline = Date.now() + START_TIMEOUT_MS
  let delay = 30
  while (Date.now() < deadline) {
    await sleep(delay)
    delay = Math.min(delay * 2, 300)
    try {
      await request({ op: 'ping' }, { timeoutMs: 2000 })
      return true
    } catch {}
  }
  throw new Error('daemon did not start')
}

module.exports = { request, ensureDaemon, spawnDaemon, connect }
