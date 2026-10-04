'use strict'

// The Gemini CLI adapter (CON-072) against what a real Gemini CLI 0.62.0
// wrote in Docker against a mock of the Gemini API
// (test/fixtures/gemini/README.md): the adapter contract, settings.json
// registration (comments kept, nothing else touched), events, the
// observe-only prompts through the daemon, chat pages and their cursors,
// the dashboard tail, usage, the process check and accounts.

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('fs')
const os = require('os')
const path = require('path')
const { spawn } = require('child_process')
const { tempDir, cleanup, guardRealConfigs } = require('./helpers/cleanup')
// Taken before anything runs; checked by the last test.
const realConfigs = guardRealConfigs()

const root = tempDir('conductore-gemini-')
process.env.CONDUCTORE_HOME = path.join(root, 'state')
process.env.CONDUCTORE_SOCKET = path.join(root, 'none.sock')
const emptyDir = path.join(root, 'empty')
fs.mkdirSync(emptyDir, { recursive: true })

const adapters = require('../lib/adapters')
const gemini = require('../lib/adapters/gemini')
const session = require('../lib/adapters/gemini-session')
const chatItems = require('../lib/adapters/chat-items')
const state = require('../lib/state')
const paths = require('../lib/paths')
const { contract } = require('./helpers/adapter-contract')

test.after(() => cleanup())

const FIX = path.join(__dirname, 'fixtures', 'gemini', '0.62.0')
const SESSION = path.join(FIX, 'session-tui.jsonl')
const hookLines = fs.readFileSync(path.join(FIX, 'hooks-tui.jsonl'), 'utf8').trim().split('\n').map(l => JSON.parse(l))
const SID = hookLines[0].body.session_id
const clone = v => JSON.parse(JSON.stringify(v))

// The recorded session, with its transcript path pointing at the fixture.
const events = hookLines.map(h => ({ header: { event: h.event, agent: 'gemini' }, body: { ...clone(h.body), transcript_path: SESSION } }))
const norm = list => list.map(e => gemini.normalize(clone(e.body), { kind: 'hook', ...e.header })).filter(Boolean)

const fixtures = {
  events,
  sessionId: SID,
  agent: { sessionId: SID, kind: 'gemini', transcriptPath: SESSION },
  missing: { sessionId: 'gone', kind: 'gemini', transcriptPath: path.join(root, 'gone.jsonl') },
  emptyDir
}

for (const c of contract(gemini, fixtures)) test(`gemini adapter contract: ${c.name}`, c.fn)

test('the registry knows Gemini CLI: observe-only approvals, items chat, no brain', () => {
  assert.ok(adapters.ids().includes('gemini'))
  assert.equal(adapters.ids()[0], 'claude')
  assert.equal(adapters.forHeader({ kind: 'hook', agent: 'gemini' }), gemini)
  const caps = adapters.capabilityMap().gemini
  assert.equal(caps.label, 'Gemini CLI')
  assert.equal(caps.approvals, 'observe')
  assert.equal(caps.chat, 'items')
  assert.equal(caps.brain, false)
  assert.equal(caps.limits, false)
  assert.equal(caps.history, true)
  assert.equal(gemini.hookAnswer, undefined)
  // No brain: a Gemini-only machine reports none rather than one that
  // writes sessions into ~/.gemini.
  assert.equal(adapters.brain({ PATH: emptyDir, HOME: emptyDir }, 'gemini'), null)
})

// --- events ---------------------------------------------------------------------

