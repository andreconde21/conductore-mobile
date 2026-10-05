'use strict'

// `digest`: the activity log (facts from synthetic hook events, its caps and
// pruning), the stuck rules, and the command through the real CLI with a
// fake `claude` that records its argv and stdin (only-changed agents,
// rolling summaries, batching, caps, timeout, lock, the 0600 store), plus
// one run through a real daemon fed by the sh hook.

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('fs')
const os = require('os')
const path = require('path')
const { execFile, execFileSync } = require('child_process')
const { Activity, isTestCommand, lineDelta, errorSignature, MAX_ENTRIES, MAX_AGENTS, KEEP_MS } = require('../lib/activity')
const dg = require('../lib/digest')
const { tempDir, cleanup } = require('./helpers/cleanup')

const HOSTD = path.join(__dirname, '..', 'bin', 'conductore-hostd')
const HOOK = path.join(__dirname, '..', 'bin', 'conductore-hook')
const root = tempDir('cnd-digest-')
const binDir = path.join(root, 'bin')
const home = path.join(root, 'home')
const state = path.join(root, 'state')
const calls = path.join(root, 'calls')
const pidsFile = path.join(root, 'pids.json')
fs.mkdirSync(binDir)
fs.mkdirSync(home)
fs.mkdirSync(state, { mode: 0o700 })

// FAKE_MODE: ok (one summary per agent id in the input), hang (ignores
// SIGTERM, never answers), not-logged-in. Every call is written to its own file under calls/.
fs.writeFileSync(path.join(binDir, 'claude'), `#!${process.execPath}
const fs = require('fs')
const { spawn } = require('child_process')
const stdin = fs.readFileSync(0, 'utf8')
// One file per call: parallel calls must not race on a shared file.
fs.mkdirSync(${JSON.stringify(calls)}, { recursive: true })
fs.writeFileSync(${JSON.stringify(calls)} + '/' + Date.now() + '-' + process.pid + '.json',
  JSON.stringify({ args: process.argv.slice(2), stdin, thinking: process.env.MAX_THINKING_TOKENS, claudecode: process.env.CLAUDECODE || null }))
const mode = process.env.FAKE_MODE || 'ok'
if (mode === 'hang') {
  const g = spawn('/bin/sleep', ['60'], { stdio: 'ignore' })
  fs.writeFileSync(${JSON.stringify(pidsFile)}, JSON.stringify([process.pid, g.pid]))
  process.on('SIGTERM', () => {})
  setInterval(() => {}, 1000)
} else if (mode === 'not-logged-in') {
  process.stdout.write(JSON.stringify({ type: 'result', is_error: true, result: 'Not logged in · Please run /login' }) + '\\n')
  process.exit(1)
} else {
  const lines = stdin.split('\\n')
  const input = JSON.parse(lines[lines.indexOf(lines.find(l => /^<AGENTS-[0-9a-f]+>$/.test(l))) + 1])
  const agents = input.agents.map(a => ({ id: a.id, summary: '**' + a.name + '** did ' + a.replies.length + ' things.' }))
  process.stdout.write(JSON.stringify({ type: 'result', is_error: false, result: '', structured_output: { agents },
    usage: { input_tokens: 1000, output_tokens: 50, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 },
    total_cost_usd: 0.00125, modelUsage: { 'claude-haiku-4-5-20251001': {} } }) + '\\n')
}
`, { mode: 0o755 })

const env = { ...process.env, PATH: `${binDir}:/usr/bin:/bin`, HOME: home, CONDUCTORE_HOME: state, CONDUCTORE_SOCKET: path.join(state, 'none.sock'), CLAUDECODE: '1', TMUX_TMPDIR: root }
for (const k of Object.keys(env)) if (/^(HERDR_|TMUX$|TMUX_PANE)/.test(k)) delete env[k]

function cli (args, extraEnv = {}) {
  return new Promise((resolve, reject) => {
    execFile(process.execPath, [HOSTD, ...args], { env: { ...env, ...extraEnv }, timeout: 60000, maxBuffer: 4 << 20 }, (err, stdout) => {
      if (err && err.code === undefined) return reject(err)
      resolve({ code: err ? err.code : 0, json: JSON.parse(stdout.trim().split('\n').pop()) })
    })
  })
}

const readCalls = () => {
  let names = []
  try { names = fs.readdirSync(calls).filter(n => n.endsWith('.json')) } catch { return [] }
  return names
    .sort((a, b) => parseInt(a, 10) - parseInt(b, 10))
    .map(n => JSON.parse(fs.readFileSync(path.join(calls, n), 'utf8')))
}
const resetCalls = () => { fs.rmSync(calls, { recursive: true, force: true }) }
const promptOf = call => {
  const lines = call.stdin.split('\n')
  const i = lines.findIndex(l => /^<AGENTS-[0-9a-f]+>$/.test(l))
  assert.ok(i > 0, 'input between delimiters')
  assert.equal(lines[i + 2], lines[i].replace('<', '</'))
  return JSON.parse(lines[i + 1])
}

