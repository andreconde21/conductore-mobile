'use strict'

// The agent adapter layer (CON-045 step 2): the contract run against the
// Claude Code adapter, proof that Claude Code's output did not change, and
// the registry's extension points (an unknown agent is dropped, a second
// adapter's events become agents of its kind and its hook answers reach the
// waiting hook).

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('fs')
const path = require('path')
const { execFileSync } = require('child_process')
const { tempDir, cleanup } = require('./helpers/cleanup')

const root = tempDir('conductore-adapters-')
const home = path.join(root, 'state')
process.env.CONDUCTORE_HOME = home
process.env.CONDUCTORE_SOCKET = path.join(root, 'none.sock')
const emptyDir = path.join(root, 'empty')
fs.mkdirSync(emptyDir, { recursive: true })

const adapters = require('../lib/adapters')
const claude = require('../lib/adapters/claude')
const chatItems = require('../lib/adapters/chat-items')
const permission = require('../lib/permission')
const transcript = require('../lib/transcript')
const state = require('../lib/state')
const paths = require('../lib/paths')
const summarize = require('../lib/summarize')
const guide = require('../lib/guide')
const digest = require('../lib/digest')
const { contract } = require('./helpers/adapter-contract')

test.after(() => cleanup())

// --- fixtures ----------------------------------------------------------------

const sid = 'c1'
const cwd = '/home/u/proj'
const transcriptFile = path.join(root, 'c1.jsonl')
fs.writeFileSync(transcriptFile, [
  { type: 'user', uuid: 'u1', timestamp: '2026-10-03T10:00:00.000Z', message: { role: 'user', content: 'Fix the tests' } },
  { type: 'assistant', uuid: 'a1', parentUuid: 'u1', timestamp: '2026-10-03T10:00:05.000Z', message: { role: 'assistant', model: 'claude-x', content: [{ type: 'text', text: 'On it.' }, { type: 'tool_use', id: 't1', name: 'Bash', input: { command: 'npm test' } }], usage: { input_tokens: 10, output_tokens: 5 } } },
  { type: 'user', uuid: 'u2', parentUuid: 'a1', timestamp: '2026-10-03T10:00:09.000Z', message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 't1', content: 'ok' }] } },
  { type: 'assistant', uuid: 'a2', parentUuid: 'u2', timestamp: '2026-10-03T10:00:12.000Z', message: { role: 'assistant', model: 'claude-x', content: [{ type: 'text', text: 'All green.' }] } }
].map(l => JSON.stringify(l)).join('\n') + '\n')

const hook = (event, body = {}) => ({ header: { event, claude_pid: '1' }, body: { session_id: sid, cwd, transcript_path: transcriptFile, ...body } })
const events = [
  hook('SessionStart', { source: 'startup' }),
  hook('UserPromptSubmit', { prompt: 'Fix the tests' }),
  hook('PreToolUse', { tool_name: 'Bash', tool_input: { command: 'npm test' } }),
  hook('PermissionRequest', { tool_name: 'Bash', tool_input: { command: 'npm test' }, permission_suggestions: [] }),
  hook('PostToolUse', { tool_name: 'Bash', tool_input: { command: 'npm test' }, tool_response: {} }),
  // The hook name only in argv, as older Claude Code versions sent it.
  { header: { event: 'Stop' }, body: { session_id: sid, last_assistant_message: 'All green.' } }
]

const fixtures = {
  events,
  sessionId: sid,
  agent: { sessionId: sid, kind: 'claude', transcriptPath: transcriptFile },
  missing: { sessionId: 'gone', kind: 'claude', transcriptPath: path.join(root, 'gone.jsonl') },
  emptyDir
}

for (const c of contract(claude, fixtures)) test(`claude adapter contract: ${c.name}`, c.fn)

// --- registry ----------------------------------------------------------------

