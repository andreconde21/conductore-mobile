'use strict'

// cswap accounts for `usage`: parsing `cswap list --json` (a fixture with
// the real schema-v1 shape, fake accounts), email masking, absence, the
// timeout, the 60 s cache and its stale fallback, `cswap-switch`, and the
// CLI end to end with a fake cswap.

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('fs')
const path = require('path')
const { tempDir, cleanup } = require('./helpers/cleanup')
const { execFile } = require('child_process')
const cswap = require('../lib/cswap')

const HOSTD = path.join(__dirname, '..', 'bin', 'conductore-hostd')
const FIXTURE = fs.readFileSync(path.join(__dirname, 'fixtures', 'cswap-list.json'), 'utf8')
const NOW = Date.parse('2026-09-27T08:20:00Z')

function tmpDir () {
  return tempDir('conductore-cswap-')
}

// A fake cswap: prints [stdout] for `list`, [switchOut] for `switch`,
// after [sleep] seconds; logs its arguments.
function fakeCswap (dir, { stdout = FIXTURE, switchOut = '', sleep = 0 } = {}) {
  const bin = path.join(dir, 'cswap')
  fs.writeFileSync(path.join(dir, 'list.out'), stdout)
  fs.writeFileSync(path.join(dir, 'switch.out'), switchOut)
  fs.writeFileSync(bin, `#!/bin/sh
echo "$*" >> "${dir}/calls"
${sleep ? `sleep ${sleep}` : ''}
case "$1" in
  list) cat "${dir}/list.out" ;;
  switch) cat "${dir}/switch.out" ;;
esac
`, { mode: 0o755 })
  return bin
}

const calls = dir => { try { return fs.readFileSync(path.join(dir, 'calls'), 'utf8').trim().split('\n') } catch { return [] } }

test('parseList: slot, alias, label, active, disabled, limits and per-model windows', () => {
  const r = cswap.parseList(JSON.parse(FIXTURE), NOW)
  assert.equal(r.activeSlot, 1)
  assert.equal(r.accounts.length, 3)
  const [work, home, third] = r.accounts
  assert.deepEqual(work, {
    slot: 1,
    alias: 'work',
    label: 'work',
    active: true,
    disabled: false,
    status: 'ok',
    limits: {
      '5h': { usedPct: 17, resetsAt: Date.parse('2026-09-27T12:59:59.667Z'), expired: false },
      '7d': { usedPct: 5, resetsAt: Date.parse('2026-10-03T21:59:59.667Z'), expired: false }
    },
    usageAt: Date.parse('2026-09-27T08:19:56Z'),
    perModel: [{ model: 'Fable', usedPct: 7, resetsAt: Date.parse('2026-10-03T21:59:59.667Z'), expired: false }]
  })
  // No fresh usage: the last good one, marked stale.
  assert.equal(home.stale, true)
  assert.equal(home.active, false)
  assert.deepEqual(home.limits['5h'], { usedPct: 0, resetsAt: null, expired: false })
  assert.equal(home.limits['7d'].usedPct, 98)
  assert.equal(home.usageAt, Date.parse('2026-09-26T21:11:53Z'))
  // No alias: a masked email; no usage at all: no windows.
  assert.equal(third.alias, null)
  assert.equal(third.label, 'c***@m***.net')
  assert.equal(third.disabled, true)
  assert.equal(third.status, 'token_expired')
  assert.deepEqual(third.limits, {})
  assert.equal(third.stale, undefined)
})

test('parseList never carries an email, organisation or uuid', () => {
  const text = JSON.stringify(cswap.parseList(JSON.parse(FIXTURE), NOW))
  for (const secret of ['alice', 'bob', 'carol', 'example', 'Organization', '00000000']) {
    assert.ok(!text.includes(secret), `leaked ${secret}`)
  }
})

test('parseList marks windows that already reset, and rejects other JSON', () => {
  const later = Date.parse('2026-09-27T21:00:00Z')
  const home = cswap.parseList(JSON.parse(FIXTURE), later).accounts[1]
  assert.equal(home.limits['7d'].expired, true)
  assert.equal(cswap.parseList({ schemaVersion: 1, error: { type: 'X', message: 'no' } }), null)
  assert.equal(cswap.parseList(null), null)
  assert.deepEqual(cswap.parseList({ accounts: [{ number: 'x' }, null] }), { activeSlot: null, accounts: [] })
})

test('maskEmail keeps the first letters and the top-level domain', () => {
  assert.equal(cswap.maskEmail('andre@outsmartis.com'), 'a***@o***.com')
  assert.equal(cswap.maskEmail('x@y'), 'x***@y***')
  assert.equal(cswap.maskEmail('noatsign'), 'n***')
  assert.equal(cswap.maskEmail(''), null)
  assert.equal(cswap.maskEmail(undefined), null)
  assert.equal(cswap.maskEmails('Switched to Account-2 (bob@example.org) ok'), 'Switched to Account-2 (b***@e***.org) ok')
})

