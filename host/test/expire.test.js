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

test('an auto-approved agent carries its process; expiry ends its session rules', { skip: !proc.hasProc() }, async () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'cnd-exp-'))
  const env = { ...process.env, CONDUCTORE_HOME: home, CONDUCTORE_SOCKET: path.join(home, 'hostd.sock'), CONDUCTORE_PERMISSION_TIMEOUT: '30' }
  for (const k of Object.keys(env)) if (/^(TMUX|HERDR_)/.test(k)) delete env[k]
  env.TMUX_TMPDIR = home
  const cli = (...args) => new Promise((resolve, reject) => {
    execFile(process.execPath, [HOSTD, ...args], { env, timeout: 20000 }, (err, stdout) => {
      if (err && err.code === undefined) return reject(err)
      resolve(JSON.parse(stdout.trim().split('\n').pop()))
    })
  })
  // A stand-in Claude Code: runs one hook (through `sh -c`) per stdin line,
  // printing the hook's stdout as one JSON line.
  const script = `
    process.title = 'claude'
    const { spawn } = require('child_process')
    require('readline').createInterface({ input: process.stdin }).on('line', line => {
      const ev = JSON.parse(line)
      const c = spawn("'" + ${JSON.stringify(HOOK)} + "' " + ev.hook_event_name, { shell: true, stdio: ['pipe', 'pipe', 'ignore'] })
      let out = ''
      c.stdout.on('data', d => { out += d })
      c.on('exit', () => process.stdout.write(JSON.stringify({ out }) + '\\n'))
      c.stdin.end(line)
    })`
  const claude = spawn(process.execPath, ['-e', script], { env, stdio: ['pipe', 'pipe', 'ignore'] })
  const replies = require('readline').createInterface({ input: claude.stdout })
  const answers = []
  const waiting = []
  replies.on('line', l => { const r = JSON.parse(l); const w = waiting.shift(); w ? w(r) : answers.push(r) })
  const run = ev => new Promise(resolve => { waiting.push(resolve); claude.stdin.write(JSON.stringify({ session_id: 'k7', cwd: home, ...ev }) + '\n') })
  const read = { hook_event_name: 'PermissionRequest', tool_name: 'Read', tool_input: { file_path: path.join(home, 'notes.txt') } }
  try {
    await run({ hook_event_name: 'SessionStart' })
    const first = run(read)
    let req
    for (let i = 0; i < 100 && !req; i++) {
      await new Promise(r => setTimeout(r, 50))
      const a = (await cli('status')).agents.find(a => a.sessionId === 'k7')
      req = a && a.pending[0]
    }
    const t = await cli('trust', req.id, '--scope', 'session', '--until-session-end')
    assert.equal(t.rule.endsWithSession, 'k7')
    await first
    // Answered by the rule, before the phone sees it.
    const auto = await run(read)
    assert.equal(JSON.parse(auto.out).hookSpecificOutput.decision.behavior, 'allow')
    const agent = (await cli('status')).agents.find(a => a.sessionId === 'k7')
    assert.equal(agent.process.pid, claude.pid)
    assert.ok(agent.lastAutoApprovedAt)
    claude.kill('SIGKILL')
    await new Promise(r => claude.on('exit', r))
    assert.equal((await cli('status')).agents.find(a => a.sessionId === 'k7').state, 'ended')
    assert.ok(!(await cli('rules')).rules.some(r => r.id === t.rule.id))
  } finally {
    claude.kill('SIGKILL')
    await cli('stop').catch(() => {})
    await new Promise(r => setTimeout(r, 200))
    fs.rmSync(home, { recursive: true, force: true })
  }
})
