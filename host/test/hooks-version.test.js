'use strict'

// The newer hook events (PostToolUseFailure, StopFailure) go into
// settings.json only when the local Claude Code knows them: before 2.1.101
// one unknown event name made Claude Code ignore the whole file. `install`
// asks `claude --version` (a fake here), `doctor` says what was skipped
// and why, `uninstall` removes them.

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('fs')
const path = require('path')
const { execFile } = require('child_process')
const settings = require('../lib/settings')
const { tempDir, cleanup } = require('./helpers/cleanup')

const HOSTD = path.join(__dirname, '..', 'bin', 'conductore-hostd')
const root = tempDir('cnd-hooksver-')
const binDir = path.join(root, 'bin')
const home = path.join(root, 'home')
const file = path.join(root, 'settings.json')
fs.mkdirSync(binDir)
fs.mkdirSync(home)

const env = {
  ...process.env,
  PATH: `${binDir}:/usr/bin:/bin`,
  HOME: home,
  CONDUCTORE_HOME: path.join(root, 'state'),
  CONDUCTORE_SOCKET: path.join(root, 'state', 'hostd.sock'),
  CONDUCTORE_CLAUDE_SETTINGS: file,
  TMUX_TMPDIR: tempDir('cnd-hooksver-tmux-')
}
for (const k of Object.keys(env)) if (/^(HERDR_|TMUX$|TMUX_PANE)/.test(k)) delete env[k]
delete env.CLAUDECODE

function fakeClaude (version) {
  const bin = path.join(binDir, 'claude')
  if (version === null) { try { fs.unlinkSync(bin) } catch {} return }
  fs.writeFileSync(bin, `#!/bin/sh\necho "${version} (Claude Code)"\n`, { mode: 0o755 })
}

function cli (...args) {
  return new Promise((resolve, reject) => {
    execFile(process.execPath, [HOSTD, ...args], { env, timeout: 30000 }, (err, stdout) => {
      if (err && err.code === undefined) return reject(err)
      resolve({ code: err ? err.code : 0, json: JSON.parse(stdout.trim().split('\n').pop()) })
    })
  })
}

const hooks = () => JSON.parse(fs.readFileSync(file, 'utf8')).hooks || {}

test.after(async () => {
  await cli('stop').catch(() => {})
  await cleanup()
})

test('eventsFor: which newer events a Claude Code version gets', () => {
  assert.deepEqual(settings.eventsFor('2.1.280').events, [...settings.EVENTS, 'PostToolUseFailure', 'StopFailure'])
  assert.deepEqual(settings.eventsFor('2.1.119').skipped, [])
  const mid = settings.eventsFor('2.1.100')
  assert.deepEqual(mid.events, [...settings.EVENTS, 'StopFailure'])
  assert.deepEqual(mid.skipped, [{ event: 'PostToolUseFailure', reason: 'needs Claude Code 2.1.119, found 2.1.100' }])
  const old = settings.eventsFor('2.0.50')
  assert.deepEqual(old.events, settings.EVENTS)
  assert.equal(old.skipped.length, 2)
  for (const unknown of [null, '', 'garbage']) {
    assert.deepEqual(settings.eventsFor(unknown).events, settings.EVENTS)
    assert.ok(settings.eventsFor(unknown).skipped.every(s => s.reason === 'Claude Code version unknown'))
  }
  assert.ok(settings.atLeast('2.2.0', '2.1.119'))
  assert.ok(!settings.atLeast('2.1.99', '2.1.119'))
  assert.ok(settings.atLeast('3.0.0', '2.1.119'))
})

test('merge without an optional event takes ours off it and keeps others', () => {
  const HOOK = '/x/conductore-hook'
  const full = settings.merge({ hooks: { StopFailure: [{ hooks: [{ type: 'command', command: 'echo mine' }] }] } }, HOOK, settings.eventsFor('2.1.280').events)
  assert.equal(full.hooks.StopFailure.length, 2)
  assert.equal(full.hooks.PostToolUseFailure.length, 1)
  const base = settings.merge(full, HOOK)
  assert.deepEqual(base.hooks.StopFailure, [{ hooks: [{ type: 'command', command: 'echo mine' }] }])
  assert.equal(base.hooks.PostToolUseFailure, undefined)
  assert.deepEqual(settings.installed(base), settings.EVENTS)
})

test('an old Claude Code gets the base hooks only; doctor says why', async () => {
  fs.writeFileSync(file, '{}')
  fakeClaude('2.1.50')
  const i = await cli('install')
  assert.equal(i.code, 0)
  assert.equal(i.json.claudeVersion, '2.1.50')
  assert.deepEqual(i.json.events, settings.EVENTS)
  assert.deepEqual(i.json.skipped.map(s => s.event), ['PostToolUseFailure', 'StopFailure'])
  assert.equal(hooks().PostToolUseFailure, undefined)
  assert.equal(hooks().StopFailure, undefined)
  const d = await cli('doctor')
  const check = d.json.checks.find(c => c.name === 'optional hooks')
  assert.equal(check.ok, true)
  assert.match(check.detail, /none registered/)
  assert.match(check.detail, /PostToolUseFailure skipped \(needs Claude Code 2\.1\.119, found 2\.1\.50\)/)
  assert.match(check.detail, /Claude Code 2\.1\.50/)
  assert.equal(d.json.checks.find(c => c.name === 'hooks registered').ok, true)
})

test('a new Claude Code gets them; a downgrade takes them off; uninstall removes them', async () => {
  fs.writeFileSync(file, '{}')
  fakeClaude('2.1.280')
  const i = await cli('install')
  assert.deepEqual(i.json.skipped, [])
  assert.equal(i.json.events.length, 11)
  assert.equal(hooks().PostToolUseFailure.length, 1)
  assert.equal(hooks().StopFailure[0].hooks[0].async, true)
  const d = await cli('doctor')
  assert.match(d.json.checks.find(c => c.name === 'optional hooks').detail, /registered: PostToolUseFailure, StopFailure/)

  fakeClaude('2.1.90')
  const down = await cli('install')
  assert.deepEqual(down.json.events, [...settings.EVENTS, 'StopFailure'])
  assert.equal(hooks().PostToolUseFailure, undefined)
  assert.equal(hooks().StopFailure.length, 1)

  const u = await cli('uninstall')
  assert.ok(u.json.removed.includes('StopFailure'))
  assert.deepEqual(hooks(), {})
})

test('no claude found: nothing optional is registered', async () => {
  fs.writeFileSync(file, '{}')
  fakeClaude(null)
  const i = await cli('install')
  assert.equal(i.json.claudeVersion, null)
  assert.deepEqual(i.json.events, settings.EVENTS)
  assert.ok(i.json.skipped.every(s => s.reason === 'Claude Code version unknown'))
  await cli('uninstall')
})
