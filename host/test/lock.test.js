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

test('daemons starting together over a stale lock: one runs and the lock names it', async () => {
  // The hook and the CLI both start a daemon when none answers. The loser
  // once read the winner's lock while it was still empty, took it over and,
  // finding the socket served, removed it: a daemon ran with no hostd.pid.
  for (let round = 0; round < 5; round++) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'cnd-lockr-'))
    const renv = { ...env, CONDUCTORE_HOME: dir, CONDUCTORE_SOCKET: path.join(dir, 'hostd.sock') }
    const squatter = spawn('sleep', ['60'], { stdio: 'ignore' })
    const daemons = []
    try {
      fs.writeFileSync(path.join(dir, 'hostd.pid'), `${squatter.pid}\n`)
      for (let i = 0; i < 6; i++) {
        const d = spawn(process.execPath, [HOSTD, 'daemon'], { env: renv, stdio: 'ignore' })
        d.exited = new Promise(resolve => d.on('exit', resolve))
        daemons.push(d)
      }
      // Every loser exits at once; the winner keeps serving.
      let alive = daemons
      for (let i = 0; i < 100; i++) {
        alive = daemons.filter(d => d.exitCode === null && d.signalCode === null)
        if (alive.length <= 1 && fs.existsSync(renv.CONDUCTORE_SOCKET)) break
        await sleep(50)
      }
      assert.equal(alive.length, 1, `${alive.length} daemons running`)
      assert.equal(parseInt(fs.readFileSync(path.join(dir, 'hostd.pid'), 'utf8'), 10), alive[0].pid)
      assert.deepEqual(fs.readdirSync(dir).filter(n => n.startsWith('hostd.pid')), ['hostd.pid'])
    } finally {
      for (const d of daemons) d.kill()
      await Promise.all(daemons.map(d => d.exited))
      squatter.kill()
      fs.rmSync(dir, { recursive: true, force: true })
    }
  }
})

test.after(async () => {
  await cli('stop').catch(() => {})
  await sleep(200)
  fs.rmSync(home, { recursive: true, force: true })
})