test('events and records without an agent belong to Claude Code; an unknown agent has no adapter', () => {
  assert.equal(adapters.DEFAULT_KIND, 'claude')
  assert.equal(adapters.forHeader({ kind: 'hook', event: 'Stop' }), claude)
  assert.equal(adapters.forHeader({ kind: 'hook', agent: 'claude' }), claude)
  assert.equal(adapters.forHeader({ kind: 'hook', agent: 'nope' }), null)
  assert.equal(adapters.forHeader({ kind: 'hook', agent: '../evil' }), null)
  assert.equal(adapters.forHeader({ kind: 'hook', agent: 'constructor' }), null)
  assert.equal(adapters.of({ sessionId: 'x' }), claude)
  assert.equal(adapters.of({ kind: 'nope' }), claude)
  assert.equal(adapters.of({ agent_kind: 'claude' }), claude)
  assert.deepEqual(adapters.ids(), ['claude'])
})

test('the capability map names every adapter with its label', () => {
  const map = adapters.capabilityMap()
  assert.deepEqual(Object.keys(map), ['claude'])
  assert.equal(map.claude.label, 'Claude Code')
  assert.equal(map.claude.chat, 'entries')
  assert.equal(map.claude.approvals, 'hook')
})

test('the brain is the first adapter whose binary is installed', () => {
  assert.equal(adapters.brain({ PATH: emptyDir, HOME: emptyDir }), null)
  const bin = path.join(root, 'bin')
  fs.mkdirSync(bin, { recursive: true })
  fs.writeFileSync(path.join(bin, 'claude'), '#!/bin/sh\nexit 0\n', { mode: 0o755 })
  const found = adapters.brain({ PATH: bin, HOME: emptyDir })
  assert.equal(found.adapter, claude)
  assert.equal(found.runner.agent, 'claude')
  assert.equal(found.runner.bin, path.join(bin, 'claude'))
})

// --- Claude Code's output is unchanged ----------------------------------------

test('Claude Code: normalize only tags the event (and takes the hook name from argv)', () => {
  const body = { session_id: 's', hook_event_name: 'Stop', last_assistant_message: 'x', extra: { a: 1 } }
  const out = claude.normalize(body, { event: 'Ignored' })
  assert.equal(out, body)
  assert.deepEqual(out, { session_id: 's', hook_event_name: 'Stop', last_assistant_message: 'x', extra: { a: 1 }, agent_kind: 'claude' })
  assert.equal(claude.normalize({ session_id: 's' }, { event: 'Stop' }).hook_event_name, 'Stop')
  assert.equal(claude.normalize(null, {}), null)
})

test('Claude Code: the hook answer is byte for byte the decision permission.js built', () => {
  const plan = { session_id: 's', tool_name: 'ExitPlanMode', tool_input: { plan: 'do it' } }
  const bash = { session_id: 's', tool_name: 'Bash', tool_input: { command: 'ls' }, permission_suggestions: [{ type: 'addRules', behavior: 'allow', rules: [{ toolName: 'Bash', ruleContent: 'ls' }], destination: 'localSettings' }] }
  const question = { session_id: 's', tool_name: 'AskUserQuestion', tool_input: { questions: [{ question: 'Pick?', options: [{ label: 'A' }] }] } }
  const cases = [
    [bash, 'allow'], [bash, 'deny', 'nope'], [bash, 'deny'], [bash, 'always'], [bash, 'timeout'], [bash, 'gone'],
    [plan, 'allow'], [plan, 'always'], [plan, 'deny'],
    [question, 'answer', null, { 'Pick?': 'A' }], [question, 'answer', null, { 'Other?': 'A' }], [question, 'deny']
  ]
  for (const [event, decision, message, answers] of cases) {
    const legacy = permission.permissionOutput(event, decision, message, answers)
    assert.equal(claude.hookAnswer(event, decision, message, answers), legacy ? JSON.stringify(legacy) + '\n' : '\n', `${event.tool_name} ${decision}`)
  }
  assert.deepEqual(claude.checkAnswers(question, { 'Pick?': 'A' }), permission.answerInput(question, { 'Pick?': 'A' }))
})

