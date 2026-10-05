'use strict'

// Codex's session file ("rollout", $CODEX_HOME/sessions/YYYY/MM/DD/
// rollout-<time>-<thread id>.jsonl) read into the neutral chat items
// (chat-items.js) and the dashboard tail (types.js Tail). Checked against
// real files of Codex 0.160.0 (paginated history) and 0.130.0 (legacy):
// test/fixtures/codex/.
//
// Every line is an envelope { timestamp, type, payload }. What is read:
//
//   response_item  message (role user | assistant | developer), reasoning,
//                  function_call / custom_tool_call (+ their *_output by
//                  call_id), local_shell_call, web_search_call. Written in
//                  both history modes, so tools, replies and thinking come
//                  from here.
//   event_msg      the user's own prompt: `item_completed` UserMessage
//                  (paginated, 0.145+) or `user_message` (legacy); the
//                  response_item user messages also carry the injected
//                  context (AGENTS.md, environment), so they are not used.
//                  `item_completed` CommandExecution / FileChange refine a
//                  tool's result; `turn_aborted`, `error` become notices;
//                  `token_count` the tail's tokens.
//   compacted      a "context compacted" notice.
//
// Anything else (session_meta, turn_context, world_state,
// token_usage_record, ...) is skipped without parsing.
//
// Paging is by byte offset, sent as an opaque string cursor. Item ids are
// the byte offset of their line (stable: the file only grows), tools use
// their call id, so a tool re-read with its result replaces the running
// one in the app. A page never ends after a call whose result has not
// been written yet: its cursor stays on that call, so the next read
// returns it again, finished. A call whose result lies past the page is
// finished from the lines after it.

const fs = require('fs')
const items = require('./chat-items')

const DEFAULT_MAX_BYTES = 256 * 1024
const MAX_MAX_BYTES = 4 * 1024 * 1024
const TAIL_BYTES = 512 * 1024
const HEAD_MAX = 1024 * 1024
const CHUNK = 64 * 1024

// Codex's tool names onto the neutral kinds the phone draws.
const TOOL_KINDS = {
  exec_command: 'bash',
  shell: 'bash',
  shell_command: 'bash',
  local_shell_call: 'bash',
  'container.exec': 'bash',
  write_stdin: 'bash',
  apply_patch: 'edit',
  view_image: 'read',
  web_search: 'web',
  web_search_call: 'web',
  request_user_input: 'question',
  spawn_agent: 'task',
  send_input: 'task',
  wait: 'task',
  close_agent: 'task',
  update_plan: 'todo'
}

function toolKind (name) {
  if (typeof name !== 'string' || !name) return 'other'
  if (Object.prototype.hasOwnProperty.call(TOOL_KINDS, name)) return TOOL_KINDS[name]
  return name.startsWith('mcp__') ? 'mcp' : 'other'
}

// --- file access ----------------------------------------------------------------

function readRange (fd, start, length) {
  const buf = Buffer.alloc(Math.max(0, length))
  let got = 0
  while (got < buf.length) {
    const n = fs.readSync(fd, buf, got, buf.length - got, start + got)
    if (n === 0) break
    got += n
  }
  return buf.subarray(0, got)
}

// The offset just past the newline that ends the line holding `pos`, or
// `size` when the file ends first.
function nextLineStart (fd, pos, size) {
  while (pos < size) {
    const buf = readRange(fd, pos, Math.min(CHUNK, size - pos))
    const nl = buf.indexOf(0x0a)
    if (nl !== -1) return pos + nl + 1
    pos += buf.length
    if (!buf.length) break
  }
  return size
}

// Whether the session writes paginated history (session_meta, the first
// line, says so since 0.145). Cached per file: it never changes.
const modes = new Map()

function isPaginated (fd, file) {
  if (modes.has(file)) return modes.get(file)
  let head = Buffer.alloc(0)
  let nl = -1
  while (nl === -1 && head.length < HEAD_MAX) {
    const more = readRange(fd, head.length, CHUNK)
    if (!more.length) break
    head = Buffer.concat([head, more])
    nl = head.indexOf(0x0a)
  }
  let paginated = false
  if (nl !== -1) {
    try {
      const meta = JSON.parse(head.subarray(0, nl).toString('utf8'))
      paginated = !!(meta && meta.type === 'session_meta' && meta.payload && meta.payload.history_mode === 'paginated')
    } catch {}
    if (modes.size > 200) modes.delete(modes.keys().next().value)
    modes.set(file, paginated)
  }
  return paginated
}