test('Gemini\'s hooks become the daemon\'s events; its tools Claude Code\'s names', () => {
  gemini._announced.clear()
  const out = norm(events)
  assert.deepEqual([...new Set(out.map(e => e.hook_event_name))].sort(), ['PermissionRequest', 'PostToolUse', 'PreToolUse', 'SessionEnd', 'SessionStart', 'Stop', 'UserPromptSubmit'])
  // PreCompress (fired on every turn) is not ours to report.
  assert.equal(gemini.normalize(clone(hookLines.find(h => h.event === 'PreCompress').body), { kind: 'hook', event: 'PreCompress' }), null)

  const prompt = out.find(e => e.hook_event_name === 'UserPromptSubmit')
  assert.equal(prompt.prompt, 'SHELLME')
  const pre = out.find(e => e.hook_event_name === 'PreToolUse')
  assert.equal(pre.tool_name, 'Bash')
  assert.equal(pre.tool_input.command, 'touch made.txt')
  assert.equal(pre.gemini_tool_name, 'run_shell_command')

  // The prompts, without a tool name of their own: the announced call.
  const asks = out.filter(e => e.hook_event_name === 'PermissionRequest')
  assert.deepEqual(asks.map(e => [e.tool_name, e.tool_kind, e.answerable]), [['Bash', 'bash', false], ['Write', 'write', false], ['TodoWrite', 'todo', false]])
  assert.equal(asks[0].tool_input.command, 'touch made.txt')
  assert.equal(asks[1].tool_input.file_path, '/work/proj/hello.txt')

  const stop = out.filter(e => e.hook_event_name === 'Stop').pop()
  assert.equal(stop.last_assistant_message, 'The answer is **42**.')
})

test('a prompt with no announced call takes its tool from the details; failures and other notifications', () => {
  gemini._announced.clear()
  const n = hookLines.find(h => h.event === 'Notification')
  const e = gemini.normalize(clone(n.body), { kind: 'hook', event: 'Notification' })
  assert.equal(e.tool_name, 'Bash')
  assert.equal(e.tool_input.command, 'touch made.txt')
  // A call announced for something else is not used.
  gemini.normalize({ ...clone(hookLines.find(h => h.event === 'BeforeTool').body), tool_name: 'read_file', tool_input: { file_path: '/x' } }, { kind: 'hook' })
  assert.equal(gemini.normalize(clone(n.body), { kind: 'hook' }).tool_name, 'Bash')
  // Only permission prompts.
  assert.equal(gemini.normalize({ ...clone(n.body), notification_type: 'Other' }, { kind: 'hook' }), null)
  // An AfterTool with an error is a failure (the dashboard's failed runs).
  const after = clone(hookLines.find(h => h.event === 'AfterTool').body)
  after.tool_response = { llmContent: '', returnDisplay: '', error: 'Command exited with code 1' }
  const f = gemini.normalize(after, { kind: 'hook' })
  assert.equal(f.hook_event_name, 'PostToolUseFailure')
  assert.equal(f.error, 'Command exited with code 1')
  assert.equal(f.tool_name, 'Bash')
})

test('observe-only prompts: pending until the tool runs or the turn ends; the phone cannot answer them', async () => {
  const st = state.createState()
  let t = 1000
  for (const e of norm(events.slice(0, 4))) state.reduce(st, e, t++)
  const ask = gemini.normalize(clone(hookLines[4].body), { kind: 'hook' })
  state.reduce(st, ask, t++)
  const agent = st.agents[SID]
  assert.equal(agent.state, 'needs_permission')
  assert.equal(agent.pending[0].answerable, false)
  assert.equal(agent.pending[0].toolKind, 'bash')
  // Another tool finishing does not answer it; its own does.
  state.reduce(st, { session_id: SID, hook_event_name: 'PostToolUse', tool_name: 'Read', agent_kind: 'gemini' }, t++)
  assert.equal(agent.pending.length, 1)
  state.reduce(st, gemini.normalize(clone(hookLines[5].body), { kind: 'hook' }), t++)
  assert.equal(agent.pending.length, 0)
  assert.equal(agent.state, 'working')
  // A turn end clears what is left.
  state.reduce(st, ask, t++)
  state.reduce(st, { session_id: SID, hook_event_name: 'Stop', agent_kind: 'gemini' }, t++)
  assert.deepEqual([agent.pending.length, agent.state], [0, 'waiting_input'])
  // Requests the phone answers keep the old behaviour.
  state.reduce(st, { session_id: SID, hook_event_name: 'PermissionRequest', request_id: 'r', tool_name: 'Bash', tool_input: { command: 'x' } }, t++)
  state.reduce(st, { session_id: SID, hook_event_name: 'PostToolUse', tool_name: 'Bash' }, t++)
  assert.equal(agent.pending.length, 1)
})