test('Claude Code: the brain calls keep their exact claude -p arguments', () => {
  const legacy = (system, schema) => ['-p', '--tools', '', '--safe-mode', '--no-session-persistence', '--output-format', 'json', '--model', 'haiku', '--system-prompt', system, ...(schema ? ['--json-schema', JSON.stringify(schema)] : [])]
  assert.deepEqual(summarize.claudeArgs(45), legacy(summarize.systemPrompt(45)))
  assert.deepEqual(guide.claudeArgs(), legacy(guide.SYSTEM_PROMPT, guide.OUTPUT_SCHEMA))
  assert.deepEqual(digest.claudeArgs('pt'), legacy(digest.systemPrompt('pt'), digest.OUTPUT_SCHEMA))
  assert.ok(summarize.claudeArgs(45).includes('--safe-mode'))
  assert.equal(summarize.claudeArgs(45)[summarize.claudeArgs(45).indexOf('--tools') + 1], '')
})

test('Claude Code: a transcript page through the adapter is the one transcript.js reads', () => {
  for (const opts of [{}, { since: 0 }, { tailBytes: 200 }, { before: 300, maxBytes: 1024 }]) {
    assert.deepEqual(claude.readTranscript(fixtures.agent, opts), transcript.readTranscript(transcriptFile, opts))
  }
  assert.deepEqual(claude.readTranscript({ sessionId: 'x' }, {}), { error: 'no transcript recorded for this session yet (it appears with the next hook event)' })
  assert.deepEqual(claude.readTranscript({ transcriptPath: 'rel.jsonl' }, {}), { error: 'transcript path is not an absolute .jsonl file' })
  assert.deepEqual(claude.readTranscript(fixtures.missing, {}), { error: `transcript not found: ${fixtures.missing.transcriptPath}` })
  assert.deepEqual(claude.readTail(fixtures.agent, { since: 0 }), digest.readTail(transcriptFile, { since: 0 }))
})

test('Claude Code: agents are of kind claude; pending requests carry no adapter-only fields', () => {
  const st = state.createState()
  state.reduce(st, claude.normalize({ session_id: 'k', hook_event_name: 'PermissionRequest', tool_name: 'Bash', tool_input: { command: 'ls' }, request_id: 'r1' }, {}))
  assert.equal(st.agents.k.kind, 'claude')
  assert.deepEqual(Object.keys(st.agents.k.pending[0]).sort(), ['createdAt', 'id', 'summary', 'toolInput', 'toolName'])
  // An event with no adapter tag (a reducer test, an old caller) stays Claude Code's.
  const st2 = state.createState()
  state.reduce(st2, { session_id: 'k', hook_event_name: 'SessionStart' })
  assert.equal(st2.agents.k.kind, 'claude')
})

test('an adapter can add toolKind and answerable to a pending request', () => {
  const st = state.createState()
  state.reduce(st, { session_id: 'g', hook_event_name: 'PermissionRequest', agent_kind: 'gemini', tool_name: 'Bash', tool_input: { command: 'ls' }, request_id: 'r1', tool_kind: 'bash', answerable: false })
  assert.equal(st.agents.g.kind, 'gemini')
  assert.equal(st.agents.g.pending[0].toolKind, 'bash')
  assert.equal(st.agents.g.pending[0].answerable, false)
})

test('Claude Code tool names map onto the neutral kinds the phone draws', () => {
  const expect = { Bash: 'bash', Edit: 'edit', MultiEdit: 'edit', Write: 'write', Read: 'read', Grep: 'search', Glob: 'search', WebFetch: 'web', Task: 'task', Agent: 'task', TodoWrite: 'todo', AskUserQuestion: 'question', ExitPlanMode: 'plan', mcp__github__x: 'mcp', Unknown: 'other', constructor: 'other' }
  for (const [name, kind] of Object.entries(expect)) assert.equal(claude.toolKind(name), kind, name)
})

// --- the neutral chat format ----------------------------------------------------

