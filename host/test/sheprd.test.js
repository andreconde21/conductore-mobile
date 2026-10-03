'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('fs')
const path = require('path')
const { execFile } = require('child_process')
const { tempDir, cleanup } = require('./helpers/cleanup')
const toml = require('../lib/toml-lite')
const sheprd = require('../lib/sheprd')

const HOSTD = path.join(__dirname, '..', 'bin', 'conductore-hostd')

test.after(cleanup)

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
