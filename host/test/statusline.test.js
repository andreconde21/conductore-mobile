'use strict'

// Statusline usage: mapping, settings wiring and migration, and the full path
// through the sh client and a real daemon (usage stored without touching
// state, held/parked reports, throttled change events, chained passthrough).

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('fs')
const path = require('path')
const { tempDir, cleanup } = require('./helpers/cleanup')
const { spawn } = require('child_process')
const sl = require('../lib/statusline')

const HOSTD = path.join(__dirname, '..', 'bin', 'conductore-hostd')
const HOOK = path.join(__dirname, '..', 'bin', 'conductore-hook')
const SL = path.join(__dirname, '..', 'bin', 'conductore-statusline')
const BIN = '/home/u/.local/share/conductore/bin/conductore-statusline'
const LEGACY = '/home/u/.local/share/conductore/bin/conductore-hostd'
const q = s => `'${s.replace(/'/g, "'\\''")}'`

const sample = (extra = {}) => ({
  session_id: 'st1',
  cwd: '/work/api',
  model: { id: 'claude-x', display_name: 'Opus' },
  workspace: { current_dir: '/work/api' },
  context_window: { used_percentage: 42.5, total_input_tokens: 85000, context_window_size: 200000 },
  rate_limits: {
    five_hour: { used_percentage: 23.5, resets_at: 1738425600 },
    seven_day: { used_percentage: 41.2, resets_at: 1738857600 }
  },
  cost: { total_cost_usd: 1.23 },
  ...extra
})

test('usageFrom maps the statusline fields', () => {
  assert.deepEqual(sl.usageFrom(sample()), {
    contextUsedPct: 42.5,
    contextTokens: 85000,
    windowLabel: '200k',
    limits: [
      { label: '5h', usedPct: 23.5, resetsAt: 1738425600000 },
      { label: '7d', usedPct: 41.2, resetsAt: 1738857600000 }
    ]
  })
  assert.equal(sl.windowLabel(1000000), '1M')
  // Nulls dropped, absent windows omitted, nothing known -> null.
  assert.deepEqual(sl.usageFrom({ context_window: { used_percentage: null, context_window_size: 200000 }, rate_limits: { seven_day: { used_percentage: 5 } } }),
    { windowLabel: '200k', limits: [{ label: '7d', usedPct: 5 }] })
  assert.equal(sl.usageFrom({ session_id: 'x' }), null)
  assert.equal(sl.usageFrom(null), null)
  assert.equal(sl.usageFrom({ context_window: { used_percentage: 140 } }).contextUsedPct, 100)
})

test('defaultLine is short and survives junk', () => {
  assert.equal(sl.defaultLine(sample()), 'Opus · api · 43% ctx · 5h 24%')
  assert.equal(sl.defaultLine(null), 'conductore')
})

test('merge sets, wraps and is idempotent; unmerge restores', () => {
  const set = sl.merge({}, BIN)
  assert.equal(set.action, 'set')
  assert.deepEqual(set.settings.statusLine, { type: 'command', command: `'${BIN}'` })
  assert.equal(sl.merge(set.settings, BIN).action, 'unchanged')
  assert.deepEqual(sl.unmerge(set.settings), {})

  const theirs = { statusLine: { type: 'command', command: "~/bin/line.sh --fmt 'a b'", padding: 1 } }
  const wrapped = sl.merge(theirs, BIN)
  assert.equal(wrapped.action, 'wrapped')
  assert.equal(wrapped.settings.statusLine.padding, 1)
  assert.equal(sl.chainOf(wrapped.settings.statusLine), "~/bin/line.sh --fmt 'a b'")
  const again = sl.merge(wrapped.settings, BIN)
  assert.equal(again.action, 'unchanged')
  assert.deepEqual(sl.unmerge(again.settings), theirs)
  // A moved install updates the path but keeps the wrapped command.
  const moved = sl.merge(wrapped.settings, '/opt/c/bin/conductore-statusline')
  assert.equal(moved.action, 'updated')
  assert.equal(sl.chainOf(moved.settings.statusLine), "~/bin/line.sh --fmt 'a b'")
  assert.deepEqual(sl.describe(wrapped.settings), { wired: true, detail: "wired, wrapping: ~/bin/line.sh --fmt 'a b'" })
  assert.equal(sl.describe(theirs).wired, false)
})