test.after(() => cleanup())

const T0 = Date.parse('2026-09-27T08:00:00Z')
const min = n => n * 60000

// --- activity -----------------------------------------------------------------

function feed (act, sid, events) {
  for (const [t, e] of events) act.onEvent({ session_id: sid, ...e }, t)
}

test('facts: turns, edits with line estimates, tests, failures, waiting time', () => {
  const act = new Activity()
  const sid = 's1'
  act.onChange({ type: 'change', sessionId: sid, agent: { state: 'working', updatedAt: T0, name: 'api', cwd: '/w/api' } })
  feed(act, sid, [
    [T0, { hook_event_name: 'UserPromptSubmit' }],
    [T0 + min(1), { hook_event_name: 'PostToolUse', tool_name: 'Edit', tool_input: { file_path: '/w/api/a.js', old_string: 'x\ny\nz', new_string: 'x\nY\nY2\nz' } }],
    [T0 + min(2), { hook_event_name: 'PostToolUse', tool_name: 'Write', tool_input: { file_path: '/w/api/b.js', content: 'one\ntwo\nthree\n' } }],
    [T0 + min(3), { hook_event_name: 'PostToolUse', tool_name: 'Edit', tool_input: { file_path: '/w/api/a.js', old_string: 'q', new_string: 'r' } }],
    [T0 + min(4), { hook_event_name: 'PostToolUse', tool_name: 'Bash', tool_input: { command: 'npm test' } }],
    [T0 + min(5), { hook_event_name: 'PostToolUseFailure', tool_name: 'Bash', tool_input: { command: 'cd api && npm test -- --grep x' }, error: 'Exit code 1\nFAIL a.test.js' }],
    [T0 + min(6), { hook_event_name: 'PostToolUseFailure', tool_name: 'Bash', tool_input: { command: 'ls /nope' }, error: 'Exit code 2' }],
    [T0 + min(6), { hook_event_name: 'PostToolUseFailure', tool_name: 'Bash', tool_input: { command: 'sleep 100' }, is_interrupt: true, error: 'interrupted' }],
    [T0 + min(7), { hook_event_name: 'PostToolUse', tool_name: 'Read', tool_input: { file_path: '/w/api/c.js' } }],
    [T0 + min(8), { hook_event_name: 'Stop' }]
  ])
  act.onChange({ type: 'change', sessionId: sid, agent: { state: 'needs_permission', updatedAt: T0 + min(10) } })
  act.onChange({ type: 'change', sessionId: sid, agent: { state: 'working', updatedAt: T0 + min(25) } })
  act.onChange({ type: 'change', sessionId: sid, agent: { state: 'waiting_input', updatedAt: T0 + min(30) } })
  // Nothing is kept of the inputs but a path, a command's first line, an
  // error's first line and hashes.
  assert.doesNotMatch(JSON.stringify(act), /Y2|three|sleep 100/)

  const f = dg.countFacts(act.agents[sid], T0 - 1, T0 + min(40), null)
  assert.equal(f.turns, 1)
  assert.equal(f.filesEdited, 2)
  assert.deepEqual(f.files, ['/w/api/a.js', '/w/api/b.js'])
  assert.equal(f.linesAdded, 2 + 3 + 1)
  assert.equal(f.linesRemoved, 1 + 0 + 1)
  assert.equal(f.lines, 'estimate')
  assert.equal(f.testRuns, 2)
  assert.equal(f.testsPassed, 1)
  assert.equal(f.testsFailed, 1)
  assert.deepEqual(f.lastTest, { ok: false, at: T0 + min(5), command: 'cd api && npm test -- --grep x' })
  assert.equal(f.commands, 1)
  assert.equal(f.failedCommands, 2)
  assert.equal(f.waitingPermissionMs, min(15))
  assert.equal(f.waitingInputMs, min(10))

  // A later window counts only what happened in it.
  const g = dg.countFacts(act.agents[sid], T0 + min(4), T0 + min(40), null)
  assert.equal(g.turns, 0)
  assert.equal(g.filesEdited, 0)
  assert.equal(g.testRuns, 2)
})

