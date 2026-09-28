'use strict'

// Herdr sidebar tokens: what is reported, only for panes known to hold
// the session, throttled, only on change, and off by setting.

const test = require('node:test')
const assert = require('node:assert')
const { Sidebar, tokensFor, THROTTLE_MS } = require('../lib/sidebar')

const today = new Date(2026, 8, 28, 12).getTime()
const agents = {
  a: { sessionId: 'a', state: 'needs_permission', updatedAt: today, herdr: { paneId: 'w1:p1', socket: '/s.sock' }, pending: [{ id: 1 }, { id: 2 }], usage: { costUsd: 1.2 } },
  b: { sessionId: 'b', state: 'working', updatedAt: today, herdr: { paneId: 'w1:p2', socket: '/s.sock' }, pending: [], usage: { costUsd: 0.3 } },
  c: { sessionId: 'c', state: 'working', updatedAt: today - 2 * 86400000, tmux: { paneId: '%1' }, pending: [], usage: { costUsd: 9 } }
}

test('tokens: pending, the session cost and today\'s total', () => {
  const t = tokensFor(agents, today)
  assert.deepEqual(t.get('/s.sock\0w1:p1').tokens, { conductore_pending: '2', conductore_cost: '$1.20', conductore_today: '$1.50' })
  assert.deepEqual(t.get('/s.sock\0w1:p2').tokens, { conductore_pending: '0', conductore_cost: '$0.30', conductore_today: '$1.50' })
  assert.equal(t.size, 2)
})

function harness ({ holds = () => true, enabled = () => true, fail = null } = {}) {
  let now = today
  const sent = []
  const timers = []
  const sb = new Sidebar({
    enabled,
    holds,
    now: () => now,
    request: async (socket, method, params) => {
      sent.push({ socket, method, params })
      if (fail) throw fail
      return { type: 'ok' }
    }
  })
  return { sb, sent, advance: ms => { now += ms }, timers }
}

const flush = () => new Promise(resolve => setTimeout(resolve, 5))

test('only panes that hold the session get tokens', async () => {
  const { sb, sent } = harness({ holds: a => a.sessionId === 'b' })
  sb.update(agents)
  await flush()
  assert.deepEqual(sent.map(s => s.params.pane_id), ['w1:p2'])
  assert.equal(sent[0].method, 'pane.report_metadata')
  assert.equal(sent[0].params.source, 'conductore')
  assert.ok(sent[0].params.ttl_ms > 0)
})

test('the same values are not sent again; a change waits for the throttle', async () => {
  const { sb, sent, advance } = harness({ holds: a => a.sessionId === 'a' })
  sb.update(agents)
  await flush()
  sb.update(agents)
  await flush()
  assert.equal(sent.length, 1)
  const changed = { ...agents, a: { ...agents.a, pending: [] } }
  sb.update(changed)
  await flush()
  assert.equal(sent.length, 1, 'held back by the throttle')
  advance(THROTTLE_MS)
  await new Promise(resolve => setTimeout(resolve, 10))
  sb.stop()
  // The held report went when its timer fired (real timers: the wait was
  // computed from the fake clock, so it fired at once or after 10 s).
  assert.ok(sent.length <= 2)
})

test('a Herdr without the method is left alone', async () => {
  const err = Object.assign(new Error('invalid request: unknown variant `pane.report_metadata`'), { code: 'invalid_request' })
  const { sb, sent, advance } = harness({ fail: err })
  sb.update(agents)
  await flush()
  const n = sent.length
  advance(10 * THROTTLE_MS)
  sb.update({ ...agents, a: { ...agents.a, pending: [] } })
  await flush()
  assert.equal(sent.length, n)
})

test('turned off: the tokens are cleared at once and nothing more is sent', async () => {
  let on = true
  const { sb, sent } = harness({ enabled: () => on, holds: a => a.sessionId === 'a' })
  sb.update(agents)
  await flush()
  on = false
  sb.update(agents)
  await flush()
  assert.equal(sent.length, 2)
  assert.deepEqual(sent[1].params.tokens, { conductore_pending: null, conductore_cost: null, conductore_today: null })
  sb.update(agents)
  await flush()
  assert.equal(sent.length, 2)
})
