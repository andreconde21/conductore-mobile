'use strict'

// The Cursor CLI adapter (CON-073) against what a real Cursor `agent`
// 2026.10.01 wrote, run in Docker against a mock of Cursor's API
// (test/fixtures/cursor/README.md): the adapter contract, hooks.json
// registration, events, the watch-only approval, the transcript pages,
// the agent process, and Cursor's copies of the Claude Code hooks.

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('fs')
const path = require('path')
const { execFileSync, spawn } = require('child_process')
const { tempDir, cleanup, guardRealConfigs } = require('./helpers/cleanup')
// Taken before anything runs; checked by the last test.
const realConfigs = guardRealConfigs()

const root = tempDir('conductore-cursor-')
const home = path.join(root, 'state')
process.env.CONDUCTORE_HOME = home
process.env.CONDUCTORE_SOCKET = path.join(root, 'none.sock')
const emptyDir = path.join(root, 'empty')
fs.mkdirSync(emptyDir, { recursive: true })

const FIX = path.join(__dirname, 'fixtures', 'cursor', '2026.10.01')
// A temp HOME with the cli-config.json Cursor wrote (allowlist mode,
// Shell(ls) allowed): what wouldAsk() reads.
const userHome = path.join(root, 'home')
fs.mkdirSync(path.join(userHome, '.cursor'), { recursive: true })
fs.copyFileSync(path.join(FIX, 'cli-config.json'), path.join(userHome, '.cursor', 'cli-config.json'))
process.env.HOME = userHome
delete process.env.CURSOR_CONFIG_DIR
delete process.env.XDG_CONFIG_HOME
delete process.env.CURSOR_DATA_DIR

const adapters = require('../lib/adapters')
const cursor = require('../lib/adapters/cursor')
const claude = require('../lib/adapters/claude')
const ct = require('../lib/adapters/cursor-transcript')
const chatItems = require('../lib/adapters/chat-items')
const state = require('../lib/state')
const paths = require('../lib/paths')
const { contract } = require('./helpers/adapter-contract')

test.after(() => cleanup())

const TRANSCRIPT = path.join(FIX, 'transcript-tui.jsonl')
const ABORTED = path.join(FIX, 'transcript-aborted.jsonl')
const readJsonl = file => fs.readFileSync(file, 'utf8').trim().split('\n').map(l => JSON.parse(l))
const hookLines = readJsonl(path.join(FIX, 'hooks-tui.jsonl'))
const claudeLines = readJsonl(path.join(FIX, 'claude-hooks-in-cursor.jsonl'))
const SID = hookLines[0].body.conversation_id
const clone = v => JSON.parse(JSON.stringify(v))

const events = hookLines.map(h => ({ header: { event: h.event, agent: 'cursor' }, body: clone(h.body) }))
const norm = (h, header = {}) => cursor.normalize(clone(h.body), { kind: 'hook', event: h.event, agent: 'cursor', ...header })

const fixtures = {
  events,
  sessionId: SID,
  agent: { sessionId: SID, kind: 'cursor', transcriptPath: TRANSCRIPT },
  missing: { sessionId: 'gone', kind: 'cursor', transcriptPath: path.join(root, 'gone', 'gone.jsonl') },
  emptyDir
}

for (const c of contract(cursor, fixtures)) test(`cursor adapter contract: ${c.name}`, c.fn)

test('the registry knows Cursor; it reports watch-only approvals, neutral chat and its launch command', () => {
  assert.equal(adapters.forHeader({ kind: 'hook', agent: 'cursor' }), cursor)
  assert.deepEqual(adapters.ids().slice(0, 3), ['claude', 'codex', 'opencode'])
  const caps = adapters.capabilityMap().cursor
  assert.equal(caps.label, 'Cursor')
  assert.equal(caps.approvals, 'observe')
  assert.equal(caps.chat, 'items')
  assert.equal(caps.brain, false)
  assert.equal(caps.launch, 'cursor-agent')
  assert.equal(typeof cursor.hookAnswer, 'undefined')
})

// --- hooks.json -----------------------------------------------------------------

const hookBin = path.join(__dirname, '..', 'bin', 'conductore-hook')

