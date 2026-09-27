'use strict'

// `usage`: Claude transcript and Codex session scanning on synthetic
// fixtures (dedupe of streamed blocks and resumed copies, incremental
// offsets, the per-call cap, Codex running totals and rate limits),
// limits, project names, prices, and the CLI end to end.

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('fs')
const path = require('path')
const { tempDir, cleanup } = require('./helpers/cleanup')
const { execFile } = require('child_process')
const usage = require('../lib/usage')
const pricing = require('../lib/pricing')

const HOSTD = path.join(__dirname, '..', 'bin', 'conductore-hostd')
const HOUR = 3600 * 1000
// Noon today, local time: entries a few hours around it stay on "today".
const NOW = (() => { const d = new Date(); d.setHours(12, 0, 0, 0); return d.getTime() })()
const TODAY = usage.localDate(NOW)
const YESTERDAY = usage.addDays(TODAY, -1)

function tmpHome () {
  const root = tempDir('conductore-usage-')
  const home = path.join(root, 'home')
  fs.mkdirSync(path.join(home, '.claude', 'projects'), { recursive: true })
  return { root, home, cacheFile: path.join(root, 'usage-cache.json') }
}

function assistant ({ id, req = 'req_1', model = 'claude-opus-5', at = NOW, cwd = '/work/api', input = 10, output = 100, cacheWrite = 0, cache1h = 0, cacheRead = 0, speed }) {
  const u = { input_tokens: input, output_tokens: output, cache_creation_input_tokens: cacheWrite, cache_read_input_tokens: cacheRead }
  if (cache1h) u.cache_creation = { ephemeral_5m_input_tokens: cacheWrite - cache1h, ephemeral_1h_input_tokens: cache1h }
  if (speed) u.speed = speed
  return JSON.stringify({
    type: 'assistant',
    cwd,
    sessionId: 's1',
    requestId: req,
    timestamp: new Date(at).toISOString(),
    uuid: `u-${id}-${output}`,
    message: { id, model, role: 'assistant', content: [{ type: 'text', text: 'synthetic' }], usage: u }
  })
}

const userLine = text => JSON.stringify({ type: 'user', timestamp: new Date(NOW).toISOString(), message: { role: 'user', content: text } })

function writeTranscript (home, rel, lines) {
  const file = path.join(home, '.claude', 'projects', rel)
  fs.mkdirSync(path.dirname(file), { recursive: true })
  fs.writeFileSync(file, lines.map(l => l + '\n').join(''))
  return file
}

const run = (t, opts = {}) => usage.compute({ env: { HOME: t.home }, now: NOW, cacheFile: t.cacheFile, machine: 'box', ...opts })

