'use strict'

// The Codex adapter (CON-068) against what a real Codex wrote: Codex 0.160.0
// (paginated history, TUI on the shared daemon) and 0.130.0 (legacy
// history), run in Docker against a mock of the model API
// (test/fixtures/codex/README.md). The adapter contract, hooks.json
// registration and the read-only trust check, events, the hook answers,
// the chat pages and their cursors, the process of a daemon-run hook,
// accounts and the brain call.

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('fs')
const path = require('path')
const { execFileSync, spawn } = require('child_process')
const { tempDir, cleanup } = require('./helpers/cleanup')

const root = tempDir('conductore-codex-')
const home = path.join(root, 'state')
process.env.CONDUCTORE_HOME = home
process.env.CONDUCTORE_SOCKET = path.join(root, 'none.sock')
const emptyDir = path.join(root, 'empty')
fs.mkdirSync(emptyDir, { recursive: true })

const adapters = require('../lib/adapters')
const codex = require('../lib/adapters/codex')
const rollout = require('../lib/adapters/codex-rollout')
const chatItems = require('../lib/adapters/chat-items')
const state = require('../lib/state')
const paths = require('../lib/paths')
const risk = require('../lib/risk')
const { contract } = require('./helpers/adapter-contract')

test.after(() => cleanup())

const FIX = path.join(__dirname, 'fixtures', 'codex')
const TUI_ROLLOUT = path.join(FIX, '0.160.0', 'rollout-tui.jsonl')
const LEGACY_ROLLOUT = path.join(FIX, '0.130.0', 'rollout-exec-legacy.jsonl')
const hookLines = fs.readFileSync(path.join(FIX, '0.160.0', 'hooks-tui.jsonl'), 'utf8').trim().split('\n').map(l => JSON.parse(l))
const SID = hookLines[0].body.session_id
const clone = v => JSON.parse(JSON.stringify(v))

// The recorded session, with its transcript path pointing at the fixture.
const events = hookLines.map(h => ({ header: { event: h.event, agent: 'codex' }, body: { ...clone(h.body), transcript_path: TUI_ROLLOUT } }))

const fixtures = {
  events,
  sessionId: SID,
  agent: { sessionId: SID, kind: 'codex', transcriptPath: TUI_ROLLOUT },
  missing: { sessionId: 'gone', kind: 'codex', transcriptPath: path.join(root, 'gone.jsonl') },
  emptyDir
}

for (const c of contract(codex, fixtures)) test(`codex adapter contract: ${c.name}`, c.fn)

test('the registry knows Codex after Claude Code; its capabilities ask for the trust step', () => {
  assert.deepEqual(adapters.ids().slice(0, 2), ['claude', 'codex'])
  assert.equal(adapters.forHeader({ kind: 'hook', agent: 'codex' }), codex)
  const caps = adapters.capabilityMap().codex
  assert.equal(caps.label, 'Codex')
  assert.equal(caps.chat, 'items')
  assert.equal(caps.approvals, 'hook')
  assert.equal(caps.always, false)
  assert.equal(caps.accounts, 'show')
  assert.deepEqual(caps.setup, ['trust-hooks'])
})

// --- hooks.json -----------------------------------------------------------------

function codexHome (name) {
  const dir = path.join(root, name)
  fs.mkdirSync(dir, { recursive: true })
  return { CODEX_HOME: dir, HOME: root, PATH: emptyDir }
}

const hookBin = path.join(__dirname, '..', 'bin', 'conductore-hook')

