'use strict'

// The OpenCode adapter (CON-069, CON-045 step 4). OpenCode is integrated
// through a plugin only (no `--port` server, decision 4):
//
//   registration  install() drops opencode-plugin.mjs, a file we own, as
//                 <config>/opencode/plugins/conductore.js; never opencode.json
//   events        the plugin runs inside OpenCode and hands its bus events to
//                 `conductore-hook --agent opencode <event>` (the spool, with
//                 the pane's TMUX/HERDR env); normalize() maps them onto
//                 Claude Code's hook vocabulary, child sessions folded into
//                 their root as subagents
//   liveness      the hook's parent is the OpenCode process (comm opencode)
//   approvals     the plugin runs the hook as a blocking PermissionRequest and
//                 replies through OpenCode's own client with what the hook
//                 printed (hookAnswer): once / reject, question answers.
//                 "always" is a once: OpenCode's own always saves its broader
//                 patterns (`npm *` for `npm test`), more than the user saw;
//                 the phone saves a Conductore rule instead. So, for the
//                 daemon, a hook like Claude Code's
//   chat          OpenCode's SQLite database, read-only (node:sqlite, Node
//                 22.5+), as neutral chat items paged by message id
//   usage         tokens and cost OpenCode reports per assistant message
//                 (`usage` section `opencode`); no plan limits
//   brain         `opencode run --pure` with an in-memory database, every
//                 permission denied and every tool off, the prompt on stdin
//
// Everything heavy is required lazily: the daemon loads this module for
// every OpenCode event.

const fs = require('fs')
const os = require('os')
const path = require('path')

const lazy = name => { let m; return () => m || (m = require(name)) }
const items = lazy('./chat-items')
const proc = lazy('../proc')

const ID = 'opencode'
const LABEL = 'OpenCode'
const PLUGIN_FILE = 'conductore.js'
const PLUGIN_MARK = 'CONDUCTORE_PLUGIN=opencode'
const PLUGIN_SOURCE = path.join(__dirname, 'opencode-plugin.mjs')
const HOOK_PLACEHOLDER = "'__CONDUCTORE_HOOK__'"
// Messages per transcript page.
const PAGE_MESSAGES = 40

function capabilities () {
  return {
    events: 'plugin',
    approvals: 'hook',
    always: false,
    questions: true,
    plans: false,
    chat: 'items',
    send: 'pane',
    interrupt: 'pane',
    liveUsage: false,
    limits: false,
    history: true,
    brain: true,
    brainSchema: false,
    accounts: null,
    facts: 'partial',
    undo: false
  }
}

// --- detection and registration -----------------------------------------------

function home (env) { return env.HOME || os.homedir() }

// The opencode binary: on PATH, else where its installer puts it.
function findBin (env = process.env) {
  const dirs = String(env.PATH || '').split(path.delimiter).filter(Boolean)
  dirs.push(path.join(home(env), '.opencode', 'bin'))
  for (const dir of dirs) {
    const file = path.join(dir, 'opencode')
    try { fs.accessSync(file, fs.constants.X_OK); if (fs.statSync(file).isFile()) return file } catch {}
  }
  return null
}

function detect (env = process.env) {
  const bin = findBin(env)
  if (!bin) return { present: false, version: null, bin: null }
  try {
    const text = require('child_process').execFileSync(bin, ['--version'], { encoding: 'utf8', timeout: 5000, stdio: ['ignore', 'pipe', 'ignore'], env: { ...env, OPENCODE_DISABLE_AUTOUPDATE: '1' } })
    const m = /(\d+\.\d+\.\d+)/.exec(text)
    return { present: true, version: m ? m[1] : null, bin }
  } catch {
    return { present: true, version: null, bin }
  }
}

// OpenCode's global config directory (where it loads plugins/ from).
function configDir (env = process.env) {
  return path.join(env.XDG_CONFIG_HOME || path.join(home(env), '.config'), 'opencode')
}

function pluginPath (env = process.env) {
  return path.join(configDir(env), 'plugins', PLUGIN_FILE)
}

// The plugin file for this hook client.
function renderPlugin (hookBin) {
  const src = fs.readFileSync(PLUGIN_SOURCE, 'utf8')
  return src.replace(HOOK_PLACEHOLDER, JSON.stringify(hookBin))
}

const isOurs = text => typeof text === 'string' && text.includes(PLUGIN_MARK)

// Writes plugins/conductore.js (atomic). A file of that name that is not
// ours is kept as conductore.js.bak-<time> first. opencode.json is never
// touched. Returns what `install` prints for OpenCode, or { error }.
function install ({ hookBin, env = process.env }) {
  if (!hookBin || !fs.existsSync(hookBin)) return { error: `client not found at ${hookBin}` }
  const file = pluginPath(env)
  let text
  try { text = renderPlugin(hookBin) } catch (err) { return { error: `cannot read the plugin source: ${err.message}` } }
  let current = null
  try { current = fs.readFileSync(file, 'utf8') } catch {}
  if (current === text) return { plugin: file, action: 'unchanged' }
  let backup = null
  try {
    fs.mkdirSync(path.dirname(file), { recursive: true })
    if (current !== null && !isOurs(current)) {
      backup = `${file}.bak-${Date.now()}`
      fs.copyFileSync(file, backup)
    }
    const tmp = `${file}.tmp-${process.pid}`
    fs.writeFileSync(tmp, text, { mode: 0o644 })
    fs.renameSync(tmp, file)
  } catch (err) {
    return { error: `cannot write ${file}: ${err.message}` }
  }
  const out = { plugin: file, action: current === null ? 'installed' : 'updated' }
  if (backup) out.backup = backup
  return out
}