test('helpers: test runners, line deltas, error signatures', () => {
  for (const c of ['npm test', 'cd app && flutter test test/a_test.dart', 'CI=1 pytest -x', 'go test ./...', 'node --test test/*.test.js', 'cargo test', 'yarn test --watch=false']) assert.ok(isTestCommand(c), c)
  for (const c of ['npm install', 'git status', 'echo test', 'cat test.txt', 'flutter analyze']) assert.ok(!isTestCommand(c), c)
  assert.deepEqual(lineDelta('a\nb\nc', 'a\nB\nc'), [1, 1])
  assert.deepEqual(lineDelta('', 'x\ny'), [2, 0])
  assert.equal(errorSignature('Exit code 1\nError at line 42: expected 3 got 4'), errorSignature('Exit code 1\nError at line 7: expected 9 got 1'))
})

test('the log is bounded: entries per agent, agents, labels, and pruned after KEEP_MS', () => {
  const act = new Activity()
  for (let i = 0; i < MAX_ENTRIES + 50; i++) act.onEvent({ session_id: 'big', hook_event_name: 'PostToolUse', tool_name: 'Bash', tool_input: { command: `echo ${i}` } }, T0 + i)
  const a = act.agents.big
  assert.equal(a.ev.length, MAX_ENTRIES)
  assert.equal(a.dropped, 50)
  assert.equal(a.since, T0 + 50)
  assert.ok(Object.keys(a.labels).length <= 60)
  assert.equal(dg.countFacts(a, T0, T0 + 1000, null).partial, true)
  assert.equal(dg.countFacts(a, T0 + 100, T0 + 1000, null).partial, false)
  // A long command keeps its first line only, capped.
  act.onEvent({ session_id: 'big', hook_event_name: 'PostToolUse', tool_name: 'Bash', tool_input: { command: 'x'.repeat(5000) + '\nsecret line' } }, T0 + 9999)
  assert.ok(Object.values(a.labels).every(l => l.length <= 120 && !l.includes('secret')))

  for (let i = 0; i < MAX_AGENTS + 5; i++) act.onEvent({ session_id: `a${i}`, hook_event_name: 'UserPromptSubmit' }, T0 + 20000 + i)
  assert.equal(Object.keys(act.agents).length, MAX_AGENTS)
  assert.ok(!act.agents.big, 'the least recent agent went first')

  act.onEvent({ session_id: 'late', hook_event_name: 'UserPromptSubmit' }, T0 + KEEP_MS + 30000)
  act.prune(T0 + KEEP_MS + 30000)
  assert.deepEqual(Object.keys(act.agents), ['late'])
  // Round trip through JSON (activity.json).
  const back = new Activity(JSON.parse(JSON.stringify(act)))
  assert.deepEqual(back.agents, act.agents)
})

// --- stuck --------------------------------------------------------------------

