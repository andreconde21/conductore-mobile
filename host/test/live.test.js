'use strict'

// The live store's diffs and lazy changes, and the Herdr-only agents:
// grace period, short-turn hysteresis and de-duplication against the
// sessions the hooks report.

for (const k of Object.keys(process.env)) if (k.startsWith('HERDR_') || k.startsWith('TMUX')) delete process.env[k]

const test = require('node:test')
const assert = require('node:assert')
const { LiveStore, LiveBridge, NEW_AGENT_GRACE_MS, WORKING_HYSTERESIS_MS } = require('../lib/live')

test('replaceServer reports only differences; activity-only changes are lazy', () => {
  const changes = []
  const store = new LiveStore(ch => changes.push(ch))
  const w = (activity, name = 'a') => ({ kind: 'tmuxWindow', server: 'tmux', id: '@1', name, activity })
  store.replaceServer('tmux', new Map([['twin:tmux:$0:@1', w(1)], ['tses:tmux:$0', { kind: 'tmuxSession', server: 'tmux', id: '$0' }]]))
  assert.equal(changes.length, 2)
  store.replaceServer('tmux', new Map([['twin:tmux:$0:@1', w(1)], ['tses:tmux:$0', { kind: 'tmuxSession', server: 'tmux', id: '$0' }]]))
  assert.equal(changes.length, 2)
  store.replaceServer('tmux', new Map([['twin:tmux:$0:@1', w(5)], ['tses:tmux:$0', { kind: 'tmuxSession', server: 'tmux', id: '$0' }]]))
  assert.deepEqual(changes[2], { key: 'twin:tmux:$0:@1', entity: w(5), lazy: true })
  store.replaceServer('tmux', new Map([['twin:tmux:$0:@1', w(6, 'b')]]))
  assert.deepEqual(changes[3], { key: 'tses:tmux:$0', entity: null, lazy: false })
  assert.equal(changes[4].lazy, false)
  // The server record is not the server's entity set.
  store.set('srv:tmux', { kind: 'server', id: 'tmux' })
  store.replaceServer('tmux', new Map())
  assert.ok(store.get('srv:tmux'))
})

function bridge (companion = []) {
  let now = 1000000
  const out = []
  const b = new LiveBridge({ onChange: r => out.push(r), companionAgents: () => companion, now: () => now, makeHerdr: () => ({ start () {}, stop () {} }), makeTmux: () => ({ start () {}, stop () {} }) })
  // Like the store's own change hook, which recomputes on every pane change.
  const pane = (id, status, extra = {}) => {
    b.store.set(`pane:herdr:${id}`, { kind: 'pane', server: 'herdr', id, workspaceId: 'w1', tabId: 'w1:t1', focused: false, title: 'fix tests', cwd: '/work/api', agent: 'codex', agentStatus: status, name: null, sessionId: null, seq: 1, ...extra })
    b.recomputeAgents()
  }
  return { b, out, pane, tick: ms => { now += ms; b.recomputeAgents() }, agents: () => out.filter(r => r.agent !== undefined) }
}

test('a Herdr-only agent shows after the grace period, with its kind', () => {
  const { b, pane, tick, agents } = bridge()
  pane('w1:p1', 'idle')
  b.recomputeAgents()
  assert.equal(agents().length, 0)
  tick(NEW_AGENT_GRACE_MS)
  const [r] = agents()
  assert.equal(r.agent, 'herdr/w1:p1')
  assert.equal(r.record.kind, 'codex')
  assert.equal(r.record.source, 'herdr')
  assert.equal(r.record.state, 'idle')
  assert.equal(r.record.herdr.paneId, 'w1:p1')
})

test('a turn shorter than the hysteresis never shows as working, nor finishes', () => {
  const { b, pane, tick, agents } = bridge()
  pane('w1:p1', 'idle')
  tick(NEW_AGENT_GRACE_MS)
  pane('w1:p1', 'working')
  tick(1000)
  pane('w1:p1', 'done')
  tick(10)
  assert.deepEqual(agents().map(r => r.record.state), ['idle'])
  // A long one does, and its end is published as done.
  pane('w1:p1', 'working')
  tick(10)
  tick(WORKING_HYSTERESIS_MS)
  pane('w1:p1', 'done')
  tick(10)
  assert.deepEqual(agents().map(r => r.record.state), ['idle', 'working', 'done'])
  // Blocked shows at once.
  pane('w1:p1', 'blocked')
  tick(10)
  assert.equal(agents().at(-1).record.state, 'blocked')
})

test('a pane the hooks report (same session or same pane) is never a Herdr-only agent', () => {
  const companion = [{ sessionId: 'claude-1', state: 'working', herdr: { paneId: 'w1:p2', socket: null } }]
  const { pane, tick, agents } = bridge(companion)
  pane('w1:p1', 'working', { agent: 'claude', sessionId: 'claude-1' })
  pane('w1:p2', 'working', { agent: 'claude' })
  pane('w1:p3', 'idle', { agent: 'gemini' })
  tick(NEW_AGENT_GRACE_MS)
  assert.deepEqual(agents().map(r => r.agent), ['herdr/w1:p3'])
  // The session ends: its pane is Herdr's to report again.
  companion[0].state = 'ended'
  tick(1)
  tick(NEW_AGENT_GRACE_MS)
  assert.ok(agents().some(r => r.agent === 'herdr/w1:p2'))
})

test('a pane that closes removes its agent', () => {
  const { b, pane, tick, agents } = bridge()
  pane('w1:p1', 'idle')
  tick(NEW_AGENT_GRACE_MS)
  b.store.remove('pane:herdr:w1:p1')
  tick(1)
  assert.deepEqual(agents().at(-1), { agent: 'herdr/w1:p1', record: null })
})

test('the bridge starts on demand and stops when nobody asked for a while; tmux only when opted in', () => {
  const started = []
  const stopped = []
  let tmuxOn = false
  const b = new LiveBridge({
    makeHerdr: s => ({ start () { started.push(s.id) }, stop () {} }),
    makeTmux: () => ({ start () { started.push('tmux') }, stop () { stopped.push('tmux') } }),
    tmuxEnabled: () => tmuxOn
  })
  process.env.CONDUCTORE_HERDR_SOCKETS = '/nonexistent/h.sock'
  try {
    assert.equal(b.running, false)
    b.touch()
    assert.equal(b.running, true)
    // Off by default: no control client, and the phone is told to poll.
    assert.deepEqual(started, ['herdr'])
    assert.equal(b.store.get('srv:tmux').state, 'off')
    tmuxOn = true
    b.syncTmux()
    assert.deepEqual(started, ['herdr', 'tmux'])
    assert.equal(b.store.get('srv:tmux'), null)
    tmuxOn = false
    b.syncTmux()
    assert.deepEqual(stopped, ['tmux'])
    assert.equal(b.store.get('srv:tmux').state, 'off')
    b.stop()
    assert.equal(b.running, false)
  } finally {
    delete process.env.CONDUCTORE_HERDR_SOCKETS
  }
})
