'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const state = require('../lib/state')

const ev = (hook_event_name, extra = {}) => ({ session_id: 's1', cwd: '/home/u/proj', hook_event_name, ...extra })

function fresh (...events) {
  const st = state.createState()
  let t = 1000
  for (const e of events) state.reduce(st, e, t++)
  return st
}

test('SessionStart creates a waiting agent named after cwd', () => {
  const st = fresh(ev('SessionStart', { source: 'startup' }))
  const a = st.agents.s1
  assert.equal(a.state, 'waiting_input')
  assert.equal(a.name, 'proj')
  assert.equal(a.cwd, '/home/u/proj')
  assert.equal(st.seq, 1)
})

test('prompt -> tool use -> stop walks working then waiting_input', () => {
  const st = fresh(
    ev('SessionStart'),
    ev('UserPromptSubmit', { prompt: 'do it' }),
    ev('PreToolUse', { tool_name: 'Bash', tool_input: { command: 'ls' } }),
    ev('PostToolUse', { tool_name: 'Bash', tool_input: { command: 'ls' }, tool_response: {} })
  )
  assert.equal(st.agents.s1.state, 'working')
  assert.equal(st.agents.s1.lastToolName, 'Bash')
  state.reduce(st, ev('Stop', { last_assistant_message: 'All done.' }))
  assert.equal(st.agents.s1.state, 'waiting_input')
  assert.equal(st.agents.s1.lastMessage, 'All done.')
  assert.equal(st.seq, 5)
})

test('PermissionRequest adds a pending request with a one-line summary', () => {
  const st = fresh(ev('UserPromptSubmit'), ev('PermissionRequest', {
    request_id: 'r1',
    tool_name: 'Bash',
    tool_input: { command: 'git   status\n--short', description: 'status' }
  }))
  const a = st.agents.s1
  assert.equal(a.state, 'needs_permission')
  assert.equal(a.pending.length, 1)
  assert.equal(a.pending[0].id, 'r1')
  assert.equal(a.pending[0].summary, 'git status --short')
  assert.deepEqual(a.pending[0].toolInput, { command: 'git   status\n--short', description: 'status' })
})

test('summary truncates to 200 chars and tool input caps at 4 KB', () => {
  const long = 'x'.repeat(10000)
  const st = fresh(ev('PermissionRequest', { request_id: 'r1', tool_name: 'Write', tool_input: { file_path: '/tmp/a', content: long } }))
  const p = st.agents.s1.pending[0]
  assert.equal(p.summary, '/tmp/a')
  assert.equal(p.toolInput._truncated, true)
  assert.ok(p.toolInput.preview.length <= 4096)
  assert.ok(state.summarize('Bash', { command: long }).length <= 200)
})

test('decision resolves pending and returns to working; timeout keeps needs_permission', () => {
  const st = fresh(ev('PermissionRequest', { request_id: 'r1', tool_name: 'Bash', tool_input: { command: 'ls' } }))
  const changes = state.resolvePermission(st, 'r1', 'allow')
  assert.equal(changes.length, 1)
  assert.equal(changes[0].reason, 'decision:allow')
  assert.equal(st.agents.s1.state, 'working')
  assert.equal(st.agents.s1.pending.length, 0)
  assert.equal(state.resolvePermission(st, 'nope', 'allow').length, 0)

  state.reduce(st, ev('PermissionRequest', { request_id: 'r2', tool_name: 'Edit', tool_input: { file_path: '/a' } }))
  state.resolvePermission(st, 'r2', 'timeout')
  assert.equal(st.agents.s1.state, 'needs_permission')
  // It stays, answerable in the terminal only (CON-096).
  assert.equal(st.agents.s1.pending.length, 1)
  assert.equal(st.agents.s1.pending[0].expired, true)
  assert.equal(st.agents.s1.pending[0].answerable, false)
  assert.match(st.agents.s1.lastMessage, /terminal/)
  // Another call of the same tool (a parallel one) leaves it.
  state.reduce(st, ev('PostToolUse', { tool_name: 'Edit', tool_input: { file_path: '/b' }, tool_response: {} }))
  assert.equal(st.agents.s1.pending.length, 1)
  assert.equal(st.agents.s1.state, 'needs_permission')
  // This call's PostToolUse: answered in the terminal.
  state.reduce(st, ev('PostToolUse', { tool_name: 'Edit', tool_input: { file_path: '/a' }, tool_response: {} }))
  assert.equal(st.agents.s1.pending.length, 0)
  assert.equal(st.agents.s1.state, 'working')
})

test('an expired request ends with the turn, a refusal or a new prompt (CON-096)', () => {
  for (const [end, extra] of [['Stop', {}], ['PermissionDenied', { tool_name: 'Bash' }], ['UserPromptSubmit', {}]]) {
    const st = fresh(ev('PermissionRequest', { request_id: 'r1', tool_name: 'Bash', tool_input: { command: 'ls' } }))
    state.resolvePermission(st, 'r1', 'timeout')
    assert.equal(st.agents.s1.pending.length, 1, end)
    state.reduce(st, ev(end, extra))
    assert.equal(st.agents.s1.pending.length, 0, end)
  }
})