// The hook types Cursor 2026.10.01 accepts in hooks.json (its validator
// rejects the whole file on an unknown one).
const CURSOR_HOOK_TYPES = ['beforeShellExecution', 'beforeMCPExecution', 'afterShellExecution', 'afterMCPExecution', 'beforeReadFile', 'afterFileEdit', 'beforeTabFileRead', 'afterTabFileEdit', 'stop', 'beforeSubmitPrompt', 'afterAgentResponse', 'afterAgentThought', 'sessionStart', 'sessionEnd', 'preCompact', 'subagentStart', 'subagentStop', 'preToolUse', 'postToolUse', 'postToolUseFailure', 'workspaceOpen']

function cursorHome (name) {
  const dir = path.join(root, name)
  fs.mkdirSync(path.join(dir, '.cursor'), { recursive: true })
  return { HOME: dir, PATH: emptyDir }
}

test('install adds our hooks to ~/.cursor/hooks.json, keeps the user\'s, is idempotent, backs up and never touches cli-config.json', () => {
  const env = cursorHome('install')
  const file = path.join(env.HOME, '.cursor', 'hooks.json')
  const config = path.join(env.HOME, '.cursor', 'cli-config.json')
  const theirs = { version: 1, hooks: { beforeShellExecution: [{ command: '/usr/bin/their-guard', matcher: 'rm', failClosed: true }], stop: [{ command: 'notify-send done' }] } }
  fs.writeFileSync(file, JSON.stringify(theirs), { mode: 0o640 })
  fs.writeFileSync(config, '{"version":1,"approvalMode":"allowlist"}')

  const r = cursor.install({ hookBin, env })
  assert.equal(r.error, undefined)
  assert.equal(r.changed, true)
  const doc = JSON.parse(fs.readFileSync(file, 'utf8'))
  assert.equal(doc.version, 1)
  assert.deepEqual(doc.hooks.beforeShellExecution[0], theirs.hooks.beforeShellExecution[0])
  assert.deepEqual(doc.hooks.stop[0], theirs.hooks.stop[0])
  assert.deepEqual(cursor.installed(doc).sort(), [...cursor.EVENTS].sort())
  for (const event of Object.keys(doc.hooks)) assert.ok(CURSOR_HOOK_TYPES.includes(event), `Cursor knows ${event}`)
  const ours = doc.hooks.preToolUse[0]
  assert.equal(ours.command, `'${hookBin}' --agent cursor preToolUse`)
  // Never blocking: no failClosed, a short timeout.
  assert.equal(ours.failClosed, undefined)
  assert.ok(ours.timeout > 0 && ours.timeout <= 30)
  assert.equal(fs.statSync(file).mode & 0o777, 0o640)
  assert.deepEqual(JSON.parse(fs.readFileSync(`${file}.bak`, 'utf8')), theirs)
  assert.equal(fs.readFileSync(config, 'utf8'), '{"version":1,"approvalMode":"allowlist"}')

  const again = cursor.install({ hookBin, env })
  assert.equal(again.changed, false)
  assert.deepEqual(JSON.parse(fs.readFileSync(file, 'utf8')), doc)

  // A moved client replaces our handlers in place.
  const moved = path.join(root, 'moved', 'conductore-hook')
  fs.mkdirSync(path.dirname(moved), { recursive: true })
  fs.copyFileSync(hookBin, moved)
  cursor.install({ hookBin: moved, env })
  const doc2 = JSON.parse(fs.readFileSync(file, 'utf8'))
  assert.equal(doc2.hooks.stop.length, 2)
  assert.equal(doc2.hooks.stop[1].command, `'${moved}' --agent cursor stop`)

  const u = cursor.uninstall({ env })
  assert.deepEqual(u.removed.sort(), [...cursor.EVENTS].sort())
  assert.deepEqual(JSON.parse(fs.readFileSync(file, 'utf8')), theirs)
})

