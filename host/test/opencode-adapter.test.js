'use strict'

// The OpenCode adapter (CON-069): the adapter contract on events and a
// database recorded from OpenCode 1.18.34 (test/fixtures/opencode, a mock
// provider: no real conversation), plus its own mapping, approvals, chat
// paging, usage, install and brain.

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('fs')
const path = require('path')
const { tempDir, cleanup } = require('./helpers/cleanup')

const root = tempDir('conductore-opencode-')
const dataDir = path.join(root, 'data', 'opencode')
const emptyDir = path.join(root, 'empty')
fs.mkdirSync(dataDir, { recursive: true })
fs.mkdirSync(emptyDir, { recursive: true })
process.env.CONDUCTORE_HOME = path.join(root, 'state')
process.env.CONDUCTORE_SOCKET = path.join(root, 'none.sock')
// Never near the real OpenCode data or config.
process.env.XDG_DATA_HOME = path.join(root, 'data')
process.env.XDG_CONFIG_HOME = path.join(root, 'config')
process.env.HOME = path.join(root, 'home')

// The real OpenCode config of whoever runs the tests: never written.
const realConfig = path.join(require('os').userInfo().homedir, '.config', 'opencode')
const snapshot = dir => {
  const out = {}
  const walk = d => {
    let names = []
    try { names = fs.readdirSync(d) } catch { return }
    for (const n of names) {
      if (n === 'node_modules') continue
      const f = path.join(d, n)
      const st = fs.lstatSync(f)
      if (st.isDirectory()) walk(f)
      else out[f] = `${st.size}:${st.mtimeMs}`
    }
  }
  walk(dir)
  return out
}
const realBefore = snapshot(realConfig)

const adapters = require('../lib/adapters')
const opencode = require('../lib/adapters/opencode')
const chatItems = require('../lib/adapters/chat-items')
const state = require('../lib/state')
const usage = require('../lib/usage')
const { contract } = require('./helpers/adapter-contract')

test.after(() => cleanup())

test.after(() => {
  assert.deepEqual(snapshot(realConfig), realBefore, `${realConfig} changed`)
})

const sqliteOk = !!opencode.sqlite()
const FIXTURE = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures', 'opencode', '1.18.34.json'), 'utf8'))
const dbFile = path.join(dataDir, 'opencode.db')

// The fixture's rows in a fresh database with OpenCode's columns, plus
// `extra` messages (for paging).
function writeDb (file, extra = []) {
  const { DatabaseSync } = opencode.sqlite()
  try { fs.unlinkSync(file) } catch {}
  const db = new DatabaseSync(file)
  db.exec(`CREATE TABLE session (id text PRIMARY KEY, project_id text, parent_id text, slug text, directory text NOT NULL, title text, version text, time_created integer, time_updated integer);
    CREATE TABLE message (id text PRIMARY KEY, session_id text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL);
    CREATE TABLE part (id text PRIMARY KEY, message_id text NOT NULL, session_id text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL);`)
  const s = db.prepare('INSERT INTO session (id, parent_id, directory, title, version, time_created, time_updated) VALUES (?, ?, ?, ?, ?, ?, ?)')
  for (const r of FIXTURE.db.session) s.run(r.id, r.parent_id, r.directory, r.title, r.version, r.time_created, r.time_updated)
  const m = db.prepare('INSERT INTO message VALUES (?, ?, ?, ?, ?)')
  for (const r of [...FIXTURE.db.message, ...extra.filter(x => x.kind === 'message')]) m.run(r.id, r.session_id, r.time_created, r.time_updated, r.data)
  const p = db.prepare('INSERT INTO part VALUES (?, ?, ?, ?, ?, ?)')
  for (const r of [...FIXTURE.db.part, ...extra.filter(x => x.kind === 'part')]) p.run(r.id, r.message_id, r.session_id, r.time_created, r.time_updated, r.data)
  db.close()
}

if (sqliteOk) writeDb(dbFile)