test('install adds our hooks to hooks.json, keeps the user\'s in place, is idempotent and never touches config.toml', () => {
  const env = codexHome('install')
  const file = path.join(env.CODEX_HOME, 'hooks.json')
  const config = path.join(env.CODEX_HOME, 'config.toml')
  const theirs = { hooks: { PreToolUse: [{ matcher: 'Bash', hooks: [{ type: 'command', command: '/usr/bin/their-guard', timeout: 5 }] }], Stop: [{ hooks: [{ type: 'command', command: 'notify-send done' }] }] } }
  fs.writeFileSync(file, JSON.stringify(theirs), { mode: 0o640 })
  fs.writeFileSync(config, 'model = "gpt-5.5"\n')
  const configBefore = fs.readFileSync(config, 'utf8')

  const r = codex.install({ hookBin, env })
  assert.equal(r.error, undefined)
  assert.equal(r.changed, true)
  assert.equal(r.trusted, false)
  assert.match(r.next, /\/hooks/)
  const doc = JSON.parse(fs.readFileSync(file, 'utf8'))
  // Theirs first and unchanged (their trust is keyed by position).
  assert.deepEqual(doc.hooks.PreToolUse[0], theirs.hooks.PreToolUse[0])
  assert.deepEqual(doc.hooks.Stop[0], theirs.hooks.Stop[0])
  assert.deepEqual(codex.installed(doc).map(h => h.event).sort(), [...codex.EVENTS].sort())
  const pr = doc.hooks.PermissionRequest[0].hooks[0]
  assert.equal(pr.command, `'${hookBin}' --agent codex PermissionRequest`)
  assert.equal(pr.timeout, 600)
  assert.equal(pr.async, undefined)
  assert.equal(doc.hooks.SessionEnd[0].hooks[0].timeout, 3)
  assert.equal(doc.hooks.Interrupt[0].hooks[0].timeout, 3)
  assert.equal(doc.hooks.PreToolUse[1].hooks[0].async, true)
  assert.equal(fs.statSync(file).mode & 0o777, 0o640)
  assert.deepEqual(JSON.parse(fs.readFileSync(`${file}.bak`, 'utf8')), theirs)
  assert.equal(fs.readFileSync(config, 'utf8'), configBefore)

  // Again: nothing to change, nothing written.
  const mtime = fs.statSync(file).mtimeMs
  assert.equal(codex.install({ hookBin, env }).changed, false)
  assert.equal(fs.statSync(file).mtimeMs, mtime)

  // A moved client: our handlers are updated where they are.
  const moved = path.join(root, 'other bin', 'conductore-hook')
  fs.mkdirSync(path.dirname(moved), { recursive: true })
  fs.copyFileSync(hookBin, moved)
  codex.install({ hookBin: moved, env })
  const again = JSON.parse(fs.readFileSync(file, 'utf8'))
  assert.equal(again.hooks.PreToolUse.length, 2)
  assert.equal(again.hooks.PreToolUse[1].hooks[0].command, `'${moved}' --agent codex PreToolUse`)

  const u = codex.uninstall({ env })
  assert.deepEqual(u.removed.sort(), [...codex.EVENTS].sort())
  assert.deepEqual(JSON.parse(fs.readFileSync(file, 'utf8')), theirs)
  assert.equal(fs.readFileSync(config, 'utf8'), configBefore)
})

test('install refuses a hooks.json it cannot parse and leaves it alone', () => {
  const env = codexHome('broken')
  const file = path.join(env.CODEX_HOME, 'hooks.json')
  fs.writeFileSync(file, '{"hooks": ')
  assert.match(codex.install({ hookBin, env }).error, /cannot parse/)
  assert.equal(fs.readFileSync(file, 'utf8'), '{"hooks": ')
  assert.match(codex.uninstall({ env }).error, /cannot parse/)
  // A value that is not a list of groups is not ours to change.
  fs.writeFileSync(file, JSON.stringify({ hooks: { Stop: 'weird' } }))
  codex.install({ hookBin, env })
  assert.equal(JSON.parse(fs.readFileSync(file, 'utf8')).hooks.Stop, 'weird')
})