test('install creates hooks.json when there is none, and refuses one it cannot parse', () => {
  const env = cursorHome('fresh')
  const file = path.join(env.HOME, '.cursor', 'hooks.json')
  assert.equal(cursor.install({ hookBin, env }).changed, true)
  assert.equal(JSON.parse(fs.readFileSync(file, 'utf8')).version, 1)
  const bad = cursorHome('bad')
  fs.writeFileSync(path.join(bad.HOME, '.cursor', 'hooks.json'), '{ nope')
  assert.match(cursor.install({ hookBin, env: bad }).error, /cannot parse/)
  assert.equal(fs.readFileSync(path.join(bad.HOME, '.cursor', 'hooks.json'), 'utf8'), '{ nope')
})

// --- events -----------------------------------------------------------------------

test('the recorded session maps onto the daemon vocabulary', () => {
  const out = hookLines.map(h => norm(h)).filter(Boolean)
  assert.deepEqual(out.map(e => e.hook_event_name), [
    'SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PermissionRequest', 'PostToolUse', 'Stop', 'Notification',
    'UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'Notification', 'Stop', 'SessionEnd'
  ])
  for (const e of out) {
    assert.equal(e.session_id, SID)
    assert.equal(e.cwd, '/home/u/proj')
    assert.equal(e.agent_kind, 'cursor')
  }
  const pre = out.find(e => e.hook_event_name === 'PreToolUse')
  assert.equal(pre.tool_name, 'Bash')
  assert.deepEqual(pre.tool_input, { command: 'echo hello-from-cursor', cwd: '/home/u/proj' })
  assert.equal(pre.cursor_tool_name, 'Shell')
  assert.equal(out[1].prompt, 'run the echo command')
  // transcript_path is null until the first turn was written: the file's
  // name is Cursor's, under the data dir of this HOME.
  assert.equal(out[0].transcript_path, path.join(userHome, '.cursor', 'projects', 'home-u-proj', 'agent-transcripts', SID, `${SID}.jsonl`))
  const end = hookLines.at(-1).body
  assert.equal(cursor.transcriptPathFor('/home/u/proj', SID, { HOME: '/home/u' }), end.transcript_path)
})

test('only a command Cursor will ask about becomes a request, and the phone can only watch it', () => {
  const shells = hookLines.filter(h => h.event === 'beforeShellExecution')
  // echo is not allowlisted: Cursor showed "Run this command?".
  const req = norm(shells[0])
  assert.equal(req.hook_event_name, 'PermissionRequest')
  assert.equal(req.answerable, false)
  assert.equal(req.tool_kind, 'bash')
  assert.equal(req.tool_input.command, 'echo hello-from-cursor')
  // ls is (Shell(ls) in cli-config.json): it ran without asking.
  assert.equal(norm(shells[1]), null)
  const ask = command => cursor.wouldAsk({ command, sandbox: false }, {})
  assert.equal(ask('ls -la && ls'), false)
  assert.equal(ask('ls && rm -rf build'), true)
  assert.equal(ask('FOO=1 ls'), false)
  assert.equal(cursor.wouldAsk({ command: 'echo x', sandbox: true }, {}), false)
  assert.deepEqual(cursor.simpleCommands('a b && c | d; e\nf || g'), ['a b', 'c', 'd', 'e', 'f', 'g'])
})

test('Run Everything, Auto-review and a denied command never reach the phone', () => {
  const dir = path.join(root, 'modes')
  fs.mkdirSync(dir, { recursive: true })
  const env = mode => {
    fs.writeFileSync(path.join(dir, 'cli-config.json'), JSON.stringify({ version: 1, approvalMode: mode, permissions: { allow: [], deny: ['Shell(rm)'] } }))
    return { HOME: root, CURSOR_CONFIG_DIR: dir }
  }
  assert.equal(cursor.wouldAsk({ command: 'echo x' }, {}, env('allowlist')), true)
  assert.equal(cursor.wouldAsk({ command: 'rm -rf x' }, {}, env('allowlist')), false)
  assert.equal(cursor.wouldAsk({ command: 'echo x' }, {}, env('unrestricted')), false)
  assert.equal(cursor.wouldAsk({ command: 'echo x' }, {}, env('auto-review')), false)
  assert.equal(cursor.configPath({ HOME: '/h', XDG_CONFIG_HOME: '/x' }), '/x/cursor/cli-config.json')
})

