'use strict'

// The neutral chat format (CON-045 decision 7): what `transcript` returns
// for every agent except Claude Code, whose own entry format the app
// already parses (it moves to this format later, behind a flag). An
// adapter's readTranscript() reads its agent's native transcript and builds
// these items with the helpers below, so the app never parses Codex,
// OpenCode or Gemini files.
//
// A page:
//   { format: 'items', items: [ChatItem], cursor, startCursor, more, reset? }
//     cursor       opaque; `transcript <sid> --cursor <cursor>` returns
//                  what came after this page
//     startCursor  opaque; `--before-cursor <startCursor>` returns the page
//                  before this one (null at the start of the session)
//     more         another page follows at once (read again with cursor)
//     reset        the transcript was rewritten: drop what you had
//
// A ChatItem: { id, type, at, ...fields }. `id` is stable across reads
// (the app keys its widgets by it); `at` is an ISO time or null. An item
// whose `sidechain` is true belongs to a subagent: the app folds it under
// the item whose id is its `parentId` (a `tool` of kind `task`).
//
//   user       text, images (count), queued (typed while the agent worked),
//              truncated
//   assistant  text, truncated
//   thinking   (the text is never sent)
//   tool       tool (native name, shown as is), toolKind (TOOL_KINDS),
//              input (object, capped like `status`), inputTruncated,
//              title (one line), result: null while running, else
//              { ok, text, truncated, images }
//   todo       todos: [{ text, status: pending | in_progress | completed }]
//   plan       plan (text), status: pending | approved | rejected, feedback
//   question   questions: [{ question, header, multiSelect, options:
//              [{ label, description }] }], answer (null until answered)
//   notice     level: info | error | interrupted | compacted, text
//   shell      command, stdout, stderr (a command the user ran themselves)
//
// Names and values only ever get added; the app skips types it does not know.

const { capInput } = require('../transcript')

const FORMAT = 'items'
const TEXT_CAP = 32 * 1024
const RESULT_CAP = 4096
const NOTICE_CAP = 500

const TYPES = ['user', 'assistant', 'thinking', 'tool', 'todo', 'plan', 'question', 'notice', 'shell']
const TOOL_KINDS = ['bash', 'edit', 'write', 'read', 'search', 'web', 'task', 'mcp', 'todo', 'question', 'plan', 'other']
const NOTICE_LEVELS = ['info', 'error', 'interrupted', 'compacted']
const TODO_STATUSES = ['pending', 'in_progress', 'completed']
const PLAN_STATUSES = ['pending', 'approved', 'rejected']

function cap (s, max) {
  if (typeof s !== 'string') return { value: '', truncated: false }
  return s.length <= max ? { value: s, truncated: false } : { value: s.slice(0, max - 1) + '…', truncated: true }
}

const iso = at => {
  if (at === null || at === undefined || at === '') return null
  const d = typeof at === 'number' ? new Date(at) : new Date(String(at))
  return Number.isFinite(d.getTime()) ? d.toISOString() : null
}

function base (type, id, at, extra) {
  const item = { id: String(id), type, at: iso(at) }
  if (extra && extra.sidechain) { item.sidechain = true; item.parentId = extra.parentId ? String(extra.parentId) : null }
  return item
}

function user (id, text, { at, images = 0, queued = false, sidechain, parentId } = {}) {
  const c = cap(text, TEXT_CAP)
  const item = { ...base('user', id, at, { sidechain, parentId }), text: c.value }
  if (images) item.images = images
  if (queued) item.queued = true
  if (c.truncated) item.truncated = true
  return item
}

function assistant (id, text, { at, sidechain, parentId } = {}) {
  const c = cap(text, TEXT_CAP)
  const item = { ...base('assistant', id, at, { sidechain, parentId }), text: c.value }
  if (c.truncated) item.truncated = true
  return item
}

function thinking (id, { at, sidechain, parentId } = {}) {
  return base('thinking', id, at, { sidechain, parentId })
}

// result: undefined/null while running, else { ok, text, images }.
function tool (id, { tool: name, toolKind, input, title, result, at, sidechain, parentId }) {
  const c = capInput(input && typeof input === 'object' ? input : null)
  const item = {
    ...base('tool', id, at, { sidechain, parentId }),
    tool: typeof name === 'string' && name ? name : 'tool',
    toolKind: TOOL_KINDS.includes(toolKind) ? toolKind : 'other',
    input: c.value || {}
  }
  if (c.truncated) item.inputTruncated = true
  if (typeof title === 'string' && title) item.title = cap(title.replace(/\s+/g, ' ').trim(), 200).value
  item.result = null
  if (result) {
    const r = cap(typeof result.text === 'string' ? result.text : '', RESULT_CAP)
    item.result = { ok: result.ok !== false, text: r.value }
    if (r.truncated) item.result.truncated = true
    if (result.images) item.result.images = result.images
  }
  return item
}

