'use strict'

// The Cursor CLI adapter (CON-073, CON-045 step 5). Checked against
// Cursor's `agent` (cursor-agent) 2026.10.01-e373342 installed in Docker,
// run headless and as the TUI in tmux against a local mock of Cursor's API
// (no account): the hook payloads, what a hook's answer does, the process
// tree and the transcript files. test/fixtures/cursor/ has what it wrote.
//
//   registration  our own entries in ~/.cursor/hooks.json (`version: 1`),
//                 merged by the mark `conductore-hook --agent cursor`, with
//                 a backup; never cli-config.json
//   events        the sh hook -> spool (`agent=cursor`). Cursor's events are
//                 camelCase (sessionStart, beforeSubmitPrompt, preToolUse,
//                 stop, ...) with `conversation_id`; normalize() maps them
//                 onto Claude Code's, and Shell onto Bash
//   double hooks  Cursor also runs the hooks in ~/.claude/settings.json
//                 (ours included) with its own payload; the Claude Code
//                 adapter drops those (they carry `cursor_version`)
//   liveness      the hook runs under `bash -c`; its grandparent is the
//                 `agent` node process (comm "MainThread"), recognised by
//                 its command line
//   approvals     observe only. A hook can deny or force Cursor's prompt,
//                 never allow: `{"permission":"allow"}` from
//                 beforeShellExecution still shows "Run this command?"
//                 (verified). beforeShellExecution fires before that prompt
//                 for every command, so a request reaches the phone only
//                 when Cursor will ask (not allowlisted, no --force, no
//                 "Run Everything", not sandboxed), as `answerable: false`
//   chat          cursor-transcript.js: agent-transcripts/<id>/<id>.jsonl
//                 -> neutral items (no timestamps or tool results in it)
//   usage         none: token counts arrive per turn in `stop`, plan meters
//                 only in the interactive /usage
//   brain         none: `agent -p` has no tool-off switch (--mode ask
//                 still reads files), no JSON schema, and saves its chats
//
// Everything is required lazily: the daemon loads this module for every
// Cursor event.

const fs = require('fs')
const os = require('os')
const path = require('path')

const lazy = name => { let m; return () => m || (m = require(name)) }
const transcript = lazy('./cursor-transcript')
const proc = lazy('../proc')

const ID = 'cursor'
const LABEL = 'Cursor'

// The hooks we register. None blocks: Cursor's hooks cannot allow, so
// nothing waits for the phone. Short timeouts (seconds): the sh hook only
// writes a spool file.
const EVENTS = ['sessionStart', 'sessionEnd', 'beforeSubmitPrompt', 'preToolUse', 'postToolUse', 'postToolUseFailure', 'beforeShellExecution', 'stop', 'afterAgentResponse', 'subagentStop']
const TIMEOUT = 10

function capabilities () {
  return {
    events: 'hooks',
    approvals: 'observe',
    always: false,
    questions: false,
    plans: false,
    chat: 'items',
    send: 'pane',
    interrupt: 'pane',
    liveUsage: false,
    limits: false,
    history: false,
    brain: false,
    brainSchema: false,
    accounts: null,
    facts: 'partial',
    undo: true,
    // The command New workspace types to start it (CON-071).
    launch: 'cursor-agent'
  }
}

// --- paths -----------------------------------------------------------------------

const homeOf = env => env.HOME || os.homedir()
// Cursor reads hooks from ~/.cursor/hooks.json whatever its config dir is.
const hooksPath = (env = process.env) => path.join(homeOf(env), '.cursor', 'hooks.json')
// cli-config.json (approval mode, allowlist): CURSOR_CONFIG_DIR, else
// $XDG_CONFIG_HOME/cursor, else ~/.cursor (Cursor's cursor-config/paths).
function configPath (env = process.env) {
  if (env.CURSOR_CONFIG_DIR && env.CURSOR_CONFIG_DIR.trim()) return path.join(env.CURSOR_CONFIG_DIR, 'cli-config.json')
  if (env.XDG_CONFIG_HOME && env.XDG_CONFIG_HOME.trim()) return path.join(env.XDG_CONFIG_HOME, 'cursor', 'cli-config.json')
  return path.join(homeOf(env), '.cursor', 'cli-config.json')
}
const dataDir = (env = process.env) => (env.CURSOR_DATA_DIR && env.CURSOR_DATA_DIR.trim() ? env.CURSOR_DATA_DIR : path.join(homeOf(env), '.cursor'))

