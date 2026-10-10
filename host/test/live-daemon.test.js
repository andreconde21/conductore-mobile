'use strict'

// The live bridge inside a real daemon: nothing starts without a flag, the
// flags bring entities and Herdr-only agents, pollers only get what they
// asked for, and a hook-reported session hides its Herdr twin. Herdr is
// the fake server; tmux has no server (a socket path that does not exist).

for (const k of Object.keys(process.env)) if (k.startsWith('HERDR_') || k.startsWith('TMUX')) delete process.env[k]

const test = require('node:test')
const assert = require('node:assert')
const fs = require('fs')
const path = require('path')
const { execFile, spawn } = require('child_process')
const { tempDir, cleanup } = require('./helpers/cleanup')
const { FakeHerdr } = require('./helpers/fake-herdr')

const HOSTD = path.join(__dirname, '..', 'bin', 'conductore-hostd')
const HOOK = path.join(__dirname, '..', 'bin', 'conductore-hook')
const home = tempDir('hl-ld-')
const fake = new FakeHerdr(path.join(home, 'h.sock'))
// The daemon's `herdr pane list` (hook enrichment) never reaches a real
// Herdr: this one knows nothing.
const fakeBin = tempDir('hl-ld-bin-')
fs.writeFileSync(path.join(fakeBin, 'herdr'), '#!/bin/sh\nexit 1\n', { mode: 0o755 })
const env = {
  ...process.env,
  PATH: `${fakeBin}:${process.env.PATH}`,
  CONDUCTORE_HOME: home,
  CONDUCTORE_SOCKET: path.join(home, 'd.sock'),
  CONDUCTORE_CLAUDE_SETTINGS: path.join(home, 'settings.json'),
  CONDUCTORE_HERDR_SOCKETS: fake.socket,
  CONDUCTORE_TMUX_SOCKET: path.join(home, 'no-tmux', 'default'),
  TMUX_TMPDIR: tempDir('hl-ld-tmux-')
}

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms))
function cli (...args) {
  return new Promise(resolve => execFile(process.execPath, [HOSTD, ...args], { env, timeout: 30000 }, (err, stdout) => resolve({ err, lines: String(stdout).split('\n').filter(Boolean).map(l => JSON.parse(l)) })))
}
async function until (fn, ms = 10000) {
  for (let t = 0; t < ms; t += 100) {
    const v = await fn()
    if (v) return v
    await sleep(100)
  }
  return fn()
}
function hook (event, extra = {}) {
  return new Promise(resolve => {
    const child = spawn(HOOK, [event.hook_event_name], { env: { ...env, ...extra }, stdio: ['pipe', 'ignore', 'ignore'] })
    child.on('exit', resolve)
    child.stdin.end(JSON.stringify(event))
  })
}

test.before(() => fake.start())
test.after(async () => {
  await cli('stop')
  await fake.stop()
  await cleanup()
})

test('without a flag the bridge never starts', async () => {
  const [st] = (await cli('status')).lines
  assert.equal(st.live, undefined)
  await hook({ session_id: 'boot', cwd: '/work', hook_event_name: 'SessionStart' })
  const [again] = (await cli('status')).lines
  assert.ok(again.capabilities.includes('live'))
  await sleep(300)
  assert.equal(fake.requests.length, 0)
})

test('status --live brings Herdr as entities, and events deliver changes only to live pollers', async () => {
  const st = await until(async () => {
    const [s] = (await cli('status', '--live')).lines
    return s.live && s.live.entities['pane:herdr:w1:p1'] ? s : null
  })
  assert.equal(st.live.entities['srv:herdr'].state, 'up')
  // tmux-live is off by default: no control client, the phone polls tmux.
  assert.equal(st.live.entities['srv:tmux'].state, 'off')
  assert.equal(st.live.entities['ws:herdr:w1'].label, 'alpha')
  const [now] = (await cli('status', '--live')).lines
  const since = now.seq
  const plain = cli('events', '--since', String(since), '--timeout', '3')
  const live = cli('events', '--since', String(since), '--timeout', '10', '--live', '--only', 'live')
  await sleep(700)
  fake.setStatus('w1:p1', 'working')
  const liveLines = (await live).lines
  const pane = liveLines.find(l => l.type === 'live' && l.key === 'pane:herdr:w1:p1')
  assert.ok(pane, JSON.stringify(liveLines))
  assert.equal(pane.entity.agentStatus, 'working')
  assert.ok(pane.seq > since)
  assert.deepEqual((await plain).lines.map(l => l.type), ['timeout'])
})