const [bashSid, questionSid] = FIXTURE.db.session.map(s => s.id)
// The recorded hook input, pointed at this test's data directory.
const events = FIXTURE.events.map(e => ({
  header: { event: e.event, agent: 'opencode', claude_pid: '1' },
  body: { ...e.body, store: { data: dataDir, db: null } }
}))
const bashEvents = events.filter(e => e.body.session_id === bashSid)
const agent = { sessionId: bashSid, kind: 'opencode', transcriptPath: `opencode:${dbFile}` }
const questionAgent = { ...agent, sessionId: questionSid }
const fixtures = {
  events: bashEvents,
  sessionId: bashSid,
  agent,
  missing: { sessionId: 'ses_missing', kind: 'opencode', transcriptPath: `opencode:${dbFile}` },
  emptyDir
}

const norm = e => opencode.normalize(JSON.parse(JSON.stringify(e.body)), e.header)

for (const c of contract(opencode, fixtures)) test(`opencode adapter contract: ${c.name}`, { skip: !sqliteOk && /transcript|tail/.test(c.name) && 'no node:sqlite' }, c.fn)

test('the registry knows OpenCode after Claude Code', () => {
  assert.equal(adapters.ids()[0], 'claude')
  assert.equal(adapters.get('opencode'), opencode)
  assert.equal(adapters.forHeader({ agent: 'opencode' }), opencode)
  assert.equal(adapters.capabilityMap().opencode.label, 'OpenCode')
  assert.equal(adapters.capabilityMap().opencode.chat, 'items')
})

test('recorded plugin events map onto the hook vocabulary, in order', () => {
  const out = bashEvents.map(norm)
  assert.deepEqual(out.map(e => e && e.hook_event_name), ['SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PermissionRequest', 'PostToolUse', 'Stop'])
  for (const e of out) {
    assert.equal(e.agent_kind, 'opencode')
    assert.equal(e.session_id, bashSid)
    assert.equal(e.transcript_path, `opencode:${dbFile}`)
    assert.equal(e.cwd, '/home/dev/proj')
  }
  const [, prompt, pre, request, post, stop] = out
  assert.equal(prompt.prompt, 'do it')
  assert.equal(pre.tool_name, 'Bash')
  assert.equal(pre.tool_kind, 'bash')
  assert.equal(pre.tool_input.command, 'echo hello-from-mock')
  assert.equal(request.tool_name, 'Bash')
  assert.deepEqual(request.tool_input, { command: 'echo hello-from-mock' })
  assert.equal(request.opencode_request.kind, 'permission')
  assert.deepEqual(request.opencode_request.always, ['echo *'])
  assert.equal(post.tool_response.exit, 0)
  assert.equal(stop.last_assistant_message, 'All done.')
})

test('a recorded question becomes an AskUserQuestion the phone can answer', () => {
  const request = events.filter(e => e.body.session_id === questionSid).map(norm).find(e => e && e.hook_event_name === 'PermissionRequest')
  assert.equal(request.tool_name, 'AskUserQuestion')
  assert.equal(request.tool_kind, 'question')
  assert.deepEqual(request.tool_input.questions, [{ question: 'Which colour?', header: 'Colour', multiSelect: false, options: [{ label: 'Blue', description: 'b' }, { label: 'Red', description: 'r' }] }])
  const st = state.createState()
  state.reduce(st, { ...request, request_id: 'q1' })
  assert.equal(st.agents[questionSid].pending[0].questions[0].question, 'Which colour?')
  assert.equal(st.agents[questionSid].pending[0].toolKind, 'question')
})

