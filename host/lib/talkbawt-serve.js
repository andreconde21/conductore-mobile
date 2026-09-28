'use strict'

// `conductore-hostd talkbawt serve`: the bundled self-hosted Talkbawt
// server (host/vendor/talkbawt, embedded through createTalkbawt()). Off by
// default: nothing of it loads or runs until this command starts it, and it
// stops with `serve --stop`. Its database is ~/.conductore/talkbawt.db.
//
// It listens on 127.0.0.1 (or ::1, or a tailnet address) only: the links it
// hands out are plain http://, which the clients accept only for loopback
// and tailnet hosts. To publish it, put a TLS proxy in front and pass the
// public origin as --base-url.

const fs = require('fs')
const path = require('path')
const { spawn } = require('child_process')
const { pathToFileURL } = require('url')
const paths = require('./paths')
const proc = require('./proc')
const tb = require('./talkbawt')

const VENDOR_INDEX = path.join(__dirname, '..', 'vendor', 'talkbawt', 'src', 'index.mjs')
const dbPath = () => path.join(paths.homeDir(), 'talkbawt.db')
const statePath = () => path.join(paths.homeDir(), 'talkbawt-serve.json')

// Node 22.5 brought node:sqlite; 22.5 to 22.12 need --experimental-sqlite.
function probeSqlite () {
  const emit = process.emitWarning
  // Loading it prints an ExperimentalWarning on some versions; this is only
  // a probe.
  process.emitWarning = () => {}
  try {
    require('node:sqlite')
    return true
  } catch {
    return false
  } finally {
    process.emitWarning = emit
  }
}

function checkNode (version = process.versions.node, hasSqlite = probeSqlite) {
  const [major, minor] = String(version).split('.').map(Number)
  if (!(major > 22 || (major === 22 && minor >= 5))) {
    return { ok: false, reason: `talkbawt serve needs Node.js 22.5 or newer (for node:sqlite); this is Node.js ${version}. Install a newer Node, or use a Talkbawt server elsewhere.` }
  }
  if (!hasSqlite()) {
    return { ok: false, reason: `node:sqlite is not available in Node.js ${version}; on 22.5 to 22.12 start it with NODE_OPTIONS=--experimental-sqlite` }
  }
  return { ok: true }
}

// Where it may listen: this machine or the tailnet, never every interface.
function checkHost (host) {
  const h = String(host || '').replace(/^\[|\]$/g, '')
  if (h === '127.0.0.1' || h === '::1') return h
  if (/^\d{1,3}(\.\d{1,3}){3}$/.test(h) && tb.isTailnet(h)) return h
  if (/^fd7a:115c:a1e0:/i.test(h)) return h
  throw new tb.TalkbawtError('bad-host', '--host is 127.0.0.1, ::1 or a tailnet address (100.64.0.0/10, fd7a:115c:a1e0::/48); put a TLS proxy in front to publish it')
}

function checkPort (port) {
  const n = Number(port ?? 0)
  if (!Number.isInteger(n) || n < 0 || n > 65535) throw new tb.TalkbawtError('bad-port', '--port is 0 (any free port) to 65535')
  return n
}

function readState () {
  try { return JSON.parse(fs.readFileSync(statePath(), 'utf8')) } catch { return null }
}

// A pid in the state file is ours only while it still runs `talkbawt serve`.
function isServer (pid) {
  if (!proc.pidAlive(pid)) return false
  const cmd = proc.commandLine(pid)
  return !cmd || (cmd.includes('talkbawt') && cmd.includes('serve'))
}