test('neutral chat items: builders produce valid items and a valid page', () => {
  const list = [
    chatItems.user('1', 'hi', { at: '2026-10-03T10:00:00Z', images: 1 }),
    chatItems.assistant('2', 'x'.repeat(40000), { at: 1759485600000 }),
    chatItems.thinking('3'),
    chatItems.tool('4', { tool: 'exec_command', toolKind: 'bash', input: { cmd: 'ls' }, title: 'ls\n -la', result: { ok: false, text: 'boom' } }),
    chatItems.tool('5', { tool: 'apply_patch', toolKind: 'nonsense', input: null }),
    chatItems.tool('5b', { tool: 'Read', toolKind: 'read', input: { p: 1 }, sidechain: true, parentId: '4' }),
    chatItems.todo('6', [{ text: 'a', status: 'completed' }, { text: 'b', status: 'weird' }, null]),
    chatItems.plan('7', 'the plan', { status: 'approved' }),
    chatItems.question('8', [{ question: 'Pick?', header: 'H', options: [{ label: 'A', description: 'd' }, { label: '' }] }]),
    chatItems.notice('9', 'compacted', 'Conversation compacted'),
    chatItems.notice('10', 'loud', 'x'),
    chatItems.shell('11', 'ls', { stdout: 'a', stderr: '' })
  ]
  for (const item of list) assert.equal(chatItems.validate(item), null, JSON.stringify(item).slice(0, 120))
  assert.equal(list[1].truncated, true)
  assert.equal(list[1].at, '2025-10-03T10:00:00.000Z')
  assert.equal(list[3].title, 'ls -la')
  assert.deepEqual(list[3].result, { ok: false, text: 'boom' })
  assert.equal(list[4].toolKind, 'other')
  assert.deepEqual(list[4].input, {})
  assert.equal(list[4].result, null)
  assert.deepEqual([list[5].sidechain, list[5].parentId], [true, '4'])
  assert.deepEqual(list[6].todos.map(t => t.status), ['completed', 'pending'])
  assert.deepEqual(list[8].questions[0].options, [{ label: 'A', description: 'd' }])
  assert.equal(list[10].level, 'info')
  const page = chatItems.page({ items: list, cursor: 42 })
  assert.equal(chatItems.validatePage(page), null)
  assert.deepEqual([page.format, page.cursor, page.startCursor, page.more], ['items', '42', null, false])
  assert.match(chatItems.validatePage({ ...page, items: [list[0], list[0]] }), /duplicate/)
  assert.match(chatItems.validate({ id: 'x', type: 'tool', at: null, tool: 't', toolKind: 'zzz', input: {}, result: null }), /toolKind/)
  assert.match(chatItems.validate({ id: 'x', type: 'nope', at: null }), /unknown type/)
})

// --- extension points through the daemon --------------------------------------

const fake = {
  id: 'fakeagent',
  label: 'Fake Agent',
  capabilities: () => ({ events: 'hooks', approvals: 'hook', always: false, questions: false, plans: false, chat: false, send: 'pane', interrupt: 'pane', liveUsage: false, limits: false, history: false, brain: false, brainSchema: false, accounts: null, facts: 'partial', undo: false }),
  // Its own vocabulary: { type, id, tool, args }.
  normalize (raw) {
    const names = { start: 'SessionStart', ask: 'PermissionRequest', done: 'Stop' }
    if (!raw || !names[raw.type]) return null
    return { session_id: raw.id, hook_event_name: names[raw.type], tool_name: raw.tool === 'shell' ? 'Bash' : raw.tool, tool_input: raw.args, tool_kind: raw.tool === 'shell' ? 'bash' : undefined, cwd: root, agent_kind: 'fakeagent' }
  },
  identifyProcess: () => null,
  hookAnswer: (event, decision) => (decision === 'timeout' ? '\n' : JSON.stringify({ fake: decision }) + '\n')
}

