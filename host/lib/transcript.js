'use strict'

// Incremental, size-capped reader for Claude Code transcript JSONL files.
//
// Only whole lines are ever returned: a line still being written (no trailing
// newline yet) is left for the next read, and `offset` points at its start.
// Each line is reduced to what a chat view needs; bulky payloads (tool input,
// tool output, thinking text, images) are capped or dropped.

const fs = require('fs')

const DEFAULT_MAX_BYTES = 256 * 1024
const MAX_MAX_BYTES = 4 * 1024 * 1024
const TOOL_CAP = 4096
const TEXT_CAP = 32 * 1024
const STRING_FIELD_CAP = 1024
const SYSTEM_CAP = 500
// A line longer than one read's maxBytes (a prompt with pasted images, a
// big tool result) is still read and reduced on its own up to this size;
// only a longer one is skipped.
const OVERSIZED_LINE_CAP = 64 * 1024 * 1024

// Line types a chat view renders; everything else (attachments, queue
// operations, file-history snapshots, cost state, ...) is skipped.
const KEPT_TYPES = new Set(['user', 'assistant', 'summary', 'system'])

function capString (s, max) {
  if (typeof s !== 'string') return { value: s, truncated: false }
  if (s.length <= max) return { value: s, truncated: false }
  return { value: s.slice(0, max - 1) + '…', truncated: true }
}

// Tool input keeps its structure when it can: long string fields are cut to
// STRING_FIELD_CAP first; only if the JSON is still above TOOL_CAP does it
// become {"_truncated":true,"preview":"…"} (the shape `status` uses too).
function capInput (input) {
  if (input === undefined || input === null) return { value: null, truncated: false }
  let json
  try { json = JSON.stringify(input) } catch { return { value: null, truncated: true } }
  if (json.length <= TOOL_CAP) return { value: input, truncated: false }
  let cut = false
  const shrink = v => {
    if (typeof v === 'string') {
      const c = capString(v, STRING_FIELD_CAP)
      if (c.truncated) cut = true
      return c.value
    }
    if (Array.isArray(v)) return v.map(shrink)
    if (v && typeof v === 'object') {
      const o = {}
      for (const [k, x] of Object.entries(v)) o[k] = shrink(x)
      return o
    }
    return v
  }
  const shrunk = shrink(input)
  const again = JSON.stringify(shrunk)
  if (again.length <= TOOL_CAP) return { value: shrunk, truncated: cut }
  return { value: { _truncated: true, preview: again.slice(0, TOOL_CAP) }, truncated: true }
}

function toolResultBlock (b) {
  let text = ''
  let images = 0
  if (typeof b.content === 'string') text = b.content
  else if (Array.isArray(b.content)) {
    const parts = []
    for (const x of b.content) {
      if (!x || typeof x !== 'object') continue
      if (x.type === 'text' && typeof x.text === 'string') parts.push(x.text)
      else if (x.type === 'image') images += 1
    }
    text = parts.join('\n')
  }
  const c = capString(text, TOOL_CAP)
  const out = { type: 'tool_result', tool_use_id: b.tool_use_id || null, is_error: b.is_error === true, content: c.value }
  if (c.truncated) out.truncated = true
  if (images) out.images = images
  return out
}

function contentBlock (b) {
  if (!b || typeof b !== 'object') return null
  switch (b.type) {
    case 'text': {
      const c = capString(typeof b.text === 'string' ? b.text : '', TEXT_CAP)
      return c.truncated ? { type: 'text', text: c.value, truncated: true } : { type: 'text', text: c.value }
    }
    case 'thinking':
    case 'redacted_thinking':
      // The text is never sent; the flag says whether there was any.
      return { type: 'thinking', hasText: typeof b.thinking === 'string' && b.thinking.length > 0 }
    case 'tool_use': {
      const c = capInput(b.input)
      const out = { type: 'tool_use', id: b.id || null, name: b.name || null, input: c.value }
      if (c.truncated) out.truncated = true
      return out
    }
    case 'tool_result':
      return toolResultBlock(b)
    case 'image':
      return { type: 'image', omitted: true, mediaType: (b.source && b.source.media_type) || null }
    default:
      return { type: String(b.type || 'unknown') }
  }
}

function normalizeMessage (m) {
  if (!m || typeof m !== 'object') return null
  const out = { role: m.role || null }
  if (typeof m.content === 'string') {
    const c = capString(m.content, TEXT_CAP)
    out.content = c.value
    if (c.truncated) out.truncated = true
  } else if (Array.isArray(m.content)) {
    out.content = m.content.map(contentBlock).filter(Boolean)
  } else out.content = []
  if (m.model) out.model = m.model
  return out
}

// A prompt the user typed while the agent was working, which Claude Code
// absorbed into the running turn: it is recorded only as a `queued_command`
// attachment, never as a `user` line. Prompts from teammates, coordinators
// and background tasks (other `commandMode`s or `origin`s, or `isMeta`)
// stay dropped.
function queuedPrompt (d) {
  const a = d.attachment
  if (!a || a.type !== 'queued_command' || a.commandMode !== 'prompt') return null
  if (a.isMeta || d.isMeta) return null
  if (a.origin && a.origin.kind !== 'human') return null
  if (typeof a.prompt !== 'string' && !Array.isArray(a.prompt)) return null
  return {
    type: 'user',
    uuid: d.uuid || null,
    parentUuid: d.parentUuid || null,
    timestamp: d.timestamp || a.timestamp || null,
    isSidechain: d.isSidechain === true,
    queued: true,
    message: normalizeMessage({ role: 'user', content: a.prompt })
  }
}

