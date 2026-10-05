'use strict'

// `conductore-hostd tasks <op> -`: the open "markdown tasks folder" format
// (docs/task-sources.md), read and written for the phone's task source.
// One JSON object on stdin: {folder, id?, status?, text?, author?}.
//
// A folder holds one `<id>.md` per task: YAML frontmatter (flat keys,
// scalars and simple lists) then a markdown body. A folder without task
// files of its own is a tree (CON-084): each subfolder one level down is a
// project (names starting with `_` or `.`, and symlinks, are skipped) and
// its tasks' ids are `<project>/<id>`. Only that folder is ever touched:
// the folder must be an existing absolute directory (not `/`), ids are
// plain file names (no dot-dot) with at most one project folder before
// them, a task file must be a regular file (never a symlink) directly
// inside the folder or a real project subfolder, and writes go through a
// temp file next to it and a rename. Status changes only
// rewrite the `status:` (and an existing `updated_at:`) line; comments are
// appended under a `## Comments` heading. Everything else stays byte for
// byte, line endings included.

const fs = require('fs')
const os = require('os')
const path = require('path')

// Caps on one list: tasks returned, and time spent reading (the phone
// gives up after 20 s).
const MAX_TASKS = 5000
const MAX_SCAN_MS = 8000
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

// A project subfolder's name: a plain name not starting with `_` or `.`.
const isProjectName = name => ID_RE.test(name) && !name.startsWith('_') && !name.includes('..')

// The real directory a task id lives in: folder itself, or for
// `<project>/<id>` a real (not symlinked) project subfolder directly inside
// it.
function taskDir (folder, id) {
  const bad = () => new TasksError('bad-id', 'id must be a file name without the .md (letters, digits, . _ -), optionally after one project folder: project/id')
  if (typeof id !== 'string' || id.includes('..')) throw bad()
  const parts = id.split('/')
  if (parts.length > 2 || !ID_RE.test(parts[parts.length - 1])) throw bad()
  if (parts.length === 1) return { dir: folder, name: parts[0] }
  if (!isProjectName(parts[0])) throw bad()
  const dir = path.join(folder, parts[0])
  let st
  try { st = fs.lstatSync(dir) } catch { throw new TasksError('not-found', `no task ${id}`) }
  if (!st.isDirectory()) throw new TasksError('bad-id', `${parts[0]} is not a folder`)
  let real
  try { real = fs.realpathSync(dir) } catch { throw new TasksError('not-found', `no task ${id}`) }
  if (real !== dir || path.dirname(real) !== folder) throw new TasksError('bad-id', 'id escapes the folder')
  return { dir, name: parts[1] }
}

