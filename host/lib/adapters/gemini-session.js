'use strict'

// Gemini CLI's session files (CON-072): `~/.gemini/tmp/<project>/chats/
// session-<time>-<id8>.jsonl`, JSONL since Gemini CLI 0.39. Checked
// against what Gemini CLI 0.62.0 wrote in Docker (test/fixtures/gemini).
//
// The file is a log, not a list: line 1 is the session's metadata, then
//   { id, timestamp, type, content, ... }   a message; the same id again
//                    later replaces it (a reply is written first with its
//                    text, then again with its toolCalls and their status)
//   { $set: {...} }  metadata; `$set.messages` replaces the whole history
//                    Gemini resumes from (written at start and whenever
//                    Gemini rolls its history back, e.g. after a prompt
//                    was cancelled in the terminal)
//   { $rewindTo: id }  /rewind: that message and everything after it go
// Types: user, gemini (content, thoughts[], toolCalls[], tokens, model),
// info, error, warning.
//
// The chat shows what happened, so a `$set.messages` rollback does not
// remove the cancelled turn here. Gemini re-records the rolled back
// history as new messages (new ids, same moment, no `model`) just before
// that `$set`: those copies are hidden. A `$rewindTo` is applied (the
// user asked for it).

const fs = require('fs')
const path = require('path')
const items = require('./chat-items')

// Whole-file reads: messages are rewritten by id, so a page needs the
// file's state, not one byte range. A larger file is read from its last
// MAX_BYTES (older messages are then missing).
const MAX_BYTES = 32 * 1024 * 1024
const PAGE_ITEMS = 300
// A rolled back history is re-recorded within this long before its `$set`.
const REPLAY_MS = 5000

const IGNORED_USER = /^\s*<(session_context|hook_context)>/

// --- reading the log --------------------------------------------------------------

function readFile (file) {
  const fd = fs.openSync(file, 'r')
  try {
    const size = fs.fstatSync(fd).size
    const start = Math.max(0, size - MAX_BYTES)
    const buf = Buffer.alloc(size - start)
    let got = 0
    while (got < buf.length) {
      const n = fs.readSync(fd, buf, got, buf.length - got, start + got)
      if (n === 0) break
      got += n
    }
    return { buf: buf.subarray(0, got), start, size }
  } finally {
    try { fs.closeSync(fd) } catch {}
  }
}

const timeOf = v => { const t = Date.parse(v); return Number.isFinite(t) ? t : null }

// The session's messages as shown: [{ rec, at, first, touched }] in the
// order they first appeared (`first`, `touched`: byte offsets of the first
// and the last line that wrote them), plus where the history was reset.
function parse (file) {
  const { buf, start, size } = readFile(file)
  const order = []
  const byId = new Map()
  const resets = [] // byte offsets of $rewindTo lines and rollbacks
  let meta = {}
  let lastHistorySet = -1
  let pos = 0
  if (start > 0) {
    const nl = buf.indexOf(0x0a)
    pos = nl === -1 ? buf.length : nl + 1
  }
  while (pos < buf.length) {
    let nl = buf.indexOf(0x0a, pos)
    if (nl === -1) break // a line still being written
    const off = start + pos
    const text = buf.toString('utf8', pos, nl)
    pos = nl + 1
    if (!text.trim()) continue
    let o
    try { o = JSON.parse(text) } catch { continue }
    if (!o || typeof o !== 'object' || Array.isArray(o)) continue
    if (typeof o.$rewindTo === 'string') {
      const idx = order.findIndex(m => m.rec.id === o.$rewindTo)
      const gone = idx === -1 ? order.splice(0) : order.splice(idx)
      for (const m of gone) byId.delete(m.rec.id)
      resets.push(off)
    } else if (typeof o.id === 'string' && o.id) {
      const known = byId.get(o.id)
      if (known) { known.rec = o; known.touched = off; known.at = timeOf(o.timestamp) ?? known.at } else {
        const m = { rec: o, at: timeOf(o.timestamp), first: off, touched: off }
        byId.set(o.id, m)
        order.push(m)
      }
    } else if (o.$set && typeof o.$set === 'object') {
      if (Array.isArray(o.$set.messages)) {
        // A history Gemini replaced: its copies are the messages recorded
        // just before (the run of listed messages at the end, after the
        // previous replacement, moments before this one, none of them a
        // reply of the model's own).
        const listed = new Set(o.$set.messages.map(m => m && m.id).filter(Boolean))
        const at = timeOf(o.$set.lastUpdated)
        let hidden = 0
        for (let i = order.length - 1; i >= 0; i--) {
          const m = order[i]
          if (m.hidden) continue
          if (!listed.has(m.rec.id) || m.first < lastHistorySet) break
          if (at !== null && m.at !== null && m.at >= at - REPLAY_MS && m.at <= at + REPLAY_MS && !hasModel(m.rec)) { m.hidden = true; hidden++ }
        }
        if (hidden) resets.push(off)
        lastHistorySet = off
      }
      const { messages, ...rest } = o.$set
      meta = { ...meta, ...rest }
    } else if (typeof o.sessionId === 'string') {
      meta = { ...meta, ...o }
    }
  }
  return { messages: order.filter(m => !m.hidden), meta, resets, size, end: start + pos, partial: start > 0 }
}

