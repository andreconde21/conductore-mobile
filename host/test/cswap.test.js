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

// A fake cswap: prints [stdout] for `list`, [statusOut] for `status`,
// [switchOut] for `switch`, after [sleep] seconds; logs its arguments.
function fakeCswap (dir, { stdout = FIXTURE, statusOut = '', switchOut = '', sleep = 0 } = {}) {
  const bin = path.join(dir, 'cswap')
  fs.writeFileSync(path.join(dir, 'list.out'), stdout)
  fs.writeFileSync(path.join(dir, 'status.out'), statusOut)
  fs.writeFileSync(path.join(dir, 'switch.out'), switchOut)
  fs.writeFileSync(bin, `#!/bin/sh
echo "$*" >> "${dir}/calls"
${sleep ? `sleep ${sleep}` : ''}
case "$1" in
  list) cat "${dir}/list.out" ;;
  status) cat "${dir}/status.out" ;;
  switch) cat "${dir}/switch.out" ;;
esac
`, { mode: 0o755 })
  return bin
}

// André's setup on development-central (CON-057): two managed accounts,
// neither live, and the live login a third account cswap does not manage.
function noneActive (accounts = JSON.parse(FIXTURE).accounts.slice(0, 2)) {
  return JSON.stringify({ schemaVersion: 1, activeAccountNumber: null, accounts: accounts.map(a => ({ ...a, active: false })) })
}
const UNMANAGED = JSON.stringify({ schemaVersion: 1, active: { email: 'dave@example.com', managed: false } })

const calls = dir => { try { return fs.readFileSync(path.join(dir, 'calls'), 'utf8').trim().split('\n') } catch { return [] } }