test('child sessions fold into their root as a subagent; errors, retries and deletes map too', () => {
  const base = { session_id: 'ses_root', cwd: '/p', store: { data: dataDir } }
  const n = (type, properties = {}, extra = {}) => opencode.normalize({ ...base, type, properties, ...extra }, {})
  const childTool = n('tool.execute.before', { tool: 'read', args: { filePath: '/p/a.js' } }, { child: 'ses_child' })
  assert.equal(childTool.session_id, 'ses_root')
  assert.equal(childTool.agent_id, 'ses_child')
  assert.equal(childTool.tool_name, 'Read')
  assert.deepEqual(childTool.tool_input, { file_path: '/p/a.js' })
  assert.equal(n('session.idle', {}, { child: 'ses_child' }).hook_event_name, 'SubagentStop')
  // A child's permission request waits on the root agent.
  const childAsk = n('permission.asked', { id: 'per_1', permission: 'edit', patterns: ['a.js'], metadata: { filepath: '/p/a.js' } }, { child: 'ses_child' })
  assert.equal(childAsk.agent_id, undefined)
  assert.deepEqual(childAsk.tool_input, { file_path: '/p/a.js' })
  assert.equal(n('session.created', {}, { child: 'ses_child' }), null)
  const failed = n('session.error', { error: { name: 'APIError', data: { message: 'slow down', statusCode: 429 } } })
  assert.equal(failed.hook_event_name, 'StopFailure')
  assert.equal(failed.error, 'rate_limit')
  assert.equal(n('session.error', { error: { name: 'MessageAbortedError' } }), null)
  assert.equal(n('session.error', { error: { name: 'ProviderAuthError', data: {} } }).error, 'authentication_failed')
  const retry = n('session.status', { status: { type: 'retry', attempt: 2, message: 'overloaded' } })
  assert.equal(retry.hook_event_name, 'Notification')
  assert.match(retry.message, /attempt 2.*overloaded/)
  assert.equal(n('session.status', { status: { type: 'busy' } }), null)
  assert.equal(n('session.deleted').hook_event_name, 'SessionEnd')
  assert.equal(n('permission.replied', { reply: 'reject' }).hook_event_name, 'PermissionDenied')
  assert.equal(n('permission.replied', { reply: 'once' }), null)
  const failedRun = n('tool.execute.after', { tool: 'bash', args: { command: 'false' }, exit: 1 })
  assert.equal(failedRun.hook_event_name, 'PostToolUseFailure')
  // OPENCODE_DB, relative or absolute, names the database.
  assert.equal(opencode.normalize({ ...base, type: 'session.idle', store: { data: dataDir, db: 'other.db' } }).transcript_path, `opencode:${path.join(dataDir, 'other.db')}`)
  assert.equal(opencode.normalize({ ...base, type: 'session.idle', store: { data: dataDir, db: '/x/y.db' } }).transcript_path, 'opencode:/x/y.db')
  assert.equal(opencode.normalize({ ...base, type: 'nope' }), null)
})

test('the waiting hook prints the reply the plugin sends to OpenCode', () => {
  const request = bashEvents.map(norm).find(e => e.hook_event_name === 'PermissionRequest')
  assert.equal(opencode.hookAnswer(request, 'allow'), '{"reply":"once"}\n')
  assert.equal(opencode.hookAnswer(request, 'always'), '{"reply":"always"}\n')
  assert.equal(opencode.hookAnswer(request, 'deny', 'not now'), '{"reply":"reject","message":"not now"}\n')
  assert.equal(opencode.hookAnswer(request, 'deny'), '{"reply":"reject"}\n')
  assert.equal(opencode.hookAnswer(request, 'timeout'), '\n')
  const q = { tool_name: 'AskUserQuestion', tool_input: { questions: [{ question: 'Which colour?', options: [] }, { question: 'Which sizes?', multiSelect: true, options: [] }] }, opencode_request: { kind: 'question' } }
  const answers = { 'Which colour?': 'Blue', 'Which sizes?': 'S, M' }
  assert.deepEqual(opencode.checkAnswers(q, answers).updatedInput.answers, answers)
  assert.equal(opencode.hookAnswer(q, 'answer', '', answers), '{"answers":[["Blue"],["S","M"]]}\n')
  assert.equal(opencode.hookAnswer(q, 'answer', '', { 'Which colour?': ['Red'], 'Which sizes?': ['L'] }), '{"answers":[["Red"],["L"]]}\n')
  assert.equal(opencode.hookAnswer(q, 'deny'), '{"reject":true}\n')
  assert.equal(opencode.hookAnswer(q, 'allow'), '\n')
  assert.match(opencode.checkAnswers(q, { 'Which colour?': 'Blue' }).error, /Which sizes/)
  assert.match(opencode.checkAnswers(q, []).error, /object/)
  assert.match(opencode.checkAnswers(request, answers).error, /not a question/)
})

