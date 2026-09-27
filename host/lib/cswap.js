'use strict'

// cswap (claude-swap, a Claude Code multi-account switcher): the limits of
// every configured account for `usage`, and `cswap-switch`.
//
// Found on PATH, else at ~/.local/bin/cswap ($CONDUCTORE_CSWAP overrides:
// a path, or empty for none); absent means no `accounts` field at all.
// `cswap list --json` answers from its own usage store (0.1-1 s). It runs
// with a 3 s timeout in its own process group (killed on timeout) at nice
// 10, and its answer is cached for 60 s in ~/.conductore/cswap-cache.json,
// a failure too, so a hung cswap costs at most one timeout a minute. A
// failed refresh falls back to the last answer for 15 minutes, then to
// none.
//
// Only what the phone shows leaves this module: slot, alias, a label (the
// alias, else a masked email: a***@d***.com), active, disabled and the
// limit windows. Never an email, an organisation or a token; the cache
// holds the same masked rows.

const fs = require('fs')
const os = require('os')
const path = require('path')
const { spawn } = require('child_process')

const CACHE_VERSION = 1
const TTL_MS = 60 * 1000
const STALE_MAX_MS = 15 * 60 * 1000
const LIST_TIMEOUT_MS = 3000
const SWITCH_TIMEOUT_MS = 20000
const MAX_OUTPUT = 1024 * 1024

function isExecutable (p) {
  try {
    if (!fs.statSync(p).isFile()) return false
    fs.accessSync(p, fs.constants.X_OK)
    return true
  } catch {
    return false
  }
}

function findCswap (env = process.env) {
  if (env.CONDUCTORE_CSWAP !== undefined) {
    return env.CONDUCTORE_CSWAP && isExecutable(env.CONDUCTORE_CSWAP) ? env.CONDUCTORE_CSWAP : null
  }
  for (const dir of (env.PATH || '').split(path.delimiter)) {
    if (!dir) continue
    const p = path.join(dir, 'cswap')
    if (isExecutable(p)) return p
  }
  const p = path.join(env.HOME || os.homedir(), '.local', 'bin', 'cswap')
  return isExecutable(p) ? p : null
}

// a***@d***.com: the first letter of the user and of the domain, and the
// last domain label.
function maskEmail (email) {
  if (typeof email !== 'string' || !email.trim()) return null
  const e = email.trim()
  const at = e.lastIndexOf('@')
  if (at <= 0) return `${e[0]}***`
  const domain = e.slice(at + 1)
  const dot = domain.lastIndexOf('.')
  const name = dot > 0 ? domain.slice(0, dot) : domain
  const tld = dot > 0 ? domain.slice(dot) : ''
  return `${e[0]}***@${name ? name[0] : ''}***${tld}`
}