// Removes our plugin file (only when it is ours).
function uninstall ({ env = process.env } = {}) {
  const file = pluginPath(env)
  let current = null
  try { current = fs.readFileSync(file, 'utf8') } catch {}
  if (current === null || !isOurs(current)) return { plugin: file, removed: false }
  try { fs.unlinkSync(file) } catch (err) { return { error: `cannot remove ${file}: ${err.message}` } }
  return { plugin: file, removed: true }
}

async function doctor ({ env = process.env, hookBin } = {}) {
  // Informative only (`optional`: the phone never counts them as a
  // failure); nothing at all where OpenCode is not installed.
  const found = detect(env)
  if (!found.present) return []
  const checks = []
  const add = (name, ok, detail) => checks.push({ name, ok, detail, optional: true })
  add('OpenCode', true, `${found.bin} ${found.version || '(version unknown)'}`)
  const file = pluginPath(env)
  let text = null
  try { text = fs.readFileSync(file, 'utf8') } catch {}
  const ours = isOurs(text)
  const m = ours ? /const HOOK = ("(?:[^"\\]|\\.)*")/.exec(text) : null
  let hook = null
  try { hook = m ? JSON.parse(m[1]) : null } catch {}
  const hookOk = !!hook && fs.existsSync(hook) && (!hookBin || hook === hookBin)
  add('OpenCode plugin', ours && hookOk, !ours ? `${file} missing: run install` : hookOk ? file : `${file} points at ${hook}: run install`)
  add('OpenCode chat reader', !!sqlite(), sqlite() ? 'node:sqlite' : `Node ${process.versions.node} has no node:sqlite (22.5+): no chat view or usage for OpenCode`)
  return checks
}

// --- events -------------------------------------------------------------------

// OpenCode tool names -> the neutral (Claude Code) ones risk.js, rules.js and
// the phone's tool cards know. Unknown tools (MCP: <server>_<tool>) keep
// their own name.
const TOOLS = {
  bash: 'Bash',
  edit: 'Edit',
  multiedit: 'MultiEdit',
  patch: 'Edit',
  apply_patch: 'Edit',
  write: 'Write',
  read: 'Read',
  grep: 'Grep',
  glob: 'Glob',
  list: 'LS',
  codesearch: 'Grep',
  webfetch: 'WebFetch',
  websearch: 'WebSearch',
  task: 'Task',
  todowrite: 'TodoWrite',
  todoread: 'TodoWrite',
  question: 'AskUserQuestion'
}

// Permission types (`permission.asked` .permission) -> tool names.
const PERMISSIONS = {
  bash: 'Bash',
  edit: 'Edit',
  write: 'Write',
  read: 'Read',
  webfetch: 'WebFetch',
  websearch: 'WebSearch',
  task: 'Task',
  external_directory: 'Read',
  doom_loop: 'doom_loop'
}

function toolName (name) {
  if (typeof name !== 'string' || !name) return 'tool'
  return Object.prototype.hasOwnProperty.call(TOOLS, name) ? TOOLS[name] : name
}

const KINDS = {
  Bash: 'bash', Edit: 'edit', MultiEdit: 'edit', Write: 'write', Read: 'read', LS: 'search', Grep: 'search', Glob: 'search',
  WebFetch: 'web', WebSearch: 'web', Task: 'task', TodoWrite: 'todo', AskUserQuestion: 'question'
}

// The neutral kind of an OpenCode (or already neutral) tool name.
function toolKind (name) {
  if (typeof name !== 'string' || !name) return 'other'
  const neutral = toolName(name)
  if (Object.prototype.hasOwnProperty.call(KINDS, neutral)) return KINDS[neutral]
  if (Object.prototype.hasOwnProperty.call(KINDS, name)) return KINDS[name]
  return name.startsWith('mcp__') ? 'mcp' : 'other'
}

// OpenCode's camelCase tool arguments -> Claude Code's snake_case ones.
const KEYS = { filePath: 'file_path', oldString: 'old_string', newString: 'new_string', replaceAll: 'replace_all', include: 'glob', subagent_type: 'subagent_type' }

function toolInput (name, args) {
  if (!args || typeof args !== 'object' || Array.isArray(args)) return {}
  const out = {}
  for (const [k, v] of Object.entries(args)) out[Object.prototype.hasOwnProperty.call(KEYS, k) ? KEYS[k] : k] = v
  if (name === 'question') return { questions: questionsOf(args.questions) }
  if (name === 'todowrite' && Array.isArray(args.todos)) {
    out.todos = args.todos.map(t => ({ content: t && t.content, status: t && t.status }))
  }
  return out
}

// OpenCode questions -> AskUserQuestion's.
function questionsOf (list) {
  if (!Array.isArray(list)) return []
  return list.filter(q => q && typeof q.question === 'string').map(q => {
    const out = { question: q.question, multiSelect: q.multiple === true, options: [] }
    if (typeof q.header === 'string' && q.header) out.header = q.header
    for (const o of Array.isArray(q.options) ? q.options : []) {
      if (o && typeof o.label === 'string' && o.label) out.options.push(typeof o.description === 'string' && o.description ? { label: o.label, description: o.description } : { label: o.label })
    }
    return out
  })
}

