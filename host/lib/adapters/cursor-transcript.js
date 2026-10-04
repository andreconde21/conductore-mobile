'use strict'

// Cursor CLI's agent transcript -> neutral chat items (chat-items.js), for
// the Cursor adapter. What Cursor writes (2026.10.01, read from its
// TranscriptStore and checked against the files a real `agent` wrote in
// Docker, test/fixtures/cursor/README.md):
//
//   ~/.cursor/projects/<workspace slug>/agent-transcripts/<id>/<id>.jsonl
//   (older builds: agent-transcripts/<id>.jsonl), one line per message:
//     {"role":"user","message":{"content":[{"type":"text","text":"<user_query>\n…\n</user_query>"}]}}
//     {"role":"assistant","message":{"content":[{"type":"text","text":"…"},
//                                              {"type":"tool_use","name":"Shell","input":{…}}]}}
//     {"type":"turn_ended","status":"success"|"error"|"aborted","error"?}
//     {"type":"metadata","metadata":{"overview":"…"}}  (first line, sometimes)
//
// No timestamps, no tool results (tool messages are left out), thinking is
// folded into the assistant's text. Cursor appends a line per message and
// sometimes rewrites the whole file (same lines, or fewer after it pruned
// the history).
//
// Paging is by line: the cursor is the index of the next line to read
// ("L<n>"). A tool's result is only known once another line follows it, so
// a page that ends on a tool keeps the cursor on that line: the next read
// sends it again (same id) with its result. Ids are the line index plus
// the block index, stable while the file only grows.

const fs = require('fs')
const items = require('./chat-items')

const PAGE_LINES = 200
const MAX_FILE = 16 * 1024 * 1024

// Cursor's tool names (hooks: Shell, Read, Write, Grep, Delete, Task,
// MCP:<tool>; the model's names in transcripts vary by build) onto the
// neutral kinds.
const TOOL_KINDS = {
  shell: 'bash',
  run_terminal_cmd: 'bash',
  bash: 'bash',
  write: 'write',
  edit: 'edit',
  edit_file: 'edit',
  strreplace: 'edit',
  str_replace: 'edit',
  search_replace: 'edit',
  multiedit: 'edit',
  applypatch: 'edit',
  apply_patch: 'edit',
  delete: 'edit',
  delete_file: 'edit',
  read: 'read',
  read_file: 'read',
  readlints: 'read',
  read_lints: 'read',
  grep: 'search',
  glob: 'search',
  ls: 'search',
  list: 'search',
  list_dir: 'search',
  file_search: 'search',
  codebase_search: 'search',
  semanticsearch: 'search',
  semsearch: 'search',
  websearch: 'web',
  web_search: 'web',
  webfetch: 'web',
  web_fetch: 'web',
  fetch: 'web',
  task: 'task',
  todowrite: 'todo',
  todo_write: 'todo',
  updatetodos: 'todo',
  update_todos: 'todo',
  askquestion: 'question',
  ask_question: 'question',
  createplan: 'plan',
  create_plan: 'plan'
}

function toolKind (name) {
  if (typeof name !== 'string' || !name) return 'other'
  if (/^mcp[:_]/i.test(name)) return 'mcp'
  return TOOL_KINDS[name.toLowerCase()] || 'other'
}

// Cursor wraps the prompt as <user_query>…</user_query> (the context tags
// around it are already stripped by Cursor).
function promptText (text) {
  if (typeof text !== 'string') return ''
  const m = /<user_query>\s*([\s\S]*?)\s*<\/user_query>/.exec(text)
  return (m ? m[1] : text).trim()
}

const textOf = content => (Array.isArray(content) ? content : [])
  .filter(b => b && b.type === 'text' && typeof b.text === 'string')
  .map(b => b.text)
  .join('\n')

// One line of a tool call's title: the command, the path, the pattern.
function titleOf (input) {
  if (!input || typeof input !== 'object') return ''
  for (const k of ['command', 'path', 'file_path', 'target_file', 'pattern', 'query', 'url', 'description']) {
    if (typeof input[k] === 'string' && input[k]) return input[k]
  }
  return ''
}

