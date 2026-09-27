'use strict'

// Review M19: the socket path must not depend on the environment of whoever
// started the daemon. It is <state dir>/hostd.sock; a daemon from 0.7 or
// earlier listening in $XDG_RUNTIME_DIR/conductore stays reachable.

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('fs')
const path = require('path')
const { tempDir, cleanup } = require('./helpers/cleanup')
const { spawn, execFile } = require('child_process')

const HOSTD = path.join(__dirname, '..', 'bin', 'conductore-hostd')
const root = tempDir('cnd-sock-')
const home = path.join(root, 'h')
const xdg = path.join(root, 'x')
fs.mkdirSync(home)
fs.mkdirSync(xdg, { mode: 0o700 })
const base = { ...process.env, HOME: home }
for (const k of Object.keys(base)) if (/^(TMUX|HERDR_|CONDUCTORE_|XDG_RUNTIME_DIR$)/.test(k)) delete base[k]

const sleep = ms => new Promise(r => setTimeout(r, ms))

function cli (env, ...args) {
  return new Promise((resolve, reject) => {
    execFile(process.execPath, [HOSTD, ...args], { env, timeout: 20000 }, (err, stdout) => {
      if (err && err.code === undefined) return reject(err)
      resolve(JSON.parse(stdout.trim().split('\n').pop()))
    })
  })
}

async function startDaemon (env, sock) {
  const d = spawn(process.execPath, [HOSTD, 'daemon'], { env, stdio: 'ignore' })
  d.exited = new Promise(resolve => d.on('exit', resolve))
  for (let i = 0; i < 100 && !fs.existsSync(sock); i++) await sleep(50)
  assert.ok(fs.existsSync(sock), `no socket at ${sock}`)
  return d
}

test('the daemon listens in the state dir whether or not its starter had XDG_RUNTIME_DIR', async () => {
  const sock = path.join(home, '.conductore', 'hostd.sock')
  const d = await startDaemon({ ...base, XDG_RUNTIME_DIR: xdg }, sock)
  assert.equal(fs.existsSync(path.join(xdg, 'conductore', 'hostd.sock')), false)
  // A client with no XDG_RUNTIME_DIR (cron, su, nohup) reaches it.
  assert.equal((await cli(base, 'status')).source, 'daemon')
  assert.equal((await cli({ ...base, XDG_RUNTIME_DIR: xdg }, 'status')).source, 'daemon')
  assert.equal((await cli(base, 'stop')).stopped, true)
  await d.exited
})

test('a daemon from 0.7 still listening in XDG_RUNTIME_DIR is found and can be stopped', async () => {
  const legacy = path.join(xdg, 'conductore', 'hostd.sock')
  fs.mkdirSync(path.dirname(legacy), { recursive: true, mode: 0o700 })
  // Stand-in for the old daemon: same state dir and lock, legacy socket.
  const d = await startDaemon({ ...base, CONDUCTORE_HOME: path.join(home, '.conductore'), CONDUCTORE_SOCKET: legacy }, legacy)
  assert.equal((await cli({ ...base, XDG_RUNTIME_DIR: xdg }, 'status')).source, 'daemon')
  assert.equal((await cli({ ...base, XDG_RUNTIME_DIR: xdg }, 'stop')).stopped, true)
  await d.exited
})

test.after(() => cleanup())