test('an alias that is an email is masked too', () => {
  const r = cswap.parseList({ accounts: [{ number: 1, email: 'a@b.com', alias: 'me@corp.io', usage: null }] }, NOW)
  assert.equal(r.accounts[0].label, 'm***@c***.io')
})

test('findCswap: PATH first, then ~/.local/bin, CONDUCTORE_CSWAP overrides', () => {
  const dir = tmpDir()
  const onPath = path.join(dir, 'path')
  const home = path.join(dir, 'home')
  const local = path.join(home, '.local', 'bin')
  fs.mkdirSync(onPath)
  fs.mkdirSync(local, { recursive: true })
  assert.equal(cswap.findCswap({ PATH: onPath, HOME: home }), null)
  const localBin = fakeCswap(local)
  assert.equal(cswap.findCswap({ PATH: onPath, HOME: home }), localBin)
  const pathBin = fakeCswap(onPath)
  assert.equal(cswap.findCswap({ PATH: onPath, HOME: home }), pathBin)
  assert.equal(cswap.findCswap({ PATH: onPath, HOME: home, CONDUCTORE_CSWAP: '' }), null)
  assert.equal(cswap.findCswap({ PATH: '', HOME: dir, CONDUCTORE_CSWAP: localBin }), localBin)
  // Not executable: not cswap.
  fs.chmodSync(pathBin, 0o644)
  assert.equal(cswap.findCswap({ PATH: onPath, HOME: home }), localBin)
})

test('accounts: null without cswap', async () => {
  assert.equal(await cswap.accounts({ bin: null }), null)
  const dir = tmpDir()
  assert.equal(await cswap.accounts({ env: { PATH: dir, HOME: dir } }), null)
})

test('accounts: cached for the TTL, asked again after it', async () => {
  const dir = tmpDir()
  const cacheFile = path.join(dir, 'cswap-cache.json')
  let runs = 0
  const runner = async () => { runs++; return { code: 0, stdout: FIXTURE } }
  const first = await cswap.accounts({ bin: '/x/cswap', cacheFile, now: NOW, runner })
  assert.equal(first.present, true)
  assert.equal(first.activeSlot, 1)
  assert.equal(first.accounts.length, 3)
  assert.equal(first.fetchedAt, NOW)
  const again = await cswap.accounts({ bin: '/x/cswap', cacheFile, now: NOW + 30000, runner })
  assert.equal(runs, 1)
  assert.deepEqual(again.accounts, first.accounts)
  assert.equal(again.fetchedAt, NOW)
  await cswap.accounts({ bin: '/x/cswap', cacheFile, now: NOW + cswap.TTL_MS + 1, runner })
  assert.equal(runs, 2)
  // The cache holds only masked rows.
  const cached = fs.readFileSync(cacheFile, 'utf8')
  assert.ok(!cached.includes('@example'))
  assert.ok(!cached.includes('alice'))
  assert.equal(fs.statSync(cacheFile).mode & 0o777, 0o600)
})

test('accounts: a failure is cached too and falls back to the last good answer', async () => {
  const dir = tmpDir()
  const cacheFile = path.join(dir, 'cswap-cache.json')
  let ok = true
  let runs = 0
  const runner = async () => { runs++; return ok ? { code: 0, stdout: FIXTURE } : { code: 1, stdout: 'Traceback' } }
  await cswap.accounts({ bin: '/x/cswap', cacheFile, now: NOW, runner })
  ok = false
  const t1 = NOW + cswap.TTL_MS + 1
  const stale = await cswap.accounts({ bin: '/x/cswap', cacheFile, now: t1, runner })
  assert.equal(stale.stale, true)
  assert.equal(stale.error, 'unavailable')
  assert.equal(stale.fetchedAt, NOW)
  assert.equal(stale.accounts.length, 3)
  // The failure is not retried within the TTL.
  const again = await cswap.accounts({ bin: '/x/cswap', cacheFile, now: t1 + 1000, runner })
  assert.equal(runs, 2)
  assert.equal(again.stale, true)
  // Too old to show: nothing, but cswap is still reported.
  const late = await cswap.accounts({ bin: '/x/cswap', cacheFile, now: NOW + cswap.STALE_MAX_MS + 1, runner })
  assert.deepEqual(late, { present: true, activeSlot: null, accounts: [], fetchedAt: null, error: 'unavailable' })
})

test('accounts: a hung cswap is killed at the timeout', async () => {
  const dir = tmpDir()
  const bin = fakeCswap(dir, { sleep: 30 })
  const started = Date.now()
  const r = await cswap.accounts({ bin, cacheFile: path.join(dir, 'c.json'), timeoutMs: 300 })
  assert.ok(Date.now() - started < 3000)
  assert.equal(r.error, 'timeout')
  assert.deepEqual(r.accounts, [])
})

