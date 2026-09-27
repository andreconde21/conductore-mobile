'use strict'

// Review M17: hostd.pid survives reboots and crashes. A stale file whose pid
// now belongs to another live process must not block the daemon.

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('fs')
const os = require('os')
const path = require('path')
const { spawn, execFile } = require('child_process')
const proc = require('../lib/proc')

const HOSTD = path.join(__dirname, '..', 'bin', 'conductore-hostd')
const HOOK = path.join(__dirname, '..', 'bin', 'conductore-hook')
const home = fs.mkdtempSync(path.join(os.tmpdir(), 'cnd-lock-'))
const env = { ...process.env, CONDUCTORE_HOME: home, CONDUCTORE_SOCKET: path.join(home, 'hostd.sock') }
for (const k of Object.keys(env)) if (/^(TMUX|HERDR_)/.test(k)) delete env[k]

const sleep = ms => new Promise(r => setTimeout(r, ms))

function cli (...args) {
  return new Promise((resolve, reject) => {
    execFile(process.execPath, [HOSTD, ...args], { env, timeout: 20000 }, (err, stdout) => {
      if (err && err.code === undefined) return reject(err)
      resolve(JSON.parse(stdout.trim().split('\n').pop()))
    })
  })
}

function hook (event) {
  return new Promise((resolve, reject) => {
    const child = spawn(HOOK, [event.hook_event_name], { env, stdio: ['pipe', 'ignore', 'ignore'] })
    child.on('error', reject)
    child.on('close', resolve)
    child.stdin.end(JSON.stringify(event))
  })
}

test('isDaemon tells a daemon from any other live process', () => {
  assert.equal(proc.isDaemon(process.pid), false)
  assert.equal(proc.isDaemon(2 ** 22 + 12345), false)
  assert.equal(proc.isDaemon(NaN), false)
})

test('a stale hostd.pid holding a live foreign pid does not block the daemon', async () => {
  fs.mkdirSync(path.join(home, 'spool'), { recursive: true })
  const squatter = spawn('sleep', ['60'], { stdio: 'ignore' })
  try {
    fs.writeFileSync(path.join(home, 'hostd.pid'), `${squatter.pid}\n`)
    await hook({ session_id: 'k1', cwd: '/work/k1', hook_event_name: 'SessionStart' })
    let st
    for (let i = 0; i < 100; i++) {
      st = await cli('status')
      if (st.source === 'daemon') break
      await sleep(50)
    }
    assert.equal(st.source, 'daemon')
    assert.deepEqual(st.agents.map(a => a.sessionId), ['k1'])
    const pid = parseInt(fs.readFileSync(path.join(home, 'hostd.pid'), 'utf8'), 10)
    assert.notEqual(pid, squatter.pid)
    assert.equal(proc.isDaemon(pid), true)
    if (proc.hasProc()) assert.equal(fs.readFileSync(`/proc/${pid}/comm`, 'utf8').trim(), 'conductore-host')
    // The live daemon itself still holds the lock: a second one exits.
    const second = await new Promise(resolve => {
      execFile(process.execPath, [HOSTD, 'daemon'], { env, timeout: 10000 }, err => resolve(err ? err.code : 0))
    })
    assert.equal(second, 0)
    assert.equal(parseInt(fs.readFileSync(path.join(home, 'hostd.pid'), 'utf8'), 10), pid)
  } finally {
    squatter.kill()
  }
})

test.after(async () => {
  await cli('stop').catch(() => {})
  await sleep(200)
  fs.rmSync(home, { recursive: true, force: true })
})