test('counts each message once: streamed blocks take the largest output, resumed copies are skipped', () => {
  const t = tmpHome()
  writeTranscript(t.home, '-work-api/a.jsonl', [
    userLine('hi'),
    assistant({ id: 'msg_1', output: 5, input: 10, cacheWrite: 1000, cache1h: 400, cacheRead: 2000 }),
    assistant({ id: 'msg_1', output: 120, input: 10, cacheWrite: 1000, cache1h: 400, cacheRead: 2000 }),
    assistant({ id: 'msg_2', req: 'req_2', output: 50, input: 1, at: NOW - 24 * HOUR }),
    assistant({ id: 'msg_s', model: '<synthetic>', output: 0 }),
    assistant({ id: 'msg_old', output: 999, at: NOW - 40 * 24 * HOUR })
  ])
  // A resumed session copies msg_1 into a new file.
  writeTranscript(t.home, '-work-api/b.jsonl', [
    assistant({ id: 'msg_1', output: 120, input: 10, cacheWrite: 1000, cache1h: 400, cacheRead: 2000 }),
    assistant({ id: 'msg_3', req: 'req_3', model: 'claude-haiku-4-5-20251001', output: 7, input: 3, speed: 'fast' })
  ])
  const r = run(t)
  assert.equal(r.schema, 1)
  assert.equal(r.machine, 'box')
  assert.equal(r.today, TODAY)
  assert.equal(r.claude.present, true)
  assert.equal(r.codex.present, false)
  assert.equal(r.claude.today.messages, 2)
  assert.equal(r.claude.range.messages, 3)
  assert.equal(r.claude.today.output, 127)
  assert.equal(r.claude.today.input, 13)
  assert.equal(r.claude.today.cacheWrite, 1000)
  assert.equal(r.claude.today.cacheRead, 2000)
  const opus = r.claude.rows.find(x => x.date === TODAY && x.model === 'claude-opus-5')
  assert.equal(opus.project, 'api')
  // 10 in, 120 out, 600 5m-writes, 400 1h-writes, 2000 reads at $5/$25.
  const expected = (10 * 5 + 120 * 25 + 600 * 6.25 + 400 * 10 + 2000 * 0.5) / 1e6
  assert.ok(Math.abs(opus.costUsd - expected) < 1e-4)
  assert.ok(r.claude.rows.some(x => x.date === YESTERDAY && x.output === 50))
  // Haiku has no fast mode price: 1x.
  const haiku = r.claude.rows.find(x => x.model.startsWith('claude-haiku'))
  assert.equal(haiku.speed, 'fast')
  assert.ok(Math.abs(haiku.costUsd - (3 * 1 + 7 * 5) / 1e6) < 1e-6)
  assert.deepEqual(r.pricing.unpriced, [])
  assert.equal(r.pricing.estimate, true)
  assert.equal(r.scan.partial, false)
})

test('incremental: only appended bytes are read, a block streamed after a scan adds its delta', () => {
  const t = tmpHome()
  const file = writeTranscript(t.home, '-work-api/a.jsonl', [assistant({ id: 'msg_1', output: 5 })])
  const first = run(t)
  assert.equal(first.claude.today.output, 5)
  const size = fs.statSync(file).size
  const again = run(t)
  assert.equal(again.scan.filesRead, 0)
  assert.equal(again.scan.bytesRead, 0)
  fs.appendFileSync(file, assistant({ id: 'msg_1', output: 80 }) + '\n' + assistant({ id: 'msg_2', req: 'r2', output: 1 }) + '\n' + '{"type":"assistant","partial')
  const third = run(t)
  assert.equal(third.scan.filesRead, 1)
  assert.equal(third.scan.bytesRead, fs.statSync(file).size - size)
  assert.equal(third.claude.today.output, 81)
  assert.equal(third.claude.today.messages, 2)
  // The half-written line is read once it is complete.
  fs.appendFileSync(file, '", "x": 1}\n' + assistant({ id: 'msg_3', req: 'r3', output: 2 }) + '\n')
  assert.equal(run(t).claude.today.output, 83)
  // Truncated and rewritten: read again from the start, nothing counted twice.
  fs.writeFileSync(file, assistant({ id: 'msg_1', output: 80 }) + '\n')
  assert.equal(run(t).claude.today.output, 83)
})

test('the per-call cap leaves a partial scan that later calls finish', () => {
  const t = tmpHome()
  const lines = []
  for (let i = 0; i < 400; i++) lines.push(assistant({ id: `msg_${i}`, req: `r${i}`, output: 1 }))
  writeTranscript(t.home, '-work-api/a.jsonl', lines.slice(0, 200))
  writeTranscript(t.home, '-work-web/b.jsonl', lines.slice(200))
  const fileBytes = fs.statSync(path.join(t.home, '.claude', 'projects', '-work-api', 'a.jsonl')).size
  let r = run(t, { maxBytes: Math.floor(fileBytes / 3) })
  assert.equal(r.scan.partial, true)
  assert.ok(r.claude.today.messages < 400)
  let calls = 1
  while (r.scan.partial && calls < 50) { r = run(t, { maxBytes: Math.floor(fileBytes / 3) }); calls++ }
  assert.equal(r.scan.partial, false)
  assert.equal(r.claude.today.messages, 400)
  assert.equal(r.claude.today.output, 400)
})

