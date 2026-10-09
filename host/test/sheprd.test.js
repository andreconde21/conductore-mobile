'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('fs')
const path = require('path')
const { execFile } = require('child_process')
const { tempDir, cleanup, guardRealConfigs } = require('./helpers/cleanup')
const toml = require('../lib/toml-lite')
const sheprd = require('../lib/sheprd')

const HOSTD = path.join(__dirname, '..', 'bin', 'conductore-hostd')

const realConfigs = guardRealConfigs()

test.after(async () => {
  await cleanup()
  realConfigs()
})

// What sheprd writes (toml::to_string_pretty after its header line).
const WRITTEN = `# herdr (andreconde fork) sidebar projects. Hand-editable; see projects.rs.
compact = true
active_only = true
recent_hours = 12
hidden = ["gpu-box/w3:scratch"]
unread = ["local/p1"]
ungrouped = ["local/w9:Storefront-old"]

[[group]]
name = "storefront"
pinned = true
members = [
    "local/w1:notes",
    "gpu-box/w2:sf",
]
match = ["storefront"]

[[group]]
name = "TheCalendar"
collapsed = true
match = ['cal', "the\\u0063alendar"]
short = "TC"
`

test('toml-lite: what sheprd writes and the README example', () => {
  const doc = toml.parse(WRITTEN)
  assert.equal(doc.compact, true)
  assert.equal(doc.recent_hours, 12)
  assert.deepEqual(doc.hidden, ['gpu-box/w3:scratch'])
  assert.equal(doc.group.length, 2)
  assert.deepEqual(doc.group[0], { name: 'storefront', pinned: true, members: ['local/w1:notes', 'gpu-box/w2:sf'], match: ['storefront'] })
  assert.deepEqual(doc.group[1].match, ['cal', 'thecalendar'])
  assert.equal(Object.getPrototypeOf(doc), Object.prototype)

  const readme = toml.parse(`compact = false                        # view
active_only = false                    # filter
recent_hours = 24
hidden = ["gpu-box/scratch"]           # machine/workspace

[[group]]
name = "storefront"
pinned = true
match = ["storefront"]                 # name or folder substring
members = ["local/notes"]              # explicit members, in display order
`)
  assert.deepEqual(readme.group, [{ name: 'storefront', pinned: true, match: ['storefront'], members: ['local/notes'] }])
})

test('toml-lite: tables, dotted keys, CRLF, escapes', () => {
  const doc = toml.parse('a.b = 1\r\n[t]\r\nx = "q\\"\\t\\\\"\r\n[t.u]\r\ny = -3\r\n[[t.list]]\r\nz = true\r\n')
  assert.deepEqual(doc, { a: { b: 1 }, t: { x: 'q"\t\\', u: { y: -3 }, list: [{ z: true }] } })
})

test('toml-lite: refuses what it does not support instead of guessing', () => {
  for (const bad of [
    'a = 1.5',
    'a = 1979-05-27',
    'a = { b = 1 }',
    'a = [[1]]',
    'a = """x"""',
    '"quoted" = 1',
    'a = "open',
    'a = 1\na = 2',
    '[t]\n[t]',
    'a = 1 b',
    'a = "\\x"',
    'a = 99999999999999999999',
    'hidden = ["x"]\n[hidden.y]'
  ]) {
    assert.throws(() => toml.parse(bad), toml.TomlError, bad)
  }
  assert.throws(() => toml.parse('a = "' + 'x'.repeat(toml.MAX_BYTES) + '"'), /too large/)
})

test('toml-lite: __proto__ is an ordinary key, nothing is polluted', () => {
  const doc = toml.parse('__proto__ = "x"\n[constructor]\nprototype = 1\n')
  assert.equal(Object.getOwnPropertyDescriptor(doc, '__proto__').value, 'x')
  assert.equal({}.prototype, undefined)
  assert.equal(Object.prototype.x, undefined)
})

test('pick keeps only the layout keys, checked', () => {
  const layout = sheprd.pick({
    compact: true,
    active_only: 'yes',
    recent_hours: -1,
    hidden: ['a/b', 3],
    unread: ['local/p1'],
    group: [{ name: 'A', match: ['a'], pinned: true, extra: 1 }, { name: '  ' }, { match: ['x'] }, 'junk']
  })
  assert.deepEqual(layout, {
    compact: true,
    hidden: ['a/b'],
    ungrouped: [],
    group: [{ name: 'A', members: [], match: ['a'], pinned: true }]
  })
})