test('stuck: working without edits, repeated failures and commands, long approvals, API errors', () => {
  const now = T0 + min(90)
  const t = dg.THRESHOLDS

  const quiet = new Activity()
  quiet.onChange({ type: 'change', sessionId: 'q', agent: { state: 'working', updatedAt: T0 } })
  feed(quiet, 'q', [[T0, { hook_event_name: 'UserPromptSubmit' }], [T0 + min(5), { hook_event_name: 'PostToolUse', tool_name: 'Edit', tool_input: { file_path: '/a', old_string: 'a', new_string: 'b' } }]])
  const q = dg.stuckFlags({ state: 'working', pending: [] }, quiet.agents.q, now, t)
  assert.deepEqual(q.map(f => f.rule), ['no-progress'])
  assert.match(q[0].reason, /Working 90 min without editing a file/)
  assert.deepEqual(dg.stuckFlags({ state: 'working', pending: [] }, quiet.agents.q, T0 + min(20), t), [])
  assert.deepEqual(dg.stuckFlags({ state: 'working', pending: [] }, quiet.agents.q, now, { ...t, workingMin: 120 }), [])

  const loop = new Activity()
  feed(loop, 'l', [[now - min(30), { hook_event_name: 'UserPromptSubmit' }]])
  for (let i = 0; i < 3; i++) feed(loop, 'l', [[now - min(20) + i, { hook_event_name: 'PostToolUseFailure', tool_name: 'Bash', tool_input: { command: 'npm run build' }, error: `Exit code 1\nerror TS2345 at ${i}` }]])
  const l = dg.stuckFlags({ state: 'waiting_input', pending: [] }, loop.agents.l, now, t)
  assert.deepEqual(l.map(f => f.rule), ['same-failure'])
  assert.equal(l[0].reason, '`npm run build` failed 3 times')
  // Failures before the last prompt do not count.
  feed(loop, 'l', [[now - min(1), { hook_event_name: 'UserPromptSubmit' }]])
  assert.deepEqual(dg.stuckFlags({ state: 'working', pending: [] }, loop.agents.l, now, { ...t, workingMin: 1000 }), [])

  const errs = new Activity()
  for (const c of ['a', 'b', 'c']) feed(errs, 'e', [[now - min(5), { hook_event_name: 'PostToolUseFailure', tool_name: 'Bash', tool_input: { command: `run ${c}` }, error: 'ECONNREFUSED 127.0.0.1:5432' }]])
  assert.match(dg.stuckFlags(null, errs.agents.e, now, t)[0].reason, /^The same error 3 times: ECONNREFUSED/)
  // Failures without error text are not "the same error: unknown".
  const blank = new Activity()
  for (const c of ['a', 'b', 'c', 'd']) feed(blank, 'b', [[now - min(5), { hook_event_name: 'PostToolUseFailure', tool_name: 'Bash', tool_input: { command: `run ${c}` }, error: '' }]])
  assert.deepEqual(dg.stuckFlags({ state: 'working', pending: [] }, blank.agents.b, now, { ...t, workingMin: 1000 }), [])

  const rep = new Activity()
  for (let i = 0; i < 5; i++) feed(rep, 'r', [[now - min(10) + i, { hook_event_name: 'PostToolUse', tool_name: 'Bash', tool_input: { command: 'curl localhost:3000/health' } }]])
  for (let i = 0; i < 8; i++) feed(rep, 'r', [[now - min(9) + i, { hook_event_name: 'PostToolUse', tool_name: 'Bash', tool_input: { command: 'git status' } }]])
  const r = dg.stuckFlags({ state: 'working', pending: [] }, rep.agents.r, now, { ...t, workingMin: 1000 })
  assert.deepEqual(r.map(f => [f.rule, f.reason]), [['repeating', 'Ran `curl localhost:3000/health` 5 times']])

  const perm = dg.stuckFlags({ state: 'needs_permission', pending: [{ id: 'x', createdAt: now - min(61) }] }, null, now, t)
  assert.deepEqual(perm.map(f => [f.rule, f.reason]), [['waiting-approval', 'Waiting 61 min for an approval']])
  assert.deepEqual(dg.stuckFlags({ state: 'needs_permission', pending: [{ id: 'x', createdAt: now - min(10) }] }, null, now, t), [])

  const failed = new Activity()
  feed(failed, 'x', [[now - min(3), { hook_event_name: 'UserPromptSubmit' }], [now - min(2), { hook_event_name: 'StopFailure', error: 'rate_limit' }]])
  assert.deepEqual(dg.stuckFlags({ state: 'waiting_input', pending: [] }, failed.agents.x, now, t).map(f => f.reason), ['Stopped on an API error (rate limit)'])
  feed(failed, 'x', [[now - min(1), { hook_event_name: 'UserPromptSubmit' }]])
  assert.deepEqual(dg.stuckFlags({ state: 'working', pending: [] }, failed.agents.x, now, t), [])
})

// --- the command --------------------------------------------------------------

const NOW = Date.now()

function transcript (name, entries) {
  const file = path.join(home, `${name}.jsonl`)
  fs.writeFileSync(file, entries.map(e => JSON.stringify(e)).join('\n') + '\n')
  return file
}

const assistant = (t, text, id, usage = { input_tokens: 10, output_tokens: 100, cache_read_input_tokens: 1000, cache_creation_input_tokens: 50 }) =>
  ({ type: 'assistant', timestamp: new Date(t).toISOString(), requestId: `r${id}`, message: { id: `m${id}`, role: 'assistant', model: 'claude-opus-4-1', usage, content: [{ type: 'text', text }] } })
const user = (t, text) => ({ type: 'user', timestamp: new Date(t).toISOString(), message: { role: 'user', content: text } })

// state.json and activity.json as the daemon writes them; no daemon runs.
function writeWorld (agents, activity) {
  fs.writeFileSync(path.join(state, 'state.json'), JSON.stringify({ version: 1, seq: 5, agents, writtenAt: NOW }))
  fs.writeFileSync(path.join(state, 'activity.json'), JSON.stringify(activity))
}

function agentRecord (sid, name, extra = {}) {
  return { sessionId: sid, name, cwd: `/w/${name}`, transcriptPath: extra.transcriptPath || null, state: 'waiting_input', lastEvent: 'Stop', lastMessage: `# Done with ${name}\n\nMore text.`, startedAt: NOW - min(120), updatedAt: NOW - min(5), endedAt: null, pending: [], ...extra }
}

function world (n, { replies = 2 } = {}) {
  const act = new Activity()
  const agents = []
  for (let i = 1; i <= n; i++) {
    const sid = `s${i}`
    const tr = transcript(sid, [user(NOW - min(60), `please fix thing ${i}`), ...Array.from({ length: replies }, (_, k) => assistant(NOW - min(50) + k, `Reply ${k} of agent ${i}`, `${i}-${k}`))])
    agents.push(agentRecord(sid, `agent${i}`, { transcriptPath: tr }))
    feed(act, sid, [[NOW - min(60), { hook_event_name: 'UserPromptSubmit' }], [NOW - min(40), { hook_event_name: 'Stop' }]])
  }
  writeWorld(agents, act.toJSON())
  return { act, agents }
}