test('a second concurrent call answers from the cache without scanning', () => {
  const t = tmpHome()
  writeTranscript(t.home, '-work-api/a.jsonl', [assistant({ id: 'msg_1', output: 5 })])
  run(t)
  fs.writeFileSync(`${t.cacheFile}.lock`, '1')
  writeTranscript(t.home, '-work-api/c.jsonl', [assistant({ id: 'msg_9', output: 9 })])
  const r = run(t)
  assert.equal(r.scan.busy, true)
  assert.equal(r.claude.today.output, 5)
  fs.unlinkSync(`${t.cacheFile}.lock`)
  assert.equal(run(t).claude.today.output, 14)
})

function codexLine (type, payload, at = NOW) {
  return JSON.stringify({ timestamp: new Date(at).toISOString(), type, payload })
}

test('Codex: running totals become per-day deltas, the newest rate limits win', () => {
  const t = tmpHome()
  const dir = path.join(t.home, '.codex', 'sessions', '2026', '09', '25')
  fs.mkdirSync(dir, { recursive: true })
  const reset = Math.round((NOW + 2 * HOUR) / 1000)
  fs.writeFileSync(path.join(dir, 'rollout-a.jsonl'), [
    codexLine('session_meta', { id: 'c1', cwd: '/work/cli' }),
    codexLine('turn_context', { cwd: '/work/cli', model: 'gpt-5-codex' }),
    codexLine('event_msg', { type: 'token_count', info: null, rate_limits: null }),
    codexLine('event_msg', {
      type: 'token_count',
      info: { total_token_usage: { input_tokens: 1000, cached_input_tokens: 400, output_tokens: 50, total_tokens: 1050 } },
      rate_limits: { primary: { used_percent: 30, window_minutes: 300, resets_at: reset }, secondary: { used_percent: 10, window_minutes: 10080, resets_in_seconds: 3600 } }
    }, NOW - HOUR),
    codexLine('event_msg', {
      type: 'token_count',
      info: { total_token_usage: { input_tokens: 3000, cached_input_tokens: 1400, output_tokens: 150, total_tokens: 3150 } },
      rate_limits: { primary: { used_percent: 42, window_minutes: 300, resets_at: reset } }
    }),
    '{"not json'
  ].join('\n') + '\n')
  const r = run(t)
  assert.equal(r.codex.present, true)
  assert.equal(r.codex.today.input, 1600)
  assert.equal(r.codex.today.cacheRead, 1400)
  assert.equal(r.codex.today.output, 150)
  assert.equal(r.codex.today.messages, 2)
  const row = r.codex.rows[0]
  assert.equal(row.project, 'cli')
  assert.equal(row.model, 'gpt-5-codex')
  assert.ok(Math.abs(row.costUsd - (1600 * 1.25 + 1400 * 0.125 + 150 * 10) / 1e6) < 1e-6)
  assert.deepEqual(r.codex.limits.map(l => [l.label, l.usedPct]), [['5h', 42]])
  assert.equal(r.codex.limits[0].resetsAt, reset * 1000)
})