// Complete lines of buf as [{ offset, text }] (offset = file position).
function linesOf (buf, base) {
  const out = []
  let from = 0
  while (from < buf.length) {
    const nl = buf.indexOf(0x0a, from)
    if (nl === -1) break
    if (nl > from) out.push({ offset: base + from, text: buf.subarray(from, nl).toString('utf8') })
    from = nl + 1
  }
  return { lines: out, end: base + from }
}

// Only these lines are parsed at all.
const WANTED = /^\{"timestamp":"[^"]*",(?:"ordinal":\d+,)?"type":"(?:response_item|event_msg|compacted)"/
const wanted = text => WANTED.test(text) || /"type":"(?:response_item|event_msg|compacted)"/.test(text)

function parseLine (text) {
  if (!wanted(text)) return null
  try {
    const o = JSON.parse(text)
    return o && typeof o === 'object' && o.payload && typeof o.payload === 'object' ? o : null
  } catch { return null }
}

// --- one line into items ---------------------------------------------------------

const textOfContent = (content, types) => (Array.isArray(content)
  ? content.filter(c => c && types.includes(c.type) && typeof c.text === 'string').map(c => c.text).join('\n')
  : '')

function parseArgs (s) {
  if (s && typeof s === 'object') return s
  if (typeof s !== 'string') return {}
  try { const v = JSON.parse(s); return v && typeof v === 'object' && !Array.isArray(v) ? v : { input: s } } catch { return { input: s } }
}

// "*** Add File: a.txt" ... -> ['a.txt'] (every file a patch touches).
function patchFiles (patch) {
  const files = []
  if (typeof patch !== 'string') return files
  // Every path the patch writes, a rename's new name too.
  for (const m of patch.matchAll(/^\*\*\* (?:Add File|Update File|Delete File|Move to): (.+)$/gm)) {
    const f = m[1].trim()
    if (f && !files.includes(f)) files.push(f)
  }
  return files
}

const commandText = c => (Array.isArray(c) ? (c.length >= 3 && /(^|\/)(ba|z|da)?sh$/.test(c[0]) && c[1] === '-lc' ? c.slice(2).join(' ') : c.join(' ')) : typeof c === 'string' ? c : '')

// A tool call's display: { tool, toolKind, input, title }.
function describeCall (name, args) {
  const kind = toolKind(name)
  if (kind === 'bash') {
    const cmd = name === 'write_stdin' ? null : commandText(args.cmd !== undefined ? args.cmd : args.command)
    if (cmd === null) return { tool: name, toolKind: kind, input: args, title: 'Write to a running command' }
    const input = { command: cmd }
    if (typeof args.workdir === 'string') input.workdir = args.workdir
    if (typeof args.justification === 'string') input.description = args.justification
    return { tool: name, toolKind: kind, input, title: cmd }
  }
  if (name === 'apply_patch') {
    const patch = typeof args.input === 'string' ? args.input : typeof args.patch === 'string' ? args.patch : ''
    const files = patchFiles(patch)
    return { tool: name, toolKind: kind, input: { files, patch }, title: files.length ? `Edit ${files.join(', ')}` : 'Edit files' }
  }
  const title = ['path', 'query', 'message', 'objective'].map(k => args[k]).find(v => typeof v === 'string' && v)
  return { tool: name, toolKind: kind, input: args, title: title || undefined }
}

