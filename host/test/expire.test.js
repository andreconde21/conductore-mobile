'use strict'

// Review M20: agents that never send SessionEnd (Claude Code killed, crashed,
// the SSH session dropped, a reboot) must not stay on the phone forever.

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('fs')
const os = require('os')
const path = require('path')
const { spawn, execFile } = require('child_process')
const state = require('../lib/state')
const proc = require('../lib/proc')

const HOSTD = path.join(__dirname, '..', 'bin', 'conductore-hostd')
const HOOK = path.join(__dirname, '..', 'bin', 'conductore-hook')

test('expire ends agents whose process is gone, or silent for too long without one', () => {
  const st = state.createState()
  const t0 = 1_000_000
  for (const sid of ['live', 'dead', 'fresh', 'stale', 'done']) state.reduce(st, { session_id: sid, hook_event_name: 'SessionStart' }, t0)
  st.agents.live.process = { pid: 11, startTime: '5' }
  st.agents.dead.process = { pid: 12, startTime: '5' }
  st.agents.stale.updatedAt = t0 - state.STALE_AFTER_MS - 1
  state.reduce(st, { session_id: 'done', hook_event_name: 'SessionEnd' }, t0)
  const changes = state.expire(st, p => p.pid === 11, t0 + 1000)
  assert.deepEqual(changes.map(c => [c.sessionId, c.reason, c.agent.state]).sort(), [['dead', 'expired', 'ended'], ['stale', 'expired', 'ended']])
  assert.equal(st.agents.dead.endedAt, t0 + 1000)
  assert.equal(st.agents.live.state, 'waiting_input')
  assert.equal(st.agents.fresh.state, 'waiting_input')
  assert.equal(st.agents.done.endedAt, t0)
  assert.deepEqual(state.expire(st, () => false, t0 + 2000).map(c => c.sessionId), ['live'])
})

test('identifyClaude accepts only a Claude Code process and sameProcess tracks it', { skip: !proc.hasProc() }, async () => {
  assert.equal(proc.identifyClaude(process.pid), null) // comm "node"
  assert.equal(proc.identifyClaude('x'), null)
  const fake = spawn(process.execPath, ['-e', 'process.title = "claude"; setInterval(() => {}, 1000)'], { stdio: 'ignore' })
  try {
    let id = null
    for (let i = 0; i < 50 && !id; i++) {
      await new Promise(r => setTimeout(r, 20))
      id = proc.identifyClaude(fake.pid)
    }
    assert.equal(id.pid, fake.pid)
    assert.equal(proc.sameProcess(id), true)
    assert.equal(proc.sameProcess({ ...id, startTime: '1' }), false)
  } finally {
    fake.kill('SIGKILL')
  }
  await new Promise(r => fake.on('exit', r))
})

test('a Claude Code killed without SessionEnd is ended by the daemon', { skip: !proc.hasProc() }, async () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'cnd-exp-'))
  const env = { ...process.env, CONDUCTORE_HOME: home, CONDUCTORE_SOCKET: path.join(home, 'hostd.sock') }
  for (const k of Object.keys(env)) if (/^(TMUX|HERDR_)/.test(k)) delete env[k]
  const cli = (...args) => new Promise((resolve, reject) => {
    execFile(process.execPath, [HOSTD, ...args], { env, timeout: 20000 }, (err, stdout) => {
      if (err && err.code === undefined) return reject(err)
      resolve(JSON.parse(stdout.trim().split('\n').pop()))
    })
  })
  // A stand-in Claude Code that runs the hook the way Claude Code does:
  // through `sh -c`, so the hook finds it as its grandparent.
  const script = `
    process.title = 'claude'
    const c = require('child_process').spawn(${JSON.stringify(`'${HOOK}' SessionStart`)}, { shell: true, stdio: ['pipe', 'ignore', 'ignore'] })
    c.stdin.end(JSON.stringify({ session_id: 'k9', cwd: '/work/k9', hook_event_name: 'SessionStart' }))
    c.on('exit', () => process.stdout.write('hooked\\n'))
    setInterval(() => {}, 1000)`
  const claude = spawn(process.execPath, ['-e', script], { env, stdio: ['ignore', 'pipe', 'ignore'] })
  try {
    await new Promise(resolve => claude.stdout.once('data', resolve))
    let agent
    for (let i = 0; i < 100; i++) {
      agent = (await cli('status')).agents.find(a => a.sessionId === 'k9')
      if (agent) break
      await new Promise(r => setTimeout(r, 50))
    }
    assert.equal(agent.state, 'waiting_input')
    assert.equal(agent.process.pid, claude.pid)
    claude.kill('SIGKILL')
    await new Promise(r => claude.on('exit', r))
    const after = (await cli('status')).agents.find(a => a.sessionId === 'k9')
    assert.equal(after.state, 'ended')
    assert.equal(after.lastEvent, 'SessionStart')
  } finally {
    claude.kill('SIGKILL')
    await cli('stop').catch(() => {})
    await new Promise(r => setTimeout(r, 200))
    fs.rmSync(home, { recursive: true, force: true })
  }
})