test('trust is read from config.toml [hooks.state] as Codex records it, never written', () => {
  // The state a real Codex wrote after "t" in /hooks (12 hooks trusted).
  const recorded = codex.hookStates(fs.readFileSync(path.join(FIX, '0.160.0', 'config-hooks-state.toml'), 'utf8'))
  assert.equal(recorded.size, 12)
  assert.ok([...recorded.values()].every(s => s.trusted && s.enabled))
  assert.ok(recorded.has('/work/home/.codex/hooks.json:permission_request:0:0'))

  const env = codexHome('trust')
  const file = path.join(env.CODEX_HOME, 'hooks.json')
  const config = path.join(env.CODEX_HOME, 'config.toml')
  fs.writeFileSync(file, JSON.stringify({ hooks: { PreToolUse: [{ hooks: [{ type: 'command', command: 'theirs' }] }] } }))
  codex.install({ hookBin, env })
  const doc = JSON.parse(fs.readFileSync(file, 'utf8'))
  const keys = codex.installed(doc).map(h => `${file}:${h.event.replace(/([a-z])([A-Z])/g, '$1_$2').toLowerCase()}:${h.group}:${h.handler}`)
  assert.ok(keys.includes(`${file}:pre_tool_use:1:0`))
  assert.ok(keys.includes(`${file}:user_prompt_submit:0:0`))
  const entry = k => `[hooks.state."${k}"]\ntrusted_hash = "sha256:${'a'.repeat(64)}"\n`
  fs.writeFileSync(config, 'model = "x"\n\n[hooks.state]\n\n' + keys.slice(1).map(entry).join('\n'))
  let t = codex.trustState(env)
  assert.equal(t.trusted, false)
  assert.equal(t.missing.length, 1)
  fs.writeFileSync(config, 'model = "x"\n\n[hooks.state]\n\n' + keys.map(entry).join('\n'))
  assert.equal(codex.trustState(env).trusted, true)
  fs.appendFileSync(config, `\n[hooks.state."${keys[0]}"]\nenabled = false\n`)
  t = codex.trustState(env)
  assert.equal(t.trusted, false)
  assert.equal(t.disabled.length, 1)
  assert.equal(codex.install({ hookBin, env }).changed, false)
})

// --- events ------------------------------------------------------------------------

test('Codex hook input is Claude Code\'s; apply_patch becomes an Edit of its file, Interrupt a Stop', () => {
  const patchReq = hookLines.find(h => h.event === 'PermissionRequest' && h.body.tool_name === 'apply_patch')
  const e = codex.normalize(clone(patchReq.body), { event: 'PermissionRequest' })
  assert.equal(e.tool_name, 'Edit')
  assert.equal(e.tool_input.file_path, '/work/repo/hello.txt')
  assert.match(e.tool_input.patch, /\*\*\* Add File: hello.txt/)
  assert.equal(e.tool_kind, 'edit')
  assert.equal(e.agent_kind, 'codex')
  // risk.js rates it as the edit it is.
  assert.equal(typeof risk.classify(e.tool_name, e.tool_input, { cwd: '/work/repo' }).level, 'string')

  const bashReq = hookLines.find(h => h.event === 'PermissionRequest' && h.body.tool_name === 'Bash')
  const b = codex.normalize(clone(bashReq.body), {})
  assert.equal(b.tool_name, 'Bash')
  assert.deepEqual(b.tool_input, { command: 'touch /outside.txt', description: 'Need to write outside the workspace' })
  assert.equal(b.tool_kind, 'bash')
  // Only requests get a kind; other events stay as Codex sent them.
  assert.equal(codex.normalize(clone(hookLines[2].body), {}).tool_kind, undefined)

  const stop = codex.normalize({ session_id: SID, hook_event_name: 'Interrupt', cwd: '/work/repo' }, {})
  assert.equal(stop.hook_event_name, 'Stop')
  assert.equal(stop.interrupted, true)
  for (const ev of ['PreCompact', 'PostCompact', 'SubagentStart', 'Nope']) assert.equal(codex.normalize({ session_id: SID, hook_event_name: ev }, {}), null)
  assert.equal(codex.normalize({ hook_event_name: 'Stop' }, {}), null)
  // The hook name from argv when the input lacks it.
  assert.equal(codex.normalize({ session_id: SID }, { event: 'SessionStart' }).hook_event_name, 'SessionStart')
})

test('the recorded session drives the state machine like a Claude Code one', () => {
  const st = state.createState()
  let t = 1000
  const seen = []
  for (const e of events) {
    const ev = codex.normalize(clone(e.body), e.header)
    if (ev.hook_event_name === 'PermissionRequest') ev.request_id = `r${t}`
    state.reduce(st, ev, t++)
    seen.push(st.agents[SID].state)
    if (ev.hook_event_name === 'PermissionRequest') {
      assert.equal(st.agents[SID].state, 'needs_permission')
      state.resolvePermission(st, `r${t - 1}`, 'allow')
    }
  }
  const agent = st.agents[SID]
  assert.equal(agent.kind, 'codex')
  assert.equal(agent.state, 'ended')
  assert.equal(agent.lastMessage, 'Done: I listed the files and added hello.txt.')
  assert.equal(agent.transcriptPath, TUI_ROLLOUT)
  assert.ok(seen.includes('working') && seen.includes('waiting_input'))
})