const EMAIL = /[^\s@"'<>(),;:]+@[^\s@"'<>(),;:]+/g

// Free text from cswap (error messages quote emails) with emails masked.
function maskEmails (text) {
  return String(text).replace(EMAIL, m => maskEmail(m))
}

function cleanAlias (alias) {
  if (typeof alias !== 'string') return null
  // eslint-disable-next-line no-control-regex
  const a = alias.replace(/[\u0000-\u001f\u007f]/g, '').trim().slice(0, 40)
  if (!a) return null
  return a.includes('@') ? maskEmails(a) : a
}

function isoMs (v) {
  const ms = typeof v === 'string' ? Date.parse(v) : NaN
  return Number.isFinite(ms) ? ms : null
}

function windowOf (w, now) {
  if (!w || typeof w !== 'object' || typeof w.pct !== 'number' || !Number.isFinite(w.pct)) return null
  const resetsAt = isoMs(w.resetsAt)
  return { usedPct: Math.max(0, Math.min(100, w.pct)), resetsAt, expired: !!(resetsAt && resetsAt <= now) }
}

// `cswap list --json` (schemaVersion 1) -> { activeSlot, accounts }, or null
// for anything else.
function parseList (obj, now = Date.now()) {
  if (!obj || typeof obj !== 'object' || !Array.isArray(obj.accounts)) return null
  const accounts = []
  for (const a of obj.accounts) {
    if (!a || typeof a !== 'object' || !Number.isInteger(a.number)) continue
    // `usage` is decision-grade (fresh); `lastGoodUsage` is the last good
    // measurement, shown as stale.
    const fresh = a.usage && typeof a.usage === 'object'
    const u = fresh ? a.usage : (a.lastGoodUsage && typeof a.lastGoodUsage === 'object' ? a.lastGoodUsage : null)
    const alias = cleanAlias(a.alias)
    const limits = {}
    const five = windowOf(u && u.fiveHour, now)
    const week = windowOf(u && u.sevenDay, now)
    if (five) limits['5h'] = five
    if (week) limits['7d'] = week
    const row = {
      slot: a.number,
      alias,
      label: alias || maskEmail(a.email) || `Account ${a.number}`,
      active: a.active === true,
      disabled: a.disabled === true,
      status: typeof a.usageStatus === 'string' ? a.usageStatus.slice(0, 32) : null,
      limits
    }
    if (u && !fresh) row.stale = true
    const at = isoMs(fresh ? a.usageFetchedAt : a.lastGoodFetchedAt)
    if (at) row.usageAt = at
    const perModel = []
    for (const s of (u && Array.isArray(u.scoped) ? u.scoped : [])) {
      const w = windowOf(s, now)
      if (w && s && typeof s.name === 'string') perModel.push({ model: s.name.slice(0, 40), ...w })
    }
    if (perModel.length) row.perModel = perModel
    accounts.push(row)
  }
  accounts.sort((x, y) => x.slot - y.slot)
  const activeSlot = Number.isInteger(obj.activeAccountNumber) ? obj.activeAccountNumber : (accounts.find(a => a.active) || {}).slot ?? null
  return { activeSlot, accounts }
}

// Runs cswap in its own process group. Resolves { code, stdout, timedOut,
// spawnError }; stderr is dropped (it may name accounts).
function run (bin, args, { timeoutMs, env = process.env }) {
  return new Promise(resolve => {
    let child
    try {
      child = spawn(bin, args, { env, stdio: ['ignore', 'pipe', 'ignore'], detached: true })
    } catch (err) {
      return resolve({ spawnError: err })
    }
    // Background work, whatever the caller's priority.
    try { os.setPriority(child.pid, Math.max(10, os.getPriority(0))) } catch {}
    let stdout = ''
    let timedOut = false
    let settled = false
    child.stdout.setEncoding('utf8')
    child.stdout.on('data', d => { if (stdout.length < MAX_OUTPUT) stdout += d })
    const kill = () => {
      try { process.kill(-child.pid, 'SIGKILL') } catch { try { child.kill('SIGKILL') } catch {} }
    }
    const settle = r => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      resolve(r)
    }
    const timer = setTimeout(() => {
      timedOut = true
      kill()
      // Do not wait for pipes a straggler may hold open.
      settle({ code: null, stdout: '', timedOut })
    }, timeoutMs)
    child.on('error', err => settle({ spawnError: err }))
    child.on('close', code => settle({ code, stdout, timedOut }))
  })
}

// The last JSON object cswap printed.
function parseJson (stdout) {
  const text = String(stdout || '').trim()
  if (!text) return null
  try { return JSON.parse(text) } catch {}
  const lines = text.split('\n')
  for (let i = lines.length - 1; i >= 0; i--) {
    try { return JSON.parse(lines[i]) } catch {}
  }
  return null
}

function readCache (file) {
  if (!file) return null
  try {
    const c = JSON.parse(fs.readFileSync(file, 'utf8'))
    return c && c.v === CACHE_VERSION && Number.isFinite(c.at) ? c : null
  } catch {
    return null
  }
}

function writeCache (file, cache) {
  if (!file) return
  try {
    const tmp = `${file}.${process.pid}.tmp`
    fs.writeFileSync(tmp, JSON.stringify({ v: CACHE_VERSION, ...cache }), { mode: 0o600 })
    fs.renameSync(tmp, file)
  } catch {}
}

function forget (file) {
  if (file) try { fs.unlinkSync(file) } catch {}
}