// One parsed JSONL object -> the chat-view entry, or null to skip it.
function normalizeEntry (d) {
  if (d && d.type === 'attachment') return queuedPrompt(d)
  if (!d || typeof d !== 'object' || !KEPT_TYPES.has(d.type)) return null
  if (d.type === 'summary') {
    return { type: 'summary', summary: capString(d.summary || '', SYSTEM_CAP).value, leafUuid: d.leafUuid || null }
  }
  const out = {
    type: d.type,
    uuid: d.uuid || null,
    parentUuid: d.parentUuid || null,
    timestamp: d.timestamp || null,
    isSidechain: d.isSidechain === true
  }
  if (d.isMeta) out.isMeta = true
  if (d.isCompactSummary) out.isCompactSummary = true
  if (d.isApiErrorMessage) out.isApiErrorMessage = true
  if (d.type === 'system') {
    out.subtype = d.subtype || null
    if (typeof d.content === 'string') out.content = capString(d.content, SYSTEM_CAP).value
    if (d.level) out.level = d.level
    return out
  }
  out.message = normalizeMessage(d.message)
  if (!out.message) return null
  return out
}

function parseLines (text) {
  const entries = []
  let skipped = 0
  for (const line of text.split('\n')) {
    if (!line.trim()) continue
    let d
    try { d = JSON.parse(line) } catch { skipped += 1; continue }
    const e = normalizeEntry(d)
    if (e) entries.push(e)
  }
  return { entries, skipped }
}

function readRange (fd, start, length) {
  const buf = Buffer.alloc(length)
  let got = 0
  while (got < length) {
    const n = fs.readSync(fd, buf, got, length - got, start + got)
    if (n === 0) break
    got += n
  }
  return buf.subarray(0, got)
}

// Reads the transcript at `file`.
//   since:     byte offset to continue from (a previous `offset`)
//   tailBytes: without `since`, start this many bytes before the end
//   before:    read the window that ends at this offset (loading older lines);
//              returns `start` = offset of the first whole line returned
//   maxBytes:  cap on bytes read in one call (default 256 KB)
// Returns { offset, size, start, entries, skipped, reset?, oversized? }.
function readTranscript (file, opts = {}) {
  let maxBytes = Number(opts.maxBytes) || DEFAULT_MAX_BYTES
  maxBytes = Math.max(1024, Math.min(maxBytes, MAX_MAX_BYTES))
  const fd = fs.openSync(file, 'r')
  try {
    const size = fs.fstatSync(fd).size
    let reset = false

    if (opts.before !== undefined) {
      const end = Math.max(0, Math.min(Number(opts.before), size))
      let start = Math.max(0, end - maxBytes)
      const buf = readRange(fd, start, end - start)
      let from = 0
      if (start > 0) {
        // Drop the partial first line; it belongs to an older window.
        const nl = buf.indexOf(0x0a)
        from = nl === -1 ? buf.length : nl + 1
        start += from
      }
      const { entries, skipped } = parseLines(buf.subarray(from).toString('utf8'))
      return { offset: end, size, start, entries, skipped }
    }

    let since = opts.since !== undefined ? Number(opts.since) : undefined
    if (since !== undefined && since > size) {
      // The file shrank (rewritten or replaced): start over from the tail.
      reset = true
      since = undefined
    }
    let start
    let alignToLine = false
    if (since === undefined) {
      const tail = opts.tailBytes !== undefined ? Number(opts.tailBytes) : maxBytes
      start = Math.max(0, size - Math.max(0, tail))
      alignToLine = start > 0
    } else start = since

    const length = Math.min(size - start, maxBytes)
    const buf = readRange(fd, start, length)
    let from = 0
    if (alignToLine) {
      // Previous byte might already be a newline; check it so a line that
      // starts exactly at `start` is kept.
      const prev = readRange(fd, start - 1, 1)
      if (prev[0] !== 0x0a) {
        const nl = buf.indexOf(0x0a)
        from = nl === -1 ? buf.length : nl + 1
      }
    }
    const lastNl = buf.lastIndexOf(0x0a)
    if (lastNl < from) {
      // No complete line in the window.
      if (length === maxBytes && start + length < size) {
        // One line longer than maxBytes: read it alone (a prompt with
        // images must not vanish), or skip it when even that is too big,
        // rather than stall forever.
        let pos = start + length
        const chunk = 64 * 1024
        while (pos < size) {
          const more = readRange(fd, pos, Math.min(chunk, size - pos))
          const nl = more.indexOf(0x0a)
          if (nl !== -1) {
            const lineStart = start + from
            const end = pos + nl + 1
            let parsed = { entries: [], skipped: 1 }
            if (end - lineStart <= OVERSIZED_LINE_CAP) {
              parsed = parseLines(readRange(fd, lineStart, end - lineStart).toString('utf8'))
            }
            return { offset: end, size, start: lineStart, entries: parsed.entries, skipped: parsed.skipped, oversized: true, ...(reset ? { reset } : {}) }
          }
          pos += more.length
        }
      }
      return { offset: start + from, size, start: start + from, entries: [], skipped: 0, ...(reset ? { reset } : {}) }
    }
    const { entries, skipped } = parseLines(buf.subarray(from, lastNl + 1).toString('utf8'))
    const out = { offset: start + lastNl + 1, size, start: start + from, entries, skipped }
    if (reset) out.reset = true
    return out
  } finally {
    fs.closeSync(fd)
  }
}

module.exports = { readTranscript, normalizeEntry, capInput, DEFAULT_MAX_BYTES, TOOL_CAP }
