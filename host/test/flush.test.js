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