test('through the daemon: a watched prompt stays pending, refuses phone answers, and a refusal in the terminal ends the turn', async () => {
  paths.ensureDirs()
  const { Daemon } = require('../lib/daemon')
  const d = new Daemon()
  try {
    gemini._announced.clear()
    // The session file as it was when the write prompt showed: no result yet.
    const file = path.join(root, 'live-session.jsonl')
    const lines = fs.readFileSync(SESSION, 'utf8').split('\n')
    const cut = lines.findIndex(l => l.includes('"status":"cancelled"'))
    fs.writeFileSync(file, lines.slice(0, cut).join('\n') + '\n')
    const body = h => ({ ...clone(h.body), transcript_path: file })
    const write = hookLines.findIndex(h => h.event === 'BeforeTool' && h.body.tool_name === 'write_file')
    for (const h of [hookLines[0], ...hookLines.slice(write - 3, write + 1)]) await d.process({ header: { kind: 'hook', agent: 'gemini', event: h.event }, body: body(h) })
    await d.process({ header: { kind: 'hook', agent: 'gemini', event: 'Notification' }, body: body(hookLines[write + 1]) })
    const agent = d.state.agents[SID]
    assert.equal(agent.kind, 'gemini')
    assert.equal(agent.state, 'needs_permission')
    assert.equal(agent.pending.length, 1)
    const req = agent.pending[0]
    assert.equal(req.answerable, false)
    assert.equal(req.toolName, 'Write')
    assert.ok(req.risk, 'rated like any request')
    assert.ok(d.observed.has(req.id))

    // The phone cannot answer it, approve it in bulk or trust it.
    const replies = []
    const c = { end () {}, write () {} }
    d.reply = (_c, msg) => replies.push(msg)
    d.handleDecide({ requestId: req.id, decision: 'allow' }, c)
    assert.match(replies.pop().error, /terminal/)
    const ops = require('../lib/approval-ops')
    assert.deepEqual(ops.handle(d, { op: 'approve-low', ids: [req.id] }).skipped, [{ id: req.id, reason: 'answer it in the terminal' }])
    assert.match(ops.handle(d, { op: 'trust', requestId: req.id }).error, /terminal/)
    assert.equal(agent.pending.length, 1)

    // Still waiting in the terminal: nothing changes.
    req.createdAt = Date.parse('2026-10-04T18:08:28Z')
    d.checkObserved()
    assert.equal(agent.pending.length, 1)

    // Refused (Esc): Gemini writes the cancelled call, no hook fires.
    fs.writeFileSync(file, lines.join('\n'))
    d.checkObserved()
    assert.equal(agent.pending.length, 0)
    assert.equal(agent.state, 'waiting_input')
    assert.equal(d.observed.size, 0)
  } finally {
    clearInterval(d.observeTimer)
    clearInterval(d.probeTimer)
  }
})

// --- settings.json --------------------------------------------------------------------

const hookBin = path.join(__dirname, '..', 'bin', 'conductore-hook')

function geminiHome (name, text) {
  const home = path.join(root, name)
  fs.mkdirSync(path.join(home, '.gemini'), { recursive: true })
  const file = path.join(home, '.gemini', 'settings.json')
  if (text !== undefined) fs.writeFileSync(file, text, { mode: 0o640 })
  return { env: { HOME: home, PATH: emptyDir }, file }
}

const USER_SETTINGS = `{
  // my settings
  "security": { "auth": { "selectedType": "oauth-personal" } },
  /* keep this */
  "hooks": {
    "BeforeTool": [
      { "matcher": "write_file", "hooks": [{ "name": "guard", "type": "command", "command": "/usr/bin/guard", "timeout": 5000 }] }
    ],
  },
  "ui": { "theme": "Default" }, // trailing
}
`