test('sameCall: same tool, the request input within the call input (CON-096)', () => {
  const q = { questions: [{ question: 'A?', options: [{ label: 'x' }] }] }
  const req = { tool_name: 'AskUserQuestion', tool_input: q }
  assert.ok(state.sameCall(req, { tool_name: 'AskUserQuestion', tool_input: { ...q, answers: { 'A?': 'x' } } }))
  assert.ok(!state.sameCall(req, { tool_name: 'AskUserQuestion', tool_input: { questions: [{ question: 'B?', options: [{ label: 'x' }] }] } }))
  assert.ok(!state.sameCall(req, { tool_name: 'Bash', tool_input: q }))
  assert.ok(state.sameCall({ tool_name: 'Bash', tool_input: { command: 'ls' } }, { tool_name: 'Bash', tool_input: { command: 'ls', description: 'List' } }))
  assert.ok(!state.sameCall({ tool_name: 'Bash', tool_input: { command: 'ls' } }, { tool_name: 'Bash', tool_input: { command: 'ls -a' } }))
  assert.ok(!state.within([1, 2], [1, 2, 3]))
  assert.ok(!state.sameCall(null, { tool_name: 'Bash' }))
})

test('a request answered in the terminal after the turn ended leaves the agent idle, not working', () => {
  const st = fresh(
    ev('PermissionRequest', { request_id: 'r1', tool_name: 'Bash', tool_input: { command: 'ls' } }),
    ev('PostToolUse', { tool_name: 'Bash', tool_input: {}, tool_response: {} }),
    ev('Stop', { last_assistant_message: 'Done.' })
  )
  // The daemon notices the hook is gone only after the Stop.
  state.resolvePermission(st, 'r1', 'gone')
  assert.equal(st.agents.s1.state, 'waiting_input')
  assert.equal(st.agents.s1.pending.length, 0)
  // Mid-turn, a gone hook still means the agent works on.
  state.reduce(st, ev('UserPromptSubmit'))
  state.reduce(st, ev('PermissionRequest', { request_id: 'r2', tool_name: 'Bash', tool_input: { command: 'ls' } }))
  state.resolvePermission(st, 'r2', 'gone')
  assert.equal(st.agents.s1.state, 'working')
})

test('two pending requests: resolving one keeps needs_permission', () => {
  const st = fresh(
    ev('PermissionRequest', { request_id: 'r1', tool_name: 'Bash', tool_input: { command: 'a' } }),
    ev('PermissionRequest', { request_id: 'r2', tool_name: 'Bash', tool_input: { command: 'b' } })
  )
  state.resolvePermission(st, 'r1', 'deny')
  assert.equal(st.agents.s1.state, 'needs_permission')
  assert.equal(st.agents.s1.pending.length, 1)
  assert.equal(st.agents.s1.pending[0].id, 'r2')
})

test('Notification idle_prompt and permission_prompt set states; other types only record message', () => {
  const st = fresh(ev('UserPromptSubmit'), ev('Notification', { notification_type: 'idle_prompt', message: 'Waiting for input' }))
  assert.equal(st.agents.s1.state, 'waiting_input')
  assert.equal(st.agents.s1.lastMessage, 'Waiting for input')
  state.reduce(st, ev('Notification', { notification_type: 'permission_prompt', message: 'Needs permission' }))
  assert.equal(st.agents.s1.state, 'needs_permission')
  state.reduce(st, ev('UserPromptSubmit'))
  state.reduce(st, ev('Notification', { notification_type: 'auth_success', message: 'ok' }))
  assert.equal(st.agents.s1.state, 'working')
  assert.equal(st.agents.s1.lastMessage, 'ok')
})

test('AskUserQuestion means waiting_input with the question as message', () => {
  const st = fresh(ev('UserPromptSubmit'), ev('PreToolUse', {
    tool_name: 'AskUserQuestion',
    tool_input: { questions: [{ question: 'Which DB?', options: [] }] }
  }))
  assert.equal(st.agents.s1.state, 'waiting_input')
  assert.equal(st.agents.s1.lastMessage, 'Which DB?')
  state.reduce(st, ev('PostToolUse', { tool_name: 'AskUserQuestion', tool_input: {}, tool_response: {} }))
  assert.equal(st.agents.s1.state, 'working')
})

test('subagent events do not flip the parent to waiting', () => {
  const st = fresh(ev('UserPromptSubmit'), ev('SubagentStop', { agent_id: 'a1', agent_type: 'Explore' }),
    ev('Notification', { agent_id: 'a1', notification_type: 'idle_prompt', message: 'x' }))
  assert.equal(st.agents.s1.state, 'working')
  assert.equal(st.agents.s1.lastEvent, 'Notification')
})