test('hook answers are the decision JSON a real Codex 0.160 accepted', () => {
  // Printed by the hook and checked in the TUI: allow ran the command,
  // deny showed "Blocked by hook" with the message.
  const req = codex.normalize(clone(hookLines.find(h => h.event === 'PermissionRequest').body), {})
  assert.equal(codex.hookAnswer(req, 'allow'), '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}\n')
  assert.equal(codex.hookAnswer(req, 'always'), '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}\n')
  assert.equal(codex.hookAnswer(req, 'deny', 'Denied from the phone'), '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied from the phone"}}}\n')
  assert.equal(codex.hookAnswer(req, 'timeout'), '\n')
  assert.equal(codex.hookAnswer(req, 'answer', null, {}), '\n')
})

// --- chat ---------------------------------------------------------------------------

const brief = it => [it.type, it.type === 'tool' ? `${it.tool}:${it.toolKind}:${it.title}:${it.result && it.result.ok}` : it.text || (it.todos && it.todos.map(t => `${t.status}:${t.text}`).join('|')) || '']

test('a paginated (0.160) session reads as the user\'s prompts, tools with their outcome, and replies', () => {
  const page = codex.readTranscript(fixtures.agent, {})
  assert.equal(chatItems.validatePage(page), null)
  assert.deepEqual(page.items.map(brief), [
    ['user', 'Touch a file outside'],
    ['thinking', ''],
    ['tool', 'exec_command:bash:touch /outside.txt:true'],
    ['tool', 'apply_patch:edit:Edit hello.txt:true'],
    ['assistant', 'Done: I listed the files and added hello.txt.'],
    ['user', 'Again please'],
    ['thinking', ''],
    // Denied from the phone (the hook's deny), so not run.
    ['tool', 'exec_command:bash:touch /outside.txt:false'],
    ['tool', 'apply_patch:edit:Edit hello.txt:false'],
    ['assistant', 'Done: I listed the files and added hello.txt.'],
    ['user', 'Third time'],
    ['thinking', ''],
    ['tool', 'exec_command:bash:touch /outside.txt:true'],
    ['tool', 'apply_patch:edit:Edit hello.txt:true'],
    ['assistant', 'Done: I listed the files and added hello.txt.']
  ])
  const call = page.items.find(i => i.id === 'call_5')
  assert.deepEqual(call.input, { command: 'touch /outside.txt', workdir: '/', description: 'Need to write outside the workspace' })
  assert.equal(page.items.find(i => i.id === 'call_10').result.text, 'Denied from the phone')
  // None of the injected context (AGENTS.md, environment, skills).
  assert.ok(!page.items.some(i => /AGENTS\.md|environment_context|skills_instructions/.test(i.text || '')))
  assert.equal(page.startCursor, null)
  assert.equal(page.cursor, String(fs.statSync(TUI_ROLLOUT).size))
  assert.equal(page.more, false)
})

test('a legacy (0.130) session reads the same way, its plan as a todo list', () => {
  const page = codex.readTranscript({ transcriptPath: LEGACY_ROLLOUT }, {})
  assert.equal(chatItems.validatePage(page), null)
  assert.deepEqual(page.items.map(brief), [
    ['user', 'Add hello.txt'],
    ['thinking', ''],
    ['tool', 'exec_command:bash:ls -la:false'],
    ['tool', 'apply_patch:edit:Edit hello.txt:false'],
    ['todo', 'completed:List files|in_progress:Add hello.txt'],
    ['assistant', 'Done: I listed the files and added hello.txt.']
  ])
})