// Cursor's own names: the workspace slug and the transcript file
// (utils/workspace-paths, agent-transcript/paths).
const slug = dir => String(dir).replace(/[^a-zA-Z0-9]/g, '-').replace(/-+/g, '-').replace(/^-+|-+$/g, '')
const fileId = id => encodeURIComponent(id).replace(/%/g, '_').slice(0, 200)

function transcriptPathFor (workspace, conversationId, env = process.env) {
  if (!workspace || !conversationId) return null
  const id = fileId(conversationId)
  return path.join(dataDir(env), 'projects', slug(workspace), 'agent-transcripts', id, `${id}.jsonl`)
}

// --- detection --------------------------------------------------------------------

const BINS = ['cursor-agent', 'agent']

function findCursor (env = process.env) {
  if (env.CONDUCTORE_CURSOR_BIN) return env.CONDUCTORE_CURSOR_BIN
  // `agent` alone is too common a name: only when it is Cursor's (a link
  // into ~/.local/share/cursor-agent).
  for (const name of BINS) {
    for (const dir of String(env.PATH || '').split(':')) {
      if (!dir) continue
      const file = path.join(dir, name)
      try {
        fs.accessSync(file, fs.constants.X_OK)
        if (!fs.statSync(file).isFile()) continue
        if (name === 'agent' && !/cursor-agent/.test(fs.realpathSync(file))) continue
        return file
      } catch {}
    }
  }
  return null
}

// "2026.10.01-e373342" -> itself, or null.
function parseVersion (text) {
  const m = /(\d{4}\.\d{2}\.\d{2}(?:-[0-9a-f]+)?)/.exec(String(text || ''))
  return m ? m[1] : null
}

function detect (env = process.env) {
  const bin = findCursor(env)
  if (!bin) return { present: false, version: null, bin: null }
  // The version is the directory the launcher links into; no need to start
  // node for it.
  let version = null
  try { version = parseVersion(fs.realpathSync(bin)) } catch {}
  if (!version) {
    try { version = parseVersion(require('child_process').execFileSync(bin, ['--version'], { encoding: 'utf8', timeout: 5000, stdio: ['ignore', 'pipe', 'ignore'], env })) } catch {}
  }
  return { present: true, version, bin }
}

// --- hooks.json -------------------------------------------------------------------