test('SessionEnd ends the agent, prune removes it after an hour', () => {
  const st = fresh(ev('SessionStart'), ev('PermissionRequest', { request_id: 'r1', tool_name: 'Bash', tool_input: { command: 'x' } }))
  state.reduce(st, ev('SessionEnd', { reason: 'other' }), 5000)
  assert.equal(st.agents.s1.state, 'ended')
  assert.equal(st.agents.s1.pending.length, 0)
  assert.equal(st.agents.s1.endedAt, 5000)
  assert.equal(state.prune(st, 5000 + 30 * 60 * 1000).length, 0)
  const removed = state.prune(st, 5000 + 61 * 60 * 1000)
  assert.equal(removed.length, 1)
  assert.equal(removed[0].type, 'remove')
  assert.equal(removed[0].agent, null)
  assert.deepEqual(state.snapshot(st).agents, [])
})

test('tmux and herdr context set location and name; generic window names are ignored', () => {
  const st = fresh(ev('SessionStart', { tmux: { session: 'main', window: 2, paneId: '%5', windowName: 'node' } }))
  assert.deepEqual(st.agents.s1.tmux, { session: 'main', window: 2, paneId: '%5', windowName: 'node' })
  assert.equal(st.agents.s1.name, 'proj')
  state.reduce(st, ev('UserPromptSubmit', { tmux: { session: 'main', window: 2, paneId: '%5', windowName: 'reviewer' } }))
  assert.equal(st.agents.s1.name, 'reviewer')
  state.reduce(st, ev('Stop', { herdr: { workspaceId: 'w1', paneId: 'w1:p1', name: 'fixer' } }))
  assert.equal(st.agents.s1.name, 'fixer')
  assert.equal(st.agents.s1.herdr.paneId, 'w1:p1')
})

test('events without a session id or event name are ignored', () => {
  const st = state.createState()
  assert.equal(state.reduce(st, { cwd: '/x', hook_event_name: 'Stop' }).length, 0)
  assert.equal(state.reduce(st, { session_id: 's' }).length, 0)
  assert.equal(state.reduce(st, null).length, 0)
  assert.equal(st.seq, 0)
})

test('snapshot sorts by most recent and each change carries a full agent copy', () => {
  const st = state.createState()
  state.reduce(st, { session_id: 'a', cwd: '/a', hook_event_name: 'SessionStart' }, 1)
  const [ch] = state.reduce(st, { session_id: 'b', cwd: '/b', hook_event_name: 'SessionStart' }, 2)
  assert.equal(ch.agent.sessionId, 'b')
  ch.agent.name = 'mutated'
  assert.equal(st.agents.b.name, 'b')
  assert.deepEqual(state.snapshot(st).agents.map(a => a.sessionId), ['b', 'a'])
})

test('transcript_path is recorded and kept when later events omit it', () => {
  const st = fresh(
    ev('SessionStart', { transcript_path: '/home/u/.claude/projects/p/s1.jsonl' }),
    ev('UserPromptSubmit', { prompt: 'x' })
  )
  assert.equal(st.agents.s1.transcriptPath, '/home/u/.claude/projects/p/s1.jsonl')
  assert.equal(fresh(ev('Stop')).agents.s1.transcriptPath, null)
})

test('names drop Claude title glyphs; a bare "claude" window falls back to cwd', () => {
  const named = win => fresh(ev('SessionStart', { tmux: { session: 'main', window: 1, paneId: '%1', windowName: win } })).agents.s1.name
  assert.equal(named('⚠ claude'), 'proj')
  assert.equal(named('✳ Fix the tests'), 'Fix the tests')
  assert.equal(named('✻  reviewer'), 'reviewer')
  assert.equal(named('● ◐ api'), 'api')
  assert.equal(named('⚠️ deploy'), 'deploy')
  assert.equal(named('🤖 bot'), 'bot')
  assert.equal(named('⠋ spinner'), 'spinner')
  assert.equal(named('✳'), 'proj')
  assert.equal(named('C++ port'), 'C++ port')
  assert.equal(fresh(ev('SessionStart', { herdr: { paneId: 'w1:p1', name: '✳ builder' } })).agents.s1.name, 'builder')
  assert.equal(state.cleanName('  plain '), 'plain')
})

test('a question PreToolUse spooled after its PermissionRequest keeps the request answerable (CON-062)', () => {
  const input = { questions: [{ question: 'Pick?', options: [{ label: 'A' }, { label: 'B' }] }] }
  const st = fresh(ev('PermissionRequest', { tool_name: 'AskUserQuestion', tool_input: input }), ev('PreToolUse', { tool_name: 'AskUserQuestion', tool_input: input }))
  const a = st.agents.s1
  assert.equal(a.state, 'needs_permission')
  assert.equal(a.pending.length, 1)
  assert.equal(a.pending[0].summary, 'Pick?')
  assert.deepEqual(a.pending[0].questions, [{ question: 'Pick?', kind: 'choice', multiSelect: false, options: [{ label: 'A' }, { label: 'B' }] }])
})