test('install adds our hooks to settings.json, keeps comments and other hooks, backs up, is idempotent; uninstall removes only ours', () => {
  const { env, file } = geminiHome('install', USER_SETTINGS)
  const r = gemini.install({ hookBin, env })
  assert.equal(r.error, undefined)
  assert.equal(r.changed, true)
  assert.equal(r.next, null)
  const text = fs.readFileSync(file, 'utf8')
  for (const keep of ['// my settings', '/* keep this */', '// trailing', '"ui": { "theme": "Default" }']) assert.ok(text.includes(keep), keep)
  const doc = JSON.parse(gemini.stripJsonc(text))
  assert.equal(doc.security.auth.selectedType, 'oauth-personal')
  assert.deepEqual(gemini.installed(doc).sort(), [...gemini.EVENTS].sort())
  // Theirs first and unchanged; ours in a group of its own.
  assert.equal(doc.hooks.BeforeTool[0].hooks[0].command, '/usr/bin/guard')
  const ours = doc.hooks.BeforeTool[1]
  assert.equal(ours.matcher, '*')
  assert.equal(ours.hooks[0].name, 'conductore')
  assert.equal(ours.hooks[0].command, `'${hookBin}' --agent gemini BeforeTool`)
  assert.equal(ours.hooks[0].timeout, 10000)
  assert.equal(doc.hooks.Notification[0].matcher, undefined)
  assert.equal(fs.statSync(file).mode & 0o777, 0o640)
  assert.equal(fs.readFileSync(`${file}.bak`, 'utf8'), USER_SETTINGS)

  // Again: nothing to change, nothing written.
  const mtime = fs.statSync(file).mtimeMs
  assert.equal(gemini.install({ hookBin, env }).changed, false)
  assert.equal(fs.statSync(file).mtimeMs, mtime)

  const u = gemini.uninstall({ env })
  assert.deepEqual(u.removed.sort(), [...gemini.EVENTS].sort())
  const after = fs.readFileSync(file, 'utf8')
  assert.deepEqual(JSON.parse(gemini.stripJsonc(after)), JSON.parse(gemini.stripJsonc(USER_SETTINGS)))
  for (const keep of ['// my settings', '/* keep this */', '// trailing']) assert.ok(after.includes(keep), keep)
  assert.deepEqual(gemini.uninstall({ env }).removed, [])
})

test('install creates settings.json when there is none, refuses one that does not parse, and says when hooks are off', () => {
  const fresh = geminiHome('fresh')
  assert.equal(gemini.install({ hookBin, env: fresh.env }).changed, true)
  assert.deepEqual(gemini.installed(JSON.parse(fs.readFileSync(fresh.file, 'utf8'))).length, gemini.EVENTS.length)
  // Uninstalling leaves an empty object, not our hooks.
  gemini.uninstall({ env: fresh.env })
  assert.deepEqual(JSON.parse(fs.readFileSync(fresh.file, 'utf8')), {})

  const broken = geminiHome('broken', '{ "a": 1,, }')
  assert.match(gemini.install({ hookBin, env: broken.env }).error, /cannot parse/)
  assert.equal(fs.readFileSync(broken.file, 'utf8'), '{ "a": 1,, }')
  assert.equal(fs.existsSync(`${broken.file}.bak`), false)

  const off = geminiHome('off', '{"hooksConfig": {"enabled": false}}')
  assert.match(gemini.install({ hookBin, env: off.env }).next, /hooksConfig\.enabled/)
  const disabled = geminiHome('disabled', '{"hooksConfig": {"disabled": ["conductore"]}}')
  assert.match(gemini.install({ hookBin, env: disabled.env }).next, /\/hooks enable conductore/)

  // GEMINI_CLI_HOME stands in for the home directory.
  assert.equal(gemini.settingsPath({ GEMINI_CLI_HOME: '/x', HOME: '/y' }), '/x/.gemini/settings.json')
})

test('the JSONC reader leaves strings alone', () => {
  const t = '{"a": "// not a comment, }", "b": [1, 2,], /* c */ "c": "x\\"/*y*/",}'
  assert.deepEqual(JSON.parse(gemini.stripJsonc(t)), { a: '// not a comment, }', b: [1, 2], c: 'x"/*y*/' })
})

// --- chat ---------------------------------------------------------------------------