test('cursors page forwards and backwards over the same ids', () => {
  const full = codex.readTranscript(fixtures.agent, {}).items.map(i => i.id)
  // The tail first, then older pages until the start.
  let page = codex.readTranscript(fixtures.agent, { tailBytes: 12000 })
  assert.notEqual(page.startCursor, null)
  const seen = [...page.items.map(i => i.id)]
  let guard = 0
  while (page.startCursor !== null && guard++ < 20) {
    page = codex.readTranscript(fixtures.agent, { beforeCursor: page.startCursor, maxBytes: 12000 })
    assert.equal(chatItems.validatePage(page), null)
    seen.unshift(...page.items.map(i => i.id).filter(id => !seen.includes(id)))
  }
  assert.deepEqual(seen, full)
  // Forwards from the start in small steps.
  const fwd = []
  let cursor = '0'
  guard = 0
  while (guard++ < 50) {
    const p = codex.readTranscript(fixtures.agent, { cursor, maxBytes: 12000 })
    for (const it of p.items) if (!fwd.includes(it.id)) fwd.push(it.id)
    if (p.cursor === cursor && !p.more) break
    cursor = p.cursor
    if (!p.more) break
  }
  assert.deepEqual(fwd, full)
  // A cursor past the end (the file was replaced): a fresh tail, flagged.
  const reset = codex.readTranscript(fixtures.agent, { cursor: '99999999' })
  assert.equal(reset.reset, true)
  assert.equal(reset.items.length, full.length)
  // Garbage cursors read from the start / the tail, never throw.
  assert.equal(chatItems.validatePage(codex.readTranscript(fixtures.agent, { cursor: 'x' })), null)
})

test('a call still running holds the cursor, so the next page brings it with its result', () => {
  const lines = fs.readFileSync(TUI_ROLLOUT, 'utf8').split('\n')
  const callLine = lines.findIndex(l => l.includes('"type":"function_call"') && l.includes('call_5'))
  const live = path.join(root, 'live.jsonl')
  fs.writeFileSync(live, lines.slice(0, callLine + 1).join('\n') + '\n')
  const agent = { transcriptPath: live }
  const first = codex.readTranscript(agent, {})
  const running = first.items.find(i => i.id === 'call_5')
  assert.equal(running.result, null)
  const callOffset = Buffer.byteLength(lines.slice(0, callLine).join('\n') + '\n')
  assert.equal(first.cursor, String(callOffset))
  assert.equal(first.more, false)
  // Polling again before the output: the same running call, same cursor.
  assert.deepEqual(codex.readTranscript(agent, { cursor: first.cursor }).items.map(i => i.id), ['call_5'])
  // The rest arrives.
  fs.writeFileSync(live, lines.join('\n'))
  const next = codex.readTranscript(agent, { cursor: first.cursor })
  assert.equal(next.items[0].id, 'call_5')
  assert.deepEqual(next.items[0].result, { ok: true, text: '' })
  // A turn that ended without the result does not hold the cursor.
  const aborted = path.join(root, 'aborted.jsonl')
  fs.writeFileSync(aborted, lines.slice(0, callLine + 1).join('\n') + '\n' + JSON.stringify({ timestamp: '2026-10-03T12:10:00.000Z', type: 'event_msg', payload: { type: 'turn_aborted', reason: 'interrupted' } }) + '\n')
  const ab = codex.readTranscript({ transcriptPath: aborted }, {})
  assert.deepEqual(ab.items.find(i => i.id === 'call_5').result, { ok: false, text: 'Interrupted' })
  assert.equal(ab.items.at(-1).level, 'interrupted')
  assert.equal(ab.cursor, String(fs.statSync(aborted).size))
})

test('a line longer than a page is skipped instead of stalling', () => {
  const big = path.join(root, 'big.jsonl')
  const huge = JSON.stringify({ timestamp: '2026-10-03T12:00:00.000Z', type: 'response_item', payload: { type: 'function_call_output', call_id: 'x', output: 'y'.repeat(300 * 1024) } })
  const after = JSON.stringify({ timestamp: '2026-10-03T12:00:01.000Z', type: 'response_item', payload: { type: 'message', role: 'assistant', content: [{ type: 'output_text', text: 'after' }] } })
  fs.writeFileSync(big, huge + '\n' + after + '\n')
  const p1 = codex.readTranscript({ transcriptPath: big }, { cursor: '0' })
  assert.deepEqual(p1.items, [])
  assert.equal(p1.cursor, String(Buffer.byteLength(huge) + 1))
  assert.equal(p1.more, true)
  const p2 = codex.readTranscript({ transcriptPath: big }, { cursor: p1.cursor })
  assert.deepEqual(p2.items.map(i => i.text), ['after'])
})

test('missing or odd session files give the error transcript prints', () => {
  assert.match(codex.readTranscript({}, {}).error, /no session file/)
  assert.match(codex.readTranscript({ transcriptPath: 'rel.jsonl' }, {}).error, /absolute/)
  assert.match(codex.readTranscript(fixtures.missing, {}).error, /not found/)
})