test('Claude limits: the later window wins, then the higher use; past windows are marked expired', () => {
  const now = NOW
  const merged = usage.mergeLimits([
    [{ label: '5h', usedPct: 80, resetsAt: now - HOUR }, { label: '7d', usedPct: 20, resetsAt: now + 50 * HOUR }],
    [{ label: '5h', usedPct: 12, resetsAt: now + 3 * HOUR }, { label: '7d', usedPct: 22, resetsAt: now + 50 * HOUR + 1000 }]
  ])
  assert.deepEqual(merged.map(l => [l.label, l.usedPct]), [['5h', 12], ['7d', 22]])

  const t = tmpHome()
  const agents = [
    { sessionId: 'a', name: 'api', cwd: '/work/api', state: 'working', usage: { contextUsedPct: 41, contextTokens: 82000, windowLabel: '200k', limits: [{ label: '5h', usedPct: 55, resetsAt: now + HOUR }] } },
    { sessionId: 'b', state: 'ended', usage: { contextUsedPct: 90 } }
  ]
  const r = run(t, { agents })
  assert.deepEqual(r.claude.limits, [{ label: '5h', usedPct: 55, resetsAt: now + HOUR, expired: false }])
  assert.deepEqual(r.claude.sessions, [{ sessionId: 'a', name: 'api', project: 'api', state: 'working', contextUsedPct: 41, contextTokens: 82000, windowLabel: '200k' }])
  // Remembered after the session is gone; expired once the window passed.
  const later = run(t, { agents: [], now: now + 2 * HOUR })
  assert.equal(later.claude.limits[0].usedPct, 55)
  assert.equal(later.claude.limits[0].expired, true)
})

test('project names: repository root, linked worktree, home', () => {
  const root = tempDir('conductore-proj-')
  const repo = path.join(root, 'myrepo')
  fs.mkdirSync(path.join(repo, '.git', 'worktrees', 'wt'), { recursive: true })
  fs.mkdirSync(path.join(repo, 'src', 'deep'), { recursive: true })
  const wt = path.join(root, 'wt-feature')
  fs.mkdirSync(path.join(wt, 'lib'), { recursive: true })
  fs.writeFileSync(path.join(wt, '.git'), `gitdir: ${path.join(repo, '.git', 'worktrees', 'wt')}\n`)
  assert.equal(usage.resolveProject(path.join(repo, 'src', 'deep'), '/nohome'), 'myrepo')
  assert.equal(usage.resolveProject(path.join(wt, 'lib'), '/nohome'), 'myrepo')
  assert.equal(usage.resolveProject(root, root), '~')
  assert.equal(usage.resolveProject('/gone/away/proj', '/nohome'), 'proj')
})

test('prices: dated ids match, unknown models cost null and are listed', () => {
  assert.equal(pricing.priceFor('claude', 'claude-haiku-4-5-20251001').input, 1)
  assert.equal(pricing.priceFor('claude', 'claude-opus-4-8').input, 5)
  assert.equal(pricing.priceFor('claude', 'claude-opus-4-20250514').input, 15)
  assert.equal(pricing.priceFor('claude', 'claude-opus-5-5').cacheRead, 0.2)
  assert.equal(pricing.priceFor('claude', 'claude-unknown-9'), null)
  assert.equal(pricing.costUsd('claude', 'claude-opus-5', { output: 1e6 }, 'fast'), 50)
  assert.match(pricing.AS_OF, /^\d{4}-\d{2}-\d{2}$/)
  const t = tmpHome()
  writeTranscript(t.home, '-work-api/a.jsonl', [assistant({ id: 'm', model: 'claude-future-1' })])
  const r = run(t)
  assert.deepEqual(r.pricing.unpriced, ['claude-future-1'])
  assert.equal(r.claude.today.costUsd, null)
  assert.equal(r.claude.today.tokens, 110)
})

test('--days and --since pick the range; nothing installed reports absent', () => {
  const t = tmpHome()
  writeTranscript(t.home, '-work-api/a.jsonl', [
    assistant({ id: 'a', output: 1, at: NOW }),
    assistant({ id: 'b', output: 10, at: NOW - 3 * 24 * HOUR })
  ])
  assert.equal(run(t, { days: 1 }).claude.range.output, 1)
  assert.equal(run(t, { days: 7 }).claude.range.output, 11)
  assert.equal(run(t, { since: NOW - 2 * 24 * HOUR }).claude.range.output, 1)
  const empty = tempDir('conductore-empty-')
  const r = usage.compute({ env: { HOME: empty }, now: NOW, cacheFile: path.join(empty, 'c.json') })
  assert.equal(r.claude.present, false)
  assert.equal(r.codex.present, false)
  assert.deepEqual(r.claude.rows, [])
})