// What a permission request is about, as the tool input the phone shows
// and the rules match: a command for bash, a path for files, a URL.
function permissionInput (p) {
  const md = (p.metadata && typeof p.metadata === 'object') ? p.metadata : {}
  const patterns = Array.isArray(p.patterns) ? p.patterns.filter(x => typeof x === 'string') : []
  switch (p.permission) {
    case 'bash': return { command: typeof md.command === 'string' ? md.command : patterns.join(' && ') }
    case 'edit': case 'write': case 'read': case 'external_directory': {
      const file = md.filepath || md.filePath || md.path || patterns[0]
      const out = { file_path: typeof file === 'string' ? file : '' }
      if (typeof md.diff === 'string') out.diff = md.diff.slice(0, 2000)
      return out
    }
    case 'webfetch': return { url: md.url || patterns[0] || '' }
    default: return { patterns, ...(Object.keys(md).length ? { metadata: md } : {}) }
  }
}

// The database the plugin named (OPENCODE_DB, else <data>/opencode.db).
function storeOf (raw) {
  const s = raw && raw.store
  if (!s || typeof s.data !== 'string' || !path.isAbsolute(s.data)) return null
  if (typeof s.db === 'string' && s.db && s.db !== ':memory:') return path.isAbsolute(s.db) ? s.db : path.join(s.data, s.db)
  return path.join(s.data, 'opencode.db')
}

// Why a turn failed, in StopFailure's words.
function errorType (err) {
  const e = err || {}
  const code = e.data && e.data.statusCode
  if (code === 429) return 'rate_limit'
  if (code === 401 || code === 403 || e.name === 'ProviderAuthError') return 'authentication_failed'
  if (code === 402) return 'billing_error'
  if (typeof code === 'number' && code >= 500) return 'server_error'
  if (code === 400) return 'invalid_request'
  if (e.name === 'MessageOutputLengthError') return 'max_output_tokens'
  return 'unknown'
}

const cut = (s, n) => (typeof s === 'string' ? (s.length > n ? s.slice(0, n - 1) + '…' : s) : undefined)

// One spool entry from the plugin -> the daemon's event (null drops it).
function normalize (raw, header = {}) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null
  const type = raw.type
  const sid = raw.session_id
  if (typeof type !== 'string' || typeof sid !== 'string' || !sid) return null
  const p = (raw.properties && typeof raw.properties === 'object') ? raw.properties : {}
  const child = typeof raw.child === 'string' && raw.child ? raw.child : null
  const ev = { session_id: sid, agent_kind: ID }
  if (typeof raw.cwd === 'string' && raw.cwd) ev.cwd = raw.cwd
  const db = storeOf(raw)
  if (db) ev.transcript_path = `${ID}:${db}`
  if (child) ev.agent_id = child
  switch (type) {
    case 'session.created':
      if (child) return null
      ev.hook_event_name = 'SessionStart'
      ev.source = 'startup'
      if (p.info && typeof p.info.directory === 'string' && !ev.cwd) ev.cwd = p.info.directory
      return ev
    case 'chat.message':
      if (child) return null
      ev.hook_event_name = 'UserPromptSubmit'
      ev.prompt = typeof p.text === 'string' ? p.text : ''
      return ev
    case 'tool.execute.before':
    case 'tool.execute.after': {
      ev.hook_event_name = type === 'tool.execute.before' ? 'PreToolUse' : 'PostToolUse'
      ev.tool_name = toolName(p.tool)
      ev.tool_input = toolInput(p.tool, p.args)
      ev.tool_kind = toolKind(p.tool)
      if (typeof p.callID === 'string') ev.tool_use_id = p.callID
      if (type === 'tool.execute.after') {
        ev.tool_response = { output: typeof p.output === 'string' ? p.output : '', ...(typeof p.exit === 'number' ? { exit: p.exit } : {}) }
        if (ev.tool_name === 'Bash' && typeof p.exit === 'number' && p.exit !== 0) ev.hook_event_name = 'PostToolUseFailure'
      }
      return ev
    }
    case 'permission.asked': {
      if (typeof p.id !== 'string') return null
      ev.hook_event_name = 'PermissionRequest'
      ev.tool_name = Object.prototype.hasOwnProperty.call(PERMISSIONS, p.permission) ? PERMISSIONS[p.permission] : (typeof p.permission === 'string' && p.permission ? p.permission : 'tool')
      ev.tool_input = permissionInput(p)
      ev.tool_kind = toolKind(ev.tool_name)
      ev.opencode_request = { id: p.id, kind: 'permission', always: Array.isArray(p.always) ? p.always.filter(x => typeof x === 'string').slice(0, 20) : [] }
      delete ev.agent_id // the root agent is the one that waits
      return ev
    }
    case 'question.asked': {
      if (typeof p.id !== 'string') return null
      ev.hook_event_name = 'PermissionRequest'
      ev.tool_name = 'AskUserQuestion'
      ev.tool_input = { questions: questionsOf(p.questions) }
      ev.tool_kind = 'question'
      ev.opencode_request = { id: p.id, kind: 'question' }
      delete ev.agent_id
      return ev
    }
    case 'permission.replied':
      if (p.reply !== 'reject') return null
      ev.hook_event_name = 'PermissionDenied'
      delete ev.agent_id
      return ev
    case 'session.idle':
      ev.hook_event_name = child ? 'SubagentStop' : 'Stop'
      if (typeof raw.last_text === 'string' && raw.last_text) ev.last_assistant_message = raw.last_text
      return ev
    case 'session.status': {
      const st = p.status || {}
      if (st.type !== 'retry' || child) return null
      ev.hook_event_name = 'Notification'
      ev.notification_type = 'retry'
      ev.message = `Retrying (attempt ${Number(st.attempt) || 1})${typeof st.message === 'string' && st.message ? `: ${cut(st.message, 200)}` : ''}`
      return ev
    }
    case 'session.error': {
      const e = p.error || {}
      // An interrupt: session.idle follows and ends the turn.
      if (e.name === 'MessageAbortedError') return null
      ev.hook_event_name = child ? 'SubagentStop' : 'StopFailure'
      ev.error = errorType(e)
      if (e.data && typeof e.data.message === 'string') ev.error_details = cut(e.data.message, 300)
      if (typeof raw.last_text === 'string' && raw.last_text) ev.last_assistant_message = raw.last_text
      return ev
    }
    case 'session.deleted':
      if (child) return null
      ev.hook_event_name = 'SessionEnd'
      ev.reason = 'deleted'
      return ev
    default:
      return null
  }
}