test('the dashboard tail: prompts, replies, command runs and tokens of the window', () => {
  const tail = codex.readTail(fixtures.agent, { since: 0, repliesSince: 0, runsSince: 0 })
  assert.deepEqual(tail.prompts.map(p => p.text), ['Again please', 'Third time'])
  assert.equal(tail.lastReply, 'Done: I listed the files and added hello.txt.')
  assert.deepEqual(tail.runs.map(r => [r.command, r.ok]), [['touch /outside.txt', true], ['touch /outside.txt', false], ['touch /outside.txt', true]])
  // The session's totals (last token_count): 10800 in (1800 cached), 720 out.
  assert.deepEqual(tail.tokens, { input: 9000, output: 720, cacheWrite: 0, cacheRead: 1800, total: 11520 })
  const legacy = codex.readTail({ transcriptPath: LEGACY_ROLLOUT }, { since: 0 })
  assert.deepEqual(legacy.prompts.map(p => p.text), ['Add hello.txt'])
  // Only what came after `since`.
  const late = codex.readTail(fixtures.agent, { since: Date.parse('2026-10-03T12:08:51Z'), repliesSince: Date.parse('2026-10-03T12:08:51Z') })
  assert.deepEqual(late.prompts.map(p => p.text), ['Third time'])
  assert.ok(late.tokens.input < tail.tokens.input)
})

// --- process and location -------------------------------------------------------------

// Stand-ins for Codex processes: /bin/sh under the name `codex` (its comm),
// with the arguments that make it the daemon or a TUI.
function fakeCodex (dir, args, env, cwd) {
  const bin = path.join(dir, 'codex')
  if (!fs.existsSync(bin)) fs.symlinkSync('/bin/sh', bin)
  const child = spawn(bin, ['-c', 'sleep 30; :', ...args], { cwd, env: { PATH: process.env.PATH, ...env }, stdio: 'ignore' })
  return child
}

const waitComm = async pid => {
  for (let i = 0; i < 50; i++) {
    try { if (fs.readFileSync(`/proc/${pid}/comm`, 'utf8').trim() === 'codex') return } catch {}
    await new Promise(resolve => setTimeout(resolve, 20))
  }
}

test('a hook run by the shared daemon is placed in the TUI of its session, by working directory', { skip: !fs.existsSync('/proc/self/environ') }, async () => {
  const bin = path.join(root, 'fakebin')
  fs.mkdirSync(bin, { recursive: true })
  const repo = path.join(root, 'repo')
  const other = path.join(root, 'other')
  fs.mkdirSync(repo, { recursive: true })
  fs.mkdirSync(other, { recursive: true })
  const daemon = fakeCodex(bin, ['app-server'], { TMUX: '/tmp/tmux-1/default,1,0', TMUX_PANE: '%1' }, root)
  const tui = fakeCodex(bin, [], { TMUX: '/tmp/tmux-1/default,1,0', TMUX_PANE: '%7', HERDR_PANE_ID: 'p7' }, repo)
  const elsewhere = fakeCodex(bin, [], { TMUX_PANE: '%8' }, other)
  try {
    await Promise.all([daemon, tui, elsewhere].map(c => waitComm(c.pid)))
    assert.equal(codex.identifyProcess(daemon.pid), null, 'the daemon is never the agent')
    assert.equal(codex.identifyProcess(tui.pid).pid, tui.pid)
    const header = { kind: 'hook', agent: 'codex', claude_pid: String(daemon.pid), tmux: '/tmp/tmux-1/default,1,0', tmux_pane: '%1', fifo: '/x' }
    const event = { session_id: 'loc1', cwd: repo, hook_event_name: 'Stop' }
    const h = codex.origin(event, header)
    assert.equal(h.claude_pid, String(tui.pid))
    assert.equal(h.tmux_pane, '%7')
    assert.equal(h.herdr_pane, 'p7')
    assert.equal(h.fifo, '/x')
    // A hook a TUI ran itself (no daemon) keeps its own header.
    const own = { kind: 'hook', claude_pid: String(tui.pid), tmux_pane: '%7' }
    assert.equal(codex.origin(event, own), own)
    // Two TUIs in one directory: no pane and no process rather than a wrong one.
    const twin = fakeCodex(bin, [], { TMUX_PANE: '%9' }, repo)
    try {
      await waitComm(twin.pid)
      const amb = codex.origin({ session_id: 'loc2', cwd: repo, hook_event_name: 'Stop' }, header)
      assert.equal(amb.tmux_pane, undefined)
      assert.equal(amb.tmux, undefined)
      assert.equal(amb.claude_pid, undefined)
      assert.equal(amb.fifo, '/x')
      // A session already placed keeps its TUI while it runs.
      assert.equal(codex.origin(event, header).tmux_pane, '%7')
    } finally { twin.kill('SIGKILL') }
  } finally {
    for (const c of [daemon, tui, elsewhere]) c.kill('SIGKILL')
    codex._origins.clear()
  }
})