test('merge migrates the Node statusline of 0.3 to the sh one, keeping what it wraps', () => {
  const chain = "~/bin/line.sh --fmt 'a b'"
  const old = { statusLine: { type: 'command', command: `${q(LEGACY)} statusline --chain ${q(chain)}`, padding: 2 } }
  assert.equal(sl.isOurs(old.statusLine), true)
  assert.equal(sl.chainOf(old.statusLine), chain)
  assert.match(sl.describe(old).detail, /Node statusline from 0\.3/)
  const m = sl.merge(old, BIN)
  assert.equal(m.action, 'updated')
  assert.equal(m.settings.statusLine.padding, 2)
  assert.equal(m.settings.statusLine.command, `${q(BIN)} --chain ${q(chain)}`)
  assert.equal(sl.chainOf(m.settings.statusLine), chain)
  assert.equal(sl.merge(m.settings, BIN).action, 'unchanged')
  assert.deepEqual(sl.unmerge(m.settings), { statusLine: { type: 'command', command: chain, padding: 2 } })
  // A bare legacy line becomes a bare sh line.
  assert.equal(sl.merge({ statusLine: { type: 'command', command: `${q(LEGACY)} statusline` } }, BIN).settings.statusLine.command, q(BIN))
  assert.equal(sl.isOurs({ command: '~/bin/conductore-statusline-ish' }), false)
})

// --- through the real clients and daemon ---

const home = tempDir('cnd-sl-')
const env = {
  ...process.env,
  CONDUCTORE_HOME: home,
  CONDUCTORE_SOCKET: path.join(home, 'hostd.sock'),
  CONDUCTORE_CLAUDE_SETTINGS: path.join(home, 'settings.json'),
  CONDUCTORE_USAGE_THROTTLE_MS: '3000'
}
for (const k of ['TMUX', 'TMUX_PANE', 'HERDR_WORKSPACE_ID', 'HERDR_PANE_ID', 'HERDR_TAB_ID', 'HERDR_AGENT_NAME']) delete env[k]

// The Node CLI runs under node; the sh clients run as themselves.
function run (bin, args, input) {
  return new Promise((resolve, reject) => {
    const child = bin === HOSTD
      ? spawn(process.execPath, [bin, ...args], { env, stdio: ['pipe', 'pipe', 'pipe'] })
      : spawn(bin, args, { env, stdio: ['pipe', 'pipe', 'pipe'] })
    let stdout = ''
    child.stdout.on('data', d => { stdout += d })
    child.on('error', reject)
    child.on('close', code => resolve({ code, stdout }))
    child.stdin.end(input)
  })
}
const cli = async (...args) => {
  const r = await run(HOSTD, args, '')
  return { code: r.code, json: JSON.parse(r.stdout.trim().split('\n').pop()) }
}
// `status` applies everything spooled so far (starting the daemon if needed).
const agentOf = async sid => (await cli('status')).json.agents.find(a => a.sessionId === sid)

test.after(async () => {
  await cli('stop').catch(() => {})
  await cleanup()
})

test('statusline without a daemon or valid input still prints and exits 0 (sh and legacy Node)', async () => {
  for (const [bin, args] of [[SL, []], [HOSTD, ['statusline']]]) {
    const r = await run(bin, args, 'not json')
    assert.equal(r.code, 0)
    assert.equal(r.stdout, 'conductore\n')
  }
})

test('the sh default line matches lib/statusline.js', async () => {
  const cases = [
    sample(),
    { ...sample(), context_window: null, rate_limits: { five_hour: null, seven_day: { used_percentage: 5 } } },
    { ...sample(), context_window: { current_usage: { input_tokens: 1 }, used_percentage: 99.6 }, rate_limits: { five_hour: { resets_at: 1, used_percentage: 140 } } },
    { session_id: 'j1', model: { display_name: 'Sonnet' }, cwd: '/' },
    { session_id: 'j2', workspace: { current_dir: '/a/b/' }, context_window: { used_percentage: 0.4 } }
  ]
  for (const [i, input] of cases.entries()) {
    input.session_id = `dl${i}`
    const expected = sl.defaultLine(input) + '\n'
    assert.equal((await run(SL, [], JSON.stringify(input))).stdout, expected, JSON.stringify(input))
    assert.equal((await run(SL, [], JSON.stringify(input, null, 2))).stdout, expected, 'pretty-printed')
  }
})