test('chat: the recorded sessions read as neutral items', { skip: !sqliteOk && 'no node:sqlite' }, () => {
  const page = opencode.readTranscript(agent, {})
  assert.equal(chatItems.validatePage(page), null)
  assert.deepEqual(page.items.map(i => i.type), ['user', 'assistant', 'tool', 'assistant'])
  const call = page.items[2]
  assert.equal(call.tool, 'Bash')
  assert.equal(call.toolKind, 'bash')
  assert.equal(call.input.command, 'echo hello-from-mock')
  assert.deepEqual(call.result, { ok: true, text: 'hello-from-mock\n' })
  assert.equal(page.items[0].text, 'do it')
  assert.equal(page.startCursor, null)
  assert.equal(page.more, false)
  // Polling from the cursor sends the last message again (it may grow).
  const again = opencode.readTranscript(agent, { cursor: page.cursor })
  assert.equal(chatItems.validatePage(again), null)
  assert.deepEqual(again.items.map(i => i.id), page.items.slice(-1).map(i => i.id))
  assert.equal(again.reset, undefined)
  // A cursor that names no message any more starts over.
  const lost = opencode.readTranscript(agent, { cursor: 'msg_gone' })
  assert.equal(lost.reset, true)
  assert.equal(lost.items.length, page.items.length)

  const q = opencode.readTranscript(questionAgent, {})
  const question = q.items.find(i => i.type === 'question')
  assert.equal(question.answer, 'Blue')
  assert.equal(question.questions[0].options.length, 2)
})

test('chat: long sessions page backwards and forwards by message id', { skip: !sqliteOk && 'no node:sqlite' }, () => {
  const file = path.join(root, 'paging', 'opencode.db')
  fs.mkdirSync(path.dirname(file), { recursive: true })
  const extra = []
  for (let i = 0; i < 95; i++) {
    const id = `msg_z${String(i).padStart(4, '0')}`
    const role = i % 2 ? 'assistant' : 'user'
    extra.push({ kind: 'message', id, session_id: bashSid, time_created: 1791030000000 + i, time_updated: 0, data: JSON.stringify({ role, time: { created: 1791030000000 + i } }) })
    extra.push({ kind: 'part', id: `prt_z${String(i).padStart(4, '0')}`, message_id: id, session_id: bashSid, time_created: 1791030000000 + i, time_updated: 0, data: JSON.stringify({ type: 'text', text: `m${i}` }) })
  }
  writeDb(file, extra)
  const a = { ...agent, transcriptPath: `opencode:${file}` }
  const last = opencode.readTranscript(a, {})
  assert.equal(chatItems.validatePage(last), null)
  assert.equal(last.items.length, 40)
  assert.equal(last.items[39].text, 'm94')
  assert.ok(last.startCursor)
  const seen = new Set(last.items.map(i => i.id))
  let cursor = last.startCursor
  let pages = 0
  while (cursor) {
    const p = opencode.readTranscript(a, { beforeCursor: cursor })
    assert.equal(chatItems.validatePage(p), null)
    for (const i of p.items) { assert.ok(!seen.has(i.id), `no repeats: ${i.id}`); seen.add(i.id) }
    cursor = p.startCursor
    pages++
  }
  assert.equal(pages, 2)
  // Every recorded item plus the 95 added ones, each once.
  assert.equal(seen.size, 95 + 4)
  // Forward from the start: `more` until the end.
  const first = opencode.readTranscript(a, { cursor: FIXTURE.db.message.filter(m => m.session_id === bashSid)[0].id })
  assert.equal(first.more, true)
  const next = opencode.readTranscript(a, { cursor: first.cursor })
  assert.equal(next.items[0].id, first.items[first.items.length - 1].id)
})