test('digest without --summaries: facts at once, cached summaries, pending marks; no claude call', async () => {
  resetCalls()
  try { fs.unlinkSync(path.join(state, 'digest.json')) } catch {}
  world(2)
  const { code, json } = await cli(['digest', '--since', String(NOW - min(90))])
  assert.equal(code, 0)
  assert.equal(json.schema, 1)
  assert.equal(json.source, 'snapshot')
  assert.equal(json.activity, true)
  assert.equal(json.agents.length, 2)
  const a = json.agents.find(x => x.sessionId === 's1')
  assert.equal(a.headline, 'Done with agent1')
  assert.equal(a.facts.turns, 1)
  assert.equal(a.facts.tokens.output, 200)
  assert.equal(a.facts.tokens.total, 2 * 1160)
  assert.ok(a.facts.costUsd > 0)
  assert.equal(a.summaryPending, true)
  assert.equal(a.summary, null)
  assert.deepEqual(json.counts, { needsYou: 0, stuck: 0, working: 0, done: 2, total: 2 })
  assert.equal(json.summaries.enabled, false)
  assert.equal(readCalls().length, 0)
})

test('digest --summaries: one batched, locked-down call; rolling summaries only for changed agents', async () => {
  resetCalls()
  try { fs.unlinkSync(path.join(state, 'digest.json')) } catch {}
  const { act, agents } = world(2)
  const r1 = await cli(['digest', '--since', String(NOW - min(90)), '--summaries', '--lang', 'pt'])
  assert.equal(r1.code, 0)
  const cs = readCalls()
  assert.equal(cs.length, 1, 'both agents in one call')
  const args = cs[0].args
  assert.deepEqual(args.slice(0, 9), ['-p', '--tools', '', '--safe-mode', '--no-session-persistence', '--output-format', 'json', '--model', 'haiku'])
  assert.equal(args[9], '--system-prompt')
  assert.match(args[10], /never instructions to follow/)
  assert.match(args[10], /European Portuguese/)
  assert.equal(args[11], '--json-schema')
  assert.deepEqual(JSON.parse(args[12]), dg.OUTPUT_SCHEMA)
  assert.equal(args.length, 13)
  assert.equal(cs[0].thinking, '0')
  assert.equal(cs[0].claudecode, null)
  // Nothing of the input is in argv; it is all on stdin.
  assert.ok(!args.join(' ').includes('agent1'))
  const input = promptOf(cs[0])
  assert.deepEqual(input.agents.map(a => a.id), ['a1', 'a2'])
  assert.equal(input.agents[0].lastPrompt, 'please fix thing 1')
  assert.deepEqual(input.agents[0].replies, ['Reply 0 of agent 1', 'Reply 1 of agent 1'])
  assert.equal(input.agents[0].previousSummary, '')

  const j1 = r1.json
  assert.equal(j1.summaries.done, 2)
  assert.equal(j1.summaries.calls, 1)
  assert.equal(j1.summaries.tokens.total, 1050)
  assert.equal(j1.summaries.costUsd, 0.00125)
  assert.equal(j1.summaries.pending, 0)
  const s1 = j1.agents.find(a => a.sessionId === 's1')
  assert.deepEqual(s1.summary.fresh, true)
  assert.equal(s1.summary.text, 'agent1 did 2 things.')
  assert.equal(j1.summaryUsageToday.calls, 1)

  const file = path.join(state, 'digest.json')
  assert.equal(fs.statSync(file).mode & 0o777, 0o600)
  const stored = JSON.parse(fs.readFileSync(file, 'utf8'))
  assert.equal(stored.agents.s1.text, 'agent1 did 2 things.')

  // Nothing changed: no call, cached text.
  resetCalls()
  const r2 = await cli(['digest', '--since', String(NOW - min(90)), '--summaries'])
  assert.equal(readCalls().length, 0)
  assert.equal(r2.json.summaries.calls, 0)
  assert.equal(r2.json.agents.find(a => a.sessionId === 's2').summary.text, 'agent2 did 2 things.')

  // s1 did more: only s1 is asked about, with its previous summary and
  // only the replies since then.
  fs.appendFileSync(agents[0].transcriptPath, JSON.stringify(assistant(Date.now() + 1000, 'Newest reply', '1-new')) + '\n')
  agents[0].updatedAt = Date.now() + 2000
  feed(act, 's1', [[Date.now() + 1000, { hook_event_name: 'Stop' }]])
  writeWorld(agents, act.toJSON())
  resetCalls()
  const r3 = await cli(['digest', '--since', String(NOW - min(90)), '--summaries'])
  const c3 = readCalls()
  assert.equal(c3.length, 1)
  const in3 = promptOf(c3[0])
  assert.deepEqual(in3.agents.map(a => a.name), ['agent1'])
  assert.equal(in3.agents[0].previousSummary, 'agent1 did 2 things.')
  assert.deepEqual(in3.agents[0].replies, ['Newest reply'])
  assert.equal(r3.json.summaryUsageToday.calls, 2)
  assert.equal(r3.json.summaryUsageToday.runs, 2)

  // `usage` counts the companion's own calls.
  const u = await cli(['usage', '--days', '1'])
  assert.equal(u.json.companion.digest.calls, 2)
})