test('the session file becomes what the terminal showed: rolled back copies hidden, the refused call kept', () => {
  const page = gemini.readTranscript(fixtures.agent, {})
  assert.equal(chatItems.validatePage(page), null)
  const brief = page.items.map(i => [i.type, i.text || i.title || i.toolKind || (i.todos && i.todos.length) || ''])
  assert.deepEqual(brief, [
    ['user', 'SHELLME'],
    ['assistant', 'Creating the file.'],
    ['tool', 'touch made.txt'],
    ['assistant', 'Done with run_shell_command.'],
    ['user', 'WRITEME'],
    ['tool', '/work/proj/hello.txt'],
    ['notice', 'Request cancelled.'],
    ['user', 'README'],
    ['tool', '/work/proj/notes.md'],
    ['assistant', 'Done with read_file.'],
    ['user', 'TODOME'],
    ['todo', 3],
    ['assistant', 'Done with write_todos.'],
    ['user', 'THINKME'],
    ['thinking', ''],
    ['assistant', 'The answer is **42**.']
  ])
  const [shell, write, read] = page.items.filter(i => i.type === 'tool')
  assert.deepEqual([shell.toolKind, shell.result], ['bash', { ok: true, text: '' }])
  assert.equal(write.toolKind, 'write')
  assert.equal(write.result.ok, false)
  assert.match(write.result.text, /User denied/)
  assert.deepEqual(read.result, { ok: true, text: '# notes' })
  assert.equal(page.items.find(i => i.type === 'notice').level, 'interrupted')
  assert.deepEqual(page.items.find(i => i.type === 'todo').todos.map(t => t.status), ['completed', 'in_progress', 'pending'])
  assert.equal(page.cursor, String(fs.statSync(SESSION).size))
  assert.equal(page.startCursor, null)
})

test('cursors: nothing new, a new message, a message rewritten under its id, a rewind, older pages', () => {
  const file = path.join(root, 'paging.jsonl')
  fs.copyFileSync(SESSION, file)
  const agent = { sessionId: SID, kind: 'gemini', transcriptPath: file }
  const first = gemini.readTranscript(agent, {})
  assert.deepEqual(gemini.readTranscript(agent, { cursor: first.cursor }).items, [])

  const at = '2026-10-04T18:09:00.000Z'
  fs.appendFileSync(file, JSON.stringify({ id: 'u9', timestamp: at, type: 'user', content: [{ text: 'LISTME' }] }) + '\n')
  fs.appendFileSync(file, JSON.stringify({ id: 'g9', timestamp: at, type: 'gemini', content: 'Listing.', model: 'gemini-2.5-flash', tokens: { input: 10, output: 2, cached: 0, thoughts: 0, tool: 0, total: 12 } }) + '\n')
  const next = gemini.readTranscript(agent, { cursor: first.cursor })
  assert.deepEqual(next.items.map(i => i.id), ['u9', 'g9'])
  assert.equal(next.reset, undefined)

  // The reply again, now with a running call, then finished.
  const call = { id: 'c1', name: 'run_shell_command', args: { command: 'ls' }, status: 'executing', timestamp: at }
  fs.appendFileSync(file, JSON.stringify({ id: 'g9', timestamp: at, type: 'gemini', content: 'Listing.', model: 'gemini-2.5-flash', toolCalls: [call] }) + '\n')
  const running = gemini.readTranscript(agent, { cursor: next.cursor })
  assert.deepEqual(running.items.map(i => i.id), ['g9', 'g9:c1'])
  assert.equal(running.items[1].result, null)
  fs.appendFileSync(file, JSON.stringify({ id: 'g9', timestamp: at, type: 'gemini', content: 'Listing.', model: 'gemini-2.5-flash', toolCalls: [{ ...call, status: 'success', result: [{ functionResponse: { id: 'c1', name: 'run_shell_command', response: { output: 'Output: a\nb' } } }] }] }) + '\n')
  const done = gemini.readTranscript(agent, { cursor: running.cursor })
  assert.deepEqual(done.items[1].result, { ok: true, text: 'a\nb' })

  // /rewind: the window starts over.
  fs.appendFileSync(file, JSON.stringify({ $rewindTo: 'u9' }) + '\n')
  const rewound = gemini.readTranscript(agent, { cursor: done.cursor })
  assert.equal(rewound.reset, true)
  assert.equal(rewound.items.at(-1).text, 'The answer is **42**.')
  // A shorter file (replaced): reset too.
  assert.equal(gemini.readTranscript(agent, { cursor: String(10 ** 9) }).reset, true)

  // Older pages by item index.
  const tail = session.readPage(file, { limit: 5 })
  assert.equal(tail.items.length, 5)
  assert.equal(tail.startCursor, 'i11')
  const older = session.readPage(file, { beforeCursor: tail.startCursor, limit: 5 })
  assert.deepEqual(older.items.map(i => i.text || i.type), ['Request cancelled.', 'README', 'tool', 'Done with read_file.', 'TODOME'])
  assert.equal(older.startCursor, 'i6')
  assert.equal(session.readPage(file, { beforeCursor: 'i3', limit: 5 }).startCursor, null)
  assert.match(gemini.readTranscript({ transcriptPath: 'relative.jsonl' }, {}).error, /absolute/)
})