test('parseList: slot, alias, label, active, disabled, limits and per-model windows', () => {
  const r = cswap.parseList(JSON.parse(FIXTURE), NOW)
  assert.equal(r.activeSlot, 1)
  assert.equal(r.accounts.length, 3)
  const [work, home, third] = r.accounts
  assert.deepEqual(work, {
    slot: 1,
    id: cswap.accountId('alice@example.com', JSON.parse(FIXTURE).accounts[0].organizationUuid),
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

test('accountId: the same account has the same id on every machine, whatever its slot or alias (CON-100)', () => {
  const id = cswap.accountId('Alice@Example.com ', 'org-1')
  assert.match(id, /^[0-9a-f]{16}$/)
  assert.equal(cswap.accountId('alice@example.com', 'ORG-1'), id)
  assert.notEqual(cswap.accountId('alice@example.com', 'org-2'), id)
  assert.notEqual(cswap.accountId('bob@example.com', 'org-1'), id)
  assert.equal(cswap.accountId('', 'org-1'), null)
  assert.equal(cswap.accountId(undefined), null)
  // Two machines: slots and aliases differ, ids do not.
  const laptop = cswap.parseList({ accounts: [
    { number: 1, email: 'bob@example.com', organizationUuid: 'org-b', alias: 'personal' },
    { number: 2, email: 'alice@example.com', organizationUuid: 'org-a' }
  ] }, NOW)
  const server = cswap.parseList({ accounts: [
    { number: 1, email: 'alice@example.com', organizationUuid: 'org-a', alias: 'work' },
    { number: 3, email: 'bob@example.com', organizationUuid: 'org-b' }
  ] }, NOW)
  assert.equal(laptop.accounts[1].id, server.accounts[0].id)
  assert.equal(laptop.accounts[0].id, server.accounts[1].id)
  assert.notEqual(laptop.accounts[0].id, laptop.accounts[1].id)
  // The unmanaged login gets the id it has where cswap manages it.
  const login = cswap.unmanagedRow({ active: { email: 'bob@example.com', organizationUuid: 'org-b', managed: false } })
  assert.equal(login.id, server.accounts[1].id)
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

test('accounts: an unmanaged live login is a third, active row without a slot', async () => {
  const dir = tmpDir()
  const bin = fakeCswap(dir, { stdout: noneActive(), statusOut: UNMANAGED })
  const r = await cswap.accounts({ bin, cacheFile: path.join(dir, 'c.json'), listMtime: 1 })
  assert.deepEqual(calls(dir), ['list --json', 'status --json'])
  assert.equal(r.accounts.length, 3)
  assert.deepEqual(r.accounts.map(a => [a.slot, a.label, a.active]), [[1, 'work', false], [2, 'home', false], [null, 'd***@e***.com', true]])
  assert.deepEqual(r.accounts[2], { slot: null, id: cswap.accountId('dave@example.com'), alias: null, label: 'd***@e***.com', active: true, disabled: false, managed: false, status: null, limits: {} })
  assert.ok(!JSON.stringify(r).includes('dave'))
  assert.ok(!fs.readFileSync(path.join(dir, 'c.json'), 'utf8').includes('dave'))
})

test('accounts: status is asked only when no managed account is live', async () => {
  const dir = tmpDir()
  const bin = fakeCswap(dir, { statusOut: UNMANAGED })
  const r = await cswap.accounts({ bin, cacheFile: path.join(dir, 'c.json'), listMtime: 1 })
  assert.deepEqual(calls(dir), ['list --json'])
  assert.equal(r.accounts.length, 3)
  // A managed live login (or no login, or a broken status) adds nothing.
  for (const statusOut of [JSON.stringify({ schemaVersion: 1, active: { number: 1, email: 'alice@example.com', managed: true } }), JSON.stringify({ schemaVersion: 1, active: null }), 'Traceback']) {
    const d = tmpDir()
    const b = fakeCswap(d, { stdout: noneActive(), statusOut })
    const x = await cswap.accounts({ bin: b, cacheFile: path.join(d, 'c.json'), listMtime: 1 })
    assert.deepEqual(x.accounts.map(a => a.slot), [1, 2], statusOut)
  }
})

test('accounts: an account added while the companion runs shows at once', async () => {
  const dir = tmpDir()
  const data = path.join(dir, 'data')
  fs.mkdirSync(path.join(data, 'claude-swap'), { recursive: true })
  const seq = path.join(data, 'claude-swap', 'sequence.json')
  fs.writeFileSync(seq, '{}')
  fs.utimesSync(seq, new Date(NOW - 60000), new Date(NOW - 60000))
  const env = { PATH: process.env.PATH, HOME: dir, XDG_DATA_HOME: data }
  assert.equal(cswap.sequenceFile(env), seq)
  const two = JSON.parse(FIXTURE).accounts.slice(0, 2)
  const bin = fakeCswap(dir, { stdout: JSON.stringify({ ...JSON.parse(FIXTURE), accounts: two }) })
  const cacheFile = path.join(dir, 'c.json')
  assert.equal((await cswap.accounts({ bin, env, cacheFile, now: NOW })).accounts.length, 2)
  // `cswap add` of a third: the list and sequence.json change.
  fakeCswap(dir)
  fs.utimesSync(seq, new Date(NOW), new Date(NOW))
  const r = await cswap.accounts({ bin, env, cacheFile, now: NOW + 1000 })
  assert.equal(r.accounts.length, 3)
  assert.equal(calls(dir).filter(c => c === 'list --json').length, 2)
  // Unchanged since: the cache answers.
  await cswap.accounts({ bin, env, cacheFile, now: NOW + 2000 })
  assert.equal(calls(dir).filter(c => c === 'list --json').length, 2)
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

test('CLI: usage lists the unmanaged live login as a third account', async () => {
  const dir = tmpDir()
  const home = path.join(dir, 'home')
  fs.mkdirSync(home)
  const bin = fakeCswap(dir, { stdout: noneActive(), statusOut: UNMANAGED })
  const env = { HOME: home, XDG_DATA_HOME: path.join(dir, 'xdg'), CONDUCTORE_HOME: path.join(dir, 'chome'), CLAUDE_CONFIG_DIR: '', CODEX_HOME: '', CONDUCTORE_CSWAP: bin }
  const r = await hostd(['usage', '--days', '1'], env)
  assert.equal(r.code, 0)
  assert.equal(r.json.claude.cswap.activeSlot, null)
  assert.deepEqual(r.json.claude.accounts.map(a => [a.slot, a.label, a.active]), [[1, 'work', false], [2, 'home', false], [null, 'd***@e***.com', true]])
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

// CON-067 (development-central, 2026-10-03): three managed accounts, two
// needing a new login, none live; the live login a fourth account. The
// sessions' statusline says which account they really run on.
const ANDRE = JSON.stringify({
  schemaVersion: 1,
  activeAccountNumber: null,
  accounts: [
    { number: 1, email: 'alice@example.com', alias: 'work', active: false, usageStatus: 'relogin_required', usage: null, lastGoodUsage: { fiveHour: { pct: 0 }, sevenDay: { pct: 100, resetsAt: '2026-10-03T21:59:59.962513+00:00' } }, lastGoodFetchedAt: '2026-10-02T14:51:45Z' },
    { number: 2, email: 'bob@example.org', alias: 'home', active: false, usageStatus: 'relogin_required', usage: null, lastGoodUsage: { fiveHour: { pct: 0 }, sevenDay: { pct: 100, resetsAt: '2026-10-04T20:59:59.965163+00:00' } }, lastGoodFetchedAt: '2026-10-02T21:16:42Z' },
    { number: 3, email: 'carol@example.net', active: false, usageStatus: 'ok', usage: { fiveHour: { pct: 0 }, sevenDay: { pct: 100, resetsAt: '2026-10-03T13:00:00.007850+00:00' }, scoped: [{ name: 'Fable', pct: 3, resetsAt: '2026-10-03T13:00:00.008027+00:00' }] }, usageFetchedAt: '2026-10-03T11:18:42Z' }
  ]
})
const AT = Date.parse('2026-10-03T11:22:00Z')
const LIVE = [
  { label: '5h', usedPct: 14, resetsAt: Date.parse('2026-10-03T16:20:00Z'), expired: false, at: AT - 60000 },
  { label: '7d', usedPct: 52, resetsAt: Date.parse('2026-10-05T07:00:00Z'), expired: false, at: AT - 60000 }
]
const andreRows = async (now = AT) => {
  const dir = tmpDir()
  const bin = fakeCswap(dir, { stdout: ANDRE, statusOut: UNMANAGED })
  return (await cswap.accounts({ bin, cacheFile: path.join(dir, 'c.json'), listMtime: 1, now })).accounts
}

test('withLiveLimits: the unmanaged login is "not in cswap" only when the sessions\' limits match no managed account', async () => {
  const rows = cswap.withLiveLimits(await andreRows(), LIVE, AT)
  const login = rows.find(r => r.slot == null)
  assert.equal(login.inCswap, false)
  assert.equal(login.live, true)
  assert.equal(login.source, 'statusline')
  assert.equal(login.usageAt, AT - 60000)
  assert.deepEqual(login.limits, { '5h': { usedPct: 14, resetsAt: LIVE[0].resetsAt, expired: false }, '7d': { usedPct: 52, resetsAt: LIVE[1].resetsAt, expired: false } })
  assert.ok(rows.filter(r => r.slot != null).every(r => !r.live))
  // No session reported limits: cswap's word only (from ~/.claude.json,
  // which may lag): the current login, nothing claimed.
  const unknown = cswap.withLiveLimits(await andreRows(), [], AT).find(r => r.slot == null)
  assert.equal(unknown.inCswap, null)
  assert.deepEqual(unknown.limits, {})
})

test('withLiveLimits: limits matching a managed account make it the live one, with the newer numbers', async () => {
  const onCarol = [
    { label: '5h', usedPct: 30, resetsAt: Date.parse('2026-10-03T15:00:00Z'), expired: false, at: AT - 1000 },
    { label: '7d', usedPct: 100, resetsAt: Date.parse('2026-10-03T13:00:00Z'), expired: false, at: AT - 1000 }
  ]
  const rows = cswap.withLiveLimits(await andreRows(), onCarol, AT)
  const carol = rows.find(r => r.slot === 3)
  assert.equal(carol.live, true)
  assert.equal(carol.usageAt, AT - 1000)
  assert.equal(carol.limits['5h'].usedPct, 30)
  // cswap says the login is someone else: unsure, so nothing is claimed.
  assert.equal(rows.find(r => r.slot == null).inCswap, null)
  // Two managed accounts on the same weekly reset: no guess.
  const twins = JSON.parse(ANDRE)
  twins.accounts[1].lastGoodUsage.sevenDay.resetsAt = twins.accounts[2].usage.sevenDay.resetsAt
  const dir = tmpDir()
  const bin = fakeCswap(dir, { stdout: JSON.stringify(twins), statusOut: UNMANAGED })
  const both = (await cswap.accounts({ bin, cacheFile: path.join(dir, 'c.json'), listMtime: 1, now: AT })).accounts
  const r2 = cswap.withLiveLimits(both, onCarol, AT)
  assert.ok(r2.every(r => !r.live))
  assert.equal(r2.find(r => r.slot == null).inCswap, null)
})

test('accounts: relogin_required is needsLogin; windows that reset since are expired at 0 %, also from the cache', async () => {
  const dir = tmpDir()
  const cacheFile = path.join(dir, 'c.json')
  const bin = fakeCswap(dir, { stdout: ANDRE, statusOut: UNMANAGED })
  const first = await cswap.accounts({ bin, cacheFile, listMtime: 1, now: Date.parse('2026-10-03T12:59:50Z') })
  assert.deepEqual(first.accounts.map(a => [a.slot, !!a.needsLogin, !!a.stale]), [[1, true, true], [2, true, true], [3, false, false], [null, false, false]])
  assert.equal(first.accounts[2].limits['7d'].usedPct, 100)
  // 13:00 passed; the 60 s cache still answers, but not with 100 %.
  const after = await cswap.accounts({ bin, cacheFile, listMtime: 1, now: Date.parse('2026-10-03T13:00:30Z') })
  assert.equal(calls(dir).filter(c => c === 'list --json').length, 1)
  assert.deepEqual(after.accounts[2].limits['7d'], { usedPct: 0, resetsAt: Date.parse('2026-10-03T13:00:00.007Z'), expired: true })
  assert.equal(after.accounts[2].perModel[0].usedPct, 0)
  // withLiveLimits settles them again too.
  const settled = cswap.withLiveLimits(first.accounts, [], Date.parse('2026-10-03T13:00:30Z'))
  assert.equal(settled[2].limits['7d'].expired, true)
})

test('CLI: usage --fresh asks cswap again; sessions\' limits confirm the unmanaged login', async () => {
  const dir = tmpDir()
  const home = path.join(dir, 'home')
  const chome = path.join(dir, 'chome')
  fs.mkdirSync(home)
  fs.mkdirSync(chome)
  const now = Date.now()
  const week = now + 40 * 3600 * 1000
  // No daemon: `usage` reads the agents from the last snapshot.
  fs.writeFileSync(path.join(chome, 'state.json'), JSON.stringify({ seq: 1, agents: [{ sessionId: 's1', state: 'working', cwd: home, updatedAt: now, pending: [], usage: { at: now, limits: [{ label: '7d', usedPct: 52, resetsAt: week }] } }] }))
  const bin = fakeCswap(dir, { stdout: noneActive(), statusOut: UNMANAGED })
  const env = { HOME: home, XDG_DATA_HOME: path.join(dir, 'xdg'), CONDUCTORE_HOME: chome, CLAUDE_CONFIG_DIR: '', CODEX_HOME: '', CONDUCTORE_CSWAP: bin }
  const r = await hostd(['usage', '--days', '1'], env)
  assert.equal(r.code, 0)
  const login = r.json.claude.accounts.find(a => a.slot == null)
  assert.equal(login.inCswap, false)
  assert.equal(login.limits['7d'].usedPct, 52)
  assert.equal(r.json.claude.limits[0].at, now)
  await hostd(['usage', '--days', '1'], env)
  assert.equal(calls(dir).filter(c => c === 'list --json').length, 1, 'cached for 60 s')
  await hostd(['usage', '--days', '1', '--fresh'], env)
  assert.equal(calls(dir).filter(c => c === 'list --json').length, 2, '--fresh asks again')
})

test.after(() => cleanup())