test('CLI: conductore-hostd usage prints the report', async () => {
  const t = tmpHome()
  const at = Date.now()
  writeTranscript(t.home, '-work-api/a.jsonl', [assistant({ id: 'msg_1', output: 42, at })])
  const chome = path.join(t.root, 'chome')
  const run = args => new Promise(resolve => {
    execFile(process.execPath, [HOSTD, 'usage', ...args], {
      env: { ...process.env, HOME: t.home, CONDUCTORE_HOME: chome, CLAUDE_CONFIG_DIR: '', CODEX_HOME: '', CONDUCTORE_CSWAP: '' }
    }, (err, stdout) => resolve({ code: err ? err.code : 0, json: JSON.parse(stdout) }))
  })
  const ok = await run(['--days', '3'])
  assert.equal(ok.code, 0)
  assert.equal(ok.json.version, '0.9.0')
  assert.equal(ok.json.claude.today.output, 42)
  // No cswap: no accounts field at all.
  assert.equal(ok.json.claude.accounts, undefined)
  assert.equal(ok.json.claude.cswap, undefined)
  assert.ok(fs.existsSync(path.join(chome, 'usage-cache.json')))
  const bad = await run(['--days', 'x'])
  assert.equal(bad.code, 1)
  assert.match(bad.json.error, /--days/)
})

test('the time cap holds inside one large transcript and counts from startedAt', () => {
  const t = tmpHome()
  const lines = []
  for (let i = 0; i < 60000; i++) lines.push(assistant({ id: `m${i}`, req: `r${i}` }))
  writeTranscript(t.home, '-work-api/big.jsonl', lines)
  const r = run(t, { maxMs: 150 })
  assert.equal(r.scan.partial, true)
  assert.ok(r.scan.ms < 300, `${r.scan.ms} ms`)
  // Time already spent before compute (the process start) counts too.
  const late = run(t, { maxMs: 1000, startedAt: Date.now() - 950 })
  assert.equal(late.scan.partial, true)
  assert.ok(late.scan.ms < 1200, `${late.scan.ms} ms`)
  // Resumed calls finish the file and count every message once.
  let done = late
  for (let i = 0; i < 200 && done.scan.partial; i++) done = run(t, { maxMs: 400 })
  assert.equal(done.scan.partial, false)
  assert.equal(done.claude.today.messages, 60000)
  fs.rmSync(t.root, { recursive: true, force: true })
})

test('--hourly splits rows by local hour, --sessions adds per-session rows; plain rows keep their shape', () => {
  const t = tmpHome()
  const lines = [
    assistant({ id: 'h1', output: 10, at: NOW - 2 * HOUR }),
    assistant({ id: 'h2', req: 'r2', output: 20, at: NOW - 2 * HOUR + 60000 }),
    assistant({ id: 'h3', req: 'r3', output: 40, at: NOW })
  ]
  writeTranscript(t.home, '-work-api/a.jsonl', lines.map(l => l.replace('"sessionId":"s1"', '"sessionId":"aaaaaaaa-1111"')))
  writeTranscript(t.home, '-work-api/b.jsonl', [assistant({ id: 'h4', req: 'r4', output: 5, at: NOW })].map(l => l.replace('"sessionId":"s1"', '"sessionId":"bbbbbbbb-2222"')))
  const plain = run(t)
  assert.equal(plain.hourly, false)
  assert.equal(plain.claude.bySession, undefined)
  assert.equal(plain.claude.rows.length, 1)
  assert.deepEqual(Object.keys(plain.claude.rows[0]).sort(), ['cacheRead', 'cacheWrite', 'costUsd', 'date', 'input', 'messages', 'model', 'output', 'project'])
  assert.equal(plain.to, TODAY)
  assert.equal(plain.detailFrom, usage.addDays(TODAY, -30))
  assert.equal(plain.historyFrom, usage.addDays(TODAY, -61))
  assert.equal(plain.utcOffsetMin, -new Date(NOW).getTimezoneOffset())

  const r = run(t, { from: TODAY, to: TODAY, hourly: true, sessions: true })
  assert.equal(r.hourly, true)
  const hours = r.claude.rows.map(x => [x.hour, x.output]).sort((a, b) => a[0] - b[0])
  assert.deepEqual(hours, [[new Date(NOW - 2 * HOUR).getHours(), 30], [new Date(NOW).getHours(), 45]])
  assert.equal(r.claude.range.output, 75)
  const sessions = r.claude.bySession.map(x => [x.session, x.output]).sort()
  assert.deepEqual(sessions, [['aaaaaaaa', 70], ['bbbbbbbb', 5]])
  assert.equal(r.claude.bySession[0].date, TODAY)
})