const MARK = /(^|[/'" ])conductore-hook'? --agent cursor [A-Za-z]+$/

function isOurs (handler) {
  return !!handler && typeof handler === 'object' && typeof handler.command === 'string' && MARK.test(handler.command)
}

function hookCommand (hookBin, event) {
  return `'${hookBin.replace(/'/g, "'\\''")}' --agent cursor ${event}`
}

const buildHandler = (hookBin, event) => ({ command: hookCommand(hookBin, event), timeout: TIMEOUT })

function readHooks (file) {
  let text
  try { text = fs.readFileSync(file, 'utf8') } catch (err) {
    if (err.code === 'ENOENT') return {}
    throw new Error(`cannot read ${file}: ${err.message}`)
  }
  if (!text.trim()) return {}
  let v
  try { v = JSON.parse(text) } catch (err) { throw new Error(`cannot parse ${file}: ${err.message}`) }
  if (!v || typeof v !== 'object' || Array.isArray(v)) throw new Error(`${file} is not a JSON object`)
  return v
}

// Atomic replace keeping the file's mode (and a symlink's target), with a
// copy of the previous version in hooks.json.bak. Cursor refuses to load a
// hooks.json reached through a symlink in some setups, but that is the
// user's choice; we write where it points.
function writeHooks (doc, file) {
  let target = file
  try { target = fs.realpathSync(file) } catch {}
  let mode = 0o600
  try { mode = fs.statSync(target).mode & 0o7777 } catch {}
  fs.mkdirSync(path.dirname(target), { recursive: true })
  const tmp = `${target}.conductore-${process.pid}.tmp`
  fs.writeFileSync(tmp, JSON.stringify(doc, null, 2) + '\n', { mode })
  fs.chmodSync(tmp, mode)
  try { fs.copyFileSync(target, `${file}.bak`) } catch {}
  fs.renameSync(tmp, target)
}

// Cursor's format: { version: 1, hooks: { <event>: [{ command, timeout,
// matcher?, failClosed? }] } }. Our handler for every event of EVENTS, in
// place where one is already registered, else appended; ours on events we
// no longer register are removed. Other people's entries stay as they are.
function merge (doc, hookBin) {
  const out = JSON.parse(JSON.stringify(doc || {}))
  if (typeof out.version !== 'number') out.version = 1
  const hooks = out.hooks && typeof out.hooks === 'object' && !Array.isArray(out.hooks) ? out.hooks : {}
  out.hooks = hooks
  for (const event of new Set([...EVENTS, ...Object.keys(hooks)])) {
    if (hooks[event] !== undefined && !Array.isArray(hooks[event])) continue
    const list = hooks[event] || []
    const wanted = EVENTS.includes(event)
    let placed = false
    const kept = list.flatMap(h => {
      if (!isOurs(h)) return [h]
      if (!wanted || placed) return []
      placed = true
      return [buildHandler(hookBin, event)]
    })
    if (wanted && !placed) kept.push(buildHandler(hookBin, event))
    if (kept.length) hooks[event] = kept
    else delete hooks[event]
  }
  return out
}

function unmerge (doc) {
  const out = JSON.parse(JSON.stringify(doc || {}))
  if (!out.hooks || typeof out.hooks !== 'object' || Array.isArray(out.hooks)) return out
  for (const event of Object.keys(out.hooks)) {
    if (!Array.isArray(out.hooks[event])) continue
    const kept = out.hooks[event].filter(h => !isOurs(h))
    if (kept.length) out.hooks[event] = kept
    else delete out.hooks[event]
  }
  return out
}

// The events our handlers are registered on.
function installed (doc) {
  const hooks = (doc && doc.hooks && typeof doc.hooks === 'object') ? doc.hooks : {}
  return Object.keys(hooks).filter(e => Array.isArray(hooks[e]) && hooks[e].some(isOurs))
}

function install ({ hookBin, env = process.env }) {
  const file = hooksPath(env)
  let current
  try { current = readHooks(file) } catch (err) { return { error: err.message } }
  if (!fs.existsSync(hookBin)) return { error: `client not found at ${hookBin}` }
  const merged = merge(current, hookBin)
  const changed = JSON.stringify(merged) !== JSON.stringify(current)
  if (changed) {
    try { writeHooks(merged, file) } catch (err) { return { error: `cannot write ${file}: ${err.message}` } }
  }
  // Cursor reads hooks.json when a session starts.
  return { hooks: file, events: EVENTS, changed, next: changed ? 'Restart running Cursor agent sessions to load the hooks' : null }
}

function uninstall ({ env = process.env } = {}) {
  const file = hooksPath(env)
  let current
  try { current = readHooks(file) } catch (err) { return { error: err.message } }
  const removed = installed(current)
  if (removed.length) {
    try { writeHooks(unmerge(current), file) } catch (err) { return { error: `cannot write ${file}: ${err.message}` } }
  }
  return { hooks: file, removed }
}

// Informative only (`optional`: the phone never counts them as a failure).
async function doctor () {
  const found = detect()
  const checks = []
  checks.push({ name: 'cursor', optional: true, ok: found.present, detail: found.present ? `${found.bin}${found.version ? ` (${found.version})` : ''}` : 'cursor-agent not found on PATH (optional)' })
  if (!found.present) return checks
  let doc = {}
  try { doc = readHooks(hooksPath()) } catch (err) {
    checks.push({ name: 'cursor hooks', optional: true, ok: false, detail: err.message })
    return checks
  }
  const events = installed(doc)
  const absent = EVENTS.filter(e => !events.includes(e))
  checks.push({ name: 'cursor hooks', optional: true, ok: !absent.length, detail: absent.length ? `missing ${absent.join(', ')} in ${hooksPath()}; run install` : `${events.length} registered in ${hooksPath()}` })
  return checks
}

// --- events -----------------------------------------------------------------------

const EVENT_MAP = {
  sessionStart: 'SessionStart',
  beforeSubmitPrompt: 'UserPromptSubmit',
  preToolUse: 'PreToolUse',
  postToolUse: 'PostToolUse',
  postToolUseFailure: 'PostToolUseFailure',
  stop: 'Stop',
  subagentStop: 'SubagentStop',
  sessionEnd: 'SessionEnd'
}

// Cursor's hook tool names onto Claude Code's (risk.js, rules.js and
// activity.js judge Bash by its command, edits by file_path).
const TOOL_NAMES = { Shell: 'Bash', Read: 'Read', Write: 'Write', Grep: 'Grep', Glob: 'Glob', Delete: 'Edit', Task: 'Task', WebFetch: 'WebFetch', WebSearch: 'WebSearch' }

function toolInput (name, input) {
  const i = input && typeof input === 'object' && !Array.isArray(input) ? input : {}
  if (name === 'Shell') {
    const out = { command: typeof i.command === 'string' ? i.command : '' }
    if (typeof i.cwd === 'string') out.cwd = i.cwd
    return out
  }
  // Cursor names the path `path` or `file_path` depending on the tool.
  if (typeof i.file_path !== 'string' && typeof i.path === 'string') return { ...i, file_path: i.path }
  return i
}

// What reached us: a tool name and its input, as Claude Code's.
function tool (event) {
  const name = typeof event.tool_name === 'string' ? event.tool_name : ''
  const mcp = /^MCP:(.+)$/.exec(name)
  return {
    tool_name: mcp ? `mcp__cursor__${mcp[1]}` : (TOOL_NAMES[name] || name),
    tool_input: toolInput(name, event.tool_input),
    cursor_tool_name: name
  }
}

// The last reply, kept per session when afterAgentResponse comes before
// stop (Cursor sends them in either order).
const replies = new Map()

function normalize (event, header = {}) {
  if (!event || typeof event !== 'object' || Array.isArray(event)) return null
  const native = typeof event.hook_event_name === 'string' ? event.hook_event_name : header.event
  const sid = typeof event.conversation_id === 'string' && event.conversation_id ? event.conversation_id : event.session_id
  if (typeof sid !== 'string' || !sid) return null
  const roots = Array.isArray(event.workspace_roots) ? event.workspace_roots.filter(r => typeof r === 'string' && r) : []
  const cwd = typeof event.cwd === 'string' && event.cwd ? event.cwd : roots[0]
  const base = { session_id: sid, agent_kind: ID, cursor_event: native }
  if (cwd) base.cwd = cwd
  // Null until the first turn is written; the file's name is known.
  base.transcript_path = typeof event.transcript_path === 'string' && event.transcript_path ? event.transcript_path : transcriptPathFor(roots[0] || cwd, sid)
  if (typeof event.model === 'string') base.model = event.model
  switch (native) {
    case 'beforeSubmitPrompt':
      replies.delete(sid)
      return { ...base, hook_event_name: 'UserPromptSubmit', prompt: typeof event.prompt === 'string' ? event.prompt : '' }
    case 'preToolUse': case 'postToolUse': case 'postToolUseFailure': {
      const out = { ...base, hook_event_name: EVENT_MAP[native], ...tool(event) }
      if (typeof event.tool_use_id === 'string') out.tool_use_id = event.tool_use_id
      if (native === 'postToolUseFailure') {
        out.error = typeof event.error_message === 'string' ? event.error_message : typeof event.error === 'string' ? event.error : 'failed'
        if (event.is_interrupt === true) out.is_interrupt = true
      }
      return out
    }
    case 'beforeShellExecution':
      if (!wouldAsk(event, header)) return null
      return {
        ...base,
        hook_event_name: 'PermissionRequest',
        tool_name: 'Bash',
        tool_input: { command: typeof event.command === 'string' ? event.command : '', ...(typeof event.cwd === 'string' ? { cwd: event.cwd } : {}) },
        cursor_tool_name: 'Shell',
        tool_kind: 'bash',
        // Cursor's own prompt answers it; the phone can only watch.
        answerable: false
      }
    case 'afterAgentResponse': {
      const text = typeof event.text === 'string' ? event.text : ''
      if (!text.trim()) return null
      replies.set(sid, text)
      if (replies.size > 200) replies.delete(replies.keys().next().value)
      // The reply alone: no state change (stop ends the turn).
      return { ...base, hook_event_name: 'Notification', message: text }
    }
    case 'stop': {
      const out = { ...base, hook_event_name: event.status === 'error' ? 'StopFailure' : 'Stop' }
      const text = replies.get(sid)
      if (text) out.last_assistant_message = text
      replies.delete(sid)
      if (event.status === 'error') out.error = 'error'
      if (event.status === 'aborted') out.interrupted = true
      for (const k of ['input_tokens', 'output_tokens', 'cache_read_tokens', 'cache_write_tokens']) if (typeof event[k] === 'number') out[k] = event[k]
      return out
    }
    case 'sessionStart':
      return { ...base, hook_event_name: 'SessionStart', source: 'startup' }
    case 'sessionEnd':
      replies.delete(sid)
      return { ...base, hook_event_name: 'SessionEnd', reason: typeof event.reason === 'string' ? event.reason : 'other' }
    case 'subagentStop':
      return { ...base, hook_event_name: 'SubagentStop', agent_id: typeof event.subagent_id === 'string' ? event.subagent_id : 'subagent' }
    default:
      return null
  }
}

function toolKind (name) {
  if (typeof name !== 'string' || !name) return 'other'
  const claude = { Bash: 'bash', Edit: 'edit', Write: 'write', Read: 'read', Grep: 'search', Glob: 'search', WebFetch: 'web', WebSearch: 'web', Task: 'task' }
  if (claude[name]) return claude[name]
  if (/^mcp__/.test(name)) return 'mcp'
  return transcript().toolKind(name)
}

// --- will Cursor ask? ---------------------------------------------------------------

function argvOf (pid) {
  try { return fs.readFileSync(`/proc/${pid}/cmdline`, 'utf8').split('\0').filter(Boolean) } catch { return [] }
}

// Cursor's approval mode and allowlist (cli-config.json, read-only).
function permissionConfig (env = process.env) {
  try {
    const c = JSON.parse(fs.readFileSync(configPath(env), 'utf8'))
    const p = c && c.permissions && typeof c.permissions === 'object' ? c.permissions : {}
    const list = v => (Array.isArray(v) ? v.filter(s => typeof s === 'string') : [])
    return { mode: typeof c.approvalMode === 'string' ? c.approvalMode : 'allowlist', allow: list(p.allow), deny: list(p.deny) }
  } catch {
    return { mode: 'allowlist', allow: [], deny: [] }
  }
}

// The simple commands of a command line (split on ; && || | and newlines,
// leading VAR=value assignments dropped): what Cursor checks one by one.
function simpleCommands (command) {
  return String(command || '').split(/&&|\|\||[;|\n]/).map(s => s.trim()).filter(Boolean).map(s => s.split(/\s+/).filter(w => !/^[A-Za-z_][A-Za-z0-9_]*=/.test(w)).join(' ')).filter(Boolean)
}

// Shell(<prefix>) entries: a simple command matches when it is the prefix
// or starts with it and a space; Shell(*) matches all.
function shellEntries (list) {
  return list.map(s => /^Shell\((.*)\)$/.exec(s.trim())).filter(Boolean).map(m => m[1].trim())
}

const matches = (cmd, prefix) => prefix === '*' || cmd === prefix || cmd.startsWith(prefix + ' ')

// Whether Cursor shows its own "Run this command?" for a shell command:
// not when the session runs with --force/--yolo, the approval mode is not
// the allowlist one (Run Everything; Auto-review decides by itself, so we
// cannot tell), the command runs sandboxed, every simple command is
// allowlisted, or one is denied (Cursor refuses it without asking).
// A miss only costs a request the phone shows until the command runs.
function wouldAsk (event, header = {}, env = process.env) {
  if (event.sandbox === true) return false
  const pid = Number(header.agent_pid || header.claude_pid)
  if (Number.isInteger(pid) && pid > 1) {
    const argv = argvOf(pid)
    if (argv.some(a => a === '-f' || a === '--force' || a === '--yolo')) return false
  }
  const cfg = permissionConfig(env)
  if (cfg.mode !== 'allowlist') return false
  const cmds = simpleCommands(event.command)
  if (!cmds.length) return false
  const deny = shellEntries(cfg.deny)
  if (cmds.some(c => deny.some(p => matches(c, p)))) return false
  const allow = shellEntries(cfg.allow)
  return !cmds.every(c => allow.some(p => matches(c, p)))
}

// --- process ------------------------------------------------------------------------

// Cursor's `agent` is node running ~/.local/share/cursor-agent/versions/<v>/index.js
// (comm "MainThread", argv[0] the `agent` or `cursor-agent` link). Its
// `worker` and `mcp` subcommands are no session.
function isCursorAgent (argv) {
  if (!argv.length) return false
  const script = argv.slice(0, 4).find(a => /[/\\]cursor-agent[/\\]versions[/\\][^/\\]+[/\\]index\.js$/.test(a))
  if (!script) return false
  const rest = argv.slice(argv.indexOf(script) + 1).filter(a => !a.startsWith('-'))
  return !['worker', 'mcp', 'login', 'logout', 'status', 'update', 'install-shell-integration', 'uninstall-shell-integration'].includes(rest[0])
}

function identifyProcess (pid) {
  pid = Number(pid)
  if (!Number.isInteger(pid) || pid <= 1 || !proc().hasProc()) return null
  if (!isCursorAgent(argvOf(pid))) return null
  const st = proc().stat(pid)
  return st && st.startTime ? { pid, startTime: st.startTime } : null
}

// --- chat ---------------------------------------------------------------------------

const isTranscript = file => typeof file === 'string' && path.isAbsolute(file) && file.endsWith('.jsonl')

function readTranscript (agent, opts = {}) {
  const file = agent && agent.transcriptPath
  if (!file) return { error: 'no transcript recorded for this Cursor session yet (it appears with the next hook event)' }
  if (!isTranscript(file)) return { error: 'transcript path is not an absolute .jsonl file' }
  try {
    return transcript().readPage(file, opts)
  } catch (err) {
    if (err.code === 'ENOENT') {
      // Older builds wrote agent-transcripts/<id>.jsonl.
      const legacy = path.join(path.dirname(path.dirname(file)), path.basename(file))
      if (legacy !== file && fs.existsSync(legacy)) {
        try { return transcript().readPage(legacy, opts) } catch {}
      }
      return { error: `transcript not found: ${file}` }
    }
    return { error: `cannot read transcript: ${err.message}` }
  }
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
  approvals: 'observe',
  toolKind,
  readTranscript,
  inputVia: 'pane',
  interruptKey: 'escape',
  // For tests.
  EVENTS,
  merge,
  unmerge,
  installed,
  hooksPath,
  configPath,
  transcriptPathFor,
  wouldAsk,
  simpleCommands,
  isCursorAgent,
  _replies: replies
}