// Gemini's own replies carry the model; re-recorded copies do not.
const hasModel = rec => rec.type !== 'user' && typeof rec.model === 'string' && rec.model.length > 0

// --- messages -> chat items ----------------------------------------------------------

function partsText (content, { skipThought = true } = {}) {
  if (typeof content === 'string') return content
  if (!Array.isArray(content)) return ''
  return content.filter(p => p && typeof p.text === 'string' && !(skipThought && p.thought)).map(p => p.text).join('')
}

function userText (rec) {
  const text = partsText(rec.content)
  if (!text.trim() || IGNORED_USER.test(text)) return null
  return text
}

// Gemini's tool names onto the neutral kinds (chat-items.js TOOL_KINDS).
const TOOL_KINDS = {
  run_shell_command: 'bash',
  replace: 'edit',
  edit: 'edit',
  write_file: 'write',
  read_file: 'read',
  read_many_files: 'read',
  list_directory: 'search',
  glob: 'search',
  grep_search: 'search',
  search_file_content: 'search',
  web_fetch: 'web',
  google_web_search: 'web',
  write_todos: 'todo',
  ask_user: 'question',
  enter_plan_mode: 'plan',
  exit_plan_mode: 'plan',
  codebase_investigator: 'task',
  invoke_subagent: 'task'
}

function toolKind (name) {
  if (typeof name !== 'string' || !name) return 'other'
  if (Object.prototype.hasOwnProperty.call(TOOL_KINDS, name)) return TOOL_KINDS[name]
  if (name.startsWith('mcp_')) return 'mcp'
  return 'other'
}

// "<untrusted_context>\nOutput: …\nProcess Group PGID: 1\n</untrusted_context>"
// -> the output.
function cleanOutput (s) {
  return String(s)
    .replace(/<\/?untrusted_context>/g, '')
    .replace(/^\s*Process Group PGID: \d+\s*$/m, '')
    .replace(/^\s*Output: /, '')
    .replace(/^\s*\(empty\)\s*$/, '')
    .trim()
}

function responseOf (tc) {
  const parts = Array.isArray(tc.result) ? tc.result : []
  for (const p of parts) {
    const r = p && p.functionResponse && p.functionResponse.response
    if (!r || typeof r !== 'object') continue
    if (typeof r.error === 'string') return { error: r.error }
    if (typeof r.output === 'string') return { output: r.output }
  }
  return {}
}

// A finished call's result ({ ok, text }), null while it runs.
function resultOf (tc) {
  const status = tc.status
  if (status !== 'success' && status !== 'error' && status !== 'cancelled') return null
  const r = responseOf(tc)
  let text = typeof tc.resultDisplay === 'string' ? tc.resultDisplay : ''
  if (!text && r.output !== undefined) text = r.output
  if (status !== 'success') text = r.error || text || (status === 'cancelled' ? 'Cancelled' : 'Failed')
  return { ok: status === 'success', text: cleanOutput(text) }
}

function titleOf (tc) {
  const a = tc.args && typeof tc.args === 'object' ? tc.args : {}
  if (typeof a.command === 'string') return a.command
  for (const k of ['file_path', 'absolute_path', 'path', 'dir_path', 'pattern', 'url', 'query']) if (typeof a[k] === 'string' && a[k]) return a[k]
  return typeof tc.description === 'string' ? tc.description : null
}