// Runs the server in this process. Resolves { close, port, url }.
async function start ({ port, host = '127.0.0.1', baseUrl } = {}) {
  const node = checkNode()
  if (!node.ok) throw new tb.TalkbawtError('node-too-old', node.reason)
  const h = checkHost(host)
  const p = checkPort(port)
  const base = baseUrl ? tb.checkServer(baseUrl) : null
  const running = readState()
  if (running && isServer(running.pid)) throw new tb.TalkbawtError('already-running', `already serving at ${running.url} (pid ${running.pid}); stop it with talkbawt serve --stop`)
  paths.ensureDirs()
  const { createTalkbawt } = await import(pathToFileURL(VENDOR_INDEX).href)
  const server = createTalkbawt({
    dbPath: dbPath(),
    baseUrl: base,
    trustProxy: false,
    logger: { log: (...a) => tb.tlog(`serve: ${a.join(' ')}`), error: (...a) => tb.tlog(`serve error: ${a.map(String).join(' ')}`) }
  })
  const bound = await server.listen(p, h)
  const url = base || bound.url
  const state = { pid: process.pid, host: h, port: bound.port, url, localUrl: bound.url, db: dbPath(), startedAt: Date.now() }
  fs.writeFileSync(statePath(), JSON.stringify(state) + '\n', { mode: 0o600 })
  tb.tlog(`serve: listening on ${bound.url}${base ? ` as ${base}` : ''}`)
  const close = async () => {
    try { await server.close() } catch {}
    const cur = readState()
    if (cur && cur.pid === process.pid) try { fs.unlinkSync(statePath()) } catch {}
    tb.tlog('serve: stopped')
  }
  return { close, ...state }
}

// Starts it in the background (its own session, output to the log) and
// resolves its ready line.
function detach (args, { timeoutMs = 10000 } = {}) {
  return new Promise((resolve, reject) => {
    const bin = path.join(__dirname, '..', 'bin', 'conductore-hostd')
    const child = spawn(process.execPath, [bin, 'talkbawt', 'serve', ...args.filter(a => a !== '--detach')], {
      detached: true,
      stdio: ['ignore', 'pipe', 'ignore'],
      env: process.env
    })
    let out = ''
    const timer = setTimeout(() => { finish(new Error('the server did not start within 10 s (see ~/.conductore/hostd.log)')) }, timeoutMs)
    const finish = (err, value) => {
      clearTimeout(timer)
      child.stdout.removeAllListeners()
      child.stdout.destroy()
      child.unref()
      if (err) reject(err)
      else resolve(value)
    }
    child.on('error', err => finish(err))
    child.on('exit', () => {
      let parsed = null
      try { parsed = JSON.parse(out.trim().split('\n')[0]) } catch {}
      finish(null, parsed || { error: 'the server exited at once (see ~/.conductore/hostd.log)', code: 'failed' })
    })
    child.stdout.setEncoding('utf8')
    child.stdout.on('data', d => {
      out += d
      const nl = out.indexOf('\n')
      if (nl === -1) return
      let line = null
      try { line = JSON.parse(out.slice(0, nl)) } catch {}
      child.removeAllListeners('exit')
      finish(null, line || { error: 'unreadable answer from the server process', code: 'failed' })
    })
  })
}

async function status () {
  const s = readState()
  if (!s) return { ok: true, running: false }
  if (!isServer(s.pid)) {
    try { fs.unlinkSync(statePath()) } catch {}
    return { ok: true, running: false }
  }
  let healthy = false
  try {
    const r = await fetch(`${s.localUrl}/healthz`, { signal: AbortSignal.timeout(3000) })
    healthy = r.ok
  } catch {}
  return { ok: true, running: true, healthy, pid: s.pid, url: s.url, localUrl: s.localUrl, host: s.host, port: s.port, db: s.db, startedAt: s.startedAt }
}

async function stop () {
  const s = readState()
  if (!s || !isServer(s.pid)) {
    try { fs.unlinkSync(statePath()) } catch {}
    return { ok: true, running: false }
  }
  try { process.kill(s.pid, 'SIGTERM') } catch {}
  for (let i = 0; i < 60 && proc.pidAlive(s.pid); i++) await new Promise(resolve => setTimeout(resolve, 50))
  if (proc.pidAlive(s.pid)) try { process.kill(s.pid, 'SIGKILL') } catch {}
  try { fs.unlinkSync(statePath()) } catch {}
  return { ok: true, running: true, stopped: true, pid: s.pid }
}

module.exports = { checkNode, checkHost, checkPort, probeSqlite, start, detach, status, stop, dbPath, statePath, VENDOR_INDEX }