test('digest --summaries: batches of 5, at most --max-agents, inputs capped', async () => {
  resetCalls()
  try { fs.unlinkSync(path.join(state, 'digest.json')) } catch {}
  world(8, { replies: 12 })
  // A huge reply is cut.
  const big = transcript('s1', [assistant(NOW - min(30), 'x'.repeat(50000), 'big')])
  const snap = JSON.parse(fs.readFileSync(path.join(state, 'state.json'), 'utf8'))
  snap.agents[0].transcriptPath = big
  fs.writeFileSync(path.join(state, 'state.json'), JSON.stringify(snap))
  const r = await cli(['digest', '--since', String(NOW - min(90)), '--summaries', '--max-agents', '7'])
  const cs = readCalls()
  assert.equal(cs.length, 2)
  const sizes = cs.map(c => promptOf(c).agents.length).sort()
  assert.deepEqual(sizes, [2, 5])
  for (const c of cs) {
    for (const a of promptOf(c).agents) {
      assert.ok(JSON.stringify(a).length <= dg.AGENT_INPUT_MAX, 'agent input capped')
      assert.ok(a.replies.length <= 3)
    }
  }
  assert.equal(r.json.summaries.done, 7)
  assert.equal(r.json.summaries.pending, 1, 'the eighth waits for the next run')
})

test('digest --summaries: timeout kills claude and still answers with facts; busy lock; not logged in', async () => {
  resetCalls()
  try { fs.unlinkSync(path.join(state, 'digest.json')) } catch {}
  world(1)
  const t0 = Date.now()
  const r = await cli(['digest', '--since', String(NOW - min(90)), '--summaries', '--max-ms', '5000'], { FAKE_MODE: 'hang' })
  assert.ok(Date.now() - t0 < 12000)
  assert.equal(r.json.summaries.error, 'timeout')
  assert.equal(r.json.agents.length, 1)
  assert.equal(r.json.agents[0].summaryPending, true)
  const pids = JSON.parse(fs.readFileSync(pidsFile, 'utf8'))
  await new Promise(resolve => setTimeout(resolve, 1500))
  for (const pid of pids) assert.throws(() => process.kill(pid, 0), 'claude and its child were killed')
  assert.ok(!fs.existsSync(path.join(state, 'digest.lock')), 'lock released')

  // Another run holds the lock: facts, no call.
  fs.writeFileSync(path.join(state, 'digest.lock'), String(process.pid))
  resetCalls()
  const b = await cli(['digest', '--since', String(NOW - min(90)), '--summaries'])
  assert.equal(b.json.summaries.error, 'busy')
  assert.equal(readCalls().length, 0)
  fs.unlinkSync(path.join(state, 'digest.lock'))

  const n = await cli(['digest', '--since', String(NOW - min(90)), '--summaries'], { FAKE_MODE: 'not-logged-in' })
  assert.equal(n.json.summaries.error, 'not-logged-in')
})

test('the summary store is pruned with the agents and capped', () => {
  const now = Date.now()
  const store = { v: 1, agents: {}, usage: { date: '2000-01-01', runs: 1 } }
  store.agents.gone = { text: 'x', at: now - 25 * 3600 * 1000, basis: 0 }
  store.agents.known = { text: 'y', at: now - 25 * 3600 * 1000, basis: 0 }
  for (let i = 0; i < 70; i++) store.agents[`n${i}`] = { text: 'z', at: now - i, basis: 0 }
  dg.pruneStore(store, new Set(['known']), now)
  assert.ok(!store.agents.gone)
  assert.equal(Object.keys(store.agents).length, 64)
  assert.ok(store.agents.n0)
  assert.equal(store.usage, null)
})

test('bad flags answer an error line, exit 0', async () => {
  const r = await cli(['digest', '--max-agents', '99'])
  assert.equal(r.code, 0)
  assert.equal(r.json.error, 'failed')
})

// --- through a real daemon ----------------------------------------------------