test('dashboard tail: prompts, replies, tokens and OpenCode\'s cost', { skip: !sqliteOk && 'no node:sqlite' }, () => {
  const tail = opencode.readTail(agent, { since: 0, repliesSince: 0, runsSince: 0 })
  assert.deepEqual(tail.prompts.map(p => p.text), ['do it'])
  assert.deepEqual(tail.replies.map(p => p.text), ['Running a command.', 'All done.'])
  assert.equal(tail.lastReply, 'All done.')
  assert.ok(tail.tokens.input > 0 && tail.tokens.total >= tail.tokens.input)
  assert.equal(tail.costUsd, 0)
  // Nothing after the session.
  const later = opencode.readTail(agent, { since: Date.now(), repliesSince: Date.now(), runsSince: Date.now() })
  assert.equal(later.prompts.length, 0)
  assert.equal(later.tokens, null)
})

test('usage: an opencode section with tokens and cost per day, project and model', { skip: !sqliteOk && 'no node:sqlite' }, () => {
  const at = FIXTURE.db.message[0].time_created
  const r = usage.compute({ now: at + 1000, days: 7, sessions: true, env: { ...process.env, HOME: emptyDir, XDG_DATA_HOME: path.join(root, 'data') } })
  const oc = r.opencode
  assert.equal(oc.present, true)
  assert.deepEqual(oc.limits, [])
  assert.equal(oc.costSource, 'reported')
  assert.deepEqual(oc.active && [oc.active.provider, oc.active.model], ['mock', 'm1'])
  assert.equal(oc.rows.length, 1)
  assert.equal(oc.rows[0].model, 'mock/m1')
  assert.equal(oc.rows[0].provider, 'mock')
  assert.equal(oc.rows[0].messages, 4)
  assert.equal(oc.rows[0].costUsd, 0)
  assert.equal(oc.bySession.length, 2)
  assert.equal(oc.range.messages, 4)
  assert.ok(oc.range.input > 0 && oc.range.tokens === oc.range.input + oc.range.output + oc.range.cacheWrite + oc.range.cacheRead)
  // Without OpenCode data, the section says so.
  const none = usage.compute({ now: at, env: { ...process.env, HOME: emptyDir, XDG_DATA_HOME: emptyDir } })
  assert.deepEqual(none.opencode, { present: false })
})

test('install drops our plugin file only; uninstall removes only ours', () => {
  // Without XDG_CONFIG_HOME the plugin goes under HOME (a temp one here).
  const homeOnly = { PATH: '/usr/bin:/bin', HOME: path.join(root, 'home2') }
  assert.equal(opencode.pluginPath(homeOnly), path.join(root, 'home2', '.config', 'opencode', 'plugins', 'conductore.js'))
  const env = { ...process.env, HOME: path.join(root, 'home'), XDG_CONFIG_HOME: path.join(root, 'cfg') }
  const hookBin = path.join(__dirname, '..', 'bin', 'conductore-hook')
  const dir = path.join(root, 'cfg', 'opencode')
  fs.mkdirSync(path.join(dir, 'plugins'), { recursive: true })
  const config = '{"model": "x/y", "permission": {"bash": "ask"}}\n'
  fs.writeFileSync(path.join(dir, 'opencode.json'), config)
  fs.writeFileSync(path.join(dir, 'plugins', 'other.js'), 'export default {}\n')
  const r = opencode.install({ hookBin, env })
  assert.equal(r.action, 'installed')
  assert.equal(r.plugin, path.join(dir, 'plugins', 'conductore.js'))
  const text = fs.readFileSync(r.plugin, 'utf8')
  assert.ok(text.includes(opencode.PLUGIN_MARK))
  assert.ok(text.includes(`const HOOK = ${JSON.stringify(hookBin)}`))
  assert.ok(!text.includes('__CONDUCTORE_HOOK__'))
  assert.equal(opencode.install({ hookBin, env }).action, 'unchanged')
  assert.equal(fs.readFileSync(path.join(dir, 'opencode.json'), 'utf8'), config)
  assert.equal(opencode.uninstall({ env }).removed, true)
  assert.ok(!fs.existsSync(r.plugin))
  assert.ok(fs.existsSync(path.join(dir, 'plugins', 'other.js')))
  assert.equal(opencode.uninstall({ env }).removed, false)
  // Someone else's conductore.js is kept as a backup, and never removed.
  fs.writeFileSync(r.plugin, 'export default { id: "mine" }\n')
  assert.equal(opencode.uninstall({ env }).removed, false)
  const again = opencode.install({ hookBin, env })
  assert.equal(again.action, 'updated')
  assert.equal(fs.readFileSync(again.backup, 'utf8'), 'export default { id: "mine" }\n')
  assert.equal(opencode.install({ hookBin: path.join(emptyDir, 'nope'), env }).error.startsWith('client not found'), true)
  assert.equal(fs.readFileSync(path.join(dir, 'opencode.json'), 'utf8'), config)
})

