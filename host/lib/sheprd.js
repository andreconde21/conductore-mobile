'use strict'

// sheprd's project sidebar (andreconde21/sheprd, a client-side Herdr fork):
// `<herdr config dir>/sidebar.toml`, read-only, as JSON for the phone, so
// the app groups workspaces into the same projects. Never written here.
//
//   compact = false            active_only = false     recent_hours = 24
//   hidden = ["gpu-box/w3:scratch"]   ungrouped = [...]
//   [[group]] name, pinned, collapsed, match = [...], members = [...], short
//
// Only those keys are passed on (sheprd's unread/dismissed/kept marks stay
// on the machine). Members and hidden entries are `machine/<id>:<label>` or
// `machine/<label>`; `local` is the machine that holds the file.
//
// sheprd's view (CON-077, docs/sheprd-view-sync.md): `~/.local/state/sheprd/
// view.json`, written by sheprd (its client on the hub, its relay on every
// other machine), read here read-only; presence marks go back as lines
// appended to `view-updates.jsonl` next to it, which sheprd drains. Nothing
// else on disk is touched.

const crypto = require('crypto')
const fs = require('fs')
const os = require('os')
const path = require('path')
const toml = require('./toml-lite')

// Herdr's config_dir(): $XDG_CONFIG_HOME/herdr, else ~/.config/herdr.
function sidebarPath (env = process.env, home = os.homedir()) {
  const xdg = env.XDG_CONFIG_HOME
  const base = xdg && path.isAbsolute(xdg) ? xdg : path.join(home, '.config')
  return path.join(base, 'herdr', 'sidebar.toml')
}

const MAX_GROUPS = 200
const MAX_LIST = 2000
const MAX_TEXT = 512

const text = v => (typeof v === 'string' && v.length <= MAX_TEXT ? v : null)
const strings = v => Array.isArray(v) ? v.filter(s => text(s) !== null).slice(0, MAX_LIST) : []

// The keys the app uses, checked and capped.
function pick (raw) {
  const out = {}
  for (const k of ['compact', 'active_only', 'show_hidden', 'other_collapsed']) {
    if (typeof raw[k] === 'boolean') out[k] = raw[k]
  }
  if (Number.isSafeInteger(raw.recent_hours) && raw.recent_hours > 0 && raw.recent_hours <= 24 * 365) {
    out.recent_hours = raw.recent_hours
  }
  out.hidden = strings(raw.hidden)
  out.ungrouped = strings(raw.ungrouped)
  out.group = []
  for (const g of Array.isArray(raw.group) ? raw.group.slice(0, MAX_GROUPS) : []) {
    if (!g || typeof g !== 'object' || Array.isArray(g)) continue
    const name = text(g.name)
    if (!name || !name.trim()) continue
    const group = { name, members: strings(g.members), match: strings(g.match) }
    if (g.pinned === true) group.pinned = true
    if (g.collapsed === true) group.collapsed = true
    if (text(g.short) && g.short.trim()) group.short = g.short
    out.group.push(group)
  }
  return out
}

// { found: false } | { found: true, path, mtimeMs, layout } | { found: true, path, error }
function readLayout ({ file = sidebarPath() } = {}) {
  let st
  try { st = fs.statSync(file) } catch { return { found: false } }
  if (!st.isFile()) return { found: false }
  const shown = file.startsWith(os.homedir() + path.sep) ? '~' + file.slice(os.homedir().length) : file
  if (st.size > toml.MAX_BYTES) return { found: true, path: shown, error: 'sidebar.toml is too large' }
  try {
    const raw = toml.parse(fs.readFileSync(file, 'utf8'))
    return { found: true, path: shown, mtimeMs: Math.round(st.mtimeMs), layout: pick(raw) }
  } catch (err) {
    return { found: true, path: shown, error: `sidebar.toml: ${err.message}` }
  }
}

// sheprd's view (contract v1).

const VIEW_VERSION = 1
const VIEW_MAX_BYTES = 1024 * 1024
const UPDATES_MAX_BYTES = 256 * 1024
const LINE_MAX_BYTES = 1024
const MAX_AGENTS = 2000
const STALE_SECS = 120
const LOCK_STALE_MS = 10000
const LOCK_WAIT_MS = 2000
const PRESENCE = ['blocked', 'unread', 'done', 'working', 'idle']
const OPS = ['unread', 'read', 'dismiss', 'keep', 'unkeep']
// `machine/pane_id` as sheprd's hub names it: the machine is a lower-cased
// endpoint label (no slash, no control characters), the pane a herdr id.
const MACHINE = /^[^/\u0000-\u001f\u007f]{1,64}$/
const AGENT_KEY = /^[^/\u0000-\u001f\u007f]{1,64}\/[A-Za-z0-9:._-]{1,64}$/

// Fixed, like sheprd-msg's state: never XDG, never configurable.
function stateDir (home = os.homedir()) {
  return path.join(home, '.local', 'state', 'sheprd')
}

const shortText = (v, max = 64) => typeof v === 'string' && v.length > 0 && v.length <= max ? v : null
const seqOf = v => Number.isSafeInteger(v) && v >= 0 ? v : null