test('sidebarPath follows XDG_CONFIG_HOME like Herdr', () => {
  assert.equal(sheprd.sidebarPath({}, '/home/u'), '/home/u/.config/herdr/sidebar.toml')
  assert.equal(sheprd.sidebarPath({ XDG_CONFIG_HOME: '/x/cfg' }, '/home/u'), '/x/cfg/herdr/sidebar.toml')
  assert.equal(sheprd.sidebarPath({ XDG_CONFIG_HOME: 'relative' }, '/home/u'), '/home/u/.config/herdr/sidebar.toml')
})

function hostd (args, env) {
  return new Promise(resolve => execFile(process.execPath, [HOSTD, ...args], { env }, (err, stdout) => resolve(JSON.parse(String(stdout).trim().split('\n').pop()))))
}

function envFor (home) {
  const env = { ...process.env, HOME: home, CONDUCTORE_HOME: path.join(home, '.conductore'), CONDUCTORE_SOCKET: path.join(home, 's.sock') }
  delete env.XDG_CONFIG_HOME
  for (const k of Object.keys(env)) if (k.startsWith('HERDR_') || k.startsWith('TMUX')) delete env[k]
  return env
}

test('CLI sidebar-layout: none, found, broken; never writes the file', async () => {
  const home = tempDir('hl-sheprd-home-')
  const env = envFor(home)
  assert.deepEqual(await hostd(['sidebar-layout'], env), { ok: true, found: false })

  const dir = path.join(home, '.config', 'herdr')
  fs.mkdirSync(dir, { recursive: true })
  const file = path.join(dir, 'sidebar.toml')
  fs.writeFileSync(file, WRITTEN)
  const before = fs.statSync(file).mtimeMs
  const r = await hostd(['sidebar-layout'], env)
  assert.equal(r.found, true)
  assert.equal(r.path, '~/.config/herdr/sidebar.toml')
  assert.equal(r.layout.group[1].short, 'TC')
  assert.equal(r.layout.active_only, true)
  assert.equal(r.layout.unread, undefined)
  assert.equal(fs.readFileSync(file, 'utf8'), WRITTEN)
  assert.equal(fs.statSync(file).mtimeMs, before)

  fs.writeFileSync(file, 'compact = maybe\n')
  const broken = await hostd(['sidebar-layout'], env)
  assert.equal(broken.found, true)
  assert.match(broken.error, /line 1: unsupported value/)
  assert.equal(broken.layout, undefined)

  const xdg = tempDir('hl-sheprd-xdg-')
  fs.mkdirSync(path.join(xdg, 'herdr'))
  fs.writeFileSync(path.join(xdg, 'herdr', 'sidebar.toml'), '[[group]]\nname = "x"\n')
  const viaXdg = await hostd(['sidebar-layout'], { ...env, XDG_CONFIG_HOME: xdg })
  assert.deepEqual(viaXdg.layout.group, [{ name: 'x', members: [], match: [] }])
  assert.equal(fs.existsSync(path.join(home, '.conductore', 'hostd.pid')), false, 'no daemon')
})

// sheprd's view (CON-077, docs/sheprd-view-sync.md).

const NOW = 1759612400 * 1000
const VIEW = {
  version: 1,
  updated: 1759612390,
  source: 'sheprd 0.6.2',
  hub: 'laptop',
  self: 'dev',
  layout: { active_only: true, hidden: ['dev/w3:scratch'], unread: ['x/p1'], group: [{ name: 'Storefront', members: ['local/w1:notes', 'dev/w2:sf'], match: ['storefront'] }] },
  agents: {
    'dev/w2:p1': { presence: 'unread', state_seq: 41, unread: true, dismissed: false, kept: false },
    'local/w1:p2': { presence: 'idle', state_seq: 7, dismissed: true, kept: true, removed: true },
    'bad key': { presence: 'idle' },
    'dev/w2:p9': { presence: 'sleeping' }
  },
  order: ['local/w1:notes', 'dev/w2:sf', 3],
  focus: 'local/w1:p2',
  future: { anything: true }
}