test('statusline stores usage without changing state; reports are held and the last one wins', async () => {
  await run(HOOK, ['SessionStart'], JSON.stringify({ session_id: 'st1', cwd: '/work/api', hook_event_name: 'SessionStart' }))
  const before = await agentOf('st1')
  assert.ok(before, 'session registered')

  const { json: { seq } } = await cli('status')
  const r = await run(SL, [], JSON.stringify(sample()))
  assert.equal(r.code, 0)
  assert.equal(r.stdout, 'Opus · api · 43% ctx · 5h 24%\n')
  const after = await agentOf('st1')
  assert.deepEqual(after.usage, sl.usageFrom(sample()))
  assert.equal(after.state, before.state)
  assert.equal(after.updatedAt, before.updatedAt)

  const first = await cli('events', '--since', String(seq), '--timeout', '1')
  assert.equal(first.json.reason, 'usage')
  assert.deepEqual(first.json.agent.usage, after.usage)

  // The daemon took that report from the spool and opened a hold: the next
  // reports are parked (latest wins) instead of waking it.
  assert.ok(fs.existsSync(path.join(home, 'usage', 'st1.hold')))
  const seq2 = first.json.seq
  await run(SL, [], JSON.stringify(sample({ context_window: { used_percentage: 50 } })))
  await run(SL, [], JSON.stringify(sample({ context_window: { used_percentage: 60 } })))
  assert.deepEqual(fs.readdirSync(path.join(home, 'spool')), [])
  assert.equal(fs.readdirSync(path.join(home, "usage")).filter(n => n.startsWith("st1.") && n !== "st1.hold").length, 2)
  // When the hold ends (3 s here) the parked report is applied: one change, the last value.
  const lines = (await run(HOSTD, ['events', '--since', String(seq2), '--timeout', '8'], '')).stdout.trim().split('\n').map(l => JSON.parse(l))
  const usageChanges = lines.filter(l => l.reason === 'usage')
  assert.equal(usageChanges.length, 1)
  assert.equal(usageChanges[0].agent.usage.contextUsedPct, 60)
  assert.deepEqual(fs.readdirSync(path.join(home, "usage")).filter(n => n.startsWith("st1.") && n !== "st1.hold"), [])

  // The same usage again publishes nothing.
  const seq3 = usageChanges[0].seq
  await run(SL, [], JSON.stringify(sample({ context_window: { used_percentage: 60 } })))
  const none = await cli('events', '--since', String(seq3), '--timeout', '4')
  assert.equal(none.json.type, 'timeout')
})

test('usage reported before the first hook event attaches when it arrives', async () => {
  await run(SL, [], JSON.stringify(sample({ session_id: 'early' })))
  await run(HOOK, ['SessionStart'], JSON.stringify({ session_id: 'early', cwd: '/work/e', hook_event_name: 'SessionStart' }))
  const agent = await agentOf('early')
  assert.equal(agent.usage.contextUsedPct, 42.5)
})

test('legacy `conductore-hostd statusline` still reports over the socket', async () => {
  await run(HOOK, ['SessionStart'], JSON.stringify({ session_id: 'leg', cwd: '/work/l', hook_event_name: 'SessionStart' }))
  assert.ok(await agentOf('leg'))
  const r = await run(HOSTD, ['statusline'], JSON.stringify(sample({ session_id: 'leg' })))
  assert.equal(r.stdout, 'Opus · api · 43% ctx · 5h 24%\n')
  assert.equal((await agentOf('leg')).usage.contextUsedPct, 42.5)
})