const TODO = { pending: 'pending', in_progress: 'in_progress', completed: 'completed', cancelled: 'completed' }

function itemsOfMessage (m) {
  const rec = m.rec
  const id = rec.id
  const at = rec.timestamp
  const out = []
  if (rec.type === 'user') {
    const text = userText(rec)
    if (text !== null) {
      const images = Array.isArray(rec.content) ? rec.content.filter(p => p && p.inlineData).length : 0
      out.push(items.user(id, text, { at, images }))
    }
  } else if (rec.type === 'gemini') {
    if (!hasModel(rec)) return out
    if (Array.isArray(rec.thoughts) && rec.thoughts.length) out.push(items.thinking(`${id}:thinking`, { at }))
    const text = partsText(rec.content)
    if (text.trim()) out.push(items.assistant(id, text, { at }))
    for (const tc of Array.isArray(rec.toolCalls) ? rec.toolCalls : []) {
      if (!tc || typeof tc !== 'object') continue
      const tid = `${id}:${tc.id || tc.name}`
      const tat = tc.timestamp || at
      if (tc.name === 'write_todos' && tc.args && Array.isArray(tc.args.todos)) {
        out.push(items.todo(tid, tc.args.todos.map(t => ({ text: t && (t.description || t.content), status: TODO[t && t.status] || 'pending' })), { at: tat }))
        continue
      }
      out.push(items.tool(tid, { tool: tc.name, toolKind: toolKind(tc.name), input: tc.args, title: titleOf(tc), result: resultOf(tc), at: tat }))
    }
  } else if (rec.type === 'info' || rec.type === 'warning' || rec.type === 'error') {
    const text = partsText(rec.content)
    if (text.trim()) {
      const level = rec.type === 'error' ? 'error' : /cancel/i.test(text) ? 'interrupted' : 'info'
      out.push(items.notice(id, level, text, { at }))
    }
  }
  return out
}

// --- pages ----------------------------------------------------------------------------

const num = v => (typeof v === 'string' && /^\d{1,15}$/.test(v) ? Number(v) : typeof v === 'number' && Number.isInteger(v) && v >= 0 ? v : null)
const before = v => (typeof v === 'string' && /^i\d{1,9}$/.test(v) ? Number(v.slice(1)) : null)

// One `transcript` page (chat-items.js). The cursor is the file size read
// up to: the next page sends every item written since (an item rewritten
// under its id comes again; the app replaces it). startCursor `i<n>` is
// the item index the page starts at, for `--before-cursor`.
function readPage (file, opts = {}) {
  const limit = Math.max(1, Math.min(Number(opts.limit) || PAGE_ITEMS, 2000))
  if (opts.beforeCursor === undefined || opts.beforeCursor === null) {
    const since = num(opts.cursor)
    // Nothing new: answered from the size alone.
    if (since !== null && fs.statSync(file).size === since) return items.page({ items: [], cursor: since, startCursor: null })
  }
  const s = parse(file)
  const all = []
  for (const m of s.messages) for (const it of itemsOfMessage(m)) all.push({ it, touched: m.touched })

  if (opts.beforeCursor !== undefined && opts.beforeCursor !== null) {
    const end = Math.min(before(opts.beforeCursor) ?? 0, all.length)
    const from = Math.max(0, end - limit)
    return items.page({ items: all.slice(from, end).map(x => x.it), cursor: s.end, startCursor: from > 0 ? `i${from}` : null })
  }

  let since = num(opts.cursor)
  let reset = false
  if (since !== null && (since > s.size || s.resets.some(off => off >= since))) { since = null; reset = true }
  if (since === null) {
    const from = Math.max(0, all.length - limit)
    return items.page({ items: all.slice(from).map(x => x.it), cursor: s.end, startCursor: from > 0 ? `i${from}` : null, reset })
  }
  return items.page({ items: all.filter(x => x.touched >= since).map(x => x.it), cursor: s.end, startCursor: null })
}

// --- tokens ------------------------------------------------------------------------------