test('the reply and the turn end come in either order and the last message is the reply', () => {
  const st = state.createState()
  let t = 1000
  for (const e of hookLines.map(h => norm(h)).filter(Boolean)) {
    state.reduce(st, e, t++)
    if (e.hook_event_name === 'Stop' || e.hook_event_name === 'Notification') {
      if (st.agents[SID].state === 'waiting_input' && e.hook_event_name === 'Notification') assert.ok(st.agents[SID].lastMessage)
    }
  }
  const agent = st.agents[SID]
  assert.equal(agent.state, 'ended')
  assert.equal(agent.kind, 'cursor')
  assert.equal(agent.lastMessage, 'Listing again.The folder is empty.')
  // Turn 2: the reply came first; the Stop carries it.
  const turn2 = hookLines.slice(hookLines.findLastIndex(h => h.event === 'beforeSubmitPrompt'))
  const stop = turn2.map(h => norm(h)).filter(Boolean).find(e => e.hook_event_name === 'Stop')
  assert.equal(stop.last_assistant_message, 'Listing again.The folder is empty.')
  assert.equal(stop.output_tokens, 34)
})

test('Esc ends the turn as interrupted, without the error stop that follows it', () => {
  const base = { conversation_id: 's-esc', generation_id: 'g1', hook_event_name: 'stop', workspace_roots: ['/w'] }
  const a = cursor.normalize({ ...base, status: 'aborted' }, {})
  assert.equal(a.hook_event_name, 'Stop')
  assert.equal(a.interrupted, true)
  assert.equal(cursor.normalize({ ...base, status: 'error' }, {}), null)
  const e = cursor.normalize({ ...base, generation_id: 'g2', status: 'error' }, {})
  assert.equal(e.hook_event_name, 'StopFailure')
})

test("Cursor's copies of the Claude Code hooks are dropped by the Claude Code adapter", () => {
  assert.ok(claudeLines.length >= 8)
  for (const h of claudeLines) assert.equal(claude.normalize(clone(h.body), { kind: 'hook', event: h.event }), null, h.event)
  // Claude Code's own events are untouched.
  const own = claude.normalize({ session_id: 's', hook_event_name: 'Stop', cwd: '/w' }, { kind: 'hook', event: 'Stop' })
  assert.equal(own.agent_kind, 'claude')
})

// --- through the daemon -------------------------------------------------------------

test('a watch-only request stays pending until the command ran, and cannot be answered from the phone', async () => {
  paths.ensureDirs()
  const { Daemon } = require('../lib/daemon')
  const approvalOps = require('../lib/approval-ops')
  const d = new Daemon()
  const send = h => d.process({ header: { kind: 'hook', agent: 'cursor', event: h.event }, body: clone(h.body) })
  const upTo = hookLines.findIndex(h => h.event === 'beforeShellExecution')
  for (const h of hookLines.slice(0, upTo + 1)) await send(h)
  const agent = d.state.agents[SID]
  assert.equal(agent.state, 'needs_permission')
  assert.equal(agent.pending.length, 1)
  const [p] = agent.pending
  assert.equal(p.answerable, false)
  assert.equal(p.toolName, 'Bash')
  assert.equal(p.summary, 'echo hello-from-cursor')
  assert.ok(p.risk)
  assert.equal(d.waiters.size, 0)
  // The phone cannot answer it, nor approve it in a batch or trust it.
  const written = []
  d.handleDecide({ requestId: p.id, decision: 'allow' }, { write: s => written.push(JSON.parse(s)), end () {} })
  assert.deepEqual(written, [{ error: 'this agent asks in the terminal; answer it there' }])
  const low = approvalOps.handle(d, { op: 'approve-low' })
  assert.deepEqual(low.approved, [])
  assert.equal(approvalOps.handle(d, { op: 'trust', requestId: p.id }).error, 'this agent asks in the terminal; nothing was trusted')
  assert.equal(d.state.agents[SID].pending.length, 1)
  // The user answered "Run" in the terminal: the command ran.
  await send(hookLines.find((h, i) => i > upTo && h.event === 'postToolUse'))
  assert.equal(d.state.agents[SID].pending.length, 0)
  assert.equal(d.state.agents[SID].state, 'working')
})