// The file's lines (whole: Cursor's transcripts are small; a huge one is
// read from its last MAX_FILE bytes, which changes the line numbers, so
// paging then starts over).
function readLines (file) {
  const fd = fs.openSync(file, 'r')
  try {
    const size = fs.fstatSync(fd).size
    const start = Math.max(0, size - MAX_FILE)
    const buf = Buffer.alloc(size - start)
    let got = 0
    while (got < buf.length) {
      const n = fs.readSync(fd, buf, got, buf.length - got, start + got)
      if (n === 0) break
      got += n
    }
    let text = buf.subarray(0, got).toString('utf8')
    if (start > 0) text = text.slice(text.indexOf('\n') + 1)
    const lines = text.split('\n')
    // A last line without its newline may still be being written.
    if (lines.length && lines[lines.length - 1] === '') lines.pop()
    else if (lines.length) {
      try { JSON.parse(lines[lines.length - 1]) } catch { lines.pop() }
    }
    return lines
  } finally {
    fs.closeSync(fd)
  }
}

function parse (line) {
  try {
    const o = JSON.parse(line)
    return o && typeof o === 'object' && !Array.isArray(o) ? o : null
  } catch {
    return null
  }
}

// Items of lines [from, to): { items, open } where open is true when the
// last item is a tool with no line after it (its result is not known yet).
function build (lines, from, to) {
  const out = []
  let open = false
  for (let i = from; i < to; i++) {
    const o = parse(lines[i])
    if (!o) continue
    const later = i + 1 < lines.length
    if (o.type === 'turn_ended') {
      if (o.status === 'error') out.push(items.notice(`l${i}`, 'error', typeof o.error === 'string' && o.error ? o.error : 'The turn ended with an error'))
      else if (o.status === 'aborted') out.push(items.notice(`l${i}`, 'interrupted', 'Interrupted'))
      continue
    }
    const content = o.message && Array.isArray(o.message.content) ? o.message.content : null
    if (!content) continue
    if (o.role === 'user') {
      const text = promptText(textOf(content))
      if (text) out.push(items.user(`l${i}`, text))
      continue
    }
    if (o.role !== 'assistant') continue
    content.forEach((b, k) => {
      if (!b || typeof b !== 'object') return
      if (b.type === 'text' && typeof b.text === 'string' && b.text.trim()) {
        out.push(items.assistant(`l${i}.${k}`, b.text.trim()))
      } else if (b.type === 'tool_use') {
        const input = b.input && typeof b.input === 'object' && !Array.isArray(b.input) ? b.input : {}
        // No results in the file: a call another line follows has run.
        const done = later || k < content.length - 1
        out.push(items.tool(`l${i}.${k}`, { tool: b.name, toolKind: toolKind(b.name), input, title: titleOf(input), result: done ? { ok: true, text: '' } : null }))
        open = !done && i === to - 1
      }
    })
  }
  return { items: out, open }
}

const lineOf = c => {
  const m = /^L(\d+)$/.exec(String(c || ''))
  return m ? Number(m[1]) : null
}

// One page (chat-items.js page). opts: cursor (continue after a page),
// beforeCursor (the page before one), neither = the last page.
function readPage (file, opts = {}) {
  const lines = readLines(file)
  const n = lines.length
  const before = lineOf(opts.beforeCursor)
  if (before !== null) {
    const to = Math.min(before, n)
    const from = Math.max(0, to - PAGE_LINES)
    const built = build(lines, from, to)
    return items.page({ items: built.items, cursor: `L${to}`, startCursor: from > 0 ? `L${from}` : null })
  }
  let from = lineOf(opts.cursor)
  let reset = false
  // Rewritten shorter (pruned) or a cursor we never gave: start over.
  if (opts.cursor !== undefined && opts.cursor !== null && (from === null || from > n)) { from = null; reset = true }
  if (from === null) from = Math.max(0, n - PAGE_LINES)
  const to = Math.min(n, from + PAGE_LINES)
  const built = build(lines, from, to)
  // A tool still waiting for its result is sent again with the next page.
  const cursor = built.open ? to - 1 : to
  return items.page({ items: built.items, cursor: `L${cursor}`, startCursor: from > 0 ? `L${from}` : null, more: to < n, reset })
}

module.exports = { readPage, toolKind, promptText, PAGE_LINES }
