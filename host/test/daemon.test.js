'use strict'

// Integration: a real daemon on a temp socket, the real (sh) hook client, the CLI.

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('fs')
const path = require('path')
const { tempDir, cleanup, guardRealConfigs } = require('./helpers/cleanup')
// Taken before anything runs; checked by the last test.
const realConfigs = guardRealConfigs()
const { spawn, execFile } = require('child_process')

const HOSTD = path.join(__dirname, '..', 'bin', 'conductore-hostd')
const HOOK = path.join(__dirname, '..', 'bin', 'conductore-hook')

// Short socket path: unix sockets are limited to ~100 bytes.
const home = tempDir('cnd-')
// A fake tmux on PATH (the daemon inherits it from the hook that starts it):
// logs its arguments, answers display-message like tmux would.
const fakeBin = tempDir('cnd-bin-')
const tmuxLog = path.join(fakeBin, 'tmux.log')
fs.writeFileSync(path.join(fakeBin, 'tmux'), `#!/bin/sh
printf '%s\n' "$*" >> '${tmuxLog}'
printf '%s\t4242\t2\tmain\tfixer\t/work/t\n' "$7"
`, { mode: 0o755 })
// A fake herdr: `pane list` knows session h1 (pane w3:p2) and pane w3:p9;
// `pane get w5:p1` answers for a pane moved since to w6:p3 (Herdr keeps
// answering for a moved pane's old id). It also logs which Herdr server
// (HERDR_SOCKET_PATH) each call went to.
// A fake claude: `install` registers the newer hooks for this version.
fs.writeFileSync(path.join(fakeBin, 'claude'), '#!/bin/sh\necho "2.1.280 (Claude Code)"\n', { mode: 0o755 })
const herdrLog = path.join(fakeBin, 'herdr.log')
const herdrSocketLog = path.join(fakeBin, 'herdr-sockets.log')
fs.writeFileSync(path.join(fakeBin, 'herdr'), `#!/bin/sh
printf '%s\n' "$*" >> '${herdrLog}'
printf '%s\n' "\${HERDR_SOCKET_PATH:-default}" >> '${herdrSocketLog}'
if [ "$1 $2 $3" = "pane get w5:p1" ]; then
  echo '{"id":"cli:pane:get","result":{"pane":{"pane_id":"w6:p3","tab_id":"w6:t2","workspace_id":"w6","cwd":"/work/m1"}}}'
  exit 0
fi
[ "$1 $2" = "pane list" ] || exit 1
cat <<'JSON'
{"id":"cli:pane:list","result":{"type":"pane_list","panes":[
 {"pane_id":"w3:p2","tab_id":"w3:t2","workspace_id":"w3","cwd":"/work/h1","agent_session":{"agent":"claude","kind":"id","value":"h1"}},
 {"pane_id":"w3:p9","tab_id":"w3:t4","workspace_id":"w3","cwd":"/work/h2"}]}}
JSON
`, { mode: 0o755 })
const env = {
  ...process.env,
  PATH: `${fakeBin}:${process.env.PATH}`,
  CONDUCTORE_HOME: home,
  CONDUCTORE_SOCKET: path.join(home, 'hostd.sock'),
  CONDUCTORE_CLAUDE_SETTINGS: path.join(home, 'settings.json'),
  // install / uninstall run every agent adapter: never the real configs.
  HOME: path.join(home, 'user'),
  CODEX_HOME: path.join(home, 'user', '.codex'),
  XDG_CONFIG_HOME: path.join(home, 'user', '.config')
}
// Even a tmux call without -S (the fake on PATH aside) can only reach a
// private "default" server, never the real one.
env.TMUX_TMPDIR = tempDir('cnd-tmux-')
for (const k of Object.keys(env)) if (/^(TMUX$|TMUX_PANE$|HERDR_)/.test(k)) delete env[k]
for (const k of ['TMUX', 'TMUX_PANE', 'HERDR_WORKSPACE_ID', 'HERDR_PANE_ID', 'HERDR_TAB_ID', 'HERDR_AGENT_NAME']) delete env[k]

process.env.CONDUCTORE_HOME = env.CONDUCTORE_HOME
process.env.CONDUCTORE_SOCKET = env.CONDUCTORE_SOCKET
const client = require('../lib/client')

const sleep = ms => new Promise(r => setTimeout(r, ms))

function cli (...args) {
  return new Promise((resolve, reject) => {
    execFile(process.execPath, [HOSTD, ...args], { env, timeout: 30000 }, (err, stdout, stderr) => {
      if (err && err.code === undefined) return reject(err)
      const lines = stdout.split('\n').filter(Boolean).map(l => JSON.parse(l))
      resolve({ code: err ? err.code : 0, lines, json: lines[lines.length - 1], stderr })
    })
  })
}

// Runs the hook script with the given event on stdin; resolves when it
// exits (and its stdout closes, as Claude Code waits for).
function hook (event, extraEnv = {}) {
  return new Promise((resolve, reject) => {
    const t0 = Date.now()
    const child = spawn(HOOK, [event.hook_event_name], { env: { ...env, ...extraEnv }, stdio: ['pipe', 'pipe', 'pipe'] })
    let stdout = ''
    let stderr = ''
    child.stdout.on('data', d => { stdout += d })
    child.stderr.on('data', d => { stderr += d })
    child.on('error', reject)
    child.on('close', code => resolve({ code, stdout, stderr, ms: Date.now() - t0 }))
    child.stdin.end(JSON.stringify(event))
  })
}

const spooled = () => fs.readdirSync(path.join(home, 'spool')).filter(n => !n.startsWith('.'))

