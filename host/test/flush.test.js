'use strict'

// The daemon's state files (state.json, activity.json, turns.json) are
// written at most once per FLUSH_EVERY_MS during a burst of events, and
// what is on disk after the burst (and on shutdown) is the current state.
// An in-process daemon (never started: no socket, no lock) in a temp home.

for (const k of Object.keys(process.env)) if (k.startsWith('HERDR_') || k.startsWith('TMUX')) delete process.env[k]

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('fs')
const path = require('path')
const { tempDir, cleanup } = require('./helpers/cleanup')

const root = tempDir('cnd-flush-')
process.env.CONDUCTORE_HOME = path.join(root, 'state')
process.env.CONDUCTORE_SOCKET = path.join(root, 'none.sock')
process.env.HOME = path.join(root, 'home')
process.env.TMUX_TMPDIR = root
process.env.CONDUCTORE_HERDR_SOCKETS = ''
delete process.env.CONDUCTORE_FLUSH_MS

const paths = require('../lib/paths')
const { Daemon, FLUSH_EVERY_MS } = require('../lib/daemon')

test.after(() => cleanup())

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms))

test('a burst of events writes the state files at most once per flush interval, and the last write is current', async () => {
  paths.ensureDirs()
  const d = new Daemon()
  const writes = { state: 0, activity: 0 }
  const rename = fs.renameSync
  fs.renameSync = (from, to) => {
    if (to === paths.statePath()) writes.state++
    if (to === paths.activityPath()) writes.activity++
    return rename(from, to)
  }
  try {
    const event = (name, extra = {}) => d.process({ header: { kind: 'hook' }, body: { session_id: 'f1', hook_event_name: name, cwd: root, ...extra } })
    await event('SessionStart')
    await event('UserPromptSubmit', { prompt: 'go' })
    const started = Date.now()
    const window = FLUSH_EVERY_MS + 300
    let n = 0
    while (Date.now() - started < window) {
      await event(n % 2 ? 'PostToolUse' : 'PreToolUse', { tool_name: 'Bash', tool_input: { command: `echo ${n}` } })
      n++
      await sleep(40)
    }
    // One flush SNAPSHOT_DEBOUNCE_MS into the burst, the next one no
    // sooner than FLUSH_EVERY_MS after it: two at most in this window.
    assert.ok(writes.state <= 2, `state.json written ${writes.state} times in ${window} ms (${n} events)`)
    assert.ok(writes.activity <= 2, `activity.json written ${writes.activity} times in ${window} ms`)
    assert.ok(writes.state >= 1, 'written during the burst')
    // After the burst the pending flush writes the current state.
    await sleep(FLUSH_EVERY_MS + 200)
    const onDisk = JSON.parse(fs.readFileSync(paths.statePath(), 'utf8'))
    assert.equal(onDisk.seq, d.state.seq)
    // Nothing changed: no rewrite.
    const before = writes.state
    d.flushSnapshot()
    assert.equal(writes.state, before, 'an unchanged state is not rewritten')
    // A change, then shutdown's flush: on disk at once.
    await event('Stop')
    d.flushSnapshot()
    assert.equal(JSON.parse(fs.readFileSync(paths.statePath(), 'utf8')).agents.find(a => a.sessionId === 'f1').state, 'waiting_input')
  } finally {
    fs.renameSync = rename
    clearTimeout(d.snapshotTimer)
    clearTimeout(d.pruneTimer)
    clearInterval(d.probeTimer)
    d.live.stop()
    d.sidebar.stop()
  }
})

test("the phone's polls do not restart the idle exit; hook activity, user ops and --live do", async () => {
  const { PassThrough } = require('stream')
  process.env.CONDUCTORE_HERDR_SOCKETS = path.join(root, 'no-herdr.sock')
  const d = new Daemon()
  let touched = 0
  d.touch = () => { touched++ }
  const ask = async req => {
    const c = new PassThrough()
    c.resume()
    const before = touched
    await d.handle(req, c)
    c.destroy()
    await new Promise(resolve => setImmediate(resolve))
    return touched - before
  }
  try {
    assert.equal(await ask({ op: 'ping' }), 0)
    assert.equal(await ask({ op: 'status' }), 0)
    assert.equal(await ask({ op: 'status', herdrAgents: true }), 0, 'the agent monitor poll')
    assert.equal(await ask({ op: 'events', timeout: 0 }), 0)
    assert.equal(await ask({ op: 'events', herdrAgents: true, timeout: 0 }), 0)
    assert.equal(d.live.running, true, 'herdr-agents still gets its bridge')
    assert.equal(d.live.liveWanted(), false, 'but not the live one')
    assert.equal(await ask({ op: 'status', live: true }), 1, 'a live screen is a person looking')
    assert.equal(await ask({ op: 'config' }), 1)
    await d.process({ header: { kind: 'hook' }, body: { session_id: 'i1', hook_event_name: 'SessionStart', cwd: root } })
    assert.ok(touched >= 2, 'hook activity')
  } finally {
    delete process.env.CONDUCTORE_HERDR_SOCKETS
    clearTimeout(d.snapshotTimer)
    clearTimeout(d.pruneTimer)
    d.live.stop()
    d.sidebar.stop()
  }
})

test('an idle restart keeps the agents (state.json), and never happens while a request is pending', async () => {
  const { PassThrough } = require('stream')
  process.env.CONDUCTORE_IDLE_EXIT_S = '0.05'
  const d = new Daemon()
  let exits = 0
  d.shutdown = () => { exits++ }
  try {
    const event = (body) => d.process({ header: { kind: 'hook' }, body: { cwd: root, ...body } })
    await event({ session_id: 'r1', hook_event_name: 'SessionStart' })
    await event({ session_id: 'r1', hook_event_name: 'UserPromptSubmit', prompt: 'go' })
    // A watched (observe-only) pending request, as Gemini and Cursor report.
    d.state.agents.r1.pending = [{ id: 'q1', toolName: 'Bash', summary: 'make', createdAt: Date.now() }]
    d.touch()
    await sleep(250)
    assert.equal(exits, 0, 'no idle exit while a request waits')
    d.state.agents.r1.pending = []
    d.touch()
    await sleep(250)
    assert.equal(exits, 1, 'idle exit once nothing waits')
    // What the next daemon starts from: the shutdown flush.
    d.flushSnapshot()
    const next = new Daemon()
    assert.equal(next.state.agents.r1.state, 'working')
    assert.equal(next.state.seq, d.state.seq)
    const c = new PassThrough()
    let reply = ''
    c.on('data', b => { reply += b })
    await next.handle({ op: 'status' }, c)
    assert.ok(JSON.parse(reply.split('\n')[0]).agents.some(a => a.sessionId === 'r1'), 'the phone sees the agent after the restart')
    next.live.stop()
    next.sidebar.stop()
  } finally {
    delete process.env.CONDUCTORE_IDLE_EXIT_S
    clearTimeout(d.idleTimer)
    clearTimeout(d.snapshotTimer)
    clearTimeout(d.pruneTimer)
    d.live.stop()
    d.sidebar.stop()
  }
})
