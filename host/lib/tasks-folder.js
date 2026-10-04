'use strict'

// `conductore-hostd tasks <op> -`: the open "markdown tasks folder" format
// (docs/task-sources.md), read and written for the phone's task source.
// One JSON object on stdin: {folder, id?, status?, text?, author?}.
//
// A folder holds one `<id>.md` per task: YAML frontmatter (flat keys,
// scalars and simple lists) then a markdown body. Only that folder is ever
// touched: the folder must be an existing absolute directory (not `/`),
// ids are plain file names (no separators, no dot-dot), a task file must be
// a regular file (never a symlink) directly inside the folder, and writes go
// through a temp file in the same folder and a rename. Status changes only
// rewrite the `status:` (and an existing `updated_at:`) line; comments are
// appended under a `## Comments` heading. Everything else stays byte for
// byte, line endings included.

const fs = require('fs')
const os = require('os')
const path = require('path')

const MAX_FILES = 2000
const MAX_FILE_BYTES = 1024 * 1024
const MAX_COMMENT = 20000
const ID_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/
const STATUS_RE = /^[A-Za-z0-9][A-Za-z0-9 _./-]{0,47}$/
const DEFAULT_STATUSES = ['backlog', 'todo', 'in-progress', 'review', 'blocked', 'done', 'cancelled']
const COMMENTS_HEADING = '## Comments'

class TasksError extends Error {
  constructor (code, message) {
    super(message)
    this.code = code
  }
}

// The folder as a real path, or throws.
function resolveFolder (raw) {
  if (typeof raw !== 'string' || !raw.trim() || raw.length > 1024 || /[\0\n\r]/.test(raw)) throw new TasksError('bad-folder', 'folder must be a path')
  let p = raw.trim()
  if (p === '~' || p.startsWith('~/')) p = path.join(os.homedir(), p.slice(1))
  if (!path.isAbsolute(p)) throw new TasksError('bad-folder', 'folder must be an absolute path (or start with ~/)')
  let real
  try { real = fs.realpathSync(p) } catch { throw new TasksError('no-folder', `no such folder: ${raw}`) }
  if (real === path.parse(real).root) throw new TasksError('bad-folder', 'refusing the file system root')
  if (!fs.statSync(real).isDirectory()) throw new TasksError('bad-folder', `not a folder: ${raw}`)
  return real
}

// The task file for id inside folder; it must exist unless allowMissing.
function taskFile (folder, id) {
  if (typeof id !== 'string' || !ID_RE.test(id) || id.includes('..')) throw new TasksError('bad-id', 'id must be a file name without the .md (letters, digits, . _ -)')
  const file = path.join(folder, `${id}.md`)
  if (path.dirname(file) !== folder) throw new TasksError('bad-id', 'id escapes the folder')
  let st
  try { st = fs.lstatSync(file) } catch { throw new TasksError('not-found', `no task ${id}`) }
  if (!st.isFile()) throw new TasksError('bad-id', `${id}.md is not a regular file`)
  if (st.size > MAX_FILE_BYTES) throw new TasksError('too-large', `${id}.md is over ${MAX_FILE_BYTES} bytes`)
  return { file, st }
}

// --- frontmatter -----------------------------------------------------------

function unquote (v) {
  if (v.length >= 2 && v[0] === '"' && v[v.length - 1] === '"') {
    try { return JSON.parse(v) } catch { return v.slice(1, -1) }
  }
  if (v.length >= 2 && v[0] === "'" && v[v.length - 1] === "'") return v.slice(1, -1).replace(/''/g, "'")
  return v
}