test('--from/--to pick any range in the kept days; today stays today; older days become daily history', () => {
  const t = tmpHome()
  const DAY = 24 * HOUR
  writeTranscript(t.home, '-work-api/a.jsonl', [
    assistant({ id: 'a', output: 1, at: NOW }),
    assistant({ id: 'b', req: 'rb', output: 10, at: NOW - 3 * DAY }),
    assistant({ id: 'c', req: 'rc', output: 100, at: NOW - 5 * DAY })
  ])
  const r = run(t, { from: usage.addDays(TODAY, -5), to: usage.addDays(TODAY, -3) })
  assert.equal(r.from, usage.addDays(TODAY, -5))
  assert.equal(r.to, usage.addDays(TODAY, -3))
  assert.equal(r.claude.range.output, 110)
  assert.equal(r.claude.today.output, 1)
  // --to beyond today is clamped; --from alone runs to today.
  assert.equal(run(t, { from: usage.addDays(TODAY, -3), to: usage.addDays(TODAY, 4) }).to, TODAY)
  assert.equal(run(t, { from: usage.addDays(TODAY, -3) }).claude.range.output, 11)
  // --days reaches back 62 days now.
  assert.equal(run(t, { days: 62 }).from, usage.addDays(TODAY, -61))

  // 40 days on: those days are history, daily sums without hours or
  // sessions, still in a range.
  const later = NOW + 40 * DAY
  const old = run(t, { now: later, days: 62, hourly: true, sessions: true })
  assert.equal(old.claude.range.output, 111)
  assert.ok(old.claude.rows.every(x => x.hour === undefined))
  assert.deepEqual(old.claude.bySession, [])
  const cache = JSON.parse(fs.readFileSync(t.cacheFile, 'utf8'))
  assert.deepEqual(Object.keys(cache.claude.buckets[TODAY]), ['\tapi\tclaude-opus-5\t\t'])
  assert.equal(cache.claude.sessions[TODAY], undefined)
  assert.equal(cache.claude.seen[TODAY], undefined)
  // 70 days on: gone.
  assert.equal(run(t, { now: NOW + 70 * DAY, days: 62 }).claude.range.output, 0)
})

test('accounts: messages count for the cswap account last seen active before them', () => {
  const t = tmpHome()
  // Seen active: work two hours ago, then home now.
  run(t, { now: NOW - 2 * HOUR, activeAccount: 'work' })
  run(t, { now: NOW - 2 * HOUR + 1000, activeAccount: 'work' })
  writeTranscript(t.home, '-work-api/a.jsonl', [
    assistant({ id: 'a', output: 1, at: NOW - 3 * HOUR }),
    assistant({ id: 'b', req: 'rb', output: 10, at: NOW - HOUR }),
    assistant({ id: 'c', req: 'rc', output: 100, at: NOW + 1000 })
  ])
  const r = run(t, { activeAccount: 'home' })
  const by = Object.fromEntries(r.claude.rows.map(x => [x.account ?? '', x.output]))
  assert.deepEqual(by, { '': 1, work: 10, home: 100 })
  const cache = JSON.parse(fs.readFileSync(t.cacheFile, 'utf8'))
  assert.deepEqual(cache.accountLog.map(e => e[1]), ['work', 'home'])
  assert.equal(usage.accountAt(cache.accountLog, NOW - 3 * HOUR), '')
})