async function status () {
  return (await cli('status')).json
}

async function waitFor (pred, ms = 5000) {
  const deadline = Date.now() + ms
  while (Date.now() < deadline) {
    const v = await pred()
    if (v) return v
    await sleep(40)
  }
  throw new Error('timed out waiting')
}

const ev = (sid, hook_event_name, extra = {}) => ({ session_id: sid, cwd: `/work/${sid}`, hook_event_name, ...extra })

test('status without a daemon or snapshot is empty', async () => {
  assert.deepEqual(await status(), { version: 1, seq: 0, agents: [], source: 'none' })
})

test('first hook call starts the daemon; events flow into status', async () => {
  const r = await hook(ev('s1', 'SessionStart', { source: 'startup' }))
  assert.equal(r.code, 0)
  assert.equal(r.stdout, '')
  const st = await status()
  assert.equal(st.source, 'daemon')
  assert.equal(st.agents.length, 1)
  assert.equal(st.agents[0].state, 'waiting_input')
  assert.equal(st.agents[0].name, 's1')
  assert.ok(fs.existsSync(env.CONDUCTORE_SOCKET))
  assert.equal(fs.statSync(env.CONDUCTORE_SOCKET).mode & 0o077, 0)
})

test('the hook is a sh script: it spools and returns without waiting for the daemon', async () => {
  assert.match(fs.readFileSync(HOOK, 'utf8'), /^#!\/bin\/sh\n/)
  await cli('stop')
  await waitFor(async () => !fs.existsSync(env.CONDUCTORE_SOCKET))
  // Pretend a start attempt just happened, so this hook does not start one.
  fs.writeFileSync(path.join(home, 'spawn.at'), `${Math.floor(Date.now() / 1000)}\n`)
  const r = await hook(ev('q1', 'UserPromptSubmit'))
  assert.equal(r.code, 0)
  assert.equal(r.stdout, '')
  assert.equal(spooled().length, 1)
  assert.equal(fs.existsSync(env.CONDUCTORE_SOCKET), false)
  // Ordered delivery once the daemon runs: the reply to status includes it.
  await hook(ev('q1', 'Stop', { last_assistant_message: 'done' }))
  const a = (await status()).agents.find(a => a.sessionId === 'q1')
  assert.equal(a.state, 'waiting_input')
  assert.equal(a.lastMessage, 'done')
  assert.equal(spooled().length, 0)
  // The staging names (hard links of the spooled files) are gone too.
  assert.deepEqual(fs.readdirSync(path.join(home, 'tmp')), [])
})

test('the daemon runs with the memory flags and reports its footprint', async () => {
  const [ping] = await client.request({ op: 'ping' })
  assert.ok(ping.execArgv.includes('--max-old-space-size=64'), ping.execArgv.join(' '))
  assert.ok(ping.rss > 0)
  assert.equal(typeof ping.cpuMs, 'number')
})

test('tmux location is resolved by the daemon from the variables in the spool header', async () => {
  const r = await hook(ev('t1', 'SessionStart'), { TMUX: '/tmp/fake-tmux-sock,123,0', TMUX_PANE: '%7' })
  assert.equal(r.code, 0)
  const a = (await status()).agents.find(a => a.sessionId === 't1')
  assert.deepEqual(a.tmux, { session: 'main', window: 2, paneId: '%7', windowName: 'fixer', socket: '/tmp/fake-tmux-sock', panePid: 4242 })
  assert.equal(a.name, 'fixer')
  assert.match(fs.readFileSync(tmuxLog, 'utf8'), /^-u -S \/tmp\/fake-tmux-sock display-message -p -t %7 /m)
  // Herdr comes straight from the header.
  await hook(ev('t2', 'SessionStart'), { HERDR_WORKSPACE_ID: 'w1', HERDR_TAB_ID: 'w1:t1', HERDR_PANE_ID: 'w1:p1', HERDR_AGENT_NAME: 'rev' })
  const b = (await status()).agents.find(a => a.sessionId === 't2')
  assert.deepEqual(b.herdr, { workspaceId: 'w1', tabId: 'w1:t1', paneId: 'w1:p1', name: 'rev', socket: null })
  assert.equal(b.name, 'rev')
})

test("an agent in a named Herdr session records that session's socket", async () => {
  const sock = path.join(home, 'herdr-other.sock')
  fs.writeFileSync(herdrSocketLog, '')
  await hook(ev('t3', 'SessionStart'), { HERDR_WORKSPACE_ID: 'w1', HERDR_TAB_ID: 'w1:t1', HERDR_PANE_ID: 'w1:p1', HERDR_SOCKET_PATH: sock })
  const a = (await status()).agents.find(a => a.sessionId === 't3')
  assert.deepEqual(a.herdr, { workspaceId: 'w1', tabId: 'w1:t1', paneId: 'w1:p1', name: null, socket: sock })

  // Only the pane id known: its location is asked of that session's server.
  await hook(ev('t4', 'SessionStart'), { HERDR_PANE_ID: 'w3:p9', HERDR_SOCKET_PATH: sock })
  const b = (await status()).agents.find(a => a.sessionId === 't4')
  assert.deepEqual(b.herdr, { workspaceId: 'w3', tabId: 'w3:t4', paneId: 'w3:p9', name: null, socket: sock })
  // Every lookup (the checked header and the pane id) asked that server only.
  const asked = fs.readFileSync(herdrSocketLog, 'utf8').split('\n').filter(Boolean)
  assert.ok(asked.length >= 1)
  assert.deepEqual([...new Set(asked)], [sock])
})

test('Herdr location without HERDR_* comes from one cached `herdr pane list`, never from the cwd', async () => {
  fs.writeFileSync(herdrLog, '')
  // Found by Claude's session id.
  await hook(ev('h1', 'SessionStart'))
  // Only the pane id in the environment: workspace and tab are filled in.
  await hook(ev('h2', 'SessionStart'), { HERDR_PANE_ID: 'w3:p9' })
  // Not in any Herdr pane: no location, asked once.
  await hook(ev('n1', 'SessionStart'))
  for (let i = 0; i < 3; i++) {
    await hook(ev('h1', 'PreToolUse', { tool_name: 'Read', tool_input: { file_path: '/x' } }))
    await hook(ev('n1', 'PreToolUse', { tool_name: 'Read', tool_input: { file_path: '/x' } }))
  }
  const agents = (await status()).agents
  const byId = id => agents.find(a => a.sessionId === id)
  assert.deepEqual(byId('h1').herdr, { workspaceId: 'w3', tabId: 'w3:t2', paneId: 'w3:p2', name: null, socket: null })
  assert.deepEqual(byId('h2').herdr, { workspaceId: 'w3', tabId: 'w3:t4', paneId: 'w3:p9', name: null, socket: null })
  assert.equal(byId('n1').herdr, null)
  assert.equal(byId('h1').name, 'h1') // cwd basename is a name, not a location
  // Nine events, at most one herdr call (none if an earlier test's list is still cached).
  assert.ok(['', 'pane list\n'].includes(fs.readFileSync(herdrLog, 'utf8')))
})

test('a moved Herdr pane: the location follows the pane, not the stale HERDR_* of its processes (CON-062)', async () => {
  // `herdr pane move` gives the pane a new id while Claude Code keeps the
  // HERDR_* it started with: opening that old place landed on another
  // workspace.
  await hook(ev('m1', 'SessionStart'), { HERDR_WORKSPACE_ID: 'w5', HERDR_TAB_ID: 'w5:t1', HERDR_PANE_ID: 'w5:p1' })
  const moved = (await status()).agents.find(a => a.sessionId === 'm1')
  assert.deepEqual(moved.herdr, { workspaceId: 'w6', tabId: 'w6:t2', paneId: 'w6:p3', name: null, socket: null })
  // Herdr names the pane holding the session: that wins over the header.
  await hook(ev('h1', 'PreToolUse', { tool_name: 'Read', tool_input: { file_path: '/x' } }), { HERDR_WORKSPACE_ID: 'w1', HERDR_TAB_ID: 'w1:t1', HERDR_PANE_ID: 'w1:p7' })
  const h1 = (await status()).agents.find(a => a.sessionId === 'h1')
  assert.deepEqual(h1.herdr, { workspaceId: 'w3', tabId: 'w3:t2', paneId: 'w3:p2', name: null, socket: null })
})

test('concurrent hooks do not start two daemons', async () => {
  await cli('stop')
  await waitFor(async () => !fs.existsSync(env.CONDUCTORE_SOCKET))
  await Promise.all([1, 2, 3, 4].map(i => hook(ev(`c${i}`, 'UserPromptSubmit'))))
  await waitFor(async () => fs.existsSync(env.CONDUCTORE_SOCKET))
  await sleep(200)
  const [ping] = await client.request({ op: 'ping' })
  await sleep(300)
  const [ping2] = await client.request({ op: 'ping' })
  assert.equal(ping.pid, ping2.pid)
  const st = await status()
  assert.equal(st.agents.filter(a => a.sessionId.startsWith('c')).length, 4)
})

test('PermissionRequest blocks until decide allow; hook prints the decision JSON', async () => {
  const pending = hook(ev('s1', 'PermissionRequest', { tool_name: 'Bash', tool_input: { command: 'npm test' } }), { CONDUCTORE_PERMISSION_TIMEOUT: '20' })
  const req = await waitFor(async () => {
    const a = (await status()).agents.find(a => a.sessionId === 's1')
    return a && a.state === 'needs_permission' && a.pending[0]
  })
  assert.equal(req.toolName, 'Bash')
  assert.equal(req.summary, 'npm test')
  const d = await cli('decide', req.id, 'allow')
  assert.equal(d.code, 0)
  assert.equal(d.json.ok, true)
  const r = await pending
  assert.equal(r.code, 0)
  assert.deepEqual(JSON.parse(r.stdout), {
    hookSpecificOutput: { hookEventName: 'PermissionRequest', decision: { behavior: 'allow' } }
  })
  const a = (await status()).agents.find(a => a.sessionId === 's1')
  assert.equal(a.state, 'working')
  assert.equal(a.pending.length, 0)
})

test('decide deny carries the message; unknown ids fail with exit 1', async () => {
  const pending = hook(ev('s1', 'PermissionRequest', { tool_name: 'Edit', tool_input: { file_path: '/work/s1/a.js', old_string: 'a', new_string: 'b' } }), { CONDUCTORE_PERMISSION_TIMEOUT: '20' })
  const req = await waitFor(async () => ((await status()).agents.find(a => a.sessionId === 's1') || {}).pending?.[0])
  assert.equal(req.summary, '/work/s1/a.js')
  const bad = await cli('decide', 'nope', 'allow')
  assert.equal(bad.code, 1)
  assert.match(bad.json.error, /unknown request/)
  const d = await cli('decide', req.id, 'deny', '--message', 'not on prod')
  assert.equal(d.code, 0)
  const r = await pending
  assert.deepEqual(JSON.parse(r.stdout), {
    hookSpecificOutput: { hookEventName: 'PermissionRequest', decision: { behavior: 'deny', message: 'not on prod' } }
  })
})

test('decide always saves a rule for exactly this call, never a broader suggestion', async () => {
  // Claude Code's own suggestion may cover more than the user saw.
  const suggestion = { type: 'addRules', rules: [{ toolName: 'Bash', ruleContent: 'git *' }], behavior: 'allow', destination: 'localSettings' }
  const p1 = hook(ev('s1', 'PermissionRequest', { tool_name: 'Bash', tool_input: { command: 'git status' }, permission_suggestions: [suggestion] }), { CONDUCTORE_PERMISSION_TIMEOUT: '20' })
  const r1 = await waitFor(async () => ((await status()).agents.find(a => a.sessionId === 's1') || {}).pending?.[0])
  await cli('decide', r1.id, 'always')
  const out1 = JSON.parse((await p1).stdout)
  assert.deepEqual(out1.hookSpecificOutput.decision, { behavior: 'allow', updatedPermissions: [{ type: 'addRules', rules: [{ toolName: 'Bash', ruleContent: 'git status' }], behavior: 'allow', destination: 'localSettings' }] })

  const p2 = hook(ev('s1', 'PermissionRequest', { tool_name: 'Bash', tool_input: { command: 'make build' } }), { CONDUCTORE_PERMISSION_TIMEOUT: '20' })
  const r2 = await waitFor(async () => ((await status()).agents.find(a => a.sessionId === 's1') || {}).pending?.[0])
  await cli('decide', r2.id, 'always')
  const out2 = JSON.parse((await p2).stdout)
  assert.deepEqual(out2.hookSpecificOutput.decision.updatedPermissions, [
    { type: 'addRules', rules: [{ toolName: 'Bash', ruleContent: 'make build' }], behavior: 'allow', destination: 'localSettings' }
  ])
  const recorded = JSON.parse(fs.readFileSync(path.join(home, 'always-rules.json'), 'utf8'))
  assert.equal(recorded.length, 2)
  assert.equal(recorded[1].toolName, 'Bash')

  // A `*` would be a wildcard in Claude Code's syntax: allowed once, no rule.
  const p3 = hook(ev('s1', 'PermissionRequest', { tool_name: 'Bash', tool_input: { command: 'ls *.md' } }), { CONDUCTORE_PERMISSION_TIMEOUT: '20' })
  const r3 = await waitFor(async () => ((await status()).agents.find(a => a.sessionId === 's1') || {}).pending?.[0])
  await cli('decide', r3.id, 'always')
  assert.deepEqual(JSON.parse((await p3).stdout).hookSpecificOutput.decision, { behavior: 'allow' })
})

test('decide and trust refuse a request named for another agent', async () => {
  const p = hook(ev('s1', 'PermissionRequest', { tool_name: 'Bash', tool_input: { command: 'git status' } }), { CONDUCTORE_PERMISSION_TIMEOUT: '20' })
  const r = await waitFor(async () => ((await status()).agents.find(a => a.sessionId === 's1') || {}).pending?.[0])
  const wrong = await cli('decide', r.id, 'allow', '--session', 'someone-else')
  assert.equal(wrong.code, 1)
  assert.match(wrong.json.error, /not pending for that agent/)
  const t = await cli('trust', r.id, '--session', 'someone-else')
  assert.equal(t.code, 1)
  assert.match(t.json.error, /not pending for that agent/)
  assert.equal((await cli('decide', 'no-such-request', 'allow')).code, 1)
  // Still pending, and answered for its own agent.
  const ok = await cli('decide', r.id, 'deny', '--session', 's1')
  assert.equal(ok.code, 0)
  assert.equal(JSON.parse((await p).stdout).hookSpecificOutput.decision.behavior, 'deny')
})

const QUESTIONS = [
  { question: 'Which database?', header: 'DB', multiSelect: false, options: [{ label: 'Postgres', description: 'the usual' }, { label: 'SQLite' }] },
  { question: 'Which checks?', header: 'CI', multiSelect: true, options: [{ label: 'lint' }, { label: 'tests' }, { label: 'e2e', preview: 'x'.repeat(5000) }] }
]

test('AskUserQuestion: the pending request carries its questions; answers go back in updatedInput (CON-062)', async () => {
  const input = { questions: QUESTIONS }
  const pending = hook(ev('q1', 'PermissionRequest', { tool_name: 'AskUserQuestion', tool_input: input }), { CONDUCTORE_PERMISSION_TIMEOUT: '20' })
  const req = await waitFor(async () => ((await status()).agents.find(a => a.sessionId === 'q1') || {}).pending?.[0])
  assert.equal(req.summary, 'Which database? (+1 more)')
  // toolInput was cut at 4 KB by the preview; the questions are whole.
  assert.equal(req.toolInput._truncated, true)
  assert.deepEqual(req.questions, [
    { question: 'Which database?', header: 'DB', kind: 'choice', multiSelect: false, options: [{ label: 'Postgres', description: 'the usual' }, { label: 'SQLite' }] },
    { question: 'Which checks?', header: 'CI', kind: 'choice', multiSelect: true, options: [{ label: 'lint' }, { label: 'tests' }, { label: 'e2e' }] }
  ])
  // A plain allow is ignored by Claude Code for a question (the dialog
  // stayed in the terminal while the phone dropped the request): refused,
  // and the request stays answerable.
  const allow = await cli('decide', req.id, 'allow')
  assert.equal(allow.code, 1)
  assert.match(allow.json.error, /takes an answer/)
  const bad = await cli('decide', req.id, 'answer', '--answers', JSON.stringify({ 'Not asked?': 'x' }))
  assert.equal(bad.code, 1)
  assert.match(bad.json.error, /no such question/)
  assert.equal((await status()).agents.find(a => a.sessionId === 'q1').pending.length, 1)
  const d = await cli('decide', req.id, 'answer', '--answers', JSON.stringify({ 'Which database?': 'SQLite', 'Which checks?': ['lint', 'Run only the fast ones'] }))
  assert.equal(d.code, 0, JSON.stringify(d.json))
  const out = JSON.parse((await pending).stdout)
  // Exactly the input it got, plus answers: Claude Code refuses changed questions.
  assert.deepEqual(out, {
    hookSpecificOutput: {
      hookEventName: 'PermissionRequest',
      decision: { behavior: 'allow', updatedInput: { questions: QUESTIONS, answers: { 'Which database?': 'SQLite', 'Which checks?': 'lint, Run only the fast ones' } } }
    }
  })
  const a = (await status()).agents.find(a => a.sessionId === 'q1')
  assert.equal(a.pending.length, 0)
  assert.equal(a.state, 'working')
})

test('a question the phone did not answer in time waits in the terminal as a question (CON-062)', async () => {
  await hook(ev('q2', 'PreToolUse', { tool_name: 'AskUserQuestion', tool_input: { questions: QUESTIONS } }))
  const r = await hook(ev('q2', 'PermissionRequest', { tool_name: 'AskUserQuestion', tool_input: { questions: QUESTIONS } }), { CONDUCTORE_PERMISSION_TIMEOUT: '1' })
  assert.equal(r.stdout, '')
  const a = (await status()).agents.find(a => a.sessionId === 'q2')
  // The question stays, answerable in the terminal only (CON-096): the
  // phone types the answer there (`terminal-answer`).
  assert.equal(a.pending.length, 1)
  assert.equal(a.pending[0].expired, true)
  assert.equal(a.pending[0].answerable, false)
  assert.equal(a.pending[0].questions.length, 2)
  assert.equal(a.state, 'waiting_input')
  assert.equal(a.lastMessage, 'Question is waiting in the terminal: Which database? (+1 more)')
  const late = await cli('decide', a.pending[0].id, 'answer', '--answers', JSON.stringify({ 'Which database?': 'SQLite' }))
  assert.equal(late.code, 1)
  assert.match(late.json.error, /expired; answer it in the terminal/)
  // Answered in the terminal: its PostToolUse (input plus answers) ends it.
  await hook(ev('q2', 'PostToolUse', { tool_name: 'AskUserQuestion', tool_input: { questions: QUESTIONS, answers: { 'Which database?': 'SQLite' } }, tool_response: {} }))
  await waitFor(async () => (await status()).agents.find(a => a.sessionId === 'q2').pending.length === 0)
})

test('plan approval: allow echoes the plan as updatedInput; always switches to acceptEdits (CON-062)', async () => {
  // Claude Code ignores a plain allow for ExitPlanMode (its dialog is the
  // input), so the phone's "Approve" never reached it.
  const plan = { plan: '1. do it' }
  const p1 = hook(ev('p1', 'PermissionRequest', { tool_name: 'ExitPlanMode', tool_input: plan }), { CONDUCTORE_PERMISSION_TIMEOUT: '20' })
  const r1 = await waitFor(async () => ((await status()).agents.find(a => a.sessionId === 'p1') || {}).pending?.[0])
  await cli('decide', r1.id, 'allow')
  assert.deepEqual(JSON.parse((await p1).stdout).hookSpecificOutput.decision, { behavior: 'allow', updatedInput: plan })
  const p2 = hook(ev('p1', 'PermissionRequest', { tool_name: 'ExitPlanMode', tool_input: plan }), { CONDUCTORE_PERMISSION_TIMEOUT: '20' })
  const r2 = await waitFor(async () => ((await status()).agents.find(a => a.sessionId === 'p1') || {}).pending?.[0])
  await cli('decide', r2.id, 'always')
  // "Approve, auto-edit" is a mode for this session, not a rule approving every later plan.
  assert.deepEqual(JSON.parse((await p2).stdout).hookSpecificOutput.decision, {
    behavior: 'allow',
    updatedInput: plan,
    updatedPermissions: [{ type: 'setMode', mode: 'acceptEdits', destination: 'session' }]
  })
})

test('PermissionRequest timeout prints nothing and leaves the terminal prompt to Claude Code', async () => {
  const t0 = Date.now()
  const r = await hook(ev('s1', 'PermissionRequest', { tool_name: 'Bash', tool_input: { command: 'ls' } }), { CONDUCTORE_PERMISSION_TIMEOUT: '1' })
  assert.equal(r.code, 0)
  assert.equal(r.stdout, '')
  assert.ok(Date.now() - t0 >= 900)
  const a = (await status()).agents.find(a => a.sessionId === 's1')
  assert.equal(a.pending.length, 1)
  assert.equal(a.pending[0].expired, true)
  assert.equal(a.state, 'needs_permission')
  const late = await cli('decide', a.pending[0].id, 'allow')
  assert.equal(late.code, 1)
  // Allowed in the terminal: the call runs.
  await hook(ev('s1', 'PostToolUse', { tool_name: 'Bash', tool_input: { command: 'ls' }, tool_response: {} }))
  await waitFor(async () => (await status()).agents.find(a => a.sessionId === 's1').pending.length === 0)
})

test('an expired prompt refused in the terminal from the phone is dropped (CON-096)', async () => {
  // Esc on Claude Code's prompt interrupts the turn with no hook event at
  // all; terminal-answer tells the daemon.
  await hook(ev('t4', 'PermissionRequest', { tool_name: 'Bash', tool_input: { command: 'rm x' } }), { CONDUCTORE_PERMISSION_TIMEOUT: '1' })
  const [req] = (await status()).agents.find(a => a.sessionId === 't4').pending
  assert.equal(req.expired, true)
  const [other] = await client.request({ op: 'terminal-answered', sessionId: 'nope', requestId: req.id, refused: true })
  assert.equal(other.resolved, false)
  const [r] = await client.request({ op: 'terminal-answered', sessionId: 't4', requestId: req.id, refused: true })
  assert.equal(r.resolved, true)
  const a = (await status()).agents.find(a => a.sessionId === 't4')
  assert.equal(a.pending.length, 0)
  assert.equal(a.state, 'waiting_input')
})

test('a prompt answered in the terminal releases the waiting hook at once (CON-096)', async () => {
  // Claude Code shows its own dialog while the hook waits, and an answer
  // there does not end the hook: the call's PostToolUse does.
  const pending = hook(ev('t1', 'PermissionRequest', { tool_name: 'Bash', tool_input: { command: 'make' } }), { CONDUCTORE_PERMISSION_TIMEOUT: '60' })
  await waitFor(async () => ((await status()).agents.find(a => a.sessionId === 't1') || {}).pending?.[0])
  // Another call of the same tool is not this one.
  await hook(ev('t1', 'PostToolUse', { tool_name: 'Bash', tool_input: { command: 'make test' }, tool_response: {} }))
  await sleep(300)
  assert.equal((await status()).agents.find(a => a.sessionId === 't1').pending.length, 1)
  const t0 = Date.now()
  await hook(ev('t1', 'PostToolUse', { tool_name: 'Bash', tool_input: { command: 'make', description: 'Build' }, tool_response: {} }))
  const r = await pending
  assert.equal(r.stdout, '')
  assert.ok(Date.now() - t0 < 5000, `${Date.now() - t0} ms`)
  const a = (await status()).agents.find(a => a.sessionId === 't1')
  assert.equal(a.pending.length, 0)
  assert.equal(a.state, 'working')
  await waitFor(async () => !fs.readdirSync(path.join(home, 'tmp')).some(n => n.startsWith('p.')))
})

test('the turn ending or a new prompt releases a waiting hook (CON-096)', async () => {
  for (const end of ['Stop', 'UserPromptSubmit']) {
    const pending = hook(ev('t2', 'PermissionRequest', { tool_name: 'Edit', tool_input: { file_path: '/work/t2/a' } }), { CONDUCTORE_PERMISSION_TIMEOUT: '60' })
    await waitFor(async () => ((await status()).agents.find(a => a.sessionId === 't2') || {}).pending?.length === 1)
    await hook(ev('t2', end))
    const r = await pending
    assert.equal(r.stdout, '', end)
    assert.equal((await status()).agents.find(a => a.sessionId === 't2').pending.length, 0, end)
  }
})

test('the hook waits for the permission-wait setting (CON-096)', async () => {
  // `config set` writes the wait for the sh hook (seconds) and the
  // handler timeout in Claude Code's settings.json.
  const set = await cli('config', 'set', 'permission-wait', '1')
  assert.equal(set.code, 0)
  assert.equal(fs.readFileSync(path.join(home, 'permission-wait'), 'utf8'), '60\n')
  fs.writeFileSync(path.join(home, 'permission-wait'), '1\n')
  const t0 = Date.now()
  const r = await hook(ev('t3', 'PermissionRequest', { tool_name: 'Bash', tool_input: { command: 'pwd' } }))
  assert.equal(r.stdout, '')
  assert.ok(Date.now() - t0 >= 900 && Date.now() - t0 < 10000, `${Date.now() - t0} ms`)
  // Other agents' hooks keep the short default, never this setting.
  const hookFile = fs.readFileSync(HOOK, 'utf8')
  assert.match(hookFile, /\[ -z "\$agent" \] && \[ -f "\$d\/permission-wait" \]/)
  assert.equal((await cli('config', 'set', 'permission-wait', '61')).code, 1)
  await cli('config', 'set', 'permission-wait', '15')
  fs.unlinkSync(path.join(home, 'permission-wait'))
})

test('killing a waiting hook drops its pending request', async () => {
  const child = spawn(HOOK, ['PermissionRequest'], { env: { ...env, CONDUCTORE_PERMISSION_TIMEOUT: '30' }, stdio: ['pipe', 'ignore', 'ignore'] })
  child.stdin.end(JSON.stringify(ev('s1', 'PermissionRequest', { tool_name: 'Bash', tool_input: { command: 'sleep' } })))
  const req = await waitFor(async () => ((await status()).agents.find(a => a.sessionId === 's1') || {}).pending?.[0])
  child.kill('SIGKILL')
  await waitFor(async () => ((await status()).agents.find(a => a.sessionId === 's1') || {}).pending?.length === 0)
  const late = await cli('decide', req.id, 'allow')
  assert.equal(late.code, 1)
  // Its FIFO is cleaned up with it.
  await waitFor(async () => !fs.readdirSync(path.join(home, 'tmp')).some(n => n.startsWith('p.')))
})

test('stopping the daemon while a hook waits releases the hook with no output', async () => {
  const pending = hook(ev('s1', 'PermissionRequest', { tool_name: 'Bash', tool_input: { command: 'make' } }), { CONDUCTORE_PERMISSION_TIMEOUT: '30' })
  await waitFor(async () => ((await status()).agents.find(a => a.sessionId === 's1') || {}).pending?.[0])
  await cli('stop')
  const r = await pending
  assert.equal(r.code, 0)
  assert.equal(r.stdout, '')
  assert.ok(r.ms < 10000, `${r.ms} ms`)
})

test('a daemon that dies mid-wait releases the hook within seconds', async () => {
  const pending = hook(ev('s1', 'PermissionRequest', { tool_name: 'Bash', tool_input: { command: 'make' } }), { CONDUCTORE_PERMISSION_TIMEOUT: '30' })
  await waitFor(async () => ((await status()).agents.find(a => a.sessionId === 's1') || {}).pending?.[0])
  const [ping] = await client.request({ op: 'ping' })
  const t0 = Date.now()
  process.kill(ping.pid, 'SIGKILL')
  const r = await pending
  assert.equal(r.stdout, '')
  assert.ok(Date.now() - t0 < 5000, `${Date.now() - t0} ms`)
  // Leave no stale lock/socket behind for the next test.
  await status()
})

test('events long-poll returns the batch since seq, waits for new changes, and times out', async () => {
  // At least two buffered changes, whatever restarts happened before.
  await hook(ev('s1', 'UserPromptSubmit'))
  await hook(ev('s1', 'PreToolUse', { tool_name: 'Read', tool_input: { file_path: '/x' } }))
  const before = (await status()).seq
  // Backlog: the buffered changes since a recent cursor are served at once,
  // only the newest per session (each carries the whole agent).
  const backlog = await cli('events', '--since', String(before - 2), '--timeout', '5')
  assert.equal(backlog.lines.length, 1)
  assert.equal(backlog.lines[0].type, 'change')
  assert.equal(backlog.lines[0].seq, before)
  assert.equal(backlog.lines[0].agent.lastToolName, 'Read')
  await hook(ev('s9', 'SessionStart'))
  await hook(ev('s1', 'PostToolUse', { tool_name: 'Read' }))
  await hook(ev('s9', 'UserPromptSubmit'))
  const mixed = await cli('events', '--since', String(before - 2), '--timeout', '5')
  assert.deepEqual(mixed.lines.map(l => [l.sessionId, l.seq]), [['s1', before + 2], ['s9', before + 3]])
  assert.equal(mixed.lines[1].agent.state, 'working')
  const cursor = before + 3

  // A cursor older than the daemon's buffer (it restarted earlier in this run) gets a snapshot.
  const stale = await cli('events', '--since', '0', '--timeout', '1')
  assert.equal(stale.lines.length, 1)
  assert.equal(stale.lines[0].type, 'snapshot')
  assert.equal(stale.lines[0].seq, cursor)

  // Nothing new: the poll parks, then a Stop wakes it with exactly that change.
  const poll = cli('events', '--since', String(cursor), '--timeout', '10')
  await sleep(300)
  await hook(ev('s1', 'Stop', { last_assistant_message: 'Finished.' }))
  const woke = await poll
  assert.equal(woke.lines.length, 1)
  assert.equal(woke.lines[0].seq, cursor + 1)
  assert.equal(woke.lines[0].reason, 'Stop')
  assert.equal(woke.lines[0].agent.state, 'waiting_input')
  assert.equal(woke.lines[0].agent.lastMessage, 'Finished.')

  // Timeout without changes.
  const t0 = Date.now()
  const idle = await cli('events', '--since', String(cursor + 1), '--timeout', '1')
  assert.ok(Date.now() - t0 >= 900)
  assert.deepEqual(idle.lines, [{ type: 'timeout', seq: cursor + 1 }])

  // A cursor ahead of the daemon gets a snapshot to resync.
  const ahead = await cli('events', '--since', '99999', '--timeout', '1')
  assert.equal(ahead.lines[0].type, 'snapshot')
  assert.ok(Array.isArray(ahead.lines[0].agents))
})

test('status --etag answers only a marker until something changes', async () => {
  const full = await status()
  assert.equal(full.source, 'daemon')
  assert.match(full.etag, /\.\d+$/)
  const same = await cli('status', '--etag', full.etag)
  assert.deepEqual(same.json, { version: 1, seq: full.seq, etag: full.etag, unchanged: true, source: 'daemon', capabilities: full.capabilities })
  // A stale or foreign etag gets the whole state.
  const other = await cli('status', '--etag', 'x.1')
  assert.equal(other.json.unchanged, undefined)
  assert.deepEqual(other.json.agents, full.agents)
  await hook(ev('s1', 'PreToolUse', { tool_name: 'Read', tool_input: { file_path: '/y' } }))
  const changed = await cli('status', '--etag', full.etag)
  assert.equal(changed.json.unchanged, undefined)
  assert.equal(changed.json.seq, full.seq + 1)
  assert.notEqual(changed.json.etag, full.etag)
  assert.ok(Array.isArray(changed.json.agents))
})

test('SessionEnd marks ended; stop persists a snapshot that status falls back to', async () => {
  await hook(ev('s1', 'SessionEnd', { reason: 'other' }))
  const live = await status()
  assert.equal(live.agents.find(a => a.sessionId === 's1').state, 'ended')
  const stop = await cli('stop')
  assert.equal(stop.json.stopped, true)
  await waitFor(async () => !fs.existsSync(env.CONDUCTORE_SOCKET))
  const snap = await status()
  assert.equal(snap.source, 'snapshot')
  assert.equal(snap.seq, live.seq)
  assert.deepEqual(snap.agents.map(a => a.sessionId).sort(), live.agents.map(a => a.sessionId).sort())
  assert.equal((await cli('stop')).json.running, false)
})

test('daemon restart resumes the seq counter from the snapshot', async () => {
  const before = (await status()).seq
  await hook(ev('s2', 'SessionStart'))
  const st = await status()
  assert.equal(st.source, 'daemon')
  assert.equal(st.seq, before + 1)
  assert.ok(st.agents.some(a => a.sessionId === 's1' && a.state === 'ended'))
})

test('a restarted daemon never matches an etag from before, even at the same seq', async () => {
  const before = await status()
  await cli('stop')
  await waitFor(async () => !fs.existsSync(env.CONDUCTORE_SOCKET))
  await client.ensureDaemon()
  const after = await cli('status', '--etag', before.etag)
  assert.equal(after.json.source, 'daemon')
  assert.equal(after.json.seq, before.seq)
  assert.equal(after.json.unchanged, undefined)
  assert.ok(Array.isArray(after.json.agents))
})

test('install and uninstall edit the settings file idempotently', async () => {
  const file = env.CONDUCTORE_CLAUDE_SETTINGS
  fs.writeFileSync(file, JSON.stringify({ hooks: { Stop: [{ hooks: [{ type: 'command', command: 'echo other' }] }] } }))
  const i1 = await cli('install')
  assert.equal(i1.code, 0)
  assert.equal(i1.json.ok, true)
  const i2 = await cli('install')
  assert.deepEqual(JSON.parse(fs.readFileSync(file, 'utf8')), JSON.parse(fs.readFileSync(file, 'utf8')))
  assert.equal(i2.json.events.length, 11)
  const cfg = JSON.parse(fs.readFileSync(file, 'utf8'))
  assert.equal(cfg.hooks.Stop.length, 2)
  assert.equal(cfg.hooks.PermissionRequest.length, 1)
  assert.match(cfg.hooks.PermissionRequest[0].hooks[0].command, /conductore-hook' PermissionRequest$/)
  // The phone's wait (15 min by default) plus a minute: Claude Code never
  // kills the waiting hook first; the sh hook reads the wait (CON-096).
  assert.equal(cfg.hooks.PermissionRequest[0].hooks[0].timeout, 960)
  assert.equal(fs.readFileSync(path.join(home, 'permission-wait'), 'utf8'), '900\n')
  // `config set permission-wait` moves both.
  assert.equal((await cli('config', 'set', 'permission-wait', '30')).json.hookTimeout, 1860)
  assert.equal(JSON.parse(fs.readFileSync(file, 'utf8')).hooks.PermissionRequest[0].hooks[0].timeout, 1860)
  assert.equal(JSON.parse(fs.readFileSync(file, 'utf8')).hooks.Stop.length, 2)
  assert.equal(fs.readFileSync(path.join(home, 'permission-wait'), 'utf8'), '1800\n')
  await cli('config', 'set', 'permission-wait', '15')
  const u = await cli('uninstall')
  assert.equal(u.json.removed.length, 11)
  assert.deepEqual(JSON.parse(fs.readFileSync(file, 'utf8')), { hooks: { Stop: [{ hooks: [{ type: 'command', command: 'echo other' }] }] } })
})

test('doctor reports checks as JSON, with hook latency and daemon memory', async () => {
  await cli('events', '--timeout', '0') // starts the daemon
  const d = await cli('doctor')
  assert.equal(d.code, 0)
  assert.ok(Array.isArray(d.json.checks))
  assert.ok(d.json.checks.some(c => c.name === 'node' && c.ok))
  const latency = d.json.checks.find(c => c.name === 'hook latency')
  assert.equal(latency.ok, true)
  assert.match(latency.detail, /^\d+\.\d ms per event/)
  assert.match(d.json.checks.find(c => c.name === 'daemon memory').detail, /MB RSS/)
})

test('version matches package.json', async () => {
  const v = await cli('version')
  assert.equal(v.json.version, require('../package.json').version)
  assert.equal(v.json.protocol, 1)
})

test('an oversized PermissionRequest is answered at once, leaving the prompt to the terminal', async () => {
  const t0 = Date.now()
  const r = await hook(ev('s1', 'PermissionRequest', { tool_name: 'Write', tool_input: { file_path: '/x', content: 'y'.repeat(9 * 1024 * 1024) } }),
    { CONDUCTORE_PERMISSION_TIMEOUT: '60' })
  assert.equal(r.code, 0)
  assert.equal(r.stdout, '')
  assert.ok(Date.now() - t0 < 5000, `${Date.now() - t0} ms`)
  assert.deepEqual(fs.readdirSync(path.join(home, 'tmp')).filter(n => n.startsWith('p.')), [])
})

test('a PermissionRequest with no daemon that can start gives up after 5 s, printing nothing', async () => {
  const lone = tempDir('cnd-lone-')
  fs.writeFileSync(path.join(lone, 'node'), '/bin/false\n')
  const t0 = Date.now()
  const r = await hook(ev('x1', 'PermissionRequest', { tool_name: 'Bash', tool_input: { command: 'ls' } }),
    { CONDUCTORE_HOME: lone, CONDUCTORE_SOCKET: path.join(lone, 's.sock'), CONDUCTORE_PERMISSION_TIMEOUT: '60' })
  const ms = Date.now() - t0
  assert.equal(r.code, 0)
  assert.equal(r.stdout, '')
  assert.ok(ms >= 4500 && ms < 9000, `${ms} ms`)
  // The abandoned request does not linger for a later daemon to show.
  assert.deepEqual(fs.readdirSync(path.join(lone, 'spool')), [])
  assert.deepEqual(fs.readdirSync(path.join(lone, 'tmp')), [])
  fs.rmSync(lone, { recursive: true, force: true })
})

test.after(async () => {
  await cli('stop').catch(() => {})
  await cleanup()
})

test('no test touched the real agent configs (~/.claude, ~/.codex, ~/.config/opencode)', () => realConfigs())