function scalar (raw) {
  const v = raw.replace(/\s+#.*$/, '').trim()
  if (v.startsWith('[') && v.endsWith(']')) {
    const inner = v.slice(1, -1).trim()
    return inner ? inner.split(',').map(s => unquote(s.trim())).filter(s => s !== '') : []
  }
  return unquote(v)
}

// {fields, bodyStart, fmLines: [{start, end, key}]} or null without
// frontmatter. Offsets are into text; fmEnd is the closing fence's start.
function splitFrontmatter (text) {
  const bom = text.startsWith('﻿') ? 1 : 0
  const first = text.indexOf('\n', bom)
  if (first === -1 || text.slice(bom, first).replace(/\r$/, '') !== '---') return null
  const fields = {}
  const lines = []
  let pos = first + 1
  let listKey = null
  while (pos < text.length) {
    let nl = text.indexOf('\n', pos)
    if (nl === -1) nl = text.length
    const line = text.slice(pos, nl).replace(/\r$/, '')
    if (line === '---' || line === '...') {
      return { fields, lines, fmEnd: pos, bodyStart: Math.min(nl + 1, text.length) }
    }
    const item = /^\s+-\s+(.*)$/.exec(line) || (listKey && /^-\s+(.*)$/.exec(line))
    const kv = /^([A-Za-z0-9_][A-Za-z0-9_.-]*):(?:\s+(.*))?$/.exec(line)
    if (item && listKey) {
      fields[listKey].push(unquote(item[1].trim()))
    } else if (kv) {
      const value = kv[2] === undefined ? '' : kv[2]
      lines.push({ start: pos, end: nl, key: kv[1] })
      if (value.trim() === '') {
        fields[kv[1]] = []
        listKey = kv[1]
      } else {
        fields[kv[1]] = scalar(value)
        listKey = null
      }
    } else if (!/^\s/.test(line)) {
      listKey = null
    }
    pos = nl + 1
  }
  return null
}

const str = v => typeof v === 'string' ? v : Array.isArray(v) ? v.join(', ') : ''
const list = v => Array.isArray(v) ? v.filter(s => typeof s === 'string' && s) : typeof v === 'string' && v ? v.split(',').map(s => s.trim()).filter(Boolean) : []

// Comments under the `## Comments` heading: `- author (when): text`, with
// continuation lines indented.
function parseComments (body) {
  const lines = body.replace(/\r\n?/g, '\n').split('\n')
  const at = lines.findIndex(l => l.trim() === COMMENTS_HEADING)
  if (at === -1) return []
  const out = []
  for (const line of lines.slice(at + 1)) {
    if (/^#{1,2}\s/.test(line)) break
    const m = /^- (.+?) \(([^)]*)\): ?(.*)$/.exec(line)
    if (m) out.push({ author: m[1], createdAt: m[2], body: m[3] })
    else if (out.length && /^\s{2,}\S/.test(line)) out[out.length - 1].body += '\n' + line.replace(/^\s{2}/, '')
  }
  return out
}

function describe (id, text, st, withBody) {
  const fm = splitFrontmatter(text)
  if (!fm) return null
  const f = fm.fields
  const body = text.slice(fm.bodyStart)
  const firstHeading = /^#\s+(.+)$/m.exec(body)
  const task = {
    id,
    key: str(f.id) || id,
    title: str(f.title) || (firstHeading ? firstHeading[1].trim() : id),
    status: str(f.status),
    assignees: list(f.assignee).concat(list(f.assignees)),
    labels: list(f.labels).concat(list(f.tags)),
    priority: str(f.priority),
    type: str(f.type),
    createdAt: str(f.created_at) || null,
    updatedAt: str(f.updated_at) || null,
    mtimeMs: Math.round(st.mtimeMs)
  }
  if (withBody) {
    task.body = body
    task.comments = parseComments(body)
    task.fields = Object.fromEntries(Object.entries(f).filter(([, v]) => typeof v === 'string' || Array.isArray(v)))
  }
  return task
}

// --- operations ------------------------------------------------------------

function listTasks ({ folder }) {
  const dir = resolveFolder(folder)
  const names = fs.readdirSync(dir).filter(n => n.endsWith('.md') && !n.startsWith('.')).sort()
  const tasks = []
  const seen = new Set()
  let truncated = false
  for (const name of names) {
    if (tasks.length >= MAX_FILES) { truncated = true; break }
    const id = name.slice(0, -3)
    if (!ID_RE.test(id)) continue
    let st
    try { st = fs.lstatSync(path.join(dir, name)) } catch { continue }
    if (!st.isFile() || st.size > MAX_FILE_BYTES) continue
    let text
    try { text = fs.readFileSync(path.join(dir, name), 'utf8') } catch { continue }
    const task = describe(id, text, st, false)
    if (!task) continue
    if (task.status) seen.add(task.status)
    tasks.push(task)
  }
  const statuses = [...DEFAULT_STATUSES, ...[...seen].filter(s => !DEFAULT_STATUSES.includes(s)).sort()]
  return { ok: true, folder: dir, tasks, statuses, truncated }
}

function readTask ({ folder, id }) {
  const dir = resolveFolder(folder)
  const { file, st } = taskFile(dir, id)
  const task = describe(id, fs.readFileSync(file, 'utf8'), st, true)
  if (!task) throw new TasksError('no-frontmatter', `${id}.md has no frontmatter`)
  return { ok: true, task }
}

function writeAtomic (file, text, mode) {
  const tmp = path.join(path.dirname(file), `.${path.basename(file)}.${process.pid}.${Date.now()}.tmp`)
  fs.writeFileSync(tmp, text, { mode: mode & 0o777, flag: 'wx' })
  try { fs.renameSync(tmp, file) } catch (err) { try { fs.unlinkSync(tmp) } catch {} throw err }
}

const nowIso = () => new Date().toISOString().replace(/\.\d{3}Z$/, 'Z')
const yamlValue = v => /^[A-Za-z0-9_-]+$/.test(v) ? v : JSON.stringify(v)

function setStatus ({ folder, id, status }) {
  if (typeof status !== 'string' || !STATUS_RE.test(status)) throw new TasksError('bad-status', 'status must be a short word (letters, digits, space . _ / -)')
  const dir = resolveFolder(folder)
  const { file, st } = taskFile(dir, id)
  const text = fs.readFileSync(file, 'utf8')
  const fm = splitFrontmatter(text)
  if (!fm) throw new TasksError('no-frontmatter', `${id}.md has no frontmatter`)
  const eol = text.includes('\r\n') ? '\r\n' : '\n'
  const edits = []
  const statusLine = fm.lines.find(l => l.key === 'status')
  if (statusLine) edits.push({ start: statusLine.start, end: statusLine.end, text: `status: ${yamlValue(status)}${text[statusLine.end - 1] === '\r' ? '\r' : ''}` })
  else edits.push({ start: fm.fmEnd, end: fm.fmEnd, text: `status: ${yamlValue(status)}${eol}` })
  const updated = fm.lines.find(l => l.key === 'updated_at')
  if (updated) edits.push({ start: updated.start, end: updated.end, text: `updated_at: "${nowIso()}"${text[updated.end - 1] === '\r' ? '\r' : ''}` })
  let next = text
  for (const e of edits.sort((a, b) => b.start - a.start)) next = next.slice(0, e.start) + e.text + next.slice(e.end)
  writeAtomic(file, next, st.mode)
  return readTask({ folder: dir, id })
}

function addComment ({ folder, id, text: comment, author }) {
  if (typeof comment !== 'string' || !comment.trim()) throw new TasksError('bad-comment', 'comment text is empty')
  if (comment.length > MAX_COMMENT) throw new TasksError('bad-comment', `comment over ${MAX_COMMENT} characters`)
  const who = typeof author === 'string' && author.trim() ? author.trim().replace(/[\r\n()]/g, ' ').slice(0, 60) : 'Conductore'
  const dir = resolveFolder(folder)
  const { file, st } = taskFile(dir, id)
  const text = fs.readFileSync(file, 'utf8')
  const fm = splitFrontmatter(text)
  if (!fm) throw new TasksError('no-frontmatter', `${id}.md has no frontmatter`)
  const eol = text.includes('\r\n') ? '\r\n' : '\n'
  const [first, ...rest] = comment.replace(/\r\n?/g, '\n').trim().split('\n')
  const entry = [`- ${who} (${nowIso()}): ${first}`, ...rest.map(l => l ? `  ${l}` : '')].join(eol) + eol
  let next = text
  if (!next.endsWith('\n')) next += eol
  const hasHeading = next.slice(fm.bodyStart).split(/\r?\n/).some(l => l.trim() === COMMENTS_HEADING)
  if (!hasHeading) next += `${eol}${COMMENTS_HEADING}${eol}${eol}`
  next += entry
  writeAtomic(file, next, st.mode)
  return readTask({ folder: dir, id })
}

const OPS = { list: listTasks, read: readTask, status: setStatus, comment: addComment }

const USAGE = `usage: conductore-hostd tasks <list|read|status|comment> -

  One JSON object on stdin:
    list     {folder}                      every task's frontmatter
    read     {folder, id}                  one task with its body and comments
    status   {folder, id, status}          rewrite its status line
    comment  {folder, id, text, author?}   append under "## Comments"
`

async function cli (args, { readStdin }) {
  const [op] = args
  const write = obj => { process.stdout.write(JSON.stringify(obj) + '\n'); return obj.error ? 1 : 0 }
  if (!OPS[op]) return write({ error: USAGE.trim(), code: 'usage' })
  let input
  try { input = JSON.parse(await readStdin()) } catch { return write({ error: 'tasks: expected one JSON object on stdin', code: 'usage' }) }
  if (!input || typeof input !== 'object') return write({ error: 'tasks: expected one JSON object on stdin', code: 'usage' })
  try {
    return write(OPS[op](input))
  } catch (err) {
    return write({ error: err.message, code: err.code || 'failed' })
  }
}

module.exports = { cli, listTasks, readTask, setStatus, addComment, splitFrontmatter, parseComments, resolveFolder, TasksError, DEFAULT_STATUSES }