test('a version 1 cache is answered from while the transcripts are read again, then replaced', () => {
  const t = tmpHome()
  const lines = []
  for (let i = 0; i < 300; i++) lines.push(assistant({ id: `m${i}`, req: `r${i}`, output: 2 }))
  const file = writeTranscript(t.home, '-work-api/a.jsonl', lines)
  const st = fs.statSync(file)
  fs.writeFileSync(t.cacheFile, JSON.stringify({
    v: 1,
    claude: { files: { [file]: { offset: st.size, ino: st.ino, size: st.size, mtimeMs: st.mtimeMs } }, buckets: { [TODAY]: { 'api\tclaude-opus-5\t': [0, 600, 0, 0, 0, 300] } }, seen: {} },
    codex: { files: {}, buckets: {}, seen: {} },
    limits: { claude: [{ label: '5h', usedPct: 30, resetsAt: NOW + HOUR }], codex: [] },
    codexLimitsAt: 0
  }))
  let r = run(t, { maxBytes: Math.floor(st.size / 4), hourly: true })
  assert.equal(r.scan.partial, true)
  assert.equal(r.scan.rebuilding, true)
  assert.equal(r.hourly, false)
  assert.equal(r.detailFrom, null)
  // The old sums, not the half-read new ones.
  assert.equal(r.claude.today.output, 600)
  assert.equal(r.claude.rows[0].hour, undefined)
  assert.equal(r.claude.limits[0].usedPct, 30)
  for (let i = 0; i < 20 && r.scan.partial; i++) r = run(t, { maxBytes: Math.floor(st.size / 4), hourly: true })
  assert.equal(r.scan.partial, false)
  assert.equal(r.scan.rebuilding, false)
  assert.equal(r.hourly, true)
  assert.equal(r.claude.today.output, 600)
  assert.equal(r.claude.today.messages, 300)
  assert.equal(r.claude.rows[0].hour, new Date(NOW).getHours())
  assert.equal(JSON.parse(fs.readFileSync(t.cacheFile, 'utf8')).legacy, undefined)
})

test('CLI: --day with --hourly and --sessions, and bad ranges', async () => {
  const t = tmpHome()
  const at = Date.now()
  const today = usage.localDate(at)
  writeTranscript(t.home, '-work-api/a.jsonl', [assistant({ id: 'msg_1', output: 42, at })])
  const chome = path.join(t.root, 'chome')
  const run = args => new Promise(resolve => {
    execFile(process.execPath, [HOSTD, 'usage', ...args], {
      env: { ...process.env, HOME: t.home, CONDUCTORE_HOME: chome, CLAUDE_CONFIG_DIR: '', CODEX_HOME: '', CONDUCTORE_CSWAP: '' }
    }, (err, stdout) => resolve({ code: err ? err.code : 0, json: JSON.parse(stdout) }))
  })
  const ok = await run(['--days', '31', '--day', today, '--hourly', '--sessions'])
  assert.equal(ok.code, 0)
  assert.equal(ok.json.from, today)
  assert.equal(ok.json.to, today)
  assert.equal(ok.json.hourly, true)
  assert.equal(ok.json.claude.rows[0].hour, new Date(at).getHours())
  assert.equal(ok.json.claude.bySession.length, 1)
  const range = await run(['--from', usage.addDays(today, -2), '--to', today])
  assert.equal(range.json.from, usage.addDays(today, -2))
  assert.equal(range.json.claude.range.output, 42)
  for (const [args, re] of [
    [['--from', '2026-9-1'], /--from/],
    [['--day', 'monday'], /--day/],
    [['--from', today, '--to', usage.addDays(today, -1)], /after/],
    [['--day', today, '--from', today], /not both/]
  ]) {
    const bad = await run(args)
    assert.equal(bad.code, 1)
    assert.match(bad.json.error, re)
  }
})

test.after(() => cleanup())