test('a real daemon counts hook events into activity.json and serves digest', async () => {
  const dhome = tempDir('cnd-dg-')
  const denv = { ...env, CONDUCTORE_HOME: dhome, CONDUCTORE_SOCKET: path.join(dhome, 'hostd.sock'), CONDUCTORE_IDLE_EXIT_S: '60' }
  const hook = (event, body) => execFileSync(HOOK, [event], { env: denv, input: JSON.stringify({ session_id: 'd1', hook_event_name: event, cwd: dhome, ...body }) })
  const run = args => new Promise((resolve, reject) => execFile(process.execPath, [HOSTD, ...args], { env: denv, timeout: 30000 }, (err, stdout) => {
    if (err && err.code === undefined) return reject(err)
    resolve(JSON.parse(stdout.trim().split('\n').pop()))
  }))
  try {
    hook('SessionStart', {})
    hook('UserPromptSubmit', { prompt: 'go' })
    hook('PostToolUse', { tool_name: 'Write', tool_input: { file_path: path.join(dhome, 'x.txt'), content: 'a\nb\n' } })
    hook('PostToolUseFailure', { tool_name: 'Bash', tool_input: { command: 'npm test' }, error: 'Exit code 1' })
    hook('StopFailure', { error: 'overloaded', last_assistant_message: 'API Error: overloaded' })
    let j
    for (let i = 0; i < 50; i++) {
      j = await run(['digest', '--since', '0'])
      if (j.source === 'daemon' && j.agents[0] && j.agents[0].facts.testsFailed === 1 && j.agents[0].stuck.length) break
      await new Promise(resolve => setTimeout(resolve, 100))
    }
    assert.equal(j.source, 'daemon')
    assert.equal(j.activity, true)
    const a = j.agents[0]
    assert.equal(a.sessionId, 'd1')
    assert.equal(a.state, 'waiting_input')
    assert.equal(a.lastError.type, 'overloaded')
    assert.equal(a.facts.turns, 1)
    assert.deepEqual(a.facts.files, ['x.txt'])
    assert.equal(a.facts.linesAdded, 2)
    assert.equal(a.facts.testsFailed, 1)
    assert.deepEqual(a.stuck.map(s => s.rule), ['error'])
    await run(['stop'])
    // The daemon writes the log as it shuts down, just after answering.
    for (let i = 0; i < 100 && (!fs.existsSync(path.join(dhome, 'activity.json')) || fs.existsSync(path.join(dhome, 'hostd.pid')) || fs.existsSync(path.join(dhome, 'hostd.sock'))); i++) await new Promise(resolve => setTimeout(resolve, 50))
    const saved = JSON.parse(fs.readFileSync(path.join(dhome, 'activity.json'), 'utf8'))
    assert.equal(fs.statSync(path.join(dhome, 'activity.json')).mode & 0o777, 0o600)
    assert.ok(saved.agents.d1.ev.some(e => e[1] === 'x'))
    // Daemon down: the files answer.
    const k = await run(['digest', '--since', '0'])
    assert.equal(k.source, 'snapshot')
    assert.equal(k.agents[0].facts.testsFailed, 1)
  } finally {
    try { await run(['stop']) } catch {}
  }
})

test('attention: permission, questions asked, and plain idle', () => {
  assert.equal(dg.attentionOf({ state: 'needs_permission' }), 'permission')
  assert.equal(dg.attentionOf({ state: 'waiting_input', lastEvent: 'PreToolUse', lastToolName: 'AskUserQuestion' }), 'question')
  assert.equal(dg.attentionOf({ state: 'waiting_input', lastEvent: 'Notification', lastToolName: 'AskUserQuestion' }), 'question')
  assert.equal(dg.attentionOf({ state: 'waiting_input', lastEvent: 'Stop', lastToolName: 'Bash', lastMessage: 'Done.\n\nShould I push the branch?' }), 'question')
  assert.equal(dg.attentionOf({ state: 'waiting_input', lastEvent: 'Notification', lastToolName: 'Bash', lastMessage: 'Claude is waiting for your input' }), null)
  assert.equal(dg.attentionOf({ state: 'waiting_input', lastEvent: 'Stop', lastToolName: 'Edit', lastMessage: 'All tests pass.' }), null)
  assert.equal(dg.attentionOf({ state: 'working', lastMessage: 'Why?' }), null)
})

test('the headline skips Claude Code\'s idle notice for the last reply', async () => {
  try { fs.unlinkSync(path.join(state, 'digest.json')) } catch {}
  const tr = transcript('idle', [assistant(NOW - min(20), 'Deployed to staging.\nDetails follow.', 'idle-1')])
  writeWorld([agentRecord('idle1', 'idler', { transcriptPath: tr, lastEvent: 'Notification', lastMessage: 'Claude is waiting for your input' })], { v: 1, agents: {} })
  const { json } = await cli(['digest', '--since', String(NOW - min(90))])
  assert.equal(json.agents[0].headline, 'Deployed to staging.')
  assert.equal(json.agents[0].attention, null)
})