// view.json's v1 content, checked and capped; throws on what it cannot use.
function checkView (raw) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) throw new Error('not an object')
  if (raw.version !== VIEW_VERSION) throw new Error(`unsupported version ${JSON.stringify(raw.version)}`)
  const updated = seqOf(raw.updated)
  if (updated === null) throw new Error('updated is missing')
  const self = shortText(raw.self)
  if (!self || !MACHINE.test(self)) throw new Error('self is missing')
  const layout = raw.layout && typeof raw.layout === 'object' && !Array.isArray(raw.layout) ? raw.layout : {}
  const agents = {}
  const rawAgents = raw.agents && typeof raw.agents === 'object' && !Array.isArray(raw.agents) ? raw.agents : {}
  for (const [key, a] of Object.entries(rawAgents)) {
    if (Object.keys(agents).length >= MAX_AGENTS) break
    if (!AGENT_KEY.test(key) || !a || typeof a !== 'object') continue
    if (!PRESENCE.includes(a.presence)) continue
    agents[key] = {
      presence: a.presence,
      state_seq: seqOf(a.state_seq),
      unread: a.unread === true,
      dismissed: a.dismissed === true,
      kept: a.kept === true
    }
  }
  return {
    version: VIEW_VERSION,
    updated,
    source: shortText(raw.source),
    hub: shortText(raw.hub),
    self: self.toLowerCase(),
    layout: pick(layout),
    agents,
    order: strings(raw.order),
    focus: typeof raw.focus === 'string' && AGENT_KEY.test(raw.focus) ? raw.focus : null
  }
}

const shownPath = file => file.startsWith(os.homedir() + path.sep) ? '~' + file.slice(os.homedir().length) : file

// { found: false } | { found: true, path, stale, view } | { found: true, path, error }
function readView ({ dir = stateDir(), now = Date.now() } = {}) {
  const file = path.join(dir, 'view.json')
  let st
  try { st = fs.lstatSync(file) } catch { return { found: false } }
  const shown = shownPath(file)
  if (!st.isFile()) return { found: true, path: shown, error: 'view.json is not a regular file' }
  if (st.size > VIEW_MAX_BYTES) return { found: true, path: shown, error: 'view.json is too large' }
  try {
    const view = checkView(JSON.parse(fs.readFileSync(file, 'utf8')))
    return { found: true, path: shown, stale: Math.floor(now / 1000) - view.updated > STALE_SECS, view }
  } catch (err) {
    return { found: true, path: shown, error: `view.json: ${err.message}` }
  }
}

const sleepSync = ms => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms)

// The lock both sides use (Node has no flock): view-updates.lock made with
// O_EXCL; one older than LOCK_STALE_MS was left by a crash and is taken over.
function withLock (dir, fn, { waitMs = LOCK_WAIT_MS } = {}) {
  const lock = path.join(dir, 'view-updates.lock')
  const until = Date.now() + waitMs
  for (;;) {
    try {
      const fd = fs.openSync(lock, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW, 0o600)
      try { fs.writeSync(fd, String(process.pid)) } finally { fs.closeSync(fd) }
      break
    } catch (err) {
      if (err.code !== 'EEXIST') throw err
      let st = null
      try { st = fs.lstatSync(lock) } catch {}
      if (st && st.isFile() && Date.now() - st.mtimeMs > LOCK_STALE_MS) {
        try { fs.unlinkSync(lock) } catch {}
        continue
      }
      if (Date.now() >= until) throw new Error('view-updates.lock is held; try again')
      sleepSync(50)
    }
  }
  try { return fn() } finally { try { fs.unlinkSync(lock) } catch {} }
}

// The v1 line for one presence change; throws on bad input.
function updateLine ({ op, agent, stateSeq, now = Date.now(), id }) {
  if (!OPS.includes(op)) throw new Error(`op must be one of ${OPS.join(', ')}`)
  if (typeof agent !== 'string' || !AGENT_KEY.test(agent)) throw new Error('agent must be machine/pane_id')
  const seq = stateSeq === undefined || stateSeq === null ? null : seqOf(stateSeq)
  if (stateSeq !== undefined && stateSeq !== null && seq === null) throw new Error('state-seq must be a whole number')
  if (op === 'dismiss' && seq === null) throw new Error('dismiss needs --state-seq')
  const entry = { v: VIEW_VERSION, id: id || `c-${now}-${crypto.randomBytes(4).toString('hex')}`, at: Math.floor(now / 1000), from: 'conductore', op, agent }
  if (op === 'dismiss') entry.state_seq = seq
  const line = JSON.stringify(entry) + '\n'
  if (Buffer.byteLength(line) > LINE_MAX_BYTES) throw new Error('update is too long')
  return { id: entry.id, line }
}

// Appends one update for sheprd: { ok: true, id } or throws. Creates the
// state dir (0700) and the file (0600) when missing; refuses symlinks, a
// file sheprd stopped draining, and anything but one append.
function appendUpdate ({ dir = stateDir(), ...input }) {
  const { id, line } = updateLine(input)
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 })
  const dirStat = fs.lstatSync(dir)
  if (!dirStat.isDirectory()) throw new Error(`${shownPath(dir)} is not a directory`)
  const file = path.join(dir, 'view-updates.jsonl')
  withLock(dir, () => {
    let st = null
    try { st = fs.lstatSync(file) } catch {}
    if (st && !st.isFile()) throw new Error('view-updates.jsonl is not a regular file')
    if (st && st.size >= UPDATES_MAX_BYTES) throw new Error('view-updates.jsonl is full: sheprd is not reading it (is it running?)')
    const fd = fs.openSync(file, fs.constants.O_WRONLY | fs.constants.O_APPEND | fs.constants.O_CREAT | fs.constants.O_NOFOLLOW, 0o600)
    try { fs.writeSync(fd, line) } finally { fs.closeSync(fd) }
  })
  return { ok: true, id }
}

module.exports = { sidebarPath, readLayout, pick, stateDir, checkView, readView, updateLine, appendUpdate, withLock, OPS, UPDATES_MAX_BYTES }