// A reply's tokens in the companion's shape: Gemini's input includes the
// cached part, and thoughts are billed as output.
function tokensOf (t) {
  const n = v => (typeof v === 'number' && v > 0 ? v : 0)
  if (!t || typeof t !== 'object') return null
  const cacheRead = n(t.cached)
  const input = Math.max(0, n(t.input) - cacheRead)
  const output = n(t.output) + n(t.thoughts)
  return { input, output, cacheWrite: 0, cacheRead, total: input + output + cacheRead }
}

// --- dashboard tail -------------------------------------------------------------------

// The session's recent prompts, replies, command runs and tokens for the
// dashboard (types.js Tail, the shape digest.js readTail returns).
function readTail (file, { since, repliesSince = since, runsSince = since } = {}) {
  const out = { tokens: null, costUsd: null, replies: [], prompts: [], lastReply: null, runs: [], apiError: null, first: null, partial: false }
  let s
  try { s = parse(file) } catch { return out }
  const tk = { input: 0, output: 0, cacheWrite: 0, cacheRead: 0, total: 0 }
  let counted = false
  for (const m of s.messages) {
    const rec = m.rec
    const t = m.at
    if (t === null) continue
    if (out.first === null) out.first = t
    if (rec.type === 'user') {
      const text = userText(rec)
      if (text !== null) {
        out.apiError = null
        if (t >= repliesSince) out.prompts.push({ at: t, text: text.trim() })
      }
    } else if (rec.type === 'gemini' && hasModel(rec)) {
      const u = tokensOf(rec.tokens)
      if (u && t >= since) {
        counted = true
        tk.input += u.input; tk.output += u.output; tk.cacheRead += u.cacheRead; tk.total += u.total
      }
      const text = partsText(rec.content).trim()
      if (text) {
        out.lastReply = text
        if (t >= repliesSince) out.replies.push({ at: t, text })
      }
      for (const tc of Array.isArray(rec.toolCalls) ? rec.toolCalls : []) {
        const r = tc && resultOf(tc)
        const tt = timeOf(tc && tc.timestamp) ?? t
        if (!r || tt < runsSince || tc.status === 'cancelled') continue
        const command = tc.name === 'run_shell_command' && tc.args && typeof tc.args.command === 'string' ? tc.args.command : null
        if (command || !r.ok) out.runs.push({ at: tt, ok: r.ok, command, what: command || tc.name, error: r.ok ? null : (r.text.split('\n').pop() || 'error').slice(0, 80) })
      }
    } else if (rec.type === 'error') {
      out.apiError = { at: t, type: errorType(partsText(rec.content)) }
    }
  }
  if (counted) out.tokens = tk
  out.partial = s.partial && out.first !== null && out.first > since
  out.replies = out.replies.slice(-3)
  out.prompts = out.prompts.slice(-2)
  return out
}

function errorType (text) {
  const s = String(text || '').toLowerCase()
  if (/quota|rate.?limit|\b429\b|resource.?exhausted/.test(s)) return 'rate_limit'
  if (/overload|\b503\b|unavailable/.test(s)) return 'overloaded'
  if (/auth|\b401\b|\b403\b|log ?in|api key/.test(s)) return 'authentication_failed'
  if (/\b5\d\d\b/.test(s)) return 'server_error'
  return 'unknown'
}

// --- an observed permission prompt ---------------------------------------------------

// Whether the terminal already answered the prompt that showed at
// `sinceMs` for `toolName`: 'ran' (a call of that tool finished after it,
// so it was allowed), 'cancelled' (refused: Gemini cancels the turn, and
// no hook says so), or null (still waiting, or nothing to tell).
function promptOutcome (file, toolName, sinceMs) {
  let s
  try { s = parse(file) } catch { return null }
  for (let i = s.messages.length - 1; i >= 0; i--) {
    const rec = s.messages[i].rec
    for (const tc of Array.isArray(rec.toolCalls) ? rec.toolCalls : []) {
      const t = timeOf(tc && tc.timestamp)
      if (!tc || t === null || t < sinceMs) continue
      if (toolName && tc.name !== toolName) continue
      if (tc.status === 'cancelled') return 'cancelled'
      if (tc.status === 'success' || tc.status === 'error') return 'ran'
    }
    const at = s.messages[i].at
    if (at !== null && at < sinceMs - 60000) break
  }
  return null
}