// --- chat -----------------------------------------------------------------------------

const brief = it => [it.type, it.type === 'tool' ? `${it.tool}:${it.toolKind}:${it.title}:${it.result && it.result.ok}` : it.text || '']

test('the transcript reads as neutral items: prompts without Cursor\'s wrapper, replies, finished shell calls', () => {
  const page = cursor.readTranscript(fixtures.agent, {})
  assert.equal(chatItems.validatePage(page), null)
  assert.deepEqual(page.items.map(brief), [
    ['user', 'run the echo command'],
    ['assistant', 'I will run a command.'],
    ['tool', 'Shell:bash:echo hello-from-cursor:true'],
    ['assistant', 'Done: it printed hello-from-cursor.'],
    ['user', 'list it again'],
    ['assistant', 'Listing again.'],
    ['tool', 'Shell:bash:ls:true'],
    ['assistant', 'The folder is empty.']
  ])
  assert.equal(page.cursor, 'L7')
  assert.equal(page.startCursor, null)
  assert.equal(page.more, false)
  // Nothing new: an empty page on the same cursor.
  const next = cursor.readTranscript(fixtures.agent, { cursor: page.cursor })
  assert.deepEqual(next.items, [])
  assert.equal(next.cursor, 'L7')
})

test('a tool call at the end of the file is sent again, with its result, once the next line is written', () => {
  const file = path.join(root, 'growing', 'g.jsonl')
  fs.mkdirSync(path.dirname(file), { recursive: true })
  const lines = fs.readFileSync(TRANSCRIPT, 'utf8').split('\n')
  fs.writeFileSync(file, lines.slice(0, 2).join('\n') + '\n')
  const agent = { sessionId: 'g', kind: 'cursor', transcriptPath: file }
  const first = cursor.readTranscript(agent, {})
  const tool = first.items.find(i => i.type === 'tool')
  assert.equal(tool.result, null)
  assert.equal(first.cursor, 'L1')
  fs.appendFileSync(file, lines[2] + '\n')
  const second = cursor.readTranscript(agent, { cursor: first.cursor })
  const again = second.items.find(i => i.id === tool.id)
  assert.deepEqual(again.result, { ok: true, text: '' })
  assert.equal(second.cursor, 'L3')
  // Rewritten shorter (Cursor pruned it): start over.
  fs.writeFileSync(file, lines[0] + '\n')
  const reset = cursor.readTranscript(agent, { cursor: 'L3' })
  assert.equal(reset.reset, true)
  assert.equal(reset.items.length, 1)
})

test('earlier pages, an interrupted turn, and missing or legacy files', () => {
  const lines = fs.readFileSync(TRANSCRIPT, 'utf8').trim().split('\n')
  const file = path.join(root, 'long', 'l.jsonl')
  fs.mkdirSync(path.dirname(file), { recursive: true })
  const many = []
  for (let i = 0; i < ct.PAGE_LINES + 10; i++) many.push(lines[i % 2 ? 1 : 0])
  fs.writeFileSync(file, many.join('\n') + '\n')
  const agent = { sessionId: 'l', kind: 'cursor', transcriptPath: file }
  const last = cursor.readTranscript(agent, {})
  assert.equal(last.startCursor, 'L10')
  const before = cursor.readTranscript(agent, { beforeCursor: last.startCursor })
  assert.equal(chatItems.validatePage(before), null)
  assert.equal(before.startCursor, null)
  assert.equal(before.cursor, 'L10')

  const aborted = cursor.readTranscript({ sessionId: 'a', kind: 'cursor', transcriptPath: ABORTED }, {})
  assert.deepEqual(aborted.items.map(i => [i.type, i.level, i.text]), [['notice', 'interrupted', 'Interrupted']])

  assert.match(cursor.readTranscript(fixtures.missing, {}).error, /not found/)
  assert.match(cursor.readTranscript({ sessionId: 'x', kind: 'cursor' }, {}).error, /no transcript/)
  const legacyDir = path.join(root, 'legacy', 'agent-transcripts')
  fs.mkdirSync(legacyDir, { recursive: true })
  fs.copyFileSync(TRANSCRIPT, path.join(legacyDir, 'abc.jsonl'))
  const legacy = cursor.readTranscript({ sessionId: 'abc', kind: 'cursor', transcriptPath: path.join(legacyDir, 'abc', 'abc.jsonl') }, {})
  assert.equal(legacy.items.length, 8)
})