test('readView: none, checked v1, stale, refusals', () => {
  const dir = path.join(tempDir('hl-sheprd-view-'), 'sheprd')
  assert.deepEqual(sheprd.readView({ dir, now: NOW }), { found: false })
  fs.mkdirSync(dir)
  const file = path.join(dir, 'view.json')
  fs.writeFileSync(file, JSON.stringify(VIEW))
  const r = sheprd.readView({ dir, now: NOW })
  assert.equal(r.stale, false)
  assert.equal(r.view.self, 'dev')
  assert.equal(r.view.hub, 'laptop')
  assert.deepEqual(Object.keys(r.view.agents), ['dev/w2:p1', 'local/w1:p2'])
  assert.deepEqual(r.view.agents['local/w1:p2'], { presence: 'idle', state_seq: 7, unread: false, dismissed: true, kept: true, removed: true })
  assert.equal(r.view.layout.unread, undefined, 'marks never come through the layout')
  assert.deepEqual(r.view.layout.group[0].members, ['local/w1:notes', 'dev/w2:sf'])
  assert.deepEqual(r.view.order, ['local/w1:notes', 'dev/w2:sf'])
  assert.equal(r.view.focus, 'local/w1:p2')
  assert.equal(r.view.future, undefined)
  assert.equal(sheprd.readView({ dir, now: NOW + 200 * 1000 }).stale, true)

  fs.writeFileSync(file, JSON.stringify({ ...VIEW, version: 2 }))
  assert.match(sheprd.readView({ dir, now: NOW }).error, /unsupported version 2/)
  fs.writeFileSync(file, JSON.stringify({ ...VIEW, self: undefined }))
  assert.match(sheprd.readView({ dir, now: NOW }).error, /self is missing/)
  fs.writeFileSync(file, '{"version": 1,')
  assert.match(sheprd.readView({ dir, now: NOW }).error, /^view\.json: /)
  fs.writeFileSync(file, ' '.repeat(1024 * 1024 + 1))
  assert.match(sheprd.readView({ dir, now: NOW }).error, /too large/)
  fs.rmSync(file)
  const elsewhere = path.join(path.dirname(dir), 'elsewhere.json')
  fs.writeFileSync(elsewhere, JSON.stringify(VIEW))
  fs.symlinkSync(elsewhere, file)
  assert.match(sheprd.readView({ dir, now: NOW }).error, /not a regular file/)
})

test('appendUpdate: validated lines, appended, nothing else touched', () => {
  const root = tempDir('hl-sheprd-upd-')
  const dir = path.join(root, 'state', 'sheprd')
  for (const [input, error] of [
    [{ op: 'toggle', agent: 'dev/w2:p1' }, /op must be/],
    [{ op: 'unread', agent: 'dev' }, /machine\/pane_id/],
    [{ op: 'unread', agent: 'dev/w2:p1\n{"op":"x"}' }, /machine\/pane_id/],
    [{ op: 'unread', agent: '../x/p1' }, /machine\/pane_id/],
    [{ op: 'dismiss', agent: 'dev/w2:p1' }, /needs --state-seq/],
    [{ op: 'dismiss', agent: 'dev/w2:p1', stateSeq: -1 }, /whole number/]
  ]) {
    assert.throws(() => sheprd.appendUpdate({ dir, ...input, now: NOW }), error)
  }
  assert.equal(fs.existsSync(dir), false, 'a refused update creates nothing')

  const a = sheprd.appendUpdate({ dir, op: 'unread', agent: 'dev/w2:p1', now: NOW })
  const b = sheprd.appendUpdate({ dir, op: 'dismiss', agent: 'local/w1:p2', stateSeq: 7, now: NOW })
  assert.match(a.id, /^[A-Za-z0-9_-]{8,64}$/)
  assert.notEqual(a.id, b.id)
  const file = path.join(dir, 'view-updates.jsonl')
  const lines = fs.readFileSync(file, 'utf8').split('\n')
  assert.equal(lines.pop(), '')
  assert.deepEqual(lines.map(JSON.parse), [
    { v: 1, id: a.id, at: 1759612400, from: 'conductore', op: 'unread', agent: 'dev/w2:p1' },
    { v: 1, id: b.id, at: 1759612400, from: 'conductore', op: 'dismiss', agent: 'local/w1:p2', state_seq: 7 }
  ])
  assert.deepEqual(fs.readdirSync(dir), ['view-updates.jsonl'], 'the lock is gone, nothing else written')
  assert.equal(fs.statSync(file).mode & 0o777, 0o600)
  assert.equal(fs.statSync(dir).mode & 0o777, 0o700)

  // A full file means sheprd is not draining: refused, unchanged.
  fs.writeFileSync(file, 'x'.repeat(sheprd.UPDATES_MAX_BYTES))
  assert.throws(() => sheprd.appendUpdate({ dir, op: 'keep', agent: 'dev/w2:p1' }), /is full/)
  assert.equal(fs.statSync(file).size, sheprd.UPDATES_MAX_BYTES)

  // Never through a symlink.
  fs.rmSync(file)
  const target = path.join(root, 'target')
  fs.writeFileSync(target, '')
  fs.symlinkSync(target, file)
  assert.throws(() => sheprd.appendUpdate({ dir, op: 'keep', agent: 'dev/w2:p1' }), /not a regular file/)
  assert.equal(fs.readFileSync(target, 'utf8'), '')
})