test('a resumed session keeps its history (its $set lists old messages, not copies)', () => {
  const file = path.join(root, 'resumed.jsonl')
  const lines = fs.readFileSync(SESSION, 'utf8').trim().split('\n')
  const ids = lines.map(l => JSON.parse(l)).filter(o => typeof o.id === 'string').map(o => o.id)
  // Minutes later, Gemini --resume rewrites the history it loaded.
  lines.push(JSON.stringify({ $set: { messages: ids.map(id => ({ id, type: 'user', content: [] })), lastUpdated: '2026-10-04T18:20:00.000Z' } }))
  fs.writeFileSync(file, lines.join('\n') + '\n')
  assert.equal(gemini.readTranscript({ transcriptPath: file }, {}).items.length, gemini.readTranscript(fixtures.agent, {}).items.length)
})

test('the dashboard tail: prompts, replies, runs and tokens', () => {
  const tail = gemini.readTail(fixtures.agent, { since: 0, repliesSince: 0, runsSince: 0 })
  assert.deepEqual(tail.prompts.map(p => p.text), ['TODOME', 'THINKME'])
  assert.equal(tail.lastReply, 'The answer is **42**.')
  assert.deepEqual(tail.runs.map(r => [r.command, r.ok]), [['touch made.txt', true]])
  // 8 replies of 1200 in (400 cached), 25 out + 30 thoughts.
  assert.deepEqual(tail.tokens, { input: 6400, output: 440, cacheWrite: 0, cacheRead: 3200, total: 10040 })
  assert.equal(tail.costUsd, null)
  assert.equal(gemini.readTail({ transcriptPath: null }, {}), null)
})

test('usage: tokens per day, project and model from the session files', () => {
  const home = path.join(root, 'usage-home')
  const chats = path.join(home, '.gemini', 'tmp', 'proj', 'chats')
  fs.mkdirSync(chats, { recursive: true })
  fs.copyFileSync(SESSION, path.join(chats, 'session-2026-10-04T18-08-6cc5de7a.jsonl'))
  fs.copyFileSync(path.join(FIX, 'projects.json'), path.join(home, '.gemini', 'projects.json'))
  const localDate = ms => new Date(ms).toISOString().slice(0, 10)
  const r = gemini.usageReport({ env: { HOME: home }, range: { from: '2026-10-01', to: '2026-10-04', today: '2026-10-04' }, projectOf: dir => `P:${dir}`, localDate, detail: { sessions: true } })
  assert.equal(r.present, true)
  assert.deepEqual(r.limits, [])
  assert.equal(r.costSource, 'none')
  assert.equal(r.active.model, 'gemini-2.5-flash')
  assert.deepEqual(r.rows.map(x => [x.date, x.project, x.model, x.messages, x.input, x.output, x.cacheRead]), [['2026-10-04', 'P:/work/proj', 'gemini-2.5-flash', 8, 6400, 440, 3200]])
  assert.equal(r.range.tokens, 10040)
  assert.equal(r.today.messages, 8)
  assert.equal(r.bySession[0].session, SID)
  assert.deepEqual(gemini.usageReport({ env: { HOME: emptyDir }, range: { from: '2026-10-01', to: '2026-10-04', today: '2026-10-04' }, projectOf: d => d, localDate }), { present: false })
})