test('accounts: runs the real list command of a fake cswap', async () => {
  const dir = tmpDir()
  const bin = fakeCswap(dir)
  const r = await cswap.accounts({ bin, cacheFile: path.join(dir, 'c.json') })
  assert.deepEqual(calls(dir), ['list --json'])
  assert.deepEqual(r.accounts.map(a => a.label), ['work', 'home', 'c***@m***.net'])
})

test('switchAccount: a slot or the best strategy, masked refs, cache dropped', async () => {
  const dir = tmpDir()
  const cacheFile = path.join(dir, 'c.json')
  const bin = fakeCswap(dir, {
    switchOut: JSON.stringify({ schemaVersion: 1, switched: true, from: { number: 1, email: 'alice@example.com' }, to: { number: 3, email: 'carol.smith@mail.example.net' }, strategy: 'explicit', reason: 'switched', message: 'Switched to Account-3 (carol.smith@mail.example.net)', warnings: [] })
  })
  await cswap.accounts({ bin, cacheFile })
  const r = await cswap.switchAccount({ bin, slot: 3, cacheFile })
  assert.deepEqual(r, { ok: true, switched: true, reason: 'switched', strategy: 'explicit', from: { slot: 1, label: 'work' }, to: { slot: 3, label: 'c***@m***.net' } })
  assert.ok(!JSON.stringify(r).includes('example'))
  await cswap.switchAccount({ bin, best: true, cacheFile })
  const argv = calls(dir)
  assert.ok(argv.includes('switch 3 --json'))
  assert.ok(argv.includes('switch --strategy best --json'))
  // The list is asked again after each switch.
  assert.equal(argv.filter(a => a === 'list --json').length, 3)
})

test('switchAccount: errors are masked; no cswap is an error', async () => {
  const dir = tmpDir()
  const bin = fakeCswap(dir, { switchOut: JSON.stringify({ schemaVersion: 1, error: { type: 'AccountNotFound', message: 'No account bob@example.org' } }) })
  const r = await cswap.switchAccount({ bin, slot: 9 })
  assert.deepEqual(r, { ok: false, error: 'failed', message: 'No account b***@e***.org' })
  assert.equal((await cswap.switchAccount({ bin: null, slot: 1 })).error, 'cswap-missing')
})

function hostd (args, env) {
  return new Promise(resolve => {
    execFile(process.execPath, [HOSTD, ...args], { env: { ...process.env, ...env } }, (err, stdout) =>
      resolve({ code: err ? err.code : 0, json: JSON.parse(stdout) }))
  })
}

test('CLI: usage carries claude.accounts and claude.cswap with a cswap', async () => {
  const dir = tmpDir()
  const home = path.join(dir, 'home')
  fs.mkdirSync(home)
  const bin = fakeCswap(dir)
  const env = { HOME: home, CONDUCTORE_HOME: path.join(dir, 'chome'), CLAUDE_CONFIG_DIR: '', CODEX_HOME: '', CONDUCTORE_CSWAP: bin }
  const r = await hostd(['usage', '--days', '1'], env)
  assert.equal(r.code, 0)
  assert.equal(r.json.claude.cswap.present, true)
  assert.equal(r.json.claude.cswap.activeSlot, 1)
  assert.deepEqual(r.json.claude.accounts.map(a => a.slot), [1, 2, 3])
  assert.ok(fs.existsSync(path.join(dir, 'chome', 'cswap-cache.json')))
  assert.ok(!JSON.stringify(r.json).includes('@example'))
})

test('CLI: cswap-switch validates its arguments and reports the switch', async () => {
  const dir = tmpDir()
  const bin = fakeCswap(dir, { switchOut: JSON.stringify({ schemaVersion: 1, switched: false, from: { number: 1, email: 'alice@example.com' }, to: { number: 1, email: 'alice@example.com' }, strategy: 'best', reason: 'already-active', message: 'x', warnings: [] }) })
  const env = { CONDUCTORE_HOME: path.join(dir, 'chome'), CONDUCTORE_CSWAP: bin }
  for (const bad of [[], ['x'], ['1', '--best'], ['0'], ['1;rm']]) {
    const r = await hostd(['cswap-switch', ...bad], env)
    assert.equal(r.code, 1, bad.join(' '))
    assert.match(r.json.error, /usage: cswap-switch/)
  }
  const ok = await hostd(['cswap-switch', '--best'], env)
  assert.equal(ok.code, 0)
  assert.equal(ok.json.switched, false)
  assert.deepEqual(ok.json.to, { slot: 1, label: 'work' })
  const missing = await hostd(['cswap-switch', '2'], { ...env, CONDUCTORE_CSWAP: '' })
  assert.equal(missing.code, 1)
  assert.match(missing.json.error, /not installed/)
})

test.after(() => cleanup())