// --- accounts ---------------------------------------------------------------------------

test('accounts shows the active login, email masked, never a token', async () => {
  const env = codexHome('auth')
  assert.deepEqual(await codex.accounts({ env }), { present: false, accounts: [] })
  const b64 = o => Buffer.from(JSON.stringify(o)).toString('base64url')
  const idToken = `${b64({ alg: 'none' })}.${b64({ email: 'dev.person@example.com', 'https://api.openai.com/auth': { chatgpt_plan_type: 'plus' } })}.sig`
  fs.writeFileSync(path.join(env.CODEX_HOME, 'auth.json'), JSON.stringify({ OPENAI_API_KEY: null, tokens: { id_token: idToken, access_token: 'secret-access', refresh_token: 'secret-refresh', account_id: 'acc' }, last_refresh: '2026-10-01T00:00:00Z' }))
  const r = await codex.accounts({ env })
  assert.equal(r.present, true)
  assert.deepEqual(r.accounts, [{ label: 'd***@e***.com', active: true, plan: 'plus', mode: 'chatgpt' }])
  const text = JSON.stringify(r)
  for (const secret of ['secret', idToken, 'dev.person']) assert.ok(!text.includes(secret), secret)
  fs.writeFileSync(path.join(env.CODEX_HOME, 'auth.json'), JSON.stringify({ OPENAI_API_KEY: 'sk-test' }))
  assert.deepEqual((await codex.accounts({ env })).accounts, [{ label: 'API key', active: true, plan: null, mode: 'apikey' }])
})

// --- brain --------------------------------------------------------------------------------

test('the brain runs `codex exec` locked down, the prompt on stdin, and reads its JSONL', async () => {
  const args = codex.brainArgs({ schemaFile: '/s.json', model: 'm' })
  for (const a of ['--ephemeral', '--json', '--skip-git-repo-check', '--ignore-user-config', '--ignore-rules']) assert.ok(args.includes(a), a)
  assert.equal(args[args.indexOf('--sandbox') + 1], 'read-only')
  const disabled = args.filter((a, i) => args[i - 1] === '--disable')
  for (const f of ['shell_tool', 'unified_exec', 'hooks', 'plugins', 'apps', 'multi_agent']) assert.ok(disabled.includes(f), f)
  assert.ok(args.includes('web_search="disabled"'))
  assert.deepEqual(args.slice(-3), ['-m', 'm', '-'])

  // A stand-in codex that checks how it was called and prints what the
  // real `codex exec --json` printed for a schema call.
  const bin = path.join(root, 'brainbin')
  fs.mkdirSync(bin, { recursive: true })
  const log = path.join(root, 'brain.log')
  const recorded = path.join(FIX, '0.160.0', 'exec-brain.jsonl')
  fs.writeFileSync(path.join(bin, 'codex'), `#!/bin/sh\n{ echo "brain=$CONDUCTORE_BRAIN"; echo "cwd=$(pwd)"; ls -A; echo "args=$*"; echo "stdin=$(cat)"; } > '${log}'\ncat '${recorded}'\n`, { mode: 0o755 })
  // Claude Code first when both are installed; here only Codex is.
  const found = adapters.brain({ PATH: `${bin}:/usr/bin:/bin`, HOME: emptyDir }, 'codex')
  assert.equal(found.adapter, codex)
  const r = await found.runner.run({ system: 'Summarize.', prompt: '<text>hello</text>', schema: { type: 'object' }, timeoutMs: 10000 })
  assert.equal(r.ok, true)
  assert.deepEqual(r.answer, { summary: 'ok' })
  assert.equal(r.text, '{"summary":"ok"}')
  assert.deepEqual(r.tokens, { input: 1000, output: 80, cacheWrite: 0, cacheRead: 200, total: 1280 })
  const seen = fs.readFileSync(log, 'utf8')
  assert.match(seen, /^brain=1$/m)
  assert.match(seen, /--output-schema \S+schema\.json/)
  assert.match(seen, /stdin=Summarize\.\n\n<text>hello<\/text>/)
  // It ran in an empty directory of its own, removed afterwards.
  const cwd = /^cwd=(.*)$/m.exec(seen)[1]
  assert.ok(cwd.includes('conductore-codex-'))
  assert.ok(!fs.existsSync(cwd))

  fs.writeFileSync(path.join(bin, 'codex'), '#!/bin/sh\ncat >/dev/null\necho \'{"type":"error","message":"401 Unauthorized: not logged in"}\'\nexit 1\n', { mode: 0o755 })
  const out = await found.runner.run({ system: 's', prompt: 'p', timeoutMs: 10000 })
  assert.equal(out.error, 'not-logged-in')
  assert.equal(codex.brain.missing.error, 'agent-missing')
})