test('a second adapter: its events become agents of its kind, an unknown agent is dropped, its hook answer reaches the FIFO', async () => {
  paths.ensureDirs()
  adapters.register(fake)
  try {
    const { Daemon } = require('../lib/daemon')
    const d = new Daemon()
    await d.process({ header: { kind: 'hook', agent: 'fakeagent' }, body: { type: 'start', id: 'f1' } })
    assert.equal(d.state.agents.f1.kind, 'fakeagent')
    assert.equal(d.state.agents.f1.state, 'waiting_input')

    // Unknown agent: nothing applied, and a waiting hook is let go at once.
    const fifo = path.join(paths.tmpDir(), 'p.990001')
    execFileSync('mkfifo', ['-m', '600', fifo])
    let fd = fs.openSync(fifo, 'r+')
    await d.process({ header: { kind: 'hook', agent: 'nobody', fifo }, body: { type: 'start', id: 'n1', session_id: 'n1', hook_event_name: 'SessionStart' } })
    assert.equal(d.state.agents.n1, undefined)
    const buf = Buffer.alloc(64)
    assert.equal(buf.toString('utf8', 0, fs.readSync(fd, buf)), '\n')

    // A permission request of the second agent waits; the decision goes
    // out in that agent's own format.
    await d.process({ header: { kind: 'hook', agent: 'fakeagent', fifo, timeout: '30' }, body: { type: 'ask', id: 'f1', tool: 'shell', args: { command: 'make' } } })
    const pending = d.state.agents.f1.pending
    assert.equal(pending.length, 1)
    assert.equal(pending[0].toolName, 'Bash')
    assert.equal(pending[0].toolKind, 'bash')
    assert.equal(pending[0].risk.level !== undefined, true)
    assert.equal(d.settle(pending[0].id, 'allow'), true)
    assert.equal(buf.toString('utf8', 0, fs.readSync(fd, buf)), '{"fake":"allow"}\n')
    assert.equal(d.state.agents.f1.pending.length, 0)
    fs.closeSync(fd)
    fd = null
    clearInterval(d.probeTimer)
  } finally {
    adapters.unregister('fakeagent')
  }
})

test('the sh hook names another agent with --agent and Claude Code with nothing', () => {
  const hookHome = path.join(root, 'hookhome')
  fs.mkdirSync(path.join(hookHome, 'spool'), { recursive: true })
  fs.mkdirSync(path.join(hookHome, 'tmp'), { recursive: true })
  const spoolMod = require('../lib/spool')
  const run = args => {
    // A start attempt just now: the hook spools without starting a daemon.
    fs.writeFileSync(path.join(hookHome, 'spawn.at'), `${Math.floor(Date.now() / 1000)}\n`)
    const env = { PATH: process.env.PATH, HOME: root, CONDUCTORE_HOME: hookHome }
    execFileSync(path.join(__dirname, '..', 'bin', 'conductore-hook'), args, { env, input: JSON.stringify({ session_id: 'h1' }) })
    const entries = spoolMod.list(path.join(hookHome, 'spool'))
    const out = entries.map(e => spoolMod.take(e, path.join(hookHome, 'tmp')))
    return out
  }
  const [codex] = run(['--agent', 'codex', 'Stop'])
  assert.equal(codex.header.agent, 'codex')
  assert.equal(codex.header.event, 'Stop')
  assert.equal(codex.body.session_id, 'h1')
  const [plain] = run(['Stop'])
  assert.equal(plain.header.agent, undefined)
  assert.equal(plain.header.event, 'Stop')
  assert.equal(adapters.forHeader(plain.header), claude)
  assert.deepEqual(run(['--agent', '../x', 'Stop']), [])
  assert.deepEqual(run(['--agent']), [])
})

test("the app's neutral chat fixture is what chat-items.js builds today", () => {
  const file = path.join(__dirname, '..', '..', 'test', 'fixtures', 'agent_adapters', 'neutral_chat_page.json')
  const built = require('./fixtures/neutral-chat-page').page()
  assert.deepEqual(JSON.parse(fs.readFileSync(file, 'utf8')), JSON.parse(JSON.stringify(built)))
  // Every known item is valid; the future type is there to be skipped.
  for (const item of built.items.filter(i => i.type !== 'future-type')) assert.equal(chatItems.validate(item), null, item.id)
})