test('a Herdr-only agent appears with --herdr-agents, and hides once its hooks report it', async () => {
  const withAgent = await until(async () => {
    const [s] = (await cli('status', '--herdr-agents')).lines
    return s.agents.find(a => a.sessionId === 'herdr/w1:p1') ? s : null
  })
  const agent = withAgent.agents.find(a => a.sessionId === 'herdr/w1:p1')
  assert.equal(agent.source, 'herdr')
  assert.equal(agent.kind, 'codex')
  const [plain] = (await cli('status')).lines
  assert.equal(plain.agents.some(a => a.source === 'herdr'), false)
  // The pane's agent turns out to be a Claude session the hooks know.
  fake.state.panes[0].agent_session = { value: 'claude-7' }
  fake.state.panes[0].agent = 'claude'
  fake.emit('pane.updated', { pane: fake.state.panes[0] })
  await hook({ session_id: 'claude-7', cwd: '/work', hook_event_name: 'SessionStart' })
  const gone = await until(async () => {
    const [s] = (await cli('status', '--herdr-agents')).lines
    return s.agents.some(a => a.sessionId === 'herdr/w1:p1') ? null : s
  })
  assert.ok(gone.agents.some(a => a.sessionId === 'claude-7'))
})

test('an agent in a Herdr pane is named after its workspace, and follows a rename (CON-116)', async () => {
  const where = { HERDR_WORKSPACE_ID: 'w1', HERDR_TAB_ID: 'w1:t1', HERDR_PANE_ID: 'w1:p1', HERDR_SOCKET_PATH: fake.socket }
  await hook({ session_id: 'ws-1', cwd: '/root', hook_event_name: 'SessionStart' }, where)
  const named = await until(async () => {
    const [s] = (await cli('status', '--herdr-agents')).lines
    const a = s.agents.find(a => a.sessionId === 'ws-1')
    return a && a.name === 'alpha' ? a : null
  })
  assert.ok(named, 'named after the workspace')
  assert.equal(named.herdr.workspaceLabel, 'alpha')
  assert.equal(named.cwd, '/root')
  const [now] = (await cli('status', '--herdr-agents')).lines
  const poll = cli('events', '--since', String(now.seq), '--timeout', '10', '--herdr-agents')
  await sleep(500)
  fake.state.workspaces[0].label = 'Infrastructure'
  fake.emit('workspace.renamed', { workspace_id: 'w1', label: 'Infrastructure' })
  const lines = (await poll).lines
  const renamed = lines.find(l => l.sessionId === 'ws-1')
  assert.ok(renamed, JSON.stringify(lines))
  assert.equal(renamed.agent.name, 'Infrastructure')
  // The next hook event knows only the workspace id: the name stays.
  await hook({ session_id: 'ws-1', cwd: '/root', hook_event_name: 'UserPromptSubmit', prompt: 'hi' }, where)
  const [plain] = (await cli('status')).lines
  const after = plain.agents.find(a => a.sessionId === 'ws-1')
  assert.equal(after.state, 'working')
  assert.equal(after.name, 'Infrastructure')
})

test('tmux-live on starts the tmux watch (no server here: none); off again stops it', async () => {
  await cli('config', 'set', 'tmux-live', 'on')
  const on = await until(async () => {
    const [s] = (await cli('status', '--live')).lines
    return s.live.entities['srv:tmux'] && s.live.entities['srv:tmux'].state === 'none' ? s : null
  })
  assert.ok(on)
  await cli('config', 'set', 'tmux-live', 'off')
  const off = await until(async () => {
    const [s] = (await cli('status', '--live')).lines
    return s.live.entities['srv:tmux'].state === 'off' ? s : null
  })
  assert.ok(off)
})

test('the bridge only ever read from Herdr', () => {
  const methods = new Set(fake.requests.map(r => r.method))
  for (const m of methods) assert.ok(['ping', 'session.snapshot', 'events.subscribe'].includes(m), m)
})