test('the lock: held means wait then refuse; stale is taken over', () => {
  const dir = tempDir('hl-sheprd-lock-')
  const lock = path.join(dir, 'view-updates.lock')
  fs.writeFileSync(lock, '1')
  assert.throws(() => sheprd.withLock(dir, () => 1, { waitMs: 120 }), /is held/)
  assert.equal(fs.existsSync(lock), true, 'someone else\'s lock stays')
  const old = (Date.now() - 60_000) / 1000
  fs.utimesSync(lock, old, old)
  assert.equal(sheprd.withLock(dir, () => 42), 42)
  assert.equal(fs.existsSync(lock), false)
})

test('CLI sheprd-view and sheprd-view-update under a temp HOME', async () => {
  const home = tempDir('hl-sheprd-cli-')
  const env = envFor(home)
  assert.deepEqual(await hostd(['sheprd-view'], env), { ok: true, found: false })
  const dir = path.join(home, '.local', 'state', 'sheprd')
  fs.mkdirSync(dir, { recursive: true })
  fs.writeFileSync(path.join(dir, 'view.json'), JSON.stringify({ ...VIEW, updated: Math.floor(Date.now() / 1000) }))
  const r = await hostd(['sheprd-view'], env)
  assert.equal(r.found, true)
  assert.equal(r.path, '~/.local/state/sheprd/view.json')
  assert.equal(r.stale, false)
  assert.equal(r.view.agents['dev/w2:p1'].presence, 'unread')

  const ok = await hostd(['sheprd-view-update', '--op', 'dismiss', '--agent', 'dev/w2:p1', '--state-seq', '41'], env)
  assert.equal(ok.ok, true)
  const line = JSON.parse(fs.readFileSync(path.join(dir, 'view-updates.jsonl'), 'utf8'))
  assert.equal(line.id, ok.id)
  assert.equal(line.state_seq, 41)
  assert.match((await hostd(['sheprd-view-update', '--op', 'dismiss', '--agent', 'dev/w2:p1', '--state-seq', '4x'], env)).error, /whole number/)
  assert.match((await hostd(['sheprd-view-update', '--op', 'keep'], env)).error, /machine\/pane_id/)
  assert.deepEqual(fs.readdirSync(dir).sort(), ['view-updates.jsonl', 'view.json'])
  const version = await hostd(['version'], env)
  assert.ok(version.capabilities.includes('sheprd-view'))
})

// Contract v2 (CON-101): layout edits.

