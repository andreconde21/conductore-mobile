'use strict'

// `conductore-hostd usage`: token, cost and limit usage of the coding agents
// on this machine, computed here from local files (no network).
//
// Claude Code: every assistant entry of the transcripts under
// ~/.claude/projects/**/*.jsonl ($CLAUDE_CONFIG_DIR/projects) carries
// message.usage and message.model. Codex CLI: token_count events in
// ~/.codex/sessions/**/*.jsonl ($CODEX_HOME) carry running totals and the
// account's rate limits. Both are summed per local day and hour, project,
// model, speed and account (the cswap account the companion saw active at
// the time), and per day and session, into ~/.conductore/usage-cache.json.
//
// Cheap by construction:
// * incremental: the cache keeps, per file, the byte offset read so far;
//   only files whose size or mtime changed are opened, from that offset;
// * capped: one call reads at most --max-bytes / --max-ms (newest files
//   first), then answers with `scan.partial: true`; the next call goes on;
// * lines are filtered on raw bytes before anything is parsed;
// * it never talks to the daemon's hot path: hooks are untouched, and the
//   caller runs at a lower CPU priority. Two concurrent calls do not both
//   scan: the second answers from the cache with `scan.busy: true`.
//
// Streaming writes one transcript line per content block, all with the
// same message id and request id (and a growing output_tokens), and a
// resumed session copies earlier entries into a new file: entries are
// counted once per (message id, request id), the largest output wins.
//
// The last RETENTION_DAYS days are kept in full (hours, sessions, the
// hashes that dedupe messages); days up to HISTORY_DAYS back only as daily
// sums (no hour, no session), so a 30-day range can be compared with the
// 30 days before. Costs are computed from lib/pricing.js at answer time.

const fs = require('fs')
const os = require('os')
const path = require('path')
const crypto = require('crypto')
const pricing = require('./pricing')

const SCHEMA = 1
const CACHE_VERSION = 2
const RETENTION_DAYS = 31
const HISTORY_DAYS = 62
const MAX_ACCOUNT_LOG = 500
const DEFAULT_DAYS = 7
const DEFAULT_MAX_BYTES = 256 * 1024 * 1024
const DEFAULT_MAX_MS = 2500
const CHUNK = 4 * 1024 * 1024
const MAX_LINE = 16 * 1024 * 1024
const LOCK_STALE_MS = 60 * 1000
// Two reports of one limit window reset within this of each other.
const SAME_WINDOW_MS = 5 * 60 * 1000

// Bucket value slots.
const IN = 0; const OUT = 1; const CW5 = 2; const CW1H = 3; const CR = 4; const MSGS = 5

const MARK_USAGE = Buffer.from('"usage"')
const MARK_ASSISTANT = Buffer.from('"assistant"')
const MARK_TOKEN_COUNT = Buffer.from('"token_count"')
const MARK_TURN_CONTEXT = Buffer.from('"turn_context"')
const MARK_SESSION_META = Buffer.from('"session_meta"')

const pad = n => String(n).padStart(2, '0')
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/