// --- usage history ------------------------------------------------------------------------

// Session files modified on or after `fromMs`: [{ file, dir }] where dir is
// the project directory (projects.json maps directories to their slugs).
function sessionFiles (geminiDir, fromMs) {
  const tmp = path.join(geminiDir, 'tmp')
  const dirOf = new Map()
  try {
    const reg = JSON.parse(fs.readFileSync(path.join(geminiDir, 'projects.json'), 'utf8'))
    for (const [dir, slug] of Object.entries((reg && reg.projects) || {})) if (typeof slug === 'string') dirOf.set(slug, dir)
  } catch {}
  const out = []
  let slugs = []
  try { slugs = fs.readdirSync(tmp) } catch { return out }
  for (const slug of slugs) {
    const chats = path.join(tmp, slug, 'chats')
    let names = []
    try { names = fs.readdirSync(chats) } catch { continue }
    for (const name of names) {
      if (!/^session-.*\.jsonl$/.test(name)) continue
      const file = path.join(chats, name)
      let st
      try { st = fs.statSync(file) } catch { continue }
      if (st.mtimeMs < fromMs) continue
      let dir = dirOf.get(slug) || null
      if (!dir) { try { dir = fs.readFileSync(path.join(tmp, slug, '.project_root'), 'utf8').trim() || null } catch {} }
      out.push({ file, dir: dir || slug })
    }
  }
  return out
}

// The `gemini` section of `usage`: tokens per day, project and model from
// the session files (Gemini CLI keeps no other record). No prices and no
// plan limits: Gemini CLI reports neither.
function usageReport (geminiDir, { range, projectOf, localDate, detail = {} }) {
  if (!fs.existsSync(geminiDir)) return { present: false }
  const fromMs = new Date(`${range.from < range.today ? range.from : range.today}T00:00:00`).getTime()
  const zero = () => ({ input: 0, output: 0, cacheWrite: 0, cacheRead: 0, tokens: 0, messages: 0, costUsd: 0 })
  const totals = zero()
  const today = zero()
  const rows = new Map()
  const bySession = new Map()
  let active = null
  for (const { file, dir } of sessionFiles(geminiDir, fromMs)) {
    let s
    try { s = parse(file) } catch { continue }
    const project = projectOf(dir)
    for (const m of s.messages) {
      const rec = m.rec
      if (rec.type !== 'gemini' || !hasModel(rec) || m.at === null || m.at < fromMs) continue
      const u = tokensOf(rec.tokens)
      if (!u) continue
      if (!active || m.at > active.at) active = { at: m.at, model: rec.model }
      const day = localDate(m.at)
      const add = t => { t.input += u.input; t.output += u.output; t.cacheRead += u.cacheRead; t.tokens += u.total; t.messages++ }
      if (day === range.today) add(today)
      if (day < range.from || day > range.to) continue
      add(totals)
      const row = (map, key, base) => { const r = map.get(key) || { ...base, input: 0, output: 0, cacheWrite: 0, cacheRead: 0, messages: 0, costUsd: 0 }; r.input += u.input; r.output += u.output; r.cacheRead += u.cacheRead; r.messages++; map.set(key, r) }
      row(rows, `${day}\t${project}\t${rec.model}`, { date: day, project, model: rec.model })
      if (detail.sessions) row(bySession, `${day}\t${s.meta.sessionId || file}\t${rec.model}`, { date: day, session: s.meta.sessionId || path.basename(file), project, model: rec.model })
    }
  }
  const byTokens = (a, b) => (a.date === b.date ? (b.input + b.output) - (a.input + a.output) : a.date < b.date ? -1 : 1)
  const out = {
    present: true,
    limits: [],
    // No list prices for Gemini models here: tokens only.
    costSource: 'none',
    active: active ? { model: active.model, at: active.at } : null,
    today,
    range: totals,
    rows: [...rows.values()].sort(byTokens)
  }
  if (detail.sessions) out.bySession = [...bySession.values()].sort(byTokens)
  return out
}

module.exports = { parse, readPage, readTail, toolKind, itemsOfMessage, tokensOf, promptOutcome, usageReport, sessionFiles, cleanOutput, MAX_BYTES }