test('--chain feeds the same stdin to the previous command and prints its output unchanged', async () => {
  const chain = "read -r l; printf 'mine %s' \"$(printf '%s' \"$l\" | wc -c | tr -d ' ')\""
  for (const [bin, pre] of [[SL, []], [HOSTD, ['statusline']]]) {
    const r = await run(bin, [...pre, '--chain', chain], '{"a":1}\n')
    assert.equal(r.code, 0)
    assert.equal(r.stdout, 'mine 7')
  }
  // A failing chained command never breaks the line: no output, exit 0.
  const bad = await run(SL, ['--chain', 'echo oops >&2; exit 3'], JSON.stringify(sample()))
  assert.equal(bad.code, 0)
  assert.equal(bad.stdout, '')
  // The whole input arrives, not just its first line.
  const multi = await run(SL, ['--chain', 'cat'], JSON.stringify(sample(), null, 2))
  assert.equal(multi.stdout, JSON.stringify(sample(), null, 2) + '\n')
})

test('install wraps an existing statusline, doctor reports it, uninstall restores it', async () => {
  const file = env.CONDUCTORE_CLAUDE_SETTINGS
  const original = { type: 'command', command: '~/bin/my-line', padding: 0 }
  fs.writeFileSync(file, JSON.stringify({ statusLine: original }))
  const inst = await cli('install')
  assert.equal(inst.json.statusLine, 'wrapped')
  const written = JSON.parse(fs.readFileSync(file, 'utf8'))
  assert.equal(sl.chainOf(written.statusLine), '~/bin/my-line')
  assert.equal(written.statusLine.command, `${q(SL)} --chain '~/bin/my-line'`)
  const doc = await cli('doctor')
  const check = doc.json.checks.find(c => c.name === 'statusline (usage)')
  assert.equal(check.ok, true)
  assert.equal(check.detail, 'wired, wrapping: ~/bin/my-line')
  const un = await cli('uninstall')
  assert.equal(un.json.statusLineRestored, true)
  assert.deepEqual(JSON.parse(fs.readFileSync(file, 'utf8')).statusLine, original)
})

test('install migrates a 0.3 install (Node hook entries, Node statusline) idempotently', async () => {
  const file = env.CONDUCTORE_CLAUDE_SETTINGS
  const oldHook = '/old/share/conductore/bin/conductore-hook'
  const hooks = {}
  for (const e of ['SessionStart', 'PreToolUse', 'PermissionRequest', 'Stop']) {
    hooks[e] = [{ matcher: '', hooks: [{ type: 'command', command: `${q(oldHook)} ${e}`, async: true }] }]
  }
  hooks.Stop.unshift({ hooks: [{ type: 'command', command: 'echo other' }] })
  const legacyLine = { type: 'command', command: `${q('/old/share/conductore/bin/conductore-hostd')} statusline --chain 'bash ~/line.sh'`, padding: 0 }
  fs.writeFileSync(file, JSON.stringify({ hooks, statusLine: legacyLine }))
  const inst = await cli('install')
  assert.equal(inst.json.ok, true)
  assert.equal(inst.json.statusLine, 'updated')
  const cfg = JSON.parse(fs.readFileSync(file, 'utf8'))
  const ours = Object.values(cfg.hooks).flat().flatMap(g => g.hooks).filter(h => /conductore-hook' \w+$/.test(h.command))
  assert.equal(ours.length, 9)
  assert.ok(ours.every(h => h.command.startsWith(`${q(HOOK)} `)))
  assert.equal(cfg.hooks.PermissionRequest[0].hooks[0].async, undefined)
  assert.deepEqual(cfg.hooks.Stop[0], { hooks: [{ type: 'command', command: 'echo other' }] })
  assert.equal(cfg.statusLine.command, `${q(SL)} --chain 'bash ~/line.sh'`)
  assert.equal(cfg.statusLine.padding, 0)
  assert.equal(fs.readFileSync(path.join(home, 'node'), 'utf8'), process.execPath + '\n')
  // Second run: nothing to change, the file is not rewritten.
  const bytes = fs.readFileSync(file, 'utf8')
  const mtime = fs.statSync(file).mtimeMs
  const again = await cli('install')
  assert.equal(again.json.statusLine, 'unchanged')
  assert.equal(fs.readFileSync(file, 'utf8'), bytes)
  assert.equal(fs.statSync(file).mtimeMs, mtime)
  await cli('uninstall')
})