// A tool output's { ok, text }: exec_command's text header, apply_patch's
// "Exit code", the legacy shell tool's JSON, else the text as is.
function resultOf (output) {
  let text = typeof output === 'string' ? output : output && typeof output.content === 'string' ? output.content : output && Array.isArray(output) ? textOfContent(output, ['input_text', 'output_text', 'text']) : ''
  if (/^\s*\{/.test(text)) {
    try {
      const j = JSON.parse(text)
      if (j && typeof j.output === 'string') {
        const code = j.metadata && typeof j.metadata.exit_code === 'number' ? j.metadata.exit_code : 0
        return { ok: code === 0, text: j.output }
      }
    } catch {}
  }
  const exit = /(?:Process exited with code|Exit code:) (-?\d+)/.exec(text)
  const body = /\nOutput:\n([\s\S]*)$/.exec(text)
  if (body) text = body[1]
  if (exit) return { ok: Number(exit[1]) === 0, text }
  return { ok: !/^(?:\S+ failed:|unsupported call|aborted|error:)/i.test(text.trim()), text }
}

// Builds the items of a run of lines. `paginated` picks which user
// message source is the user's own.
function build (lines, paginated) {
  const out = []
  const calls = new Map() // call id -> { item, offset }
  const refined = new Map() // call id -> { ok, text } from item_completed
  const finish = (call, result) => {
    const done = items.tool(call.item.id, { ...call.desc, at: call.item.at, result })
    out[out.indexOf(call.item)] = done
    call.item = done
    call.done = true
  }
  const abandon = (at, why) => {
    for (const call of calls.values()) if (!call.done) finish(call, { ok: false, text: why })
  }
  for (const { offset, text } of lines) {
    const o = parseLine(text)
    if (!o) continue
    const p = o.payload
    const at = o.timestamp
    const id = String(offset)
    if (o.type === 'compacted') { out.push(items.notice(id, 'compacted', 'Context compacted', { at })); continue }
    if (o.type === 'event_msg') {
      if (paginated && p.type === 'item_completed' && p.item && typeof p.item === 'object') {
        const it = p.item
        if (it.type === 'UserMessage') {
          const t = textOfContent(it.content, ['text'])
          const images = Array.isArray(it.content) ? it.content.filter(c => c && /image/.test(c.type)).length : 0
          if (t.trim() || images) { abandon(at, 'No result recorded'); out.push(items.user(id, t, { at, images })) }
        } else if (it.type === 'CommandExecution' && typeof it.id === 'string') {
          const code = typeof it.exit_code === 'number' ? it.exit_code : null
          const outText = typeof it.aggregated_output === 'string' ? it.aggregated_output : typeof it.stdout === 'string' ? it.stdout : ''
          refined.set(it.id, { ok: it.status === 'completed' && (code === null || code === 0), text: outText })
        } else if (it.type === 'FileChange' && typeof it.id === 'string') {
          const msg = [it.stdout, it.stderr].filter(s => typeof s === 'string' && s).join('\n')
          refined.set(it.id, { ok: it.status === 'completed', text: msg })
        }
      } else if (!paginated && p.type === 'user_message' && typeof p.message === 'string') {
        const images = (Array.isArray(p.images) ? p.images.length : 0) + (Array.isArray(p.local_images) ? p.local_images.length : 0)
        if (p.message.trim() || images) { abandon(at, 'No result recorded'); out.push(items.user(id, p.message, { at, images })) }
      } else if (p.type === 'turn_aborted') {
        abandon(at, 'Interrupted')
        out.push(items.notice(id, 'interrupted', 'Interrupted', { at }))
      } else if (p.type === 'error' && typeof p.message === 'string') {
        out.push(items.notice(id, 'error', p.message, { at }))
      } else if (p.type === 'task_complete') {
        abandon(at, 'No result recorded')
      }
      continue
    }
    // response_item
    switch (p.type) {
      case 'message':
        if (p.role === 'assistant') {
          const t = textOfContent(p.content, ['output_text', 'text'])
          if (t.trim()) out.push(items.assistant(id, t, { at }))
        }
        break
      case 'reasoning':
        out.push(items.thinking(id, { at }))
        break
      case 'function_call':
      case 'custom_tool_call':
      case 'local_shell_call': {
        const callId = typeof p.call_id === 'string' && p.call_id ? p.call_id : id
        const name = p.type === 'local_shell_call' ? 'local_shell_call' : p.name
        const args = p.type === 'local_shell_call' ? (p.action || {}) : p.type === 'custom_tool_call' ? { input: p.input } : parseArgs(p.arguments)
        if (name === 'update_plan') {
          const plan = Array.isArray(args.plan) ? args.plan : []
          out.push(items.todo(id, plan.map(s => ({ text: s && s.step, status: s && s.status })), { at }))
          calls.set(callId, { done: true, plan: true })
          break
        }
        if (calls.has(callId)) break
        const desc = describeCall(name, args)
        const item = items.tool(callId, { ...desc, at })
        out.push(item)
        calls.set(callId, { item, desc, offset, done: false })
        break
      }
      case 'function_call_output':
      case 'custom_tool_call_output': {
        const call = calls.get(p.call_id)
        if (!call || call.plan || call.done) break
        const r = resultOf(p.output)
        const better = refined.get(p.call_id)
        finish(call, better ? { ok: better.ok && r.ok, text: better.text || r.text } : r)
        break
      }
      case 'web_search_call': {
        const query = p.action && typeof p.action.query === 'string' ? p.action.query : ''
        const callId = typeof p.id === 'string' && p.id ? p.id : id
        if (calls.has(callId)) break
        const item = items.tool(callId, { tool: 'web_search', toolKind: 'web', input: query ? { query } : {}, title: query || 'Web search', at, result: { ok: p.status !== 'failed', text: '' } })
        out.push(item)
        calls.set(callId, { done: true })
        break
      }
      default:
        break
    }
  }
  return {
    items: out,
    // Calls without their result in these lines: [{ id, offset }].
    open: () => [...calls.entries()].filter(([, c]) => !c.done && c.item).map(([id, c]) => ({ id, offset: c.offset })),
    finish: (id, result) => { const c = calls.get(id); if (c && !c.done && c.item) finish(c, result) }
  }
}

// How far past a page to look for the results of its open calls.
const LOOKAHEAD = 2 * 1024 * 1024

// Finds the results of calls left open in a page in the lines after it
// (a page boundary between a call and its output, or an older page whose
// results came later). Returns the calls still open.
function settleOpen (fd, built, from, size) {
  const open = new Map(built.open().map(c => [c.id, c]))
  let pos = from
  const limit = Math.min(size, from + LOOKAHEAD)
  while (open.size && pos < limit) {
    const { lines, end } = linesOf(readRange(fd, pos, Math.min(4 * CHUNK, limit - pos)), pos)
    if (end === pos) { pos = nextLineStart(fd, pos, size); continue }
    pos = end
    for (const { text } of lines) {
      if (text.indexOf('"turn_aborted"') !== -1 || text.indexOf('"task_complete"') !== -1) {
        const why = text.indexOf('"turn_aborted"') !== -1 ? 'Interrupted' : 'No result recorded'
        for (const id of open.keys()) built.finish(id, { ok: false, text: why })
        open.clear()
        break
      }
      if (text.indexOf('_output"') === -1) continue
      const o = parseLine(text)
      const p = o && o.payload
      if (!p || !open.has(p.call_id) || (p.type !== 'function_call_output' && p.type !== 'custom_tool_call_output')) continue
      built.finish(p.call_id, resultOf(p.output))
      open.delete(p.call_id)
    }
  }
  return [...open.values()]
}

// --- transcript pages ----------------------------------------------------------

// One `transcript` page of the rollout at `file` (chat-items.js page).
//   cursor        continue after a page (its `cursor`)
//   beforeCursor  the page before one (its `startCursor`)
//   tailBytes     without a cursor, start this far before the end
//   maxBytes      bytes read at most (default 256 KB)
function readPage (file, opts = {}) {
  let maxBytes = Number(opts.maxBytes) || DEFAULT_MAX_BYTES
  maxBytes = Math.max(1024, Math.min(maxBytes, MAX_MAX_BYTES))
  const fd = fs.openSync(file, 'r')
  try {
    const size = fs.fstatSync(fd).size
    const paginated = isPaginated(fd, file)
    const num = v => (typeof v === 'string' && /^\d{1,15}$/.test(v) ? Number(v) : typeof v === 'number' && Number.isInteger(v) && v >= 0 ? v : null)

    if (opts.beforeCursor !== undefined && opts.beforeCursor !== null) {
      const end = Math.min(num(opts.beforeCursor) ?? 0, size)
      let start = Math.max(0, end - maxBytes)
      const buf = readRange(fd, start, end - start)
      let from = 0
      if (start > 0) {
        const nl = buf.indexOf(0x0a)
        from = nl === -1 ? buf.length : nl + 1
        start += from
      }
      const { lines } = linesOf(buf.subarray(from), start)
      const built = build(lines, paginated)
      settleOpen(fd, built, end, size)
      return items.page({ items: built.items, cursor: end, startCursor: start > 0 ? start : null })
    }

    let since = opts.cursor !== undefined && opts.cursor !== null ? num(opts.cursor) : null
    let reset = false
    if (since !== null && since > size) { since = null; reset = true }
    let start
    if (since === null) {
      const tail = opts.tailBytes !== undefined ? Math.max(0, Number(opts.tailBytes) || 0) : maxBytes
      start = Math.max(0, size - tail)
      if (start > 0 && readRange(fd, start - 1, 1)[0] !== 0x0a) start = nextLineStart(fd, start, size)
    } else start = since
    const length = Math.min(size - start, maxBytes)
    const { lines, end } = linesOf(readRange(fd, start, length), start)
    if (!lines.length && end === start && length === maxBytes && start + length < size) {
      // One line longer than a page (a huge tool output): skip it rather
      // than stall.
      const past = nextLineStart(fd, start, size)
      return items.page({ items: [], cursor: past, startCursor: start > 0 ? start : null, more: past < size, reset })
    }
    const built = build(lines, paginated)
    const open = settleOpen(fd, built, end, size)
    // A call still running at the end of the session file holds the
    // cursor, so its result comes with a later page.
    const waiting = end === size && open.length ? Math.min(...open.map(c => c.offset)) : null
    const cursor = waiting !== null ? waiting : end
    return items.page({ items: built.items, cursor, startCursor: start > 0 ? start : null, more: waiting === null && end < size, reset })
  } finally {
    try { fs.closeSync(fd) } catch {}
  }
}

// --- dashboard tail --------------------------------------------------------------

// The rollout's recent prompts, replies, command runs and tokens for the
// dashboard (types.js Tail, the shape digest.js readTail returns).
function readTail (file, { since, repliesSince = since, runsSince = since, maxBytes = TAIL_BYTES } = {}, costUsd = null) {
  const out = { tokens: null, costUsd: null, replies: [], prompts: [], lastReply: null, runs: [], apiError: null, first: null, partial: false }
  let fd
  try { fd = fs.openSync(file, 'r') } catch { return out }
  try {
    const size = fs.fstatSync(fd).size
    let start = Math.max(0, size - maxBytes)
    if (start > 0) start = nextLineStart(fd, start, size)
    const paginated = isPaginated(fd, file)
    const { lines } = linesOf(readRange(fd, start, size - start), start)
    const cmds = new Map()
    let model = null
    let before = null
    let last = null
    for (const { text } of lines) {
      if (text.indexOf('"turn_context"') !== -1 && text.indexOf('"model"') !== -1) {
        try { const o = JSON.parse(text); if (o && o.payload && typeof o.payload.model === 'string') model = o.payload.model } catch {}
        continue
      }
      const o = parseLine(text)
      if (!o) continue
      const t = Date.parse(o.timestamp)
      if (!Number.isFinite(t)) continue
      if (out.first === null) out.first = t
      const p = o.payload
      if (o.type === 'event_msg') {
        if (p.type === 'token_count' && p.info && p.info.total_token_usage) {
          if (t < since) before = p.info.total_token_usage
          else last = p.info.total_token_usage
        } else if (t >= repliesSince) {
          const prompt = paginated
            ? (p.type === 'item_completed' && p.item && p.item.type === 'UserMessage' ? textOfContent(p.item.content, ['text']) : '')
            : (p.type === 'user_message' && typeof p.message === 'string' ? p.message : '')
          if (prompt.trim()) out.prompts.push({ at: t, text: prompt.trim() })
        }
        continue
      }
      if (o.type !== 'response_item') continue
      if (p.type === 'message' && p.role === 'assistant') {
        const s = textOfContent(p.content, ['output_text', 'text']).trim()
        if (s) {
          out.lastReply = s
          if (t >= repliesSince) out.replies.push({ at: t, text: s })
        }
      } else if ((p.type === 'function_call' || p.type === 'local_shell_call') && p.call_id) {
        const args = p.type === 'local_shell_call' ? (p.action || {}) : parseArgs(p.arguments)
        const name = p.type === 'local_shell_call' ? 'local_shell_call' : p.name
        if (toolKind(name) === 'bash' && name !== 'write_stdin') {
          cmds.set(p.call_id, commandText(args.cmd !== undefined ? args.cmd : args.command))
          if (cmds.size > 2000) cmds.delete(cmds.keys().next().value)
        }
      } else if (p.type === 'function_call_output' && cmds.has(p.call_id) && t >= runsSince) {
        const command = cmds.get(p.call_id)
        const r = resultOf(p.output)
        out.runs.push({ at: t, ok: r.ok, command, what: command, error: r.ok ? null : (r.text.trim().split('\n').pop() || 'error').slice(0, 80) })
      }
    }
    if (last) {
      const n = (u, k) => (u && typeof u[k] === 'number' && u[k] > 0 ? u[k] : 0)
      const d = k => Math.max(0, n(last, k) - n(before, k))
      const cacheRead = d('cached_input_tokens')
      const tk = { input: Math.max(0, d('input_tokens') - cacheRead), output: d('output_tokens'), cacheWrite: 0, cacheRead }
      tk.total = tk.input + tk.output + tk.cacheRead
      out.tokens = tk
      out.costUsd = costUsd ? costUsd(model, tk) : null
    }
    out.partial = start > 0 && out.first !== null && out.first > since
    out.replies = out.replies.slice(-3)
    out.prompts = out.prompts.slice(-2)
  } catch {} finally {
    try { fs.closeSync(fd) } catch {}
  }
  return out
}

module.exports = { readPage, readTail, toolKind, patchFiles, resultOf, describeCall, TOOL_KINDS }