test('readView passes on v2 `updates` and `rejected`, defaulting to 1 and none', () => {
  const dir = path.join(tempDir('hl-sheprd-v2view-'), 'sheprd')
  fs.mkdirSync(dir)
  const file = path.join(dir, 'view.json')
  fs.writeFileSync(file, JSON.stringify(VIEW))
  const v1 = sheprd.readView({ dir, now: NOW }).view
  assert.equal(v1.updates, 1)
  assert.deepEqual(v1.rejected, [])
  fs.writeFileSync(file, JSON.stringify({
    ...VIEW,
    updates: 2,
    rejected: [{ id: 'c-1759612400000-aaaa', why: 'renamed or deleted meanwhile' }, { id: 'bad id!' }, 'x', { id: 'c-1759612400000-bbbb', why: 'y'.repeat(500) }]
  }))
  const v2 = sheprd.readView({ dir, now: NOW }).view
  assert.equal(v2.updates, 2)
  assert.deepEqual(v2.rejected.map(r => r.id), ['c-1759612400000-aaaa', 'c-1759612400000-bbbb'])
  assert.equal(v2.rejected[1].why.length, 120)
  fs.writeFileSync(file, JSON.stringify({ ...VIEW, updates: 'two' }))
  assert.equal(sheprd.readView({ dir, now: NOW }).view.updates, 1)
})

test('updateLineV2: every op with its fields; refusals', () => {
  const ok = [
    { op: 'assign', workspace: 'dev/w2:sf', project: 'Storefront' },
    { op: 'assign', workspace: 'local/my notes', project: '' },
    { op: 'hide', workspace: 'dev/w3:scratch' },
    { op: 'show', workspace: 'dev/w3:scratch' },
    { op: 'project-create', project: 'Shop', match: ['shop'] },
    { op: 'project-create', project: 'Shop' },
    { op: 'project-rename', project: 'Shop', to: 'Storefront' },
    { op: 'project-pin', project: 'Shop', pinned: false },
    { op: 'project-rules', project: 'Shop', match: [], was: ['shop'] },
    { op: 'project-short', project: 'Shop', short: '' },
    { op: 'project-delete', project: 'Shop', members: ['dev/w2:sf'] },
    { op: 'project-move', project: 'Shop', before: '' },
    { op: 'project-move', project: 'Shop', before: 'Infra' },
    { op: 'member-move', workspace: 'dev/w2:sf', before: 'local/w1:notes' },
    { op: 'remove-active', agent: 'dev/w2:p1', state_seq: 0 },
    { op: 'keep-active', agent: 'dev/w2:p1' }
  ]
  for (const input of ok) {
    const { id, line } = sheprd.updateLineV2(input, { now: NOW })
    const parsed = JSON.parse(line)
    assert.deepEqual(parsed, { v: 2, id, at: 1759612400, from: 'conductore', ...input })
    assert.ok(line.endsWith('\n') && !line.slice(0, -1).includes('\n'))
  }
  for (const [input, error] of [
    [{ op: 'unread', agent: 'dev/w2:p1' }, /op must be one of/],
    [{ op: 'assign', workspace: 'dev/w2:sf' }, /needs project/],
    [{ op: 'assign', workspace: 'nomachine', project: 'x' }, /bad workspace/],
    [{ op: 'assign', workspace: 'dev/w2:sf\n{"v":1}', project: 'x' }, /bad workspace/],
    [{ op: 'assign', workspace: 'dev/w2:sf', project: ' padded ' }, /bad project/],
    [{ op: 'project-create', project: '' }, /bad project/],
    [{ op: 'project-create', project: 'x'.repeat(129) }, /bad project/],
    [{ op: 'project-create', project: 'Shop', match: ['a,b'] }, /bad match/],
    [{ op: 'project-create', project: 'Shop', match: Array(33).fill('a') }, /bad match/],
    [{ op: 'project-rename', project: 'Shop' }, /needs to/],
    [{ op: 'project-pin', project: 'Shop', pinned: 'yes' }, /bad pinned/],
    [{ op: 'project-short', project: 'Shop', short: 'toolongtag' }, /bad short/],
    [{ op: 'project-delete', project: 'Shop', members: ['x'] }, /bad members/],
    [{ op: 'project-move', project: 'Shop', before: 'dev/w2:sf\u0000' }, /bad before/],
    [{ op: 'member-move', workspace: 'dev/w2:sf', before: 'Shop' }, /bad before/],
    [{ op: 'remove-active', agent: 'dev/w2:p1' }, /needs state_seq/],
    [{ op: 'remove-active', agent: 'dev/w2:p1', state_seq: -2 }, /bad state_seq/],
    [{ op: 'keep-active', agent: 'dev/w2 p1' }, /bad agent/],
    [{ op: 'hide', workspace: 'dev/w2:sf', v: 1 }, /unknown field v/],
    [{ op: 'hide', workspace: 'dev/w2:sf', id: 'c-12345678' }, /unknown field id/],
    [['hide'], /must be an object/],
    [{ op: 'project-rules', project: 'Shop', match: Array(32).fill('r'.repeat(128)) }, /too long/]
  ]) {
    assert.throws(() => sheprd.updateLineV2(input, { now: NOW }), error, JSON.stringify(input).slice(0, 80))
  }
})

