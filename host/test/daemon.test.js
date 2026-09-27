'use strict'

// Integration: a real daemon on a temp socket, the real (sh) hook client, the CLI.

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('fs')
const path = require('path')
const { tempDir, cleanup } = require('./helpers/cleanup')
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
printf 'main\t2\t%s\t/work/t\tfixer\t4242\n' "$6"
`, { mode: 0o755 })
// A fake herdr: `pane list` knows session h1 (pane w3:p2) and pane w3:p9.
// It also logs which Herdr server (HERDR_SOCKET_PATH) each call went to.
// A fake claude: `install` registers the newer hooks for this version.
fs.writeFileSync(path.join(fakeBin, 'claude'), '#!/bin/sh\necho "2.1.280 (Claude Code)"\n', { mode: 0o755 })
const herdrLog = path.join(fakeBin, 'herdr.log')
const herdrSocketLog = path.join(fakeBin, 'herdr-sockets.log')
fs.writeFileSync(path.join(fakeBin, 'herdr'), `#!/bin/sh
printf '%s\n' "$*" >> '${herdrLog}'
printf '%s\n' "\${HERDR_SOCKET_PATH:-default}" >> '${herdrSocketLog}'
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
  CONDUCTORE_CLAUDE_SETTINGS: path.join(home, 'settings.json')
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
  assert.match(fs.readFileSync(tmuxLog, 'utf8'), /^-S \/tmp\/fake-tmux-sock display-message -p -t %7 /m)
  // Herdr comes straight from the header.
  await hook(ev('t2', 'SessionStart'), { HERDR_WORKSPACE_ID: 'w1', HERDR_TAB_ID: 'w1:t1', HERDR_PANE_ID: 'w1:p1', HERDR_AGENT_NAME: 'rev' })
  const b = (await status()).agents.find(a => a.sessionId === 't2')
  assert.deepEqual(b.herdr, { workspaceId: 'w1', tabId: 'w1:t1', paneId: 'w1:p1', name: 'rev', socket: null })
  assert.equal(b.name, 'rev')
})

test("an agent in a named Herdr session records that session's socket", async () => {
  const sock = path.join(home, 'herdr-other.sock')
  await hook(ev('t3', 'SessionStart'), { HERDR_WORKSPACE_ID: 'w1', HERDR_TAB_ID: 'w1:t1', HERDR_PANE_ID: 'w1:p1', HERDR_SOCKET_PATH: sock })
  const a = (await status()).agents.find(a => a.sessionId === 't3')
  assert.deepEqual(a.herdr, { workspaceId: 'w1', tabId: 'w1:t1', paneId: 'w1:p1', name: null, socket: sock })

  // Only the pane id known: its location is asked of that session's server.
  fs.writeFileSync(herdrSocketLog, '')
  await hook(ev('t4', 'SessionStart'), { HERDR_PANE_ID: 'w3:p9', HERDR_SOCKET_PATH: sock })
  const b = (await status()).agents.find(a => a.sessionId === 't4')
  assert.deepEqual(b.herdr, { workspaceId: 'w3', tabId: 'w3:t4', paneId: 'w3:p9', name: null, socket: sock })
  assert.equal(fs.readFileSync(herdrSocketLog, 'utf8'), `${sock}\n`)
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

test('decide always answers allow with updatedPermissions (suggestion preferred, else derived rule)', async () => {
  const suggestion = { type: 'addRules', rules: [{ toolName: 'Bash', ruleContent: 'git *' }], behavior: 'allow', destination: 'localSettings' }
  const p1 = hook(ev('s1', 'PermissionRequest', { tool_name: 'Bash', tool_input: { command: 'git status' }, permission_suggestions: [suggestion] }), { CONDUCTORE_PERMISSION_TIMEOUT: '20' })
  const r1 = await waitFor(async () => ((await status()).agents.find(a => a.sessionId === 's1') || {}).pending?.[0])
  await cli('decide', r1.id, 'always')
  const out1 = JSON.parse((await p1).stdout)
  assert.deepEqual(out1.hookSpecificOutput.decision, { behavior: 'allow', updatedPermissions: [suggestion] })

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
})

test('PermissionRequest timeout prints nothing and leaves the terminal prompt to Claude Code', async () => {
  const t0 = Date.now()
  const r = await hook(ev('s1', 'PermissionRequest', { tool_name: 'Bash', tool_input: { command: 'ls' } }), { CONDUCTORE_PERMISSION_TIMEOUT: '1' })
  assert.equal(r.code, 0)
  assert.equal(r.stdout, '')
  assert.ok(Date.now() - t0 >= 900)
  const a = (await status()).agents.find(a => a.sessionId === 's1')
  assert.equal(a.pending.length, 0)
  assert.equal(a.state, 'needs_permission')
  const late = await cli('decide', 'whatever', 'allow')
  assert.equal(late.code, 1)
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
  // Backlog: the buffered changes since a recent cursor are served at once.
  const backlog = await cli('events', '--since', String(before - 2), '--timeout', '5')
  assert.equal(backlog.lines.length, 2)
  assert.ok(backlog.lines.every(l => l.type === 'change' || l.type === 'remove'))
  assert.deepEqual(backlog.lines.map(l => l.seq), [before - 1, before])

  // A cursor older than the daemon's buffer (it restarted earlier in this run) gets a snapshot.
  const stale = await cli('events', '--since', '0', '--timeout', '1')
  assert.equal(stale.lines.length, 1)
  assert.equal(stale.lines[0].type, 'snapshot')
  assert.equal(stale.lines[0].seq, before)

  // Nothing new: the poll parks, then a Stop wakes it with exactly that change.
  const poll = cli('events', '--since', String(before), '--timeout', '10')
  await sleep(300)
  await hook(ev('s1', 'Stop', { last_assistant_message: 'Finished.' }))
  const woke = await poll
  assert.equal(woke.lines.length, 1)
  assert.equal(woke.lines[0].seq, before + 1)
  assert.equal(woke.lines[0].reason, 'Stop')
  assert.equal(woke.lines[0].agent.state, 'waiting_input')
  assert.equal(woke.lines[0].agent.lastMessage, 'Finished.')

  // Timeout without changes.
  const t0 = Date.now()
  const idle = await cli('events', '--since', String(before + 1), '--timeout', '1')
  assert.ok(Date.now() - t0 >= 900)
  assert.deepEqual(idle.lines, [{ type: 'timeout', seq: before + 1 }])

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