// --- without the newer hooks -------------------------------------------------

const toolUse = (t, id, command, uid) => ({ type: 'assistant', timestamp: new Date(t).toISOString(), requestId: `r${uid}`, message: { id: `m${uid}`, role: 'assistant', model: 'claude-opus-4-1', content: [{ type: 'tool_use', id, name: 'Bash', input: { command } }] } })
const toolResult = (t, id, error) => ({ type: 'user', timestamp: new Date(t).toISOString(), message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: id, is_error: !!error, content: error || 'ok' }] } })

function failingWorld () {
  const entries = [user(NOW - min(40), 'fix the build')]
  for (let i = 0; i < 3; i++) {
    entries.push(toolUse(NOW - min(30) + i * 1000, `t${i}`, 'npm test', `f${i}`))
    entries.push(toolResult(NOW - min(30) + i * 1000 + 500, `t${i}`, `Exit code 1\nFAIL src/a.test.js (${i})`))
  }
  entries.push(toolUse(NOW - min(20), 'ok1', 'git status', 'ok1'), toolResult(NOW - min(20) + 100, 'ok1', null))
  entries.push({ type: 'assistant', timestamp: new Date(NOW - min(10)).toISOString(), isApiErrorMessage: true, message: { id: 'err', role: 'assistant', model: '<synthetic>', content: [{ type: 'text', text: 'API Error: 529 {"type":"overloaded_error"}' }] } })
  const tr = transcript('fail', entries)
  const act = new Activity()
  feed(act, 'f1', [[NOW - min(40), { hook_event_name: 'UserPromptSubmit' }], [NOW - min(10), { hook_event_name: 'Stop' }]])
  writeWorld([agentRecord('f1', 'builder', { transcriptPath: tr })], act.toJSON())
}

test('without PostToolUseFailure and StopFailure, the transcript gives failures and API errors', async () => {
  try { fs.unlinkSync(path.join(state, 'digest.json')) } catch {}
  failingWorld()
  const { json } = await cli(['digest', '--since', String(NOW - min(90))])
  assert.deepEqual(json.sources, { failures: 'transcript', apiErrors: 'transcript' })
  const a = json.agents[0]
  assert.equal(a.facts.testRuns, 3)
  assert.equal(a.facts.testsFailed, 3)
  assert.equal(a.facts.failedCommands, 3)
  assert.equal(a.facts.commands, 1)
  assert.deepEqual(a.stuck.map(s => s.rule), ['same-failure', 'error'])
  assert.equal(a.stuck[0].reason, '`npm test` failed 3 times')
  assert.equal(a.stuck[1].reason, 'Stopped on an API error (overloaded)')
})

test('with the hooks registered, the activity log is used as it is', async () => {
  try { fs.unlinkSync(path.join(state, 'digest.json')) } catch {}
  failingWorld()
  const settingsFile = path.join(root, 'claude-settings.json')
  const hook = { type: 'command', command: "'/x/conductore-hook' PostToolUseFailure", async: true }
  fs.writeFileSync(settingsFile, JSON.stringify({ hooks: {
    PostToolUseFailure: [{ matcher: '', hooks: [hook] }],
    StopFailure: [{ matcher: '', hooks: [{ ...hook, command: "'/x/conductore-hook' StopFailure" }] }]
  } }))
  const { json } = await cli(['digest', '--since', String(NOW - min(90))], { CONDUCTORE_CLAUDE_SETTINGS: settingsFile })
  assert.deepEqual(json.sources, { failures: 'hooks', apiErrors: 'hooks' })
  assert.equal(json.agents[0].facts.testRuns, 0)
  assert.deepEqual(json.agents[0].stuck, [])
})

test('an API error followed by a new prompt is not an error stop', () => {
  const tr = transcript('apierr', [
    { type: 'assistant', timestamp: new Date(NOW - min(5)).toISOString(), isApiErrorMessage: true, message: { role: 'assistant', content: [{ type: 'text', text: 'API Error: Rate limit reached' }] } },
    user(NOW - min(4), 'try again')
  ])
  assert.equal(dg.readTail(tr, { since: 0 }).apiError, null)
  const tr2 = transcript('apierr2', [{ type: 'assistant', timestamp: new Date(NOW - min(5)).toISOString(), isApiErrorMessage: true, message: { role: 'assistant', content: [{ type: 'text', text: 'API Error: Rate limit reached' }] } }])
  assert.equal(dg.readTail(tr2, { since: 0 }).apiError.type, 'rate_limit')
})