test('the sh hook ignores the brain\'s own calls', () => {
  const hookHome = path.join(root, 'hookhome')
  fs.mkdirSync(path.join(hookHome, 'spool'), { recursive: true })
  fs.mkdirSync(path.join(hookHome, 'tmp'), { recursive: true })
  fs.writeFileSync(path.join(hookHome, 'spawn.at'), `${Math.floor(Date.now() / 1000)}\n`)
  const env = { PATH: process.env.PATH, HOME: root, CONDUCTORE_HOME: hookHome }
  execFileSync(hookBin, ['--agent', 'codex', 'Stop'], { env: { ...env, CONDUCTORE_BRAIN: '1' } })
  assert.deepEqual(fs.readdirSync(path.join(hookHome, 'spool')), [])
  execFileSync(hookBin, ['--agent', 'codex', 'Stop'], { env, input: JSON.stringify(hookLines.at(-2).body) })
  assert.equal(fs.readdirSync(path.join(hookHome, 'spool')).length, 1)
})

// --- through the daemon ------------------------------------------------------------------

test('a Codex permission request waits in the daemon and the decision reaches the hook in Codex\'s format', async () => {
  paths.ensureDirs()
  const { Daemon } = require('../lib/daemon')
  const d = new Daemon()
  const body = h => ({ ...clone(h.body), transcript_path: TUI_ROLLOUT })
  await d.process({ header: { kind: 'hook', agent: 'codex', event: 'SessionStart' }, body: body(hookLines[0]) })
  assert.equal(d.state.agents[SID].kind, 'codex')
  const fifo = path.join(paths.tmpDir(), 'p.990002')
  execFileSync('mkfifo', ['-m', '600', fifo])
  const fd = fs.openSync(fifo, 'r+')
  try {
    const req = hookLines.find(h => h.event === 'PermissionRequest' && h.body.tool_name === 'apply_patch')
    await d.process({ header: { kind: 'hook', agent: 'codex', event: 'PermissionRequest', fifo, timeout: '30' }, body: body(req) })
    const [pending] = d.state.agents[SID].pending
    assert.equal(pending.toolName, 'Edit')
    assert.equal(pending.toolKind, 'edit')
    assert.equal(pending.summary, '/work/repo/hello.txt')
    assert.ok(pending.risk)
    assert.equal(d.settle(pending.id, 'deny', 'Denied from the phone'), true)
    const buf = Buffer.alloc(256)
    assert.equal(buf.toString('utf8', 0, fs.readSync(fd, buf)), '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied from the phone"}}}\n')
  } finally {
    fs.closeSync(fd)
    clearInterval(d.probeTimer)
  }
})

test("the app's Codex chat fixture is what the adapter reads from the real session today", () => {
  const file = path.join(__dirname, '..', '..', 'test', 'fixtures', 'agent_adapters', 'codex_chat_page.json')
  const saved = JSON.parse(fs.readFileSync(file, 'utf8'))
  const { sessionId, agent, ...page } = saved
  assert.equal(sessionId, SID)
  assert.equal(agent.state, 'waiting_input')
  assert.deepEqual(page, JSON.parse(JSON.stringify(codex.readTranscript(fixtures.agent, {}))))
})