// The OpenCode process the plugin's hook reported (its parent).
function identifyProcess (pid) {
  pid = Number(pid)
  if (!Number.isInteger(pid) || pid <= 1 || !proc().hasProc()) return null
  const st = proc().stat(pid)
  if (!st || !/opencode/i.test(st.comm) || !st.startTime) return null
  return { pid, startTime: st.startTime }
}

// --- approvals ----------------------------------------------------------------

const isQuestion = event => !!event && (event.tool_name === 'AskUserQuestion' || (event.opencode_request && event.opencode_request.kind === 'question'))

// The questions of a request, in order (state.js keeps them whole).
const questionList = event => (event && event.tool_input && Array.isArray(event.tool_input.questions) ? event.tool_input.questions : [])

// The phone's answers ({ "<question>": "<answer>" | [answers] }): every
// question answered, else { error }.
function checkAnswers (event, answers) {
  if (!isQuestion(event)) return { error: 'not a question' }
  if (!answers || typeof answers !== 'object' || Array.isArray(answers)) return { error: 'answers must be an object keyed by question' }
  const qs = questionList(event)
  if (!qs.length) return { error: 'the question has no questions' }
  for (const q of qs) {
    const a = answers[q.question]
    const list = Array.isArray(a) ? a : [a]
    if (!list.length || !list.every(x => typeof x === 'string' && x.trim())) return { error: `no answer for "${cut(q.question, 80)}"` }
  }
  return { updatedInput: { ...event.tool_input, answers } }
}

// The line the plugin's waiting hook prints; the plugin replies through
// OpenCode's client with it ('\n' = leave OpenCode's own prompt).
function hookAnswer (event, decision, message, answers) {
  if (isQuestion(event)) {
    if (decision === 'answer' && answers && typeof answers === 'object') {
      const out = questionList(event).map(q => {
        const a = answers[q.question]
        const list = Array.isArray(a) ? a : typeof a === 'string' ? (q.multiSelect ? a.split(', ') : [a]) : []
        return list.filter(x => typeof x === 'string' && x)
      })
      return JSON.stringify({ answers: out }) + '\n'
    }
    if (decision === 'deny') return JSON.stringify({ reject: true }) + '\n'
    return '\n'
  }
  switch (decision) {
    case 'allow': return JSON.stringify({ reply: 'once' }) + '\n'
    // OpenCode's always would save its own, broader patterns.
    case 'always': return JSON.stringify({ reply: 'once' }) + '\n'
    case 'deny': {
      const out = { reply: 'reject' }
      if (typeof message === 'string' && message.trim()) out.message = message.trim().slice(0, 2000)
      return JSON.stringify(out) + '\n'
    }
    default: return '\n'
  }
}

// --- the database ---------------------------------------------------------------

let sqliteMod
// node:sqlite (Node 22.5+), without its ExperimentalWarning on stderr; null
// when this Node has none.
function sqlite () {
  if (sqliteMod !== undefined) return sqliteMod
  const emit = process.emitWarning
  process.emitWarning = (w, ...rest) => {
    const text = typeof w === 'string' ? w : (w && w.message) || ''
    if (/SQLite/i.test(text)) return
    return emit.call(process, w, ...rest)
  }
  try { sqliteMod = require('node:sqlite') } catch { sqliteMod = null } finally { process.emitWarning = emit }
  return sqliteMod
}

// Opens a database read-only; null when it cannot.
function open (file) {
  const mod = sqlite()
  if (!mod || !file) return null
  try { if (!fs.statSync(file).isFile()) return null } catch { return null }
  try {
    return new mod.DatabaseSync(file, { readOnly: true, timeout: 2000 })
  } catch {
    try { return new mod.DatabaseSync(file, { readOnly: true }) } catch { return null }
  }
}

function withDb (file, fn) {
  const db = open(file)
  if (!db) return null
  try { return fn(db) } finally { try { db.close() } catch {} }
}