// The task file for id inside folder; it must exist.
function taskFile (folder, id) {
  const { dir, name } = taskDir(folder, id)
  const file = path.join(dir, `${name}.md`)
  if (path.dirname(file) !== dir) throw new TasksError('bad-id', 'id escapes the folder')
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

function describe (id, text, st, withBody, project) {
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
  if (project) task.project = project
  if (withBody) {
    task.body = body
    task.comments = parseComments(body)
    task.fields = Object.fromEntries(Object.entries(f).filter(([, v]) => typeof v === 'string' || Array.isArray(v)))
  }
  return task
}

// --- operations ------------------------------------------------------------

// The tasks in one directory, appended to out (up to max, until
// deadline); false once a cap is hit.
function readTasksIn (dir, prefix, project, out, { max, deadline }) {
  let names
  try { names = fs.readdirSync(dir).filter(n => n.endsWith('.md') && !n.startsWith('.')).sort() } catch { return true }
  for (const name of names) {
    if (out.length >= max || Date.now() > deadline) return false
    const id = name.slice(0, -3)
    if (!ID_RE.test(id)) continue
    let st
    try { st = fs.lstatSync(path.join(dir, name)) } catch { continue }
    if (!st.isFile() || st.size > MAX_FILE_BYTES) continue
    let text
    try { text = fs.readFileSync(path.join(dir, name), 'utf8') } catch { continue }
    const task = describe(prefix + id, text, st, false, project)
    if (task) out.push(task)
  }
  return true
}

// A status as filters compare it: `In Review`, `in_review` and
// `in-review` are one.
const statusKey = s => String(s).toLowerCase().trim().replace(/[ _]+/g, '-')

// The list filters (all optional): {statuses, excludeStatuses, projects:
// string lists; updatedSince: ISO time; limit: 1..MAX_TASKS}.
function listFilters (input) {
  const names = (key, max = 200) => {
    const v = input[key]
    if (v === undefined || v === null) return null
    if (!Array.isArray(v) || v.length > max || !v.every(x => typeof x === 'string' && x.length <= 128)) throw new TasksError('bad-filter', `${key} must be a list of names`)
    return v
  }
  const statuses = names('statuses')
  const exclude = names('excludeStatuses')
  const projects = names('projects', 1000)
  let since = null
  if (input.updatedSince !== undefined && input.updatedSince !== null) {
    since = typeof input.updatedSince === 'string' ? Date.parse(input.updatedSince) : NaN
    if (Number.isNaN(since)) throw new TasksError('bad-filter', 'updatedSince must be an ISO time')
  }
  let limit = MAX_TASKS
  if (input.limit !== undefined && input.limit !== null) {
    if (!Number.isInteger(input.limit) || input.limit < 1) throw new TasksError('bad-filter', 'limit must be a positive whole number')
    limit = Math.min(input.limit, MAX_TASKS)
  }
  return {
    statuses: statuses && new Set(statuses.map(statusKey)),
    exclude: exclude && new Set(exclude.map(statusKey)),
    projects: projects && new Set(projects),
    since,
    limit
  }
}

// When a task last changed: its updated_at, else the file's mtime.
const updatedMs = t => { const at = t.updatedAt ? Date.parse(t.updatedAt) : NaN; return Number.isNaN(at) ? t.mtimeMs : at }

// limits: tests' smaller caps.
function listTasks (input, { maxTasks = MAX_TASKS, maxScanMs = MAX_SCAN_MS } = {}) {
  const dir = resolveFolder(input.folder)
  const filters = listFilters(input)
  const caps = { max: maxTasks, deadline: Date.now() + maxScanMs }
  const read = []
  let complete = readTasksIn(dir, '', null, read, caps)
  let projects = null
  if (complete && read.length === 0) {
    // A tree: one level of project folders, never through a symlink.
    const folders = fs.readdirSync(dir, { withFileTypes: true })
      .filter(e => e.isDirectory() && isProjectName(e.name) && (!filters.projects || filters.projects.has(e.name)))
      .map(e => e.name)
      .sort()
    for (const project of folders) {
      complete = readTasksIn(path.join(dir, project), `${project}/`, project, read, caps)
      if (!complete) break
    }
    projects = [...new Set(read.map(t => t.project))]
  }
  const seen = new Set(read.map(t => t.status).filter(Boolean))
  const statuses = [...DEFAULT_STATUSES, ...[...seen].filter(s => !DEFAULT_STATUSES.includes(s)).sort()]
  const matching = read.filter(t =>
    (!filters.statuses || filters.statuses.has(statusKey(t.status))) &&
    (!filters.exclude || !filters.exclude.has(statusKey(t.status))) &&
    (!filters.projects || filters.projects.has(t.project)) &&
    (filters.since === null || updatedMs(t) >= filters.since))
  // Newest first, so a limit keeps the most recent.
  matching.sort((a, b) => updatedMs(b) - updatedMs(a) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0))
  const tasks = matching.slice(0, filters.limit)
  const out = { ok: true, folder: dir, tasks, total: matching.length, statuses, truncated: !complete }
  if (projects) out.projects = projects
  return out
}

function readTask ({ folder, id }) {
  const dir = resolveFolder(folder)
  const { file, st } = taskFile(dir, id)
  const task = describe(id, fs.readFileSync(file, 'utf8'), st, true, id.includes('/') ? id.split('/')[0] : null)
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
    list     {folder, statuses?, excludeStatuses?, projects?,
              updatedSince?, limit?}       tasks' frontmatter, newest first
    read     {folder, id}                  one task with its body and comments
    status   {folder, id, status}          rewrite its status line
    comment  {folder, id, text, author?}   append under "## Comments"

  --gzip after the "-": a reply over 4 KB prints as
  {"encoding":"gzip","data":"<base64 of the gzipped JSON>"}
`

// `--gzip` (after the `-`): a reply over GZIP_MIN_CHARS goes out as
// {"encoding":"gzip","data":"<base64>"}, as for the other commands. Errors
// stay plain.
const GZIP_MIN_CHARS = 4096

async function cli (args, { readStdin }) {
  const [op] = args
  const gzip = args.includes('--gzip')
  const write = obj => {
    let json = JSON.stringify(obj)
    if (gzip && !obj.error && json.length > GZIP_MIN_CHARS) json = JSON.stringify({ encoding: 'gzip', data: require('zlib').gzipSync(json).toString('base64') })
    process.stdout.write(json + '\n')
    return obj.error ? 1 : 0
  }
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