function localDate (ms) {
  const d = new Date(ms)
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`
}

function addDays (date, n) {
  const [y, m, d] = date.split('-').map(Number)
  return localDate(new Date(y, m - 1, d + n, 12).getTime())
}

function claudeRoot (env = process.env) {
  const base = env.CLAUDE_CONFIG_DIR || path.join(env.HOME || os.homedir(), '.claude')
  return path.join(base, 'projects')
}

function codexRoots (env = process.env) {
  const base = env.CODEX_HOME || path.join(env.HOME || os.homedir(), '.codex')
  return [path.join(base, 'sessions'), path.join(base, 'archived_sessions')]
}

function isDir (p) {
  try { return fs.statSync(p).isDirectory() } catch { return false }
}

// --- project names ------------------------------------------------------------

// The repository a cwd belongs to: the main checkout's directory name, also
// for a linked worktree (its .git file points into <repo>/.git/worktrees);
// the cwd's own name outside a repository.
function makeProjectResolver (home) {
  const memo = new Map()
  return function projectOf (cwd) {
    if (typeof cwd !== 'string' || !cwd) return '(unknown)'
    let name = memo.get(cwd)
    if (name !== undefined) return name
    name = resolveProject(cwd, home)
    memo.set(cwd, name)
    return name
  }
}

function resolveProject (cwd, home) {
  if (home && path.resolve(cwd) === path.resolve(home)) return '~'
  let dir = cwd
  for (let i = 0; i < 64; i++) {
    const git = path.join(dir, '.git')
    let st = null
    try { st = fs.statSync(git) } catch {}
    if (st && st.isDirectory()) return path.basename(dir) || dir
    if (st && st.isFile()) {
      try {
        const m = /^gitdir:\s*(.+)\s*$/m.exec(fs.readFileSync(git, 'utf8'))
        if (m) {
          const target = path.resolve(dir, m[1].trim())
          const at = target.lastIndexOf(`${path.sep}.git${path.sep}`)
          if (at > 0) return path.basename(target.slice(0, at))
        }
      } catch {}
      return path.basename(dir) || dir
    }
    const parent = path.dirname(dir)
    if (parent === dir) break
    dir = parent
  }
  return path.basename(cwd) || cwd
}

// --- cache --------------------------------------------------------------------

// buckets[day]["HH\tproject\tmodel\tspeed\taccount"] (HH empty for a
// history day) and sessions[day]["session\tproject\tmodel\tspeed\taccount"]
// (the session id's first 8 characters) hold [IN, OUT, CW5, CW1H, CR, MSGS].
function emptyAgentCache () {
  return { files: {}, buckets: {}, sessions: {}, seen: {} }
}

// accountLog: [[ms, label]], each time the active cswap account was seen to
// change. legacy: a version 1 cache's daily buckets, answered from while
// the transcripts are read again for hours and sessions.
function emptyCache () {
  return { v: CACHE_VERSION, claude: emptyAgentCache(), codex: emptyAgentCache(), limits: { claude: [], codex: [] }, codexLimitsAt: 0, accountLog: [] }
}

function loadCache (file) {
  try {
    const c = JSON.parse(fs.readFileSync(file, 'utf8'))
    if (!c || (c.v !== CACHE_VERSION && c.v !== 1)) return emptyCache()
    const base = emptyCache()
    base.limits = { claude: [], codex: [], ...(c.limits || {}) }
    base.codexLimitsAt = Number(c.codexLimitsAt) || 0
    if (c.v === 1) {
      // Version 1 kept days without hours or sessions: read everything
      // again, answering from the old sums until that is done.
      base.legacy = {}
      for (const agent of ['claude', 'codex']) {
        const days = {}
        for (const [day, keys] of Object.entries((c[agent] && c[agent].buckets) || {})) {
          days[day] = {}
          for (const [key, b] of Object.entries(keys)) days[day][`\t${key}\t`] = b
        }
        base.legacy[agent] = days
      }
      return base
    }
    for (const agent of ['claude', 'codex']) base[agent] = { ...emptyAgentCache(), ...(c[agent] || {}) }
    if (Array.isArray(c.accountLog)) base.accountLog = c.accountLog
    if (c.legacy) base.legacy = c.legacy
    return base
  } catch {
    return emptyCache()
  }
}

function saveCache (file, cache) {
  const tmp = `${file}.${process.pid}.tmp`
  fs.writeFileSync(tmp, JSON.stringify(cache), { mode: 0o600 })
  fs.renameSync(tmp, file)
}

// Seen message hashes per day: a string of 8-char hashes on disk, a Set in
// memory.
function seenSets (agentCache) {
  const sets = new Map()
  return {
    has (day, h) { return this.get(day).has(h) },
    add (day, h) { this.get(day).add(h) },
    get (day) {
      let s = sets.get(day)
      if (!s) {
        s = new Set()
        const str = agentCache.seen[day]
        if (typeof str === 'string') for (let i = 0; i + 8 <= str.length; i += 8) s.add(str.slice(i, i + 8))
        sets.set(day, s)
      }
      return s
    },
    flush () {
      for (const [day, s] of sets) agentCache.seen[day] = [...s].join('')
    }
  }
}

const hash8 = s => crypto.createHash('sha1').update(s).digest('base64url').slice(0, 8)

// Days before retentionFrom become history: their hours are summed into
// one daily bucket per key, sessions and hashes go. Days before historyFrom
// go entirely.
function prune (cache, retentionFrom, historyFrom) {
  for (const agent of ['claude', 'codex']) {
    const c = cache[agent]
    for (const day of Object.keys(c.buckets)) {
      if (day < historyFrom) { delete c.buckets[day]; continue }
      if (day >= retentionFrom) continue
      const daily = {}
      let hourly = false
      for (const [key, b] of Object.entries(c.buckets[day])) {
        const tab = key.indexOf('\t')
        if (tab > 0) hourly = true
        const k = key.slice(tab)
        const sum = daily[k] || (daily[k] = [0, 0, 0, 0, 0, 0])
        for (let i = 0; i < 6; i++) sum[i] += b[i] || 0
      }
      if (hourly) c.buckets[day] = daily
    }
    for (const day of Object.keys(c.sessions)) if (day < retentionFrom) delete c.sessions[day]
    for (const day of Object.keys(c.seen)) if (day < retentionFrom) delete c.seen[day]
  }
  const log = cache.accountLog
  const cutoff = new Date(`${historyFrom}T00:00:00`).getTime()
  // Keep the entry in force at the cutoff.
  let first = 0
  while (first + 1 < log.length && log[first + 1][0] <= cutoff) first++
  if (first) log.splice(0, first)
  if (log.length > MAX_ACCOUNT_LOG) log.splice(0, log.length - MAX_ACCOUNT_LOG)
}

// Records the account seen active now when it differs from the last one.
function noteAccount (cache, label, now) {
  if (typeof label !== 'string' || !label) return
  const log = cache.accountLog
  const last = log[log.length - 1]
  if (last && last[1] === label) return
  if (last && last[0] > now) return
  log.push([now, label])
}

// The account active at ts as last seen before it; '' before the first
// sighting (or without cswap).
function accountAt (log, ts) {
  let lo = 0
  let hi = log.length - 1
  let found = ''
  while (lo <= hi) {
    const mid = (lo + hi) >> 1
    if (log[mid][0] <= ts) { found = log[mid][1]; lo = mid + 1 } else hi = mid - 1
  }
  return found
}

function lock (file) {
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      const fd = fs.openSync(file, 'wx', 0o600)
      fs.writeSync(fd, String(process.pid))
      fs.closeSync(fd)
      return () => { try { fs.unlinkSync(file) } catch {} }
    } catch (err) {
      if (err.code !== 'EEXIST') return () => {}
      let age = 0
      try { age = Date.now() - fs.statSync(file).mtimeMs } catch { continue }
      if (age < LOCK_STALE_MS) return null
      try { fs.unlinkSync(file) } catch {}
    }
  }
  return null
}

// --- file walk ----------------------------------------------------------------

function listJsonl (root, cutoffMs, out) {
  let entries
  try { entries = fs.readdirSync(root, { withFileTypes: true }) } catch { return out }
  for (const e of entries) {
    const p = path.join(root, e.name)
    if (e.isDirectory()) listJsonl(p, cutoffMs, out)
    else if (e.isFile() && e.name.endsWith('.jsonl')) {
      let st
      try { st = fs.statSync(p) } catch { continue }
      if (st.mtimeMs < cutoffMs) continue
      out.push({ path: p, size: st.size, mtimeMs: st.mtimeMs, ino: st.ino })
    }
  }
  return out
}

// Reads `file` from its cached offset, calling onLine(buf, start, end) for
// every complete line, within budget. Returns bytes consumed.
function readLines (f, state, budget, onLine) {
  let fd
  try { fd = fs.openSync(f.path, 'r') } catch { return 0 }
  let consumed = 0
  try {
    let pos = state.offset
    let carry = null
    let skipping = false
    const buf = Buffer.allocUnsafe(CHUNK)
    while (pos < f.size) {
      if (budget.exhausted()) { budget.partial = true; break }
      const n = fs.readSync(fd, buf, 0, Math.min(CHUNK, f.size - pos), pos)
      if (n <= 0) break
      budget.bytes += n
      const data = carry ? Buffer.concat([carry, buf.subarray(0, n)]) : buf.subarray(0, n)
      const dataStart = pos - (carry ? carry.length : 0)
      pos += n
      let s = 0
      let lines = 0
      let stop = false
      for (;;) {
        const e = data.indexOf(10, s)
        if (e === -1) break
        if (!skipping) onLine(data, s, e)
        skipping = false
        s = e + 1
        // A chunk of dense lines takes a while: stop mid-chunk on time too.
        if ((++lines & 63) === 0 && budget.exhausted()) { stop = true; break }
      }
      state.offset = dataStart + s
      consumed = state.offset
      if (stop) { budget.partial = true; break }
      const rest = data.length - s
      if (rest > MAX_LINE) { carry = null; skipping = true; state.offset = pos } else carry = rest ? Buffer.from(data.subarray(s)) : null
    }
  } finally {
    fs.closeSync(fd)
  }
  return consumed
}

// --- Claude -------------------------------------------------------------------

function addTo (store, day, key, vals) {
  const byDay = store[day] || (store[day] = {})
  const b = byDay[key] || (byDay[key] = [0, 0, 0, 0, 0, 0])
  for (let i = 0; i < vals.length; i++) b[i] += vals[i]
}

// One counted message (or the rest of its output): into its hour's bucket
// and its session's.
function bucketAdd (agentCache, at, vals) {
  addTo(agentCache.buckets, at.day, at.key, vals)
  addTo(agentCache.sessions, at.day, at.skey, vals)
}

// Where a message at ts is counted.
function place (ctx, ts, project, model, speed, session) {
  const d = new Date(ts)
  const rest = `${project}\t${model}\t${speed}\t${accountAt(ctx.cache.accountLog, ts)}`
  return { day: localDate(ts), key: `${pad(d.getHours())}\t${rest}`, skey: `${String(session || '').slice(0, 8)}\t${rest}` }
}

const n0 = v => (typeof v === 'number' && Number.isFinite(v) && v > 0 ? v : 0)

function claudeLineHandler (ctx, fileState) {
  const { cache, seen, projectOf, cutoffMs } = ctx
  return (data, s, e) => {
    const line = data.subarray(s, e)
    if (line.indexOf(MARK_USAGE) === -1 || line.indexOf(MARK_ASSISTANT) === -1) return
    let o
    try { o = JSON.parse(line.toString('utf8')) } catch { return }
    if (!o || o.type !== 'assistant' || !o.message || typeof o.message !== 'object') return
    const m = o.message
    const u = m.usage
    if (!u || typeof u !== 'object' || typeof m.model !== 'string' || m.model.startsWith('<')) return
    const ts = Date.parse(o.timestamp)
    if (!Number.isFinite(ts) || ts < cutoffMs) return
    const id = m.id ? `${m.id}:${o.requestId || ''}` : (o.uuid || null)
    if (!id) return
    const h = hash8(id)
    const out = n0(u.output_tokens)
    const last = fileState.last
    if (last && last.h === h) {
      // The next content block of the message just counted.
      if (out > last.out) {
        bucketAdd(cache.claude, last.at, [0, out - last.out])
        last.out = out
      }
      return
    }
    const day = localDate(ts)
    if (seen.has(day, h)) { fileState.last = null; return }
    seen.add(day, h)
    const cw = n0(u.cache_creation_input_tokens)
    const cw1h = Math.min(cw, n0(u.cache_creation && u.cache_creation.ephemeral_1h_input_tokens))
    const speed = u.speed === 'fast' ? 'fast' : ''
    const at = place(ctx, ts, projectOf(o.cwd), m.model, speed, o.sessionId)
    bucketAdd(cache.claude, at, [n0(u.input_tokens), out, cw - cw1h, cw1h, n0(u.cache_read_input_tokens), 1])
    fileState.last = { h, out, at }
  }
}

// --- Codex --------------------------------------------------------------------

const LIMIT_WINDOWS = { 300: '5h', 10080: '7d', 1440: '1d', 60: '1h' }

function codexLimit (w, ts) {
  if (!w || typeof w !== 'object') return null
  const used = typeof w.used_percent === 'number' ? w.used_percent : null
  if (used === null) return null
  const minutes = Number(w.window_minutes) || 0
  const label = LIMIT_WINDOWS[minutes] || (minutes ? `${minutes}m` : 'limit')
  const entry = { label, usedPct: Math.max(0, Math.min(100, used)) }
  if (typeof w.resets_at === 'number') entry.resetsAt = Math.round(w.resets_at * 1000)
  else if (typeof w.resets_in_seconds === 'number') entry.resetsAt = Math.round(ts + w.resets_in_seconds * 1000)
  return entry
}

function codexLineHandler (ctx, fileState) {
  const { cache, projectOf, cutoffMs } = ctx
  return (data, s, e) => {
    const line = data.subarray(s, e)
    if (line.indexOf(MARK_TOKEN_COUNT) === -1 && line.indexOf(MARK_TURN_CONTEXT) === -1 && line.indexOf(MARK_SESSION_META) === -1) return
    let o
    try { o = JSON.parse(line.toString('utf8')) } catch { return }
    const p = o && o.payload
    if (!p || typeof p !== 'object') return
    if (o.type === 'session_meta' || o.type === 'turn_context') {
      if (o.type === 'session_meta' && typeof p.id === 'string') fileState.session = p.id
      if (typeof p.cwd === 'string') fileState.cwd = p.cwd
      if (typeof p.model === 'string') fileState.model = p.model
      return
    }
    if (o.type !== 'event_msg' || p.type !== 'token_count') return
    const ts = Date.parse(o.timestamp)
    if (!Number.isFinite(ts)) return
    if (p.rate_limits && typeof p.rate_limits === 'object' && ts >= (cache.codexLimitsAt || 0)) {
      const limits = [codexLimit(p.rate_limits.primary, ts), codexLimit(p.rate_limits.secondary, ts)].filter(Boolean)
      if (limits.length) { cache.limits.codex = limits; cache.codexLimitsAt = ts }
    }
    const t = p.info && p.info.total_token_usage
    if (!t || typeof t !== 'object') return
    const now = { in: n0(t.input_tokens), cached: n0(t.cached_input_tokens), out: n0(t.output_tokens) }
    let prev = fileState.prev || { in: 0, cached: 0, out: 0 }
    // Running totals only grow; a drop is a new count (a forked session).
    if (now.in < prev.in || now.out < prev.out || now.cached < prev.cached) prev = { in: 0, cached: 0, out: 0 }
    fileState.prev = now
    const dIn = now.in - prev.in
    const dCached = now.cached - prev.cached
    const dOut = now.out - prev.out
    if (ts < cutoffMs || (dIn <= 0 && dOut <= 0)) return
    const at = place(ctx, ts, projectOf(fileState.cwd), fileState.model || 'unknown', '', fileState.session)
    bucketAdd(cache.codex, at, [Math.max(0, dIn - dCached), dOut, 0, 0, dCached, 1])
  }
}

// --- scan ---------------------------------------------------------------------

function scanAgent (agent, roots, ctx) {
  const agentCache = ctx.cache[agent]
  const files = []
  for (const root of roots) listJsonl(root, ctx.cutoffMs, files)
  const live = new Set(files.map(f => f.path))
  for (const p of Object.keys(agentCache.files)) if (!live.has(p)) delete agentCache.files[p]
  files.sort((a, b) => b.mtimeMs - a.mtimeMs)
  ctx.stats.files += files.length
  const seen = agent === 'claude' ? seenSets(agentCache) : null
  const agentCtx = { ...ctx, seen }
  for (const f of files) {
    let st = agentCache.files[f.path]
    if (st && st.ino === f.ino && st.size === f.size && st.mtimeMs === f.mtimeMs) continue
    if (!st || st.ino !== f.ino || f.size < st.offset) {
      // New, replaced or truncated: read it all again; counted entries are
      // recognised (Claude) or the running totals restart (Codex).
      st = { offset: 0 }
    }
    if (ctx.budget.exhausted()) { ctx.budget.partial = true; ctx.stats.pendingFiles++; continue }
    ctx.stats.filesRead++
    const handler = agent === 'claude' ? claudeLineHandler(agentCtx, st) : codexLineHandler(agentCtx, st)
    readLines(f, st, ctx.budget, handler)
    const complete = st.offset >= f.size || !ctx.budget.partial
    st.ino = f.ino
    // A file left mid-way keeps a stale size so the next call resumes it.
    st.size = complete ? f.size : -1
    st.mtimeMs = f.mtimeMs
    agentCache.files[f.path] = st
    if (!complete) ctx.stats.pendingFiles++
  }
  if (seen) seen.flush()
}

// --- limits -------------------------------------------------------------------

// Rate limits are per account: of two reports for one window, the one for
// the later window wins, then the higher use (it only grows in a window),
// then the newer report.
function fresher (a, b) {
  if (!a) return b
  if (!b) return a
  const ra = a.resetsAt || 0
  const rb = b.resetsAt || 0
  if (Math.abs(ra - rb) > SAME_WINDOW_MS) return rb > ra ? b : a
  if (b.usedPct !== a.usedPct) return b.usedPct > a.usedPct ? b : a
  return (b.at || 0) > (a.at || 0) ? b : a
}

function mergeLimits (lists) {
  const byLabel = new Map()
  for (const list of lists) {
    for (const l of list || []) {
      if (!l || typeof l.label !== 'string' || typeof l.usedPct !== 'number') continue
      const entry = { label: l.label, usedPct: l.usedPct, resetsAt: l.resetsAt || null }
      if (l.at) entry.at = l.at
      byLabel.set(l.label, fresher(byLabel.get(l.label), entry))
    }
  }
  const order = { '5h': 0, '7d': 1 }
  return [...byLabel.values()].sort((a, b) => (order[a.label] ?? 9) - (order[b.label] ?? 9))
}

// Which account a set of limits belongs to: when its weekly window resets
// (null when unknown). Two sets with weekly resets within SAME_WINDOW_MS
// are taken for one account.
function weekOf (limits) {
  const w = (limits || []).find(l => l && l.label === '7d')
  return w && w.resetsAt ? w.resetsAt : null
}

function sameAccount (a, b) {
  return a != null && b != null && Math.abs(a - b) <= SAME_WINDOW_MS
}

// When a session last reported its limits: its statusline record's `at`,
// or its last hook event when later (a session at the same numbers does not
// stamp a new record) or when the daemon is older.
function reportedAt (agent) {
  const at = Number(agent.usage && agent.usage.at)
  const updated = typeof agent.updatedAt === 'number' ? agent.updatedAt : Date.parse(agent.updatedAt)
  return Math.max(Number.isFinite(at) ? at : 0, Number.isFinite(updated) ? updated : 0)
}

// The live Claude login's limits from the sessions' statusline reports.
// Sessions can be on different accounts (a login changed under a session
// left open, `cswap run`): the most recent report decides the account, and
// only reports for that account's weekly window count. Each limit keeps
// when it was reported (`at`).
function liveClaudeLimits (agents) {
  const reports = []
  for (const a of agents || []) {
    if (!a || a.state === 'ended' || !a.usage || !Array.isArray(a.usage.limits) || !a.usage.limits.length) continue
    reports.push({ at: reportedAt(a), limits: a.usage.limits })
  }
  if (!reports.length) return { at: 0, limits: [] }
  reports.sort((x, y) => y.at - x.at)
  const week = weekOf(reports[0].limits)
  const same = reports.filter((r, i) => i === 0 || sameAccount(weekOf(r.limits), week))
  return { at: reports[0].at, limits: mergeLimits(same.map(r => r.limits.map(l => ({ ...l, at: r.at || undefined })))) }
}

// The Claude limits to remember: the live login's, unless the remembered
// ones were reported later (every session that knew newer numbers ended).
// A window the live reports lack is kept from the remembered ones of the
// same account (a 5-hour window not started again yet).
function claudeLimits (cached, agents) {
  const live = liveClaudeLimits(agents)
  const cachedAt = Math.max(0, ...(cached || []).map(l => l.at || 0))
  if (!live.limits.length || live.at < cachedAt) return mergeLimits([cached])
  const week = weekOf(live.limits)
  const labels = new Set(live.limits.map(l => l.label))
  const kept = (cached || []).filter(l => !labels.has(l.label) && sameAccount(weekOf(cached), week))
  return mergeLimits([live.limits, kept])
}

// What `usage` answers: a window that reset since it was reported is
// `expired` and at 0 % (its new use is unknown until the next report),
// with the reset time it had.
function publicLimits (list, now, at) {
  return list.map(l => {
    const expired = !!(l.resetsAt && l.resetsAt <= now)
    const out = { label: l.label, usedPct: expired ? 0 : l.usedPct, resetsAt: l.resetsAt || null, expired }
    if (l.at || at) out.at = l.at || at
    return out
  })
}

// --- report -------------------------------------------------------------------

function totalsOf () {
  return { input: 0, output: 0, cacheWrite: 0, cacheRead: 0, tokens: 0, messages: 0, costUsd: null }
}

function addTotals (t, row) {
  t.input += row.input
  t.output += row.output
  t.cacheWrite += row.cacheWrite
  t.cacheRead += row.cacheRead
  t.tokens += row.input + row.output + row.cacheWrite + row.cacheRead
  t.messages += row.messages
  if (row.costUsd !== null) t.costUsd = (t.costUsd || 0) + row.costUsd
}

const round6 = v => (v === null ? null : Math.round(v * 1e6) / 1e6)

function rowOf (agent, fields, b, unpriced) {
  const [project, model, speed, account] = fields
  const cost = pricing.costUsd(agent, model, { input: b[IN], output: b[OUT], cacheWrite5m: b[CW5], cacheWrite1h: b[CW1H], cacheRead: b[CR] }, speed)
  if (cost === null) unpriced.add(model)
  const row = {
    project,
    model,
    input: b[IN],
    output: b[OUT],
    cacheWrite: b[CW5] + b[CW1H],
    cacheRead: b[CR],
    messages: b[MSGS],
    costUsd: round6(cost)
  }
  if (speed) row.speed = speed
  if (account) row.account = account
  return row
}

const byCost = (a, b) => (a.date === b.date ? (b.costUsd || 0) - (a.costUsd || 0) : a.date < b.date ? -1 : 1)

// Rows from `from` to `to`: one per day, project, model, speed and account,
// or also per hour (opts.hourly; history days have none). opts.sessions
// adds bySession: one row per day, session, project, model, speed and
// account (days of the last RETENTION_DAYS only).
function report (agent, agentCache, days, range, opts, unpriced) {
  const { from, to, today } = range
  const rows = []
  const totals = totalsOf()
  const todayTotals = totalsOf()
  for (const day of Object.keys(days).sort()) {
    const inRange = day >= from && day <= to
    if (!inRange && day !== today) continue
    const sums = new Map()
    for (const [key, b] of Object.entries(days[day])) {
      const tab = key.indexOf('\t')
      const k = opts.hourly ? key : key.slice(tab + 1)
      const sum = sums.get(k)
      if (sum) for (let i = 0; i < 6; i++) sum[i] += b[i] || 0
      else sums.set(k, b.slice(0, 6))
    }
    for (const [key, b] of sums) {
      const fields = key.split('\t')
      const hour = opts.hourly ? fields.shift() : ''
      const row = { date: day, ...rowOf(agent, fields, b, unpriced) }
      if (hour) row.hour = Number(hour)
      if (inRange) { rows.push(row); addTotals(totals, row) }
      if (day === today) addTotals(todayTotals, row)
    }
  }
  totals.costUsd = round6(totals.costUsd)
  todayTotals.costUsd = round6(todayTotals.costUsd)
  rows.sort((a, b) => byCost(a, b) || (a.hour ?? -1) - (b.hour ?? -1))
  const out = { today: todayTotals, range: totals, rows }
  if (opts.sessions) {
    const bySession = []
    for (const day of Object.keys(agentCache.sessions || {}).sort()) {
      if (day < from || day > to) continue
      for (const [key, b] of Object.entries(agentCache.sessions[day])) {
        const [session, ...fields] = key.split('\t')
        bySession.push({ date: day, session, ...rowOf(agent, fields, b, unpriced) })
      }
    }
    out.bySession = bySession.sort(byCost)
  }
  return out
}

// Context use of live sessions, from the daemon's agents.
function sessionsOf (agents, projectOf) {
  const out = []
  for (const a of agents || []) {
    if (!a || a.state === 'ended' || !a.usage) continue
    const u = a.usage
    if (u.contextUsedPct === undefined && u.contextTokens === undefined) continue
    out.push({
      sessionId: a.sessionId,
      name: a.name || null,
      project: projectOf(a.cwd),
      state: a.state || null,
      contextUsedPct: u.contextUsedPct ?? null,
      contextTokens: u.contextTokens ?? null,
      windowLabel: u.windowLabel ?? null
    })
  }
  return out
}

// The dates to answer for: --from/--to (or --day) win over --since, which
// wins over --days; clamped to the days kept and to today.
function rangeOf (opts, today, historyFrom) {
  let to = today
  let from
  if (opts.from || opts.to) {
    to = opts.to || today
    from = opts.from || addDays(to, -(Math.max(1, Math.min(HISTORY_DAYS, opts.days || DEFAULT_DAYS)) - 1))
  } else if (Number.isFinite(opts.since)) {
    from = localDate(opts.since)
  } else {
    from = addDays(today, -(Math.max(1, Math.min(HISTORY_DAYS, opts.days || DEFAULT_DAYS)) - 1))
  }
  if (to > today) to = today
  if (from < historyFrom) from = historyFrom
  if (from > to) from = to
  return { from, to, today }
}

// opts: { days, since (ms), from, to (YYYY-MM-DD), hourly, sessions,
//         activeAccount (the cswap account active now), maxBytes, maxMs,
//         now, env, cacheFile, agents, machine, startedAt (ms: when maxMs
//         starts counting, e.g. the process start, so startup and the file
//         walk count too) }
function compute (opts = {}) {
  const started = opts.startedAt || Date.now()
  const env = opts.env || process.env
  const now = opts.now || Date.now()
  const home = env.HOME || os.homedir()
  const today = localDate(now)
  const retentionFrom = addDays(today, -(RETENTION_DAYS - 1))
  const historyFrom = addDays(today, -(HISTORY_DAYS - 1))
  const range = rangeOf(opts, today, historyFrom)
  const cutoffMs = new Date(`${retentionFrom}T00:00:00`).getTime()

  const cacheFile = opts.cacheFile
  const cache = loadCache(cacheFile)
  const maxBytes = opts.maxBytes || DEFAULT_MAX_BYTES
  const maxMs = opts.maxMs || DEFAULT_MAX_MS
  // Saving the cache and building the report take the rest (~100 ms on
  // 1,000 transcripts), so scanning stops a little before maxMs.
  const scanMs = maxMs - Math.min(200, maxMs / 5)
  const budget = {
    bytes: 0,
    partial: false,
    exhausted () { return this.bytes >= maxBytes || Date.now() - started >= scanMs }
  }
  const stats = { files: 0, filesRead: 0, pendingFiles: 0 }
  const projectOf = makeProjectResolver(home)
  const claudeDir = claudeRoot(env)
  const codexDirs = codexRoots(env).filter(isDir)
  const claudePresent = isDir(claudeDir)

  const unlock = cacheFile ? lock(`${cacheFile}.lock`) : () => {}
  const busy = unlock === null
  if (!busy) {
    try {
      noteAccount(cache, opts.activeAccount, now)
      const ctx = { cache, projectOf, cutoffMs, budget, stats }
      if (claudePresent) scanAgent('claude', [claudeDir], ctx)
      if (codexDirs.length) scanAgent('codex', codexDirs, ctx)
      // The rescan after an upgrade is done: answer from it.
      if (cache.legacy && !budget.partial && !stats.pendingFiles) delete cache.legacy
      prune(cache, retentionFrom, historyFrom)
      if (cache.legacy) for (const agent of ['claude', 'codex']) for (const day of Object.keys(cache.legacy[agent] || {})) if (day < historyFrom) delete cache.legacy[agent][day]
      cache.limits.claude = claudeLimits(cache.limits.claude, opts.agents)
      if (cacheFile) saveCache(cacheFile, cache)
    } finally {
      unlock()
    }
  } else {
    cache.limits.claude = claudeLimits(cache.limits.claude, opts.agents)
  }

  const unpriced = new Set()
  const legacy = cache.legacy
  const detail = { hourly: !!opts.hourly && !legacy, sessions: !!opts.sessions && !legacy }
  const daysOf = agent => (legacy ? legacy[agent] || {} : cache[agent].buckets)
  const claude = {
    present: claudePresent,
    limits: publicLimits(cache.limits.claude, now),
    sessions: sessionsOf(opts.agents, projectOf),
    ...report('claude', cache.claude, daysOf('claude'), range, detail, unpriced)
  }
  const codex = codexDirs.length
    ? { present: true, limits: publicLimits(cache.limits.codex, now, cache.codexLimitsAt), ...report('codex', cache.codex, daysOf('codex'), range, detail, unpriced) }
    : { present: false }
  // Every other agent's section, from its adapter (lib/adapters
  // usageReport): OpenCode keeps its own token and cost records.
  const others = {}
  for (const a of require('./adapters').all()) {
    if (typeof a.usageReport !== 'function' || !a.usageSection || a.usageSection === 'claude' || a.usageSection === 'codex') continue
    try {
      others[a.usageSection] = a.usageReport({ range, projectOf, localDate, detail, env, now })
    } catch (err) {
      others[a.usageSection] = { present: false, error: err.message }
    }
  }
  let cacheBytes = null
  try { cacheBytes = fs.statSync(cacheFile).size } catch {}
  return {
    schema: SCHEMA,
    machine: opts.machine || os.hostname(),
    generatedAt: now,
    timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone || null,
    utcOffsetMin: -new Date(now).getTimezoneOffset(),
    today,
    from: range.from,
    to: range.to,
    // Rows carry `hour`, and bySession is there, when asked for and known:
    // not while the cache is being rebuilt after an upgrade.
    hourly: detail.hourly,
    // Hours and sessions exist from detailFrom, daily sums from historyFrom.
    detailFrom: legacy ? null : retentionFrom,
    historyFrom,
    claude,
    codex,
    ...others,
    pricing: {
      estimate: true,
      asOf: pricing.AS_OF,
      note: pricing.NOTE,
      sources: pricing.SOURCES,
      unpriced: [...unpriced].sort()
    },
    scan: {
      ms: Date.now() - started,
      files: stats.files,
      filesRead: stats.filesRead,
      bytesRead: budget.bytes,
      partial: budget.partial,
      pendingFiles: stats.pendingFiles,
      busy,
      rebuilding: !!legacy,
      cacheBytes
    }
  }
}

module.exports = { compute, localDate, addDays, resolveProject, mergeLimits, fresher, liveClaudeLimits, claudeLimits, publicLimits, weekOf, sameAccount, accountAt, DATE_RE, RETENTION_DAYS, HISTORY_DAYS, SCHEMA }