function todo (id, todos, { at } = {}) {
  return {
    ...base('todo', id, at),
    todos: (Array.isArray(todos) ? todos : []).filter(t => t && typeof t.text === 'string').map(t => ({
      text: cap(t.text, NOTICE_CAP).value,
      status: TODO_STATUSES.includes(t.status) ? t.status : 'pending'
    }))
  }
}

function plan (id, text, { at, status = 'pending', feedback } = {}) {
  const item = { ...base('plan', id, at), plan: cap(text, TEXT_CAP).value, status: PLAN_STATUSES.includes(status) ? status : 'pending' }
  if (typeof feedback === 'string' && feedback) item.feedback = cap(feedback, NOTICE_CAP).value
  return item
}

function question (id, questions, { at, answer = null } = {}) {
  return {
    ...base('question', id, at),
    questions: (Array.isArray(questions) ? questions : []).filter(q => q && typeof q.question === 'string').map(q => {
      const out = { question: q.question, multiSelect: q.multiSelect === true, options: [] }
      if (typeof q.header === 'string' && q.header) out.header = q.header
      for (const o of Array.isArray(q.options) ? q.options : []) {
        if (!o || typeof o.label !== 'string' || !o.label) continue
        out.options.push(typeof o.description === 'string' && o.description ? { label: o.label, description: o.description } : { label: o.label })
      }
      return out
    }),
    answer: typeof answer === 'string' ? answer : null
  }
}

function notice (id, level, text, { at } = {}) {
  return { ...base('notice', id, at), level: NOTICE_LEVELS.includes(level) ? level : 'info', text: cap(text, NOTICE_CAP).value }
}

function shell (id, command, { at, stdout, stderr } = {}) {
  const item = { ...base('shell', id, at), command: cap(command, NOTICE_CAP).value }
  if (typeof stdout === 'string') item.stdout = cap(stdout, RESULT_CAP).value
  if (typeof stderr === 'string') item.stderr = cap(stderr, RESULT_CAP).value
  return item
}

function page ({ items, cursor, startCursor = null, more = false, reset = false }) {
  const out = { format: FORMAT, items, cursor: String(cursor), startCursor: startCursor === null || startCursor === undefined ? null : String(startCursor), more: !!more }
  if (reset) out.reset = true
  return out
}

// Why an item breaks the format, or null. For the adapter contract test
// and adapters' own tests; never run on the hot path.
function validate (item) {
  if (!item || typeof item !== 'object') return 'not an object'
  if (typeof item.id !== 'string' || !item.id) return 'no id'
  if (!TYPES.includes(item.type)) return `unknown type ${item.type}`
  if (item.at !== null && (typeof item.at !== 'string' || !Number.isFinite(Date.parse(item.at)))) return 'at is not an ISO time or null'
  const str = k => typeof item[k] === 'string'
  switch (item.type) {
    case 'user': case 'assistant': return str('text') ? null : 'no text'
    case 'tool':
      if (!str('tool') || !TOOL_KINDS.includes(item.toolKind)) return 'tool needs tool and a known toolKind'
      if (!item.input || typeof item.input !== 'object') return 'tool input must be an object'
      if (item.result !== null && (typeof item.result !== 'object' || typeof item.result.ok !== 'boolean' || typeof item.result.text !== 'string')) return 'bad tool result'
      return null
    case 'todo': return Array.isArray(item.todos) && item.todos.every(t => typeof t.text === 'string' && TODO_STATUSES.includes(t.status)) ? null : 'bad todos'
    case 'plan': return str('plan') && PLAN_STATUSES.includes(item.status) ? null : 'bad plan'
    case 'question': return Array.isArray(item.questions) ? null : 'no questions'
    case 'notice': return NOTICE_LEVELS.includes(item.level) && str('text') ? null : 'bad notice'
    case 'shell': return str('command') ? null : 'no command'
    default: return null
  }
}

function validatePage (p) {
  if (!p || p.format !== FORMAT) return 'format is not items'
  if (!Array.isArray(p.items)) return 'no items'
  if (typeof p.cursor !== 'string') return 'cursor must be a string'
  if (p.startCursor !== null && typeof p.startCursor !== 'string') return 'startCursor must be a string or null'
  const ids = new Set()
  for (const item of p.items) {
    const why = validate(item)
    if (why) return `item ${item && item.id}: ${why}`
    if (ids.has(item.id)) return `duplicate id ${item.id}`
    ids.add(item.id)
  }
  return null
}

module.exports = {
  FORMAT,
  TYPES,
  TOOL_KINDS,
  NOTICE_LEVELS,
  TODO_STATUSES,
  PLAN_STATUSES,
  user,
  assistant,
  thinking,
  tool,
  todo,
  plan,
  question,
  notice,
  shell,
  page,
  validate,
  validatePage
}
