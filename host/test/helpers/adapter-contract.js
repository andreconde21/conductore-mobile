'use strict'

// The contract every agent adapter must pass (lib/adapters/types.js). A
// test file per adapter runs it with fixtures of its agent:
//
//   const { contract } = require('./helpers/adapter-contract')
//   for (const c of contract(adapter, fixtures)) test(`codex: ${c.name}`, c.fn)
//
// fixtures:
//   events      spool entries of one session, in order ({ header, body }):
//               at least a prompt, a tool call, a permission request (when
//               the agent has approvals) and a turn end
//   sessionId   the session those events belong to
//   agent       an agent record whose transcript is a fixture file
//   missing     an agent record whose transcript does not exist
//   emptyDir    a directory with nothing in it (PATH and HOME for the brain)

const assert = require('node:assert/strict')
const state = require('../../lib/state')
const registry = require('../../lib/adapters')
const items = require('../../lib/adapters/chat-items')

const EVENTS = new Set(['SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'PostToolUseFailure', 'PermissionRequest', 'PermissionDenied', 'Notification', 'Stop', 'StopFailure', 'SubagentStop', 'SessionEnd'])
const APPROVALS = ['hook', 'server', 'observe', 'none']
const CHAT = ['entries', 'items', false]

const clone = v => JSON.parse(JSON.stringify(v))

function contract (adapter, fixtures) {
  const caps = () => adapter.capabilities()
  const normalized = () => fixtures.events.map(e => adapter.normalize(clone(e.body), { kind: 'hook', ...e.header })).filter(Boolean)
  const checks = [
    ['is registered under its id', () => {
      assert.match(adapter.id, /^[a-z][a-z0-9-]{0,31}$/)
      assert.equal(registry.get(adapter.id), adapter)
      assert.equal(typeof adapter.label, 'string')
      assert.ok(adapter.label.length > 0)
    }],
    ['reports its capabilities', () => {
      const c = caps()
      assert.equal(typeof c.events, 'string')
      assert.ok(APPROVALS.includes(c.approvals), `approvals ${c.approvals}`)
      assert.ok(CHAT.includes(c.chat), `chat ${c.chat}`)
      for (const k of ['always', 'questions', 'plans', 'liveUsage', 'limits', 'history', 'brain', 'brainSchema', 'undo']) assert.equal(typeof c[k], 'boolean', k)
      assert.ok(c.send === false || typeof c.send === 'string')
      assert.ok(c.interrupt === false || typeof c.interrupt === 'string')
      assert.ok(c.accounts === null || typeof c.accounts === 'string')
      assert.ok(['full', 'partial', 'none'].includes(c.facts))
      assert.deepEqual(registry.capabilityMap()[adapter.id], { label: adapter.label, ...c })
      // Every flag matches what the module has.
      assert.equal(c.brain, !!adapter.brain)
      assert.equal(!!c.chat, typeof adapter.readTranscript === 'function')
      assert.equal(c.approvals === 'hook', typeof adapter.hookAnswer === 'function')
      assert.equal(c.accounts !== null, typeof adapter.accounts === 'function')
      assert.equal(c.liveUsage, typeof adapter.liveUsage === 'function')
    }],
    ['normalizes its events into the daemon vocabulary', () => {
      const out = normalized()
      assert.ok(out.length >= 3, 'the fixture session yields events')
      for (const e of out) {
        assert.equal(e.agent_kind, adapter.id)
        assert.equal(typeof e.session_id, 'string')
        assert.ok(EVENTS.has(e.hook_event_name), `unknown event ${e.hook_event_name}`)
        if (e.tool_kind !== undefined) assert.ok(items.TOOL_KINDS.includes(e.tool_kind))
      }
      // Garbage never throws.
      for (const junk of [null, [], 'x', 42, {}]) adapter.normalize(junk, { kind: 'hook' })
    }],
    ['drives the state machine to an agent of its kind', () => {
      const st = state.createState()
      let t = 1000
      const seen = new Set()
      for (const e of normalized()) {
        if (state.reduce(st, e, t++).length) seen.add(e.hook_event_name)
      }
      const agent = st.agents[fixtures.sessionId]
      assert.ok(agent, 'the session became an agent')
      assert.equal(agent.kind, adapter.id)
      assert.ok(['working', 'waiting_input', 'needs_permission', 'ended'].includes(agent.state))
      if (caps().approvals !== 'none') assert.ok(seen.has('PermissionRequest'), 'the fixtures include a permission request')
    }],
    ['answers a waiting hook in one line', () => {
      if (caps().approvals !== 'hook') return
      const request = normalized().find(e => e.hook_event_name === 'PermissionRequest')
      for (const decision of ['allow', 'deny', 'always']) {
        const line = adapter.hookAnswer(clone(request), decision, 'no')
        assert.equal(typeof line, 'string')
        assert.ok(line.endsWith('\n') && line.indexOf('\n') === line.length - 1, 'exactly one line')
        assert.ok(line.trim().length > 0, `${decision} says something`)
        JSON.parse(line)
      }
      assert.equal(adapter.hookAnswer(clone(request), 'timeout'), '\n')
    }],
    ['maps tool names to known kinds', () => {
      if (!adapter.toolKind) return
      for (const name of ['', 'x', 'Bash', 'mcp__a__b', null, 'exec_command']) assert.ok(items.TOOL_KINDS.includes(adapter.toolKind(name)), String(name))
    }],
    ['reads a transcript page', () => {
      const c = caps()
      if (!c.chat) return
      const page = adapter.readTranscript(fixtures.agent, {})
      assert.equal(page.error, undefined, page.error)
      if (c.chat === 'items') {
        assert.equal(items.validatePage(page), null)
        assert.ok(page.items.length > 0)
        const next = adapter.readTranscript(fixtures.agent, { cursor: page.cursor })
        assert.equal(items.validatePage(next), null)
      } else {
        assert.ok(Array.isArray(page.entries) && page.entries.length > 0)
        assert.equal(typeof page.offset, 'number')
      }
      const missing = adapter.readTranscript(fixtures.missing, {})
      assert.equal(typeof missing.error, 'string')
    }],
    ['reads a dashboard tail', () => {
      if (!adapter.readTail) return
      const tail = adapter.readTail(fixtures.agent, { since: 0, repliesSince: 0, runsSince: 0 })
      assert.ok(tail && Array.isArray(tail.prompts) && Array.isArray(tail.replies))
      // No transcript: nothing, or an empty tail.
      const none = adapter.readTail(fixtures.missing, { since: 0, repliesSince: 0, runsSince: 0 })
      assert.ok(none === null || (none.prompts.length === 0 && none.replies.length === 0))
    }],
    ['never mistakes another process for its agent', () => {
      if (!adapter.identifyProcess) return
      assert.equal(adapter.identifyProcess(process.pid), null)
      assert.equal(adapter.identifyProcess('x'), null)
      assert.equal(adapter.identifyProcess(1), null)
    }],
    ['has a brain only where its binary is', () => {
      if (!adapter.brain) return
      assert.equal(typeof adapter.brain.missing.error, 'string')
      assert.equal(typeof adapter.brain.missing.message, 'string')
      assert.equal(adapter.brain.locate({ PATH: fixtures.emptyDir, HOME: fixtures.emptyDir }), null)
    }],
    ['reads live usage defensively', () => {
      if (!adapter.liveUsage) return
      for (const junk of [{}, { session_id: 's' }]) {
        const u = adapter.liveUsage(junk)
        assert.ok(u === null || typeof u === 'object')
      }
    }]
  ]
  return checks.map(([name, fn]) => ({ name, fn }))
}

module.exports = { contract, EVENTS }