test("the app's Cursor chat fixture is what the adapter reads from the real session today", () => {
  const file = path.join(__dirname, '..', '..', 'test', 'fixtures', 'agent_adapters', 'cursor_chat_page.json')
  const saved = JSON.parse(fs.readFileSync(file, 'utf8'))
  const { sessionId, agent, ...page } = saved
  assert.equal(sessionId, SID)
  assert.equal(agent.state, 'waiting_input')
  assert.deepEqual(page, JSON.parse(JSON.stringify(cursor.readTranscript(fixtures.agent, {}))))
})

// --- process ---------------------------------------------------------------------------

test('the agent process is recognised by Cursor\'s command line, not by its comm', async () => {
  // Cursor's layout: <dir>/cursor-agent/versions/<v>/index.js run by node.
  const dir = path.join(root, 'cursor-agent', 'versions', '2026.10.01-e373342')
  fs.mkdirSync(dir, { recursive: true })
  const script = path.join(dir, 'index.js')
  fs.writeFileSync(script, 'setTimeout(() => {}, 30000)\n')
  const child = spawn(process.execPath, [script, '--force'], { stdio: 'ignore' })
  const worker = spawn(process.execPath, [script, 'worker'], { stdio: 'ignore' })
  try {
    await new Promise(resolve => setTimeout(resolve, 150))
    const found = cursor.identifyProcess(child.pid)
    assert.equal(found && found.pid, child.pid)
    assert.equal(cursor.identifyProcess(worker.pid), null)
    // A session started with --force never asks: no request.
    assert.equal(cursor.wouldAsk({ command: 'echo x' }, { claude_pid: String(child.pid) }), false)
    assert.ok(cursor.isCursorAgent(['/home/u/.local/bin/agent', '--use-system-ca', '/home/u/.local/share/cursor-agent/versions/2026.10.01-e373342/index.js']))
    assert.equal(cursor.isCursorAgent(['/usr/bin/agent', 'run']), false)
  } finally {
    child.kill()
    worker.kill()
  }
})

test('the sh hook writes a Cursor event with agent=cursor and Cursor\'s payload untouched', () => {
  const hookHome = path.join(root, 'hookhome')
  const env = { PATH: process.env.PATH, HOME: root, CONDUCTORE_HOME: hookHome, CONDUCTORE_SOCKET: path.join(root, 'none.sock'), TMUX_TMPDIR: root }
  // A daemon that cannot start (no node recorded, spawn.at fresh).
  fs.mkdirSync(path.join(hookHome, 'spool'), { recursive: true })
  fs.mkdirSync(path.join(hookHome, 'tmp'), { recursive: true })
  fs.writeFileSync(path.join(hookHome, 'spool.at'), '')
  fs.writeFileSync(path.join(hookHome, 'spawn.at'), `${Math.floor(Date.now() / 1000)}\n`)
  const body = hookLines.find(h => h.event === 'beforeShellExecution').body
  const out = execFileSync(hookBin, ['--agent', 'cursor', 'beforeShellExecution'], { env, input: JSON.stringify(body) })
  // Never a decision: Cursor goes on with its own prompt.
  assert.equal(out.length, 0)
  const [name] = fs.readdirSync(path.join(hookHome, 'spool'))
  const text = fs.readFileSync(path.join(hookHome, 'spool', name), 'utf8')
  assert.match(text, /^conductore 1\nkind=hook\nevent=beforeShellExecution\n/)
  assert.match(text, /\nagent=cursor\n/)
  assert.ok(!/\nfifo=/.test(text))
  assert.deepEqual(JSON.parse(text.slice(text.indexOf('\n\n') + 2)), body)
})

test('no test touched the real agent configs (~/.claude, ~/.codex, ~/.config/opencode, ~/.cursor)', () => realConfigs())