test('brain: opencode run --pure, in-memory database, every tool off, the prompt on stdin', async () => {
  const env = opencode.brainEnv({ PATH: '/bin' })
  assert.equal(env.CONDUCTORE_BRAIN, '1')
  assert.equal(env.OPENCODE_DB, ':memory:')
  assert.deepEqual(JSON.parse(env.OPENCODE_PERMISSION), { '*': 'deny' })
  assert.deepEqual(JSON.parse(env.OPENCODE_CONFIG_CONTENT), { agent: { build: { tools: { '*': false } } } })
  assert.deepEqual(opencode.brain.args({ model: 'haiku' }), ['run', '--pure', '--format', 'json'])
  assert.deepEqual(opencode.brain.args({ model: 'openai/gpt-5-mini' }).slice(-2), ['-m', 'openai/gpt-5-mini'])
  assert.deepEqual(opencode.brain.args({ model: 'a/b; rm -rf /' }), ['run', '--pure', '--format', 'json'])
  assert.equal(opencode.brain.locate({ PATH: emptyDir, HOME: emptyDir }), null)

  // A fake opencode: checks the environment and stdin, prints NDJSON like 1.18.34.
  const bin = path.join(root, 'fakebin')
  fs.mkdirSync(bin, { recursive: true })
  fs.writeFileSync(path.join(bin, 'opencode'), `#!/bin/sh
in=$(cat)
[ "$CONDUCTORE_BRAIN" = 1 ] && [ "$OPENCODE_DB" = ":memory:" ] || { echo bad env >&2; exit 3; }
case $in in *SYSTEM*PROMPT*) ;; *) echo bad stdin >&2; exit 4 ;; esac
echo '{"type":"step_start","part":{"type":"step-start"}}'
echo '{"type":"text","part":{"type":"text","text":"{\\"summary\\": \\"ok\\"}"}}'
echo '{"type":"step_finish","part":{"type":"step-finish","tokens":{"input":10,"output":3,"reasoning":1,"cache":{"read":5,"write":0}},"cost":0.002}}'
`, { mode: 0o755 })
  const runner = opencode.brain.locate({ PATH: `${bin}:/usr/bin:/bin`, HOME: emptyDir })
  assert.equal(runner.agent, 'opencode')
  const o = await runner.run({ system: 'SYSTEM', prompt: 'PROMPT', schema: { type: 'object' }, model: 'haiku', timeoutMs: 10000 })
  assert.equal(o.ok, true, o.message)
  assert.deepEqual(o.answer, { summary: 'ok' })
  assert.deepEqual(o.tokens, { input: 10, output: 4, cacheWrite: 0, cacheRead: 5, total: 19 })
  assert.equal(o.costUsd, 0.002)
  fs.writeFileSync(path.join(bin, 'opencode'), '#!/bin/sh\nsleep 5\n', { mode: 0o755 })
  const slow = await opencode.brain.locate({ PATH: `${bin}:/usr/bin:/bin`, HOME: emptyDir }).run({ system: 's', prompt: 'p', timeoutMs: 300 })
  assert.equal(slow.error, 'timeout')
})