test("the app's Gemini chat fixture is what the adapter reads from the real session today", () => {
  const file = path.join(__dirname, '..', '..', 'test', 'fixtures', 'agent_adapters', 'gemini_chat_page.json')
  const saved = JSON.parse(fs.readFileSync(file, 'utf8'))
  const { sessionId, agent, ...page } = saved
  assert.equal(sessionId, SID)
  assert.equal(agent.state, 'waiting_input')
  assert.deepEqual(page, JSON.parse(JSON.stringify(gemini.readTranscript(fixtures.agent, {}))))
})

test('the dashboard digest names a Gemini agent\'s kind and reads its facts from the session file', async () => {
  const digest = require('../lib/digest')
  const now = Date.parse('2026-10-04T18:10:00Z')
  const agent = { sessionId: SID, kind: 'gemini', name: 'proj', cwd: '/work/proj', transcriptPath: SESSION, state: 'waiting_input', lastMessage: 'The answer is **42**.', startedAt: now - 120000, updatedAt: now - 1000, pending: [] }
  const r = await digest.digest({ now, since: now - 3600000, data: { status: { agents: [agent] }, activity: {}, source: 'test', hasActivity: false }, storeFile: path.join(root, 'digest.json'), env: { HOME: root }, gitTimeoutMs: 1 })
  const entry = r.agents.find(a => a.sessionId === SID)
  assert.equal(entry.kind, 'gemini')
  assert.equal(entry.facts.tokens.output, 440)
})

// --- process and accounts ---------------------------------------------------------------

test('identifyProcess knows a node process running gemini, not one that mentions it', async () => {
  const bin = path.join(root, 'bin')
  fs.mkdirSync(bin, { recursive: true })
  const script = path.join(bin, 'gemini')
  fs.writeFileSync(script, 'setTimeout(() => {}, 30000)\n')
  const other = path.join(bin, 'not-gemini-tool.js')
  fs.writeFileSync(other, 'setTimeout(() => {}, 30000)\n')
  const kids = [spawn(process.execPath, ['--max-old-space-size=200', script], { stdio: 'ignore' }), spawn(process.execPath, [other, 'gemini'], { stdio: 'ignore' })]
  try {
    await new Promise(resolve => setTimeout(resolve, 300))
    const found = gemini.identifyProcess(kids[0].pid)
    assert.ok(found && found.pid === kids[0].pid && found.startTime)
    assert.equal(gemini.identifyProcess(kids[1].pid), null)
  } finally {
    for (const k of kids) k.kill()
  }
})

test('accounts: the active login masked, or the kind of key; never a token', async () => {
  const home = path.join(root, 'acct')
  fs.mkdirSync(path.join(home, '.gemini'), { recursive: true })
  assert.deepEqual(await gemini.accounts({ env: { HOME: home } }), { present: false, accounts: [] })
  fs.writeFileSync(path.join(home, '.gemini', 'settings.json'), '{"security": {"auth": {"selectedType": "oauth-personal"}}}')
  fs.writeFileSync(path.join(home, '.gemini', 'google_accounts.json'), '{"active": "someone@example.com", "old": []}')
  const g = await gemini.accounts({ env: { HOME: home } })
  assert.equal(g.accounts[0].mode, 'google')
  assert.ok(!g.accounts[0].label.includes('someone@example.com'))
  fs.writeFileSync(path.join(home, '.gemini', 'settings.json'), '{"security": {"auth": {"selectedType": "gemini-api-key"}}}')
  assert.equal((await gemini.accounts({ env: { HOME: home } })).accounts[0].label, 'Gemini API key')
})

test('no test touched the real agent configs (~/.gemini included)', () => {
  assert.equal(path.join(os.homedir(), '.gemini') !== path.join(root, '.gemini'), true)
  realConfigs()
})

test('no session file yet is marked notYet, so the phone shows an empty chat (CON-071)', () => {
  assert.equal(gemini.readTranscript(fixtures.missing, {}).notYet, true)
  assert.equal(gemini.readTranscript({ sessionId: 'x', kind: 'gemini' }, {}).notYet, true)
  assert.equal(gemini.readTranscript({ sessionId: 'x', kind: 'gemini', transcriptPath: 'rel.jsonl' }, {}).notYet, undefined)
})