test('appendUpdatesV2: a batch is one write; one bad op appends nothing', () => {
  const root = tempDir('hl-sheprd-v2upd-')
  const dir = path.join(root, 'sheprd')
  assert.throws(() => sheprd.appendUpdatesV2({ dir, ops: [{ op: 'hide', workspace: 'dev/w1:a' }, { op: 'hide' }] }), /needs workspace/)
  assert.equal(fs.existsSync(dir), false, 'a refused batch creates nothing')
  assert.throws(() => sheprd.appendUpdatesV2({ dir, ops: [] }), /no op/)
  assert.throws(() => sheprd.appendUpdatesV2({ dir, ops: Array(9).fill({ op: 'hide', workspace: 'dev/w1:a' }) }), /at most 8/)

  sheprd.appendUpdate({ dir, op: 'keep', agent: 'dev/w2:p1', now: NOW })
  const r = sheprd.appendUpdatesV2({ dir, now: NOW, ops: [{ op: 'project-create', project: 'Found' }, { op: 'project-pin', project: 'Found', pinned: true }] })
  assert.equal(r.ok, true)
  assert.equal(r.ids.length, 2)
  const one = sheprd.appendUpdatesV2({ dir, now: NOW, ops: { op: 'show', workspace: 'dev/w1:a' } })
  assert.equal(one.ids.length, 1)
  const lines = fs.readFileSync(path.join(dir, 'view-updates.jsonl'), 'utf8').trim().split('\n').map(JSON.parse)
  assert.deepEqual(lines.map(l => [l.v, l.op]), [[1, 'keep'], [2, 'project-create'], [2, 'project-pin'], [2, 'show']])
  assert.deepEqual(lines.slice(1).map(l => l.id), [...r.ids, ...one.ids])
  assert.deepEqual(fs.readdirSync(dir), ['view-updates.jsonl'])

  fs.writeFileSync(path.join(dir, 'view-updates.jsonl'), 'x'.repeat(sheprd.UPDATES_MAX_BYTES))
  assert.throws(() => sheprd.appendUpdatesV2({ dir, ops: { op: 'show', workspace: 'dev/w1:a' } }), /is full/)
})

test('CLI sheprd-view-update --json under a temp HOME; capability sheprd-view-2', async () => {
  const home = tempDir('hl-sheprd-v2cli-')
  const env = envFor(home)
  const ops = [{ op: 'assign', workspace: 'dev/w2:sf', project: "Bob's \"shop\" $(x)" }, { op: 'project-short', project: 'Shop', short: 'SH' }]
  const r = await hostd(['sheprd-view-update', '--json', JSON.stringify(ops)], env)
  assert.equal(r.ok, true)
  const file = path.join(home, '.local', 'state', 'sheprd', 'view-updates.jsonl')
  const lines = fs.readFileSync(file, 'utf8').trim().split('\n').map(JSON.parse)
  assert.equal(lines[0].project, "Bob's \"shop\" $(x)")
  assert.deepEqual(lines.map(l => l.id), r.ids)
  assert.match((await hostd(['sheprd-view-update', '--json', '{nope'], env)).error, /must be a JSON op/)
  assert.match((await hostd(['sheprd-view-update', '--json', '{"op":"hide"}'], env)).error, /needs workspace/)
  assert.equal(fs.readFileSync(file, 'utf8').trim().split('\n').length, 2)
  const version = await hostd(['version'], env)
  assert.ok(version.capabilities.includes('sheprd-view-2'))
})