test('brain: a hung opencode is killed as a process group at the timeout, children too, and the call settles', async () => {
  const bin = path.join(root, 'fakebin-hang')
  fs.mkdirSync(bin, { recursive: true })
  const pidFile = path.join(root, 'grandchild.pid')
  // A child that keeps stdout open and ignores SIGTERM, under a parent
  // that dies on it: only a group SIGKILL ends both.
  fs.writeFileSync(path.join(bin, 'opencode'), `#!/bin/sh
cat >/dev/null
sh -c 'trap "" TERM; echo $$ > ${pidFile}; while :; do sleep 1; done' &
wait
`, { mode: 0o755 })
  const runner = opencode.brain.locate({ PATH: `${bin}:/usr/bin:/bin`, HOME: emptyDir })
  let child = null
  const started = Date.now()
  const o = await runner.run({ system: 's', prompt: 'p', timeoutMs: 400, onChild: c => { child = c } })
  assert.equal(o.error, 'timeout')
  assert.ok(Date.now() - started < 4000, `settled ${Date.now() - started} ms after start`)
  assert.ok(child && child.spawnargs, 'the caller got the child (for its signal handler)')
  const pid = Number(fs.readFileSync(pidFile, 'utf8'))
  let alive = true
  for (let i = 0; i < 50 && alive; i++) {
    try { process.kill(pid, 0); await new Promise(resolve => setTimeout(resolve, 50)) } catch { alive = false }
  }
  assert.equal(alive, false, 'the grandchild is gone')
})

test('only an opencode process is taken for the agent', () => {
  assert.equal(opencode.identifyProcess(process.pid), null)
  assert.equal(opencode.identifyProcess(0), null)
  assert.equal(opencode.identifyProcess('1; rm'), null)
})

test("the app's OpenCode transcript fixture is what the adapter reads today", { skip: !sqliteOk && 'no node:sqlite' }, () => {
  const file = path.join(__dirname, '..', '..', 'test', 'fixtures', 'agent_adapters', 'opencode_transcript.json')
  const dir = path.join(root, 'app-fixture')
  fs.mkdirSync(dir, { recursive: true })
  const replies = require('./fixtures/opencode-transcript').replies(dir)
  assert.deepEqual(JSON.parse(fs.readFileSync(file, 'utf8')), JSON.parse(JSON.stringify(replies)), 'regenerate: node host/test/fixtures/opencode-transcript.js > test/fixtures/agent_adapters/opencode_transcript.json')
})

test('doctor: nothing where OpenCode is missing; informative checks where it is', async () => {
  assert.deepEqual(await opencode.doctor({ env: { PATH: emptyDir, HOME: emptyDir } }), [])
  const bin = path.join(root, 'docbin')
  fs.mkdirSync(bin, { recursive: true })
  fs.writeFileSync(path.join(bin, 'opencode'), '#!/bin/sh\necho 1.18.34\n', { mode: 0o755 })
  const env = { PATH: `${bin}:/usr/bin:/bin`, HOME: emptyDir, XDG_CONFIG_HOME: path.join(root, 'doccfg') }
  const hookBin = path.join(__dirname, '..', 'bin', 'conductore-hook')
  let checks = await opencode.doctor({ env, hookBin })
  assert.ok(checks.every(c => c.optional === true))
  assert.equal(checks.find(c => c.name === 'OpenCode').detail.endsWith('1.18.34'), true)
  assert.equal(checks.find(c => c.name === 'OpenCode plugin').ok, false)
  opencode.install({ hookBin, env })
  checks = await opencode.doctor({ env, hookBin })
  assert.equal(checks.find(c => c.name === 'OpenCode plugin').ok, true)
})