// opts: { env, now, cacheFile, bin (tests; null = absent), timeoutMs,
//         ttlMs, runner (tests) }
// Resolves null without cswap, else
// { present: true, activeSlot, accounts, fetchedAt, stale?, error? }.
async function accounts (opts = {}) {
  const env = opts.env || process.env
  const bin = opts.bin !== undefined ? opts.bin : findCswap(env)
  if (!bin) return null
  const now = opts.now || Date.now()
  const ttl = opts.ttlMs ?? TTL_MS
  const cached = readCache(opts.cacheFile)
  const usable = cached && cached.bin === bin && cached.at <= now ? cached : null
  const lastGood = usable && usable.data && usable.goodAt && now - usable.goodAt < STALE_MAX_MS ? usable : null
  const answer = (data, fetchedAt, extra) => ({ present: true, activeSlot: data.activeSlot, accounts: data.accounts, fetchedAt, ...extra })
  if (usable && now - usable.at < ttl) {
    if (!usable.failed) return answer(usable.data, usable.goodAt)
    if (lastGood) return answer(lastGood.data, lastGood.goodAt, { stale: true })
    return { present: true, activeSlot: null, accounts: [], fetchedAt: null, error: 'unavailable' }
  }
  const r = await (opts.runner || run)(bin, ['list', '--json'], { timeoutMs: opts.timeoutMs || LIST_TIMEOUT_MS, env })
  const data = !r.spawnError && !r.timedOut && r.code === 0 ? parseList(parseJson(r.stdout), now) : null
  if (data) {
    writeCache(opts.cacheFile, { bin, at: now, goodAt: now, data })
    return answer(data, now)
  }
  // Remember the failure for a TTL, keeping the last good rows.
  writeCache(opts.cacheFile, { bin, at: now, failed: true, goodAt: lastGood ? lastGood.goodAt : null, data: lastGood ? lastGood.data : null })
  const error = r.timedOut ? 'timeout' : 'unavailable'
  if (lastGood) return answer(lastGood.data, lastGood.goodAt, { stale: true, error })
  return { present: true, activeSlot: null, accounts: [], fetchedAt: null, error }
}

// `cswap switch <slot> --json` or `cswap switch --strategy best --json`.
// Resolves { ok: true, switched, reason, from, to } with { slot, label }
// refs, or { ok: false, error, message } (emails masked).
async function switchAccount (opts = {}) {
  const env = opts.env || process.env
  const bin = opts.bin !== undefined ? opts.bin : findCswap(env)
  if (!bin) return { ok: false, error: 'cswap-missing', message: 'cswap is not installed on this machine' }
  const args = opts.best ? ['switch', '--strategy', 'best', '--json'] : ['switch', String(opts.slot), '--json']
  const r = await (opts.runner || run)(bin, args, { timeoutMs: opts.timeoutMs || SWITCH_TIMEOUT_MS, env })
  // Whatever happened, the next `usage` asks cswap again.
  forget(opts.cacheFile)
  if (r.spawnError) return { ok: false, error: 'failed', message: maskEmails(r.spawnError.message) }
  if (r.timedOut) return { ok: false, error: 'timeout', message: 'cswap did not answer in time' }
  const o = parseJson(r.stdout)
  if (o && o.error && typeof o.error === 'object') {
    return { ok: false, error: 'failed', message: maskEmails(o.error.message || o.error.type || 'cswap failed').slice(0, 300) }
  }
  if (!o || typeof o.switched !== 'boolean') return { ok: false, error: 'failed', message: `cswap exited with ${r.code}` }
  // Labels as `usage` shows them: the alias from a fresh list, else the
  // masked email.
  let aliases = new Map()
  const listed = await accounts({ ...opts, bin, ttlMs: 0 })
  if (listed) aliases = new Map(listed.accounts.map(a => [a.slot, a.label]))
  const ref = x => x && typeof x === 'object'
    ? { slot: Number.isInteger(x.number) ? x.number : null, label: aliases.get(x.number) || maskEmail(x.email) }
    : null
  return {
    ok: true,
    switched: o.switched,
    reason: typeof o.reason === 'string' ? o.reason.slice(0, 40) : null,
    strategy: typeof o.strategy === 'string' ? o.strategy.slice(0, 40) : null,
    from: ref(o.from),
    to: ref(o.to)
  }
}

module.exports = { findCswap, maskEmail, maskEmails, parseList, parseJson, accounts, switchAccount, run, TTL_MS, STALE_MAX_MS }