// The databases to look in for an agent: the one its plugin named, then
// every other opencode*.db beside it (OpenCode names it after its release
// channel), then the default location.
function dbCandidates (agent, env = process.env) {
  const out = []
  const ref = agent && typeof agent.transcriptPath === 'string' && agent.transcriptPath.startsWith(`${ID}:`) ? agent.transcriptPath.slice(ID.length + 1) : null
  if (ref && path.isAbsolute(ref)) out.push(ref)
  const dirs = new Set()
  if (ref && path.isAbsolute(ref)) dirs.add(path.dirname(ref))
  dirs.add(defaultDataDir(env))
  for (const dir of dirs) {
    let names = []
    try { names = fs.readdirSync(dir) } catch {}
    for (const n of names.sort()) if (/^opencode.*\.db$/.test(n)) out.push(path.join(dir, n))
  }
  return [...new Set(out)]
}

function defaultDataDir (env = process.env) {
  return path.join(env.XDG_DATA_HOME || path.join(home(env), '.local', 'share'), 'opencode')
}

// The database that holds this session, opened; or { error }.
function sessionDb (agent, env) {
  if (!sqlite()) return { error: `reading OpenCode sessions needs Node 22.5 or newer (node:sqlite); this is Node ${process.versions.node}` }
  const sid = agent && agent.sessionId
  if (typeof sid !== 'string' || !sid) return { error: 'no session id' }
  for (const file of dbCandidates(agent, env)) {
    const db = open(file)
    if (!db) continue
    try {
      if (db.prepare('SELECT 1 FROM session WHERE id = ?').get(sid)) return { db, file }
    } catch {}
    try { db.close() } catch {}
  }
  return { error: `OpenCode session ${sid} not found` }
}

const parse = text => { try { return JSON.parse(text) } catch { return null } }

// --- chat -----------------------------------------------------------------------

function messagesOf (db, sid, { cursor, beforeCursor }) {
  const cols = 'id, time_created, data'
  if (typeof beforeCursor === 'string' && beforeCursor) {
    const rows = db.prepare(`SELECT ${cols} FROM message WHERE session_id = ? AND id < ? ORDER BY id DESC LIMIT ?`).all(sid, beforeCursor, PAGE_MESSAGES + 1)
    const more = rows.length > PAGE_MESSAGES
    return { rows: rows.slice(0, PAGE_MESSAGES).reverse(), before: true, earlier: more }
  }
  if (typeof cursor === 'string' && cursor) {
    // From the last message of the previous page on: it may have grown.
    const rows = db.prepare(`SELECT ${cols} FROM message WHERE session_id = ? AND id >= ? ORDER BY id LIMIT ?`).all(sid, cursor, PAGE_MESSAGES + 1)
    const more = rows.length > PAGE_MESSAGES
    const earlier = !!db.prepare('SELECT 1 FROM message WHERE session_id = ? AND id < ? LIMIT 1').get(sid, cursor)
    return { rows: rows.slice(0, PAGE_MESSAGES), more, earlier, known: !!rows.length && rows[0].id === cursor }
  }
  const rows = db.prepare(`SELECT ${cols} FROM message WHERE session_id = ? ORDER BY id DESC LIMIT ?`).all(sid, PAGE_MESSAGES + 1)
  const earlier = rows.length > PAGE_MESSAGES
  return { rows: rows.slice(0, PAGE_MESSAGES).reverse(), earlier }
}

function partsOf (db, ids) {
  const out = new Map()
  if (!ids.length) return out
  const stmt = db.prepare('SELECT id, message_id, time_created, data FROM part WHERE message_id = ? ORDER BY id')
  for (const id of ids) out.set(id, stmt.all(id))
  return out
}

function resultText (state) {
  if (state.status === 'error') return typeof state.error === 'string' ? state.error : 'error'
  return typeof state.output === 'string' ? state.output : ''
}

// One message and its parts -> chat items.
function itemsOf (msg, parts) {
  const c = items()
  const m = parse(msg.data) || {}
  const at = (m.time && m.time.created) || msg.time_created
  const out = []
  if (m.role === 'user') {
    const texts = []
    let images = 0
    for (const row of parts) {
      const p = parse(row.data) || {}
      if (p.type === 'text' && !p.synthetic && !p.ignored && typeof p.text === 'string') texts.push(p.text)
      else if (p.type === 'file' && /^image\//.test(p.mime || '')) images++
      else if (p.type === 'compaction') out.push(c.notice(row.id, 'compacted', 'Conversation compacted', { at }))
    }
    const text = texts.join('\n').trim()
    if (text || images) out.unshift(c.user(msg.id, text, { at, images }))
    return out
  }
  for (const row of parts) {
    const p = parse(row.data) || {}
    const pat = (p.time && p.time.start) || row.time_created || at
    switch (p.type) {
      case 'text':
        if (!p.synthetic && typeof p.text === 'string' && p.text.trim()) out.push(c.assistant(row.id, p.text, { at: pat }))
        break
      case 'reasoning':
        out.push(c.thinking(row.id, { at: pat }))
        break
      case 'tool': {
        const st = p.state || {}
        const tat = (st.time && st.time.start) || pat
        if (p.tool === 'todowrite') {
          const todos = (st.input && Array.isArray(st.input.todos) ? st.input.todos : []).map(t => ({ text: t && t.content, status: t && t.status }))
          out.push(c.todo(row.id, todos, { at: tat }))
          break
        }
        if (p.tool === 'question') {
          const answers = st.metadata && Array.isArray(st.metadata.answers) ? st.metadata.answers : null
          const answer = answers ? answers.map(a => (Array.isArray(a) ? a.join(', ') : String(a))).join('; ') : null
          out.push(c.question(row.id, questionsOf(st.input && st.input.questions), { at: tat, answer }))
          break
        }
        const done = st.status === 'completed' || st.status === 'error'
        out.push(c.tool(row.id, {
          tool: toolName(p.tool),
          toolKind: toolKind(p.tool),
          input: toolInput(p.tool, st.input),
          title: typeof st.title === 'string' ? st.title : undefined,
          result: done ? { ok: st.status === 'completed' && !(st.metadata && typeof st.metadata.exit === 'number' && st.metadata.exit !== 0), text: resultText(st) } : null,
          at: tat
        }))
        break
      }
      case 'retry':
        out.push(c.notice(row.id, 'info', `Retrying${p.error && p.error.data && p.error.data.message ? `: ${p.error.data.message}` : ''}`, { at: pat }))
        break
      case 'compaction':
        out.push(c.notice(row.id, 'compacted', 'Conversation compacted', { at: pat }))
        break
      default:
    }
  }
  if (m.error && typeof m.error === 'object') {
    if (m.error.name === 'MessageAbortedError') out.push(c.notice(`${msg.id}:error`, 'interrupted', 'Interrupted', { at: (m.time && m.time.completed) || at }))
    else out.push(c.notice(`${msg.id}:error`, 'error', (m.error.data && typeof m.error.data.message === 'string' && m.error.data.message) || m.error.name || 'Error', { at: (m.time && m.time.completed) || at }))
  }
  return out
}

// One chat page of the session (chat-items.js), or { error }.
//   no cursor        the last PAGE_MESSAGES messages
//   cursor           from that message on (it is sent again: it may have
//                    grown); items keep their ids, the app replaces them
//   beforeCursor     the messages before that one
// Cursors are OpenCode message ids (they sort by time).
function readTranscript (agent, opts = {}, env = process.env) {
  const found = sessionDb(agent, env)
  if (found.error) return { error: found.error }
  const { db } = found
  try {
    const sid = agent.sessionId
    const r = messagesOf(db, sid, opts)
    const parts = partsOf(db, r.rows.map(x => x.id))
    const list = []
    for (const msg of r.rows) list.push(...itemsOf(msg, parts.get(msg.id) || []))
    const first = r.rows.length ? r.rows[0].id : null
    const last = r.rows.length ? r.rows[r.rows.length - 1].id : null
    const c = items()
    if (r.before) return c.page({ items: list, cursor: opts.beforeCursor, startCursor: r.earlier ? first : null, more: false })
    // A cursor that names no message any more (reverted, deleted): start over.
    if (opts.cursor && !r.known) {
      db.close()
      const fresh = readTranscript(agent, {}, env)
      if (!fresh.error) fresh.reset = true
      return fresh
    }
    return c.page({ items: list, cursor: last || opts.cursor || '', startCursor: r.earlier ? first : null, more: !!r.more })
  } catch (err) {
    return { error: `cannot read the OpenCode session: ${err.message}` }
  } finally {
    try { db.close() } catch {}
  }
}

// --- dashboard facts and usage -----------------------------------------------------

const TOKEN_ZERO = () => ({ input: 0, output: 0, cacheWrite: 0, cacheRead: 0, total: 0 })

function tokensOf (m) {
  const t = (m && m.tokens) || {}
  const n = v => (typeof v === 'number' && v > 0 ? v : 0)
  const cache = t.cache || {}
  return { input: n(t.input), output: n(t.output) + n(t.reasoning), cacheWrite: n(cache.write), cacheRead: n(cache.read) }
}

// Recent prompts, replies, tokens and cost since `since` (digest.js Tail).
function readTail (agent, { since = 0, repliesSince = since } = {}, env = process.env) {
  if (!agent || !agent.sessionId) return null
  const found = sessionDb(agent, env)
  if (found.error) return null
  const { db } = found
  const out = { tokens: null, costUsd: null, replies: [], prompts: [], lastReply: null, runs: [], apiError: null, first: null, partial: false }
  try {
    const from = Math.min(since, repliesSince)
    const rows = db.prepare('SELECT id, time_created, data FROM message WHERE session_id = ? AND time_created >= ? ORDER BY id').all(agent.sessionId, Math.max(0, from - 1))
    const textStmt = db.prepare("SELECT data FROM part WHERE message_id = ? ORDER BY id")
    const tk = TOKEN_ZERO()
    let cost = 0
    let counted = false
    for (const row of rows) {
      const m = parse(row.data) || {}
      const t = (m.time && m.time.created) || row.time_created
      if (out.first === null) out.first = t
      const texts = []
      for (const pr of textStmt.all(row.id)) {
        const p = parse(pr.data) || {}
        if (p.type === 'text' && !p.synthetic && typeof p.text === 'string' && p.text.trim()) texts.push(p.text.trim())
      }
      const text = texts.join('\n')
      if (m.role === 'assistant') {
        if (t >= since) {
          const u = tokensOf(m)
          tk.input += u.input; tk.output += u.output; tk.cacheWrite += u.cacheWrite; tk.cacheRead += u.cacheRead
          if (typeof m.cost === 'number') cost += m.cost
          counted = true
        }
        if (m.error && m.error.name !== 'MessageAbortedError') out.apiError = { at: t, type: errorType(m.error) }
        if (text) {
          out.lastReply = text
          if (t >= repliesSince) out.replies.push({ at: t, text })
        }
      } else if (m.role === 'user' && text && t >= repliesSince) {
        out.prompts.push({ at: t, text })
        out.apiError = null
      }
    }
    if (counted) {
      tk.total = tk.input + tk.output + tk.cacheWrite + tk.cacheRead
      out.tokens = tk
      out.costUsd = Math.round(cost * 1e4) / 1e4
    }
    out.replies = out.replies.slice(-3)
    return out
  } catch {
    return out
  } finally {
    try { db.close() } catch {}
  }
}

// The `usage` section: tokens and OpenCode's own cost per day, project,
// provider/model (and session), from every database in OpenCode's data
// directory. ctx: { range: {from, to, today}, projectOf, localDate, detail,
// env }. No plan limits: OpenCode has none of its own.
function usageReport ({ range, projectOf, localDate, detail = {}, env = process.env }) {
  if (!sqlite()) return { present: fs.existsSync(defaultDataDir(env)), limits: [], error: 'node:sqlite missing (Node 22.5+)' }
  const files = dbCandidates(null, env)
  if (!files.length) return { present: false }
  const fromMs = new Date(`${range.from < range.today ? range.from : range.today}T00:00:00`).getTime()
  const rows = new Map()
  const bySession = new Map()
  // The same totals as Claude Code's section (usage.js totalsOf).
  const zero = () => ({ input: 0, output: 0, cacheWrite: 0, cacheRead: 0, tokens: 0, messages: 0, costUsd: 0 })
  const addTo = (t, u, cost) => {
    t.input += u.input; t.output += u.output; t.cacheWrite += u.cacheWrite; t.cacheRead += u.cacheRead
    t.tokens += u.input + u.output + u.cacheWrite + u.cacheRead; t.messages++; t.costUsd += cost
  }
  const totals = zero()
  const today = zero()
  const providers = new Map()
  let active = null
  for (const file of files) {
    withDb(file, db => {
      let list = []
      try {
        list = db.prepare("SELECT m.session_id AS sid, m.time_created AS at, m.data AS data, s.directory AS dir FROM message m JOIN session s ON s.id = m.session_id WHERE m.time_created >= ? AND m.data LIKE '%\"role\":\"assistant\"%'").all(fromMs)
      } catch { return }
      for (const r of list) {
        const m = parse(r.data)
        if (!m || m.role !== 'assistant') continue
        const day = localDate(r.at)
        const model = `${m.providerID || '?'}/${m.modelID || '?'}`
        if (!active || r.at > active.at) active = { at: r.at, provider: m.providerID || null, model: m.modelID || null }
        const u = tokensOf(m)
        const cost = typeof m.cost === 'number' ? m.cost : 0
        const add = (map, key, base) => {
          const row = map.get(key) || { ...base, input: 0, output: 0, cacheWrite: 0, cacheRead: 0, messages: 0, costUsd: 0 }
          row.input += u.input; row.output += u.output; row.cacheWrite += u.cacheWrite; row.cacheRead += u.cacheRead; row.messages++; row.costUsd += cost
          map.set(key, row)
        }
        const project = projectOf(r.dir)
        if (day === range.today) addTo(today, u, cost)
        if (day < range.from || day > range.to) continue
        addTo(totals, u, cost)
        add(rows, `${day}\t${project}\t${model}`, { date: day, project, model, provider: m.providerID || null })
        if (detail.sessions) add(bySession, `${day}\t${r.sid}\t${model}`, { date: day, session: r.sid, project, model, provider: m.providerID || null })
        const pv = providers.get(m.providerID) || { provider: m.providerID || null, messages: 0, costUsd: 0 }
        pv.messages++; pv.costUsd += cost
        providers.set(m.providerID, pv)
      }
    })
  }
  const r6 = v => Math.round(v * 1e6) / 1e6
  const fix = row => ({ ...row, costUsd: r6(row.costUsd) })
  const byCost = (a, b) => (a.date === b.date ? b.costUsd - a.costUsd : a.date < b.date ? -1 : 1)
  const out = {
    present: true,
    limits: [],
    // OpenCode reports the cost itself (models.dev prices; 0 on free models).
    costSource: 'reported',
    // The provider and model of the latest answer: what OpenCode runs on now.
    active: active ? { provider: active.provider, model: active.model, at: active.at } : null,
    providers: [...providers.values()].map(fix).sort((a, b) => b.messages - a.messages),
    today: { ...today, costUsd: r6(today.costUsd) },
    range: { ...totals, costUsd: r6(totals.costUsd) },
    rows: [...rows.values()].map(fix).sort(byCost)
  }
  if (detail.sessions) out.bySession = [...bySession.values()].map(fix).sort(byCost)
  return out
}

// --- brain --------------------------------------------------------------------

// `opencode run` takes no system prompt and no schema: both go in the
// message. The model is the user's own unless one is named provider/model.
function brainPrompt ({ system, prompt, schema }) {
  const parts = [system]
  if (schema) parts.push(`Answer with one JSON object only, no prose and no code fence, matching this JSON schema:\n${typeof schema === 'string' ? schema : JSON.stringify(schema)}`)
  parts.push(prompt)
  return parts.filter(Boolean).join('\n\n')
}

function brainEnv (env) {
  const out = { ...env }
  out.CONDUCTORE_BRAIN = '1'
  out.OPENCODE_DB = ':memory:'
  out.OPENCODE_PERMISSION = '{"*":"deny"}'
  out.OPENCODE_CONFIG_CONTENT = '{"agent":{"build":{"tools":{"*":false}}}}'
  out.OPENCODE_DISABLE_AUTOUPDATE = '1'
  return out
}

function brainArgs ({ model } = {}) {
  const args = ['run', '--pure', '--format', 'json']
  if (typeof model === 'string' && /^[\w.-]+\/[\w.:/-]+$/.test(model)) args.push('-m', model)
  return args
}

// The answer, tokens and cost of `opencode run --format json` output (NDJSON).
function resultOf (stdout) {
  let text = ''
  const tokens = TOKEN_ZERO()
  let cost = null
  let error = null
  for (const line of String(stdout).split('\n')) {
    const d = parse(line.trim())
    if (!d || typeof d !== 'object') continue
    const p = d.part || {}
    if (d.type === 'text' && typeof p.text === 'string') text += p.text
    else if (d.type === 'step_finish') {
      const u = tokensOf(p)
      tokens.input += u.input; tokens.output += u.output; tokens.cacheWrite += u.cacheWrite; tokens.cacheRead += u.cacheRead
      if (typeof p.cost === 'number') cost = (cost || 0) + p.cost
    } else if (d.type === 'error') error = d.error || d
  }
  tokens.total = tokens.input + tokens.output + tokens.cacheWrite + tokens.cacheRead
  return { text: text.trim(), tokens, cost, error }
}

function answerOf (text) {
  if (!text) return null
  const s = text.trim().replace(/^```(?:json)?\s*|\s*```$/g, '')
  const parsed = parse(s)
  if (parsed && typeof parsed === 'object') return parsed
  const a = s.indexOf('{')
  const b = s.lastIndexOf('}')
  return a !== -1 && b > a ? parse(s.slice(a, b + 1)) : null
}

// One `opencode run` through the shared runner (summarize.runClaude): its
// own process group, the whole group killed at the timeout and the call
// settled then, so a hung opencode never holds the brain lock and leaves
// no children behind.
async function runBrain (bin, env, { system, prompt, schema, model, timeoutMs, onChild }) {
  const sm = require('../summarize')
  timeoutMs = timeoutMs || 60000
  // The prompt on stdin, then EOF (`opencode run` waits for it).
  const r = await sm.runClaude(bin, brainPrompt({ system, prompt, schema }), { args: brainArgs({ model }), timeoutMs, env: brainEnv(env), onChild, cwd: os.tmpdir(), maxStdout: 4 * 1024 * 1024 })
  if (r.spawnError) {
    const err = r.spawnError
    return { ok: false, error: err.code === 'ENOENT' || err.code === 'EACCES' ? 'agent-missing' : 'failed', message: `cannot run opencode: ${err.code || err.message}` }
  }
  if (r.timedOut) return { ok: false, error: 'timeout', message: `opencode did not answer within ${timeoutMs} ms` }
  const { code, signal, stdout, stderr } = r
  const res = resultOf(stdout)
  const usage = { tokens: res.tokens, costUsd: res.cost }
  if (res.error || (code !== 0 && !res.text)) {
    const why = res.error ? (res.error.name || res.error.message || 'error') : `exit ${code === null ? signal : code}`
    if (/auth|api key|unauthori[sz]ed|401/i.test(`${JSON.stringify(res.error || '')} ${stderr}`)) return { ok: false, error: 'not-logged-in', message: 'opencode has no working provider login on this machine: run opencode auth login' }
    return { ok: false, error: 'failed', message: `opencode failed (${String(why).slice(0, 80)})`, ...usage }
  }
  return { ok: true, text: res.text || null, answer: schema ? answerOf(res.text) : null, model: typeof model === 'string' && model.includes('/') ? model : null, noTextReason: code !== 0 ? `exit ${code}` : 'no text', ...usage }
}

const brain = {
  // The user's configured model (the phone's default 'haiku' is Claude's).
  defaultModel: null,
  missing: { error: 'agent-missing', message: 'opencode is not installed or not on PATH' },
  locate (env = process.env) {
    const bin = findBin(env)
    if (!bin) return null
    return { agent: ID, bin, run: req => runBrain(bin, env, req) }
  },
  args: brainArgs
}

module.exports = {
  id: ID,
  label: LABEL,
  capabilities,
  detect,
  install,
  uninstall,
  doctor,
  normalize,
  identifyProcess,
  approvals: 'hook',
  hookAnswer,
  checkAnswers,
  toolKind,
  readTranscript,
  readTail,
  usageSection: ID,
  usageReport,
  inputVia: 'pane',
  interruptKey: 'escape',
  brain,
  // For tests.
  pluginPath,
  renderPlugin,
  toolName,
  toolInput,
  itemsOf,
  resultOf,
  answerOf,
  brainEnv,
  brainPrompt,
  sqlite,
  PLUGIN_MARK
}
