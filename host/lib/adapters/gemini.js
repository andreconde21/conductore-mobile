'use strict'

// The Gemini CLI adapter (CON-072, CON-045 step 5). Checked against Gemini
// CLI 0.62.0 run inside Docker against a local mock of the Gemini API (no
// account): the hook payloads, the session files and the TUI's prompts.
// test/fixtures/gemini/ has what it wrote.
//
//   registration  our entries in the `hooks` of ~/.gemini/settings.json,
//                 named "conductore" and marked by the command
//                 `conductore-hook --agent gemini <Event>`. Gemini keeps
//                 hooks nowhere else, so this is the one main config we
//                 edit (design doc, "Integration rule"): only the `hooks`
//                 value is rewritten, comments elsewhere stay, the file is
//                 re-read right before the write, a copy goes to .bak, and
//                 a file that does not parse is never written.
//   events        the sh hook -> spool (`agent=gemini`). Gemini's hooks run
//                 synchronously (the sh hook only spools, a few ms) and in
//                 the TUI's own process, so the pane and pid are the
//                 session's. BeforeAgent -> UserPromptSubmit, BeforeTool /
//                 AfterTool -> PreToolUse / PostToolUse(Failure), AfterAgent
//                 -> Stop, Notification ToolPermission -> PermissionRequest
//   approvals     observe only (André, 2026-09-27: terminal-only for now).
//                 Gemini announces a prompt (Notification, no tool name:
//                 taken from the BeforeTool before it) but no hook can
//                 answer it and none fires when it is answered: an allowed
//                 call is seen by its AfterTool, a refused one only in the
//                 session file (the turn is cancelled), see settleObserved
//   chat          gemini-session.js: the session file -> neutral items
//   usage         tokens per reply from the session files (no prices, no
//                 plan limits: Gemini CLI reports none)
//   brain         none: every headless `gemini -p` records a session (and a
//                 projects.json entry) in ~/.gemini with no setting to stop
//                 it, and a scratch GEMINI_CLI_HOME loses a Google login
//
// Everything is required lazily: the daemon loads this module for every
// Gemini event.

const fs = require('fs')
const os = require('os')
const path = require('path')

const lazy = name => { let m; return () => m || (m = require(name)) }
const session = lazy('./gemini-session')
const proc = lazy('../proc')
const cswap = lazy('../cswap')

const ID = 'gemini'
const LABEL = 'Gemini CLI'
const HOOK_NAME = 'conductore'
// JSONL session files (what the chat reads) since 0.39.0.
const MIN_VERSION = '0.39.0'

// The hooks we register, in milliseconds (Gemini's unit). All of them only
// spool the event; none blocks. PreCompress, BeforeModel, AfterModel (per
// streamed chunk) and BeforeToolSelection are left alone.
const EVENTS = ['SessionStart', 'BeforeAgent', 'BeforeTool', 'AfterTool', 'Notification', 'AfterAgent', 'SessionEnd']
const TOOL_EVENTS = new Set(['BeforeTool', 'AfterTool'])
const TIMEOUT_MS = 10000

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
    history: true,
    brain: false,
    brainSchema: false,
    accounts: 'show',
    facts: 'partial',
    undo: true
  }
}

// --- paths -----------------------------------------------------------------------

// Gemini's home: $GEMINI_CLI_HOME stands in for the home directory.
const geminiDir = (env = process.env) => path.join(env.GEMINI_CLI_HOME || env.HOME || os.homedir(), '.gemini')
const settingsPath = env => path.join(geminiDir(env), 'settings.json')

// --- detection --------------------------------------------------------------------

function findGemini (env = process.env) {
  if (env.CONDUCTORE_GEMINI_BIN) return env.CONDUCTORE_GEMINI_BIN
  for (const dir of String(env.PATH || '').split(':')) {
    if (!dir) continue
    const file = path.join(dir, 'gemini')
    try { fs.accessSync(file, fs.constants.X_OK); if (fs.statSync(file).isFile()) return file } catch {}
  }
  return null
}

function parseVersion (text) {
  const m = /(\d+)\.(\d+)\.(\d+)/.exec(String(text || ''))
  return m ? `${m[1]}.${m[2]}.${m[3]}` : null
}

const older = (a, b) => {
  const x = a.split('.').map(Number)
  const y = b.split('.').map(Number)
  for (let i = 0; i < 3; i++) if (x[i] !== y[i]) return x[i] < y[i]
  return false
}

function detect (env = process.env) {
  const bin = findGemini(env)
  if (!bin) return { present: false, version: null, bin: null }
  try {
    // Node startup: slower than a native binary.
    const text = require('child_process').execFileSync(bin, ['--version'], { encoding: 'utf8', timeout: 15000, stdio: ['ignore', 'pipe', 'ignore'], env })
    return { present: true, version: parseVersion(text), bin }
  } catch {
    return { present: true, version: null, bin }
  }
}

// --- settings.json (JSON with comments) ------------------------------------------------

// The text without comments and trailing commas (strings untouched), for
// JSON.parse; the same length, so offsets still match the original.
function stripJsonc (text) {
  let out = ''
  let i = 0
  const n = text.length
  while (i < n) {
    const c = text[i]
    if (c === '"') {
      let j = i + 1
      while (j < n && text[j] !== '"') j += text[j] === '\\' ? 2 : 1
      out += text.slice(i, j + 1)
      i = j + 1
    } else if (c === '/' && text[i + 1] === '/') {
      let j = i
      while (j < n && text[j] !== '\n') j++
      out += ' '.repeat(j - i)
      i = j
    } else if (c === '/' && text[i + 1] === '*') {
      let j = text.indexOf('*/', i + 2)
      j = j === -1 ? n : j + 2
      out += text.slice(i, j).replace(/[^\n]/g, ' ')
      i = j
    } else {
      out += c
      i++
    }
  }
  // Trailing commas (a `,` with only blanks before } or ]), outside strings.
  let res = ''
  for (let k = 0; k < out.length; k++) {
    const c = out[k]
    if (c === '"') {
      let j = k + 1
      while (j < out.length && out[j] !== '"') j += out[j] === '\\' ? 2 : 1
      res += out.slice(k, j + 1)
      k = j
    } else if (c === ',' && /^\s*[}\]]/.test(out.slice(k + 1, k + 1 + 4096))) res += ' '
    else res += c
  }
  return res
}

function parseSettings (text, file) {
  if (!text.trim()) return {}
  let v
  try { v = JSON.parse(stripJsonc(text)) } catch (err) { throw new Error(`cannot parse ${file}: ${err.message}`) }
  if (!v || typeof v !== 'object' || Array.isArray(v)) throw new Error(`${file} is not a JSON object`)
  return v
}

function readSettings (file) {
  let text
  try { text = fs.readFileSync(file, 'utf8') } catch (err) {
    if (err.code === 'ENOENT') return { text: null, doc: {} }
    throw new Error(`cannot read ${file}: ${err.message}`)
  }
  return { text, doc: parseSettings(text, file) }
}

// Where the top-level object's `key` value is in `text` (offsets into the
// original): { start, end } of the value, or null when there is none.
// Also returns the top-level object's closing brace.
function topLevel (text, key) {
  const s = stripJsonc(text)
  let depth = 0
  let i = 0
  let found = null
  let close = -1
  const skipString = j => { j++; while (j < s.length && s[j] !== '"') j += s[j] === '\\' ? 2 : 1; return j + 1 }
  while (i < s.length) {
    const c = s[i]
    if (c === '"') {
      const end = skipString(i)
      if (depth === 1 && !found) {
        let name = null
        try { name = JSON.parse(s.slice(i, end)) } catch {}
        let k = end
        while (k < s.length && /\s/.test(s[k])) k++
        if (name === key && s[k] === ':') {
          k++
          while (k < s.length && /\s/.test(s[k])) k++
          // The value: scan to its end at the same depth.
          let d = 0
          let j = k
          while (j < s.length) {
            const ch = s[j]
            if (ch === '"') { j = skipString(j); if (d === 0) break; continue }
            if (ch === '{' || ch === '[') d++
            else if (ch === '}' || ch === ']') { if (d === 0) break; d--; if (d === 0) { j++; break } } else if (d === 0 && ch === ',') break
            j++
          }
          let end2 = j
          while (end2 > k && /\s/.test(s[end2 - 1])) end2--
          found = { keyStart: i, start: k, end: end2 }
          i = j
          continue
        }
      }
      i = end
      continue
    }
    if (c === '{' || c === '[') depth++
    else if (c === '}' || c === ']') { depth--; if (depth === 0 && c === '}') { close = i; break } }
    i++
  }
  return { value: found, close }
}

// `hooks` as JSON text, indented to sit at the top level.
const hooksText = hooks => JSON.stringify(hooks, null, 2).replace(/\n/g, '\n  ')

// The settings text with its top-level `hooks` replaced by `hooks` (removed
// when null), everything else as it was. Null when the text is not a
// single top-level object we can edit.
function withHooks (text, hooks) {
  if (text === null || !text.trim()) return hooks ? JSON.stringify({ hooks }, null, 2) + '\n' : '{}\n'
  const { value, close } = topLevel(text, 'hooks')
  if (close === -1) return null
  if (value) {
    if (hooks) return text.slice(0, value.start) + hooksText(hooks) + text.slice(value.end)
    // Remove `"hooks": …` and one comma next to it.
    const s = stripJsonc(text)
    let a = value.keyStart
    let b = value.end
    let k = b
    while (k < s.length && /\s/.test(s[k])) k++
    if (s[k] === ',') b = k + 1
    else {
      let p = a
      while (p > 0 && /\s/.test(s[p - 1])) p--
      if (s[p - 1] === ',') a = p - 1
    }
    // The line the member sat on goes with it.
    while (a > 0 && /[ \t]/.test(text[a - 1])) a--
    if (text[a - 1] === '\n' && /^[ \t]*\n/.test(text.slice(b))) a--
    return text.slice(0, a) + text.slice(b)
  }
  if (!hooks) return text
  // Insert before the closing brace, after the last member.
  const s = stripJsonc(text)
  let p = close
  while (p > 0 && /\s/.test(s[p - 1])) p--
  const empty = s[p - 1] === '{'
  const insert = `${empty ? '' : ','}\n  "hooks": ${hooksText(hooks)}\n`
  return text.slice(0, p) + insert + text.slice(close)
}

const isRecord = v => !!v && typeof v === 'object' && !Array.isArray(v)

// --- our hooks --------------------------------------------------------------------------

const MARK = /(^|[/'" ])conductore-hook'? --agent gemini [A-Za-z]+$/

function isOurs (h) {
  return isRecord(h) && h.type === 'command' && typeof h.command === 'string' && MARK.test(h.command)
}

function hookCommand (hookBin, event) {
  return `'${hookBin.replace(/'/g, "'\\''")}' --agent gemini ${event}`
}

function buildHandler (hookBin, event) {
  return { name: HOOK_NAME, type: 'command', command: hookCommand(hookBin, event), timeout: TIMEOUT_MS, description: 'Conductore Mobile: reports this session to the phone' }
}

// The hooks object with our handler for every event of EVENTS (in place
// where one is already registered, else in a group of its own at the end)
// and none on events we no longer register. Other hooks stay as they are.
function mergeHooks (hooks, hookBin) {
  const out = isRecord(hooks) ? JSON.parse(JSON.stringify(hooks)) : {}
  for (const event of new Set([...EVENTS, ...Object.keys(out)])) {
    if (out[event] !== undefined && !Array.isArray(out[event])) continue
    const groups = out[event] || []
    const wanted = EVENTS.includes(event)
    let placed = false
    for (const g of groups) {
      if (!isRecord(g) || !Array.isArray(g.hooks)) continue
      g.hooks = g.hooks.flatMap(h => {
        if (!isOurs(h)) return [h]
        if (!wanted || placed) return []
        placed = true
        return [buildHandler(hookBin, event)]
      })
    }
    const kept = groups.filter(g => !isRecord(g) || !Array.isArray(g.hooks) || g.hooks.length)
    if (wanted && !placed) kept.push(TOOL_EVENTS.has(event) ? { matcher: '*', hooks: [buildHandler(hookBin, event)] } : { hooks: [buildHandler(hookBin, event)] })
    if (kept.length) out[event] = kept
    else delete out[event]
  }
  return out
}

function unmergeHooks (hooks) {
  if (!isRecord(hooks)) return hooks
  const out = JSON.parse(JSON.stringify(hooks))
  for (const event of Object.keys(out)) {
    if (!Array.isArray(out[event])) continue
    const kept = out[event]
      .map(g => (isRecord(g) && Array.isArray(g.hooks) ? { ...g, hooks: g.hooks.filter(h => !isOurs(h)) } : g))
      .filter(g => !isRecord(g) || !Array.isArray(g.hooks) || g.hooks.length)
    if (kept.length) out[event] = kept
    else delete out[event]
  }
  return out
}

// The events our handlers sit on.
function installed (doc) {
  const found = new Set()
  const hooks = isRecord(doc) && isRecord(doc.hooks) ? doc.hooks : {}
  for (const [event, groups] of Object.entries(hooks)) {
    if (!Array.isArray(groups)) continue
    for (const g of groups) if (isRecord(g) && Array.isArray(g.hooks) && g.hooks.some(isOurs)) found.add(event)
  }
  return [...found]
}

// Writes `text` over `file` when the file still holds `before` (Gemini
// rewrites its settings itself: never over a change made since we read),
// atomically, keeping its mode (and a symlink's target), with the
// previous version in settings.json.bak.
function writeSettings (file, before, text) {
  let target = file
  try { target = fs.realpathSync(file) } catch {}
  let now = null
  try { now = fs.readFileSync(target, 'utf8') } catch {}
  if (now !== before) throw new Error(`${file} changed while it was being edited; run install again`)
  let mode = 0o600
  try { mode = fs.statSync(target).mode & 0o7777 } catch {}
  fs.mkdirSync(path.dirname(target), { recursive: true })
  const tmp = `${target}.conductore-${process.pid}.tmp`
  fs.writeFileSync(tmp, text, { mode })
  fs.chmodSync(tmp, mode)
  if (before !== null) fs.copyFileSync(target, `${file}.bak`)
  fs.renameSync(tmp, target)
}

// The settings with `hooks` set (or removed): the new text, checked to
// parse back to exactly the document intended.
function edit (file, text, doc, hooks) {
  const next = withHooks(text, hooks)
  if (next === null) throw new Error(`cannot edit ${file}: not a single JSON object`)
  const want = { ...doc }
  if (hooks) want.hooks = hooks
  else delete want.hooks
  const got = parseSettings(next, file)
  if (JSON.stringify(sortKeys(got)) !== JSON.stringify(sortKeys(want))) throw new Error(`cannot edit ${file} safely; add the hooks by hand or run uninstall`)
  return next
}

function sortKeys (v) {
  if (Array.isArray(v)) return v.map(sortKeys)
  if (!isRecord(v)) return v
  const out = {}
  for (const k of Object.keys(v).sort()) out[k] = sortKeys(v[k])
  return out
}

function hooksOff (doc) {
  const hc = isRecord(doc.hooksConfig) ? doc.hooksConfig : {}
  if (hc.enabled === false) return 'hooks are turned off in Gemini (hooksConfig.enabled is false in settings.json)'
  if (Array.isArray(hc.disabled) && hc.disabled.includes(HOOK_NAME)) return `the "${HOOK_NAME}" hooks are turned off in Gemini (/hooks enable ${HOOK_NAME})`
  return null
}

function install ({ hookBin, env = process.env }) {
  const file = settingsPath(env)
  let cur
  try { cur = readSettings(file) } catch (err) { return { error: err.message } }
  if (!fs.existsSync(hookBin)) return { error: `client not found at ${hookBin}` }
  const hooks = mergeHooks(cur.doc.hooks, hookBin)
  const changed = JSON.stringify(hooks) !== JSON.stringify(cur.doc.hooks)
  if (changed) {
    try { writeSettings(file, cur.text, edit(file, cur.text, cur.doc, hooks)) } catch (err) { return { error: err.message } }
  }
  const off = hooksOff(cur.doc)
  return { settings: file, events: EVENTS, changed, next: off ? `Turn hooks back on: ${off}` : null }
}

function uninstall ({ env = process.env } = {}) {
  const file = settingsPath(env)
  let cur
  try { cur = readSettings(file) } catch (err) { return { error: err.message } }
  const removed = installed(cur.doc)
  if (removed.length) {
    const hooks = unmergeHooks(cur.doc.hooks)
    try { writeSettings(file, cur.text, edit(file, cur.text, cur.doc, Object.keys(hooks).length ? hooks : null)) } catch (err) { return { error: err.message } }
  }
  return { settings: file, removed }
}

// Informative only (`optional`: the phone never counts them as a failure).
async function doctor () {
  const found = detect()
  const checks = []
  let detail = found.present ? `${found.bin}${found.version ? ` (${found.version})` : ''}` : 'not found on PATH (optional)'
  if (found.version && older(found.version, MIN_VERSION)) detail += `; Chat view needs ${MIN_VERSION} or newer`
  checks.push({ name: 'gemini', optional: true, ok: found.present && !(found.version && older(found.version, MIN_VERSION)), detail })
  if (!found.present) return checks
  let doc
  try { doc = readSettings(settingsPath()).doc } catch (err) {
    checks.push({ name: 'gemini hooks', optional: true, ok: false, detail: err.message })
    return checks
  }
  const events = installed(doc)
  const absent = EVENTS.filter(e => !events.includes(e))
  const off = hooksOff(doc)
  checks.push({ name: 'gemini hooks', optional: true, ok: !absent.length && !off, detail: off || (absent.length ? `missing ${absent.join(', ')} in ${settingsPath()}; run install` : `${events.length} registered in ${settingsPath()}; approvals are answered in the terminal`) })
  return checks
}

// --- events -----------------------------------------------------------------------

// Gemini's tool names onto Claude Code's (the neutral vocabulary of risk.js,
// rules.js and activity.js), with the input fields those read.
function neutralTool (name, input) {
  const a = isRecord(input) ? input : {}
  switch (name) {
    case 'run_shell_command': return { tool: 'Bash', input: { command: typeof a.command === 'string' ? a.command : '', ...(a.description ? { description: a.description } : {}), ...(a.dir_path ? { cwd: a.dir_path } : {}) } }
    case 'write_file': return { tool: 'Write', input: { file_path: a.file_path, content: a.content } }
    case 'replace': return { tool: 'Edit', input: { file_path: a.file_path, old_string: a.old_string, new_string: a.new_string } }
    case 'read_file': return { tool: 'Read', input: { file_path: a.file_path || a.absolute_path } }
    case 'glob': return { tool: 'Glob', input: { pattern: a.pattern, path: a.dir_path || a.path } }
    case 'grep_search':
    case 'search_file_content': return { tool: 'Grep', input: { pattern: a.pattern, path: a.dir_path || a.path } }
    case 'web_fetch': return { tool: 'WebFetch', input: { url: Array.isArray(a.urls) ? a.urls[0] : a.url, prompt: a.prompt } }
    case 'google_web_search': return { tool: 'WebSearch', input: { query: a.query } }
    case 'write_todos': return { tool: 'TodoWrite', input: a }
    default: return null
  }
}

// The last tool call announced per session (BeforeTool), for the
// permission prompt Gemini announces right after it without a tool name.
const announced = new Map()

function remember (event) {
  announced.delete(event.session_id)
  announced.set(event.session_id, { tool_name: event.tool_name, tool_input: event.tool_input })
  if (announced.size > 200) announced.delete(announced.keys().next().value)
}

// A Notification's `details` (exec, edit, mcp, info) as a tool call, when
// the BeforeTool before it is not known (the daemon restarted between).
function toolOfDetails (d) {
  if (!isRecord(d)) return { tool_name: 'tool', tool_input: {} }
  if (d.type === 'exec') return { tool_name: 'run_shell_command', tool_input: { command: d.command } }
  if (d.type === 'edit') return { tool_name: d.originalContent ? 'replace' : 'write_file', tool_input: { file_path: d.filePath || d.fileName } }
  if (d.type === 'mcp') return { tool_name: `mcp_${d.serverName}_${d.toolName}`, tool_input: {} }
  return { tool_name: typeof d.title === 'string' ? d.title.replace(/^Confirm:?\s*/, '') : 'tool', tool_input: typeof d.prompt === 'string' ? { prompt: d.prompt } : {} }
}

// Whether the announced call is the one a prompt's details describe.
function matches (call, d) {
  if (!call || !isRecord(d)) return !!call
  const input = isRecord(call.tool_input) ? call.tool_input : {}
  if (d.type === 'exec') return call.tool_name === 'run_shell_command' && (!d.command || input.command === d.command)
  if (d.type === 'edit') return !d.filePath || input.file_path === d.filePath
  if (d.type === 'mcp') return typeof call.tool_name === 'string' && call.tool_name.startsWith('mcp_')
  return true
}

const EVENT_MAP = {
  SessionStart: 'SessionStart',
  BeforeAgent: 'UserPromptSubmit',
  BeforeTool: 'PreToolUse',
  AfterTool: 'PostToolUse',
  Notification: 'PermissionRequest',
  AfterAgent: 'Stop',
  SessionEnd: 'SessionEnd'
}

function normalize (event, header = {}) {
  if (!isRecord(event)) return null
  const native = event.hook_event_name || header.event
  let name = EVENT_MAP[native]
  if (!name || typeof event.session_id !== 'string' || !event.session_id) return null
  const out = { ...event, hook_event_name: name, agent_kind: ID }
  if (native === 'Notification') {
    // Only permission prompts; the phone can watch them, not answer.
    if (event.notification_type !== 'ToolPermission') return null
    const call = announced.get(event.session_id)
    const t = call && matches(call, event.details) ? call : toolOfDetails(event.details)
    out.tool_name = t.tool_name
    out.tool_input = t.tool_input
    out.answerable = false
  } else if (native === 'BeforeTool') {
    remember(event)
  } else if (native === 'AfterTool') {
    const r = event.tool_response
    if (isRecord(r) && r.error !== undefined && r.error !== null && r.error !== '') {
      out.hook_event_name = name = 'PostToolUseFailure'
      out.error = typeof r.error === 'string' ? r.error : (isRecord(r.error) && typeof r.error.message === 'string' ? r.error.message : 'error')
    }
  } else if (native === 'AfterAgent') {
    if (typeof event.prompt_response === 'string') out.last_assistant_message = event.prompt_response
  } else if (native === 'SessionEnd' || native === 'SessionStart') {
    announced.delete(event.session_id)
  }
  if (out.tool_name !== undefined) {
    const n = neutralTool(out.tool_name, out.tool_input)
    out.gemini_tool_name = out.tool_name
    if (n) { out.tool_name = n.tool; out.tool_input = n.input }
  }
  if (name === 'PermissionRequest') out.tool_kind = session().toolKind(out.gemini_tool_name)
  return out
}

function toolKind (toolName) {
  if (typeof toolName !== 'string' || !toolName) return 'other'
  const neutral = { Bash: 'bash', Edit: 'edit', Write: 'write', Read: 'read', Glob: 'search', Grep: 'search', WebFetch: 'web', WebSearch: 'web', TodoWrite: 'todo' }
  if (Object.prototype.hasOwnProperty.call(neutral, toolName)) return neutral[toolName]
  return session().toolKind(toolName)
}

// --- process ------------------------------------------------------------------------------

function argvOf (pid) {
  try { return fs.readFileSync(`/proc/${pid}/cmdline`, 'utf8').split('\0').filter(Boolean) } catch { return [] }
}

// Whether a process is Gemini CLI: `node [flags] …/gemini` (the launcher
// and the child it relaunches with a larger heap, which runs the hooks) or
// a binary named gemini. Not a process that merely mentions gemini.
function isGemini (pid) {
  const st = proc().stat(pid)
  if (!st) return false
  const argv = argvOf(pid)
  if (/^gemini/.test(st.comm)) return true
  if (!/^node/.test(st.comm)) return false
  const script = argv.slice(1).find(a => !a.startsWith('-'))
  return !!script && (path.basename(script) === 'gemini' || /[/\\]@google[/\\]gemini-cli[/\\]/.test(script))
}

// The Gemini process a hook reported (it runs the hooks itself).
function identifyProcess (pid) {
  pid = Number(pid)
  if (!Number.isInteger(pid) || pid <= 1 || !proc().hasProc()) return null
  if (!isGemini(pid)) return null
  const st = proc().stat(pid)
  return st && st.startTime ? { pid, startTime: st.startTime } : null
}

// --- observed prompts ----------------------------------------------------------------------

// Whether the terminal answered an observed prompt (daemon.js, while one is
// pending): null while it waits, else { turnEnded } (true when it was
// refused: Gemini then cancels the whole turn without a hook).
function settleObserved (agent, request) {
  if (!agent || !isSession(agent.transcriptPath) || !request) return null
  const outcome = session().promptOutcome(agent.transcriptPath, nativeOf(request.toolName), (request.createdAt || 0) - 2000)
  if (!outcome) return null
  return { turnEnded: outcome === 'cancelled' }
}

const NATIVE = { Bash: 'run_shell_command', Write: 'write_file', Edit: 'replace', Read: 'read_file', Glob: 'glob', Grep: 'grep_search', WebFetch: 'web_fetch', WebSearch: 'google_web_search', TodoWrite: 'write_todos' }
const nativeOf = toolName => NATIVE[toolName] || toolName || null

// --- chat and facts --------------------------------------------------------------------------

const isSession = file => typeof file === 'string' && path.isAbsolute(file) && file.endsWith('.jsonl')

function readTranscript (agent, opts = {}) {
  const file = agent && agent.transcriptPath
  if (!file) return { error: 'no session file recorded for this Gemini session yet (it appears with the next hook event)', notYet: true }
  if (!isSession(file)) return { error: 'session file path is not an absolute .jsonl file (Gemini CLI 0.39 or newer writes one)' }
  try {
    return session().readPage(file, opts)
  } catch (err) {
    if (err.code === 'ENOENT') return { error: `session file not found: ${file}`, notYet: true }
    return { error: `cannot read session file: ${err.message}` }
  }
}

function readTail (agent, opts) {
  if (!agent || !isSession(agent.transcriptPath)) return null
  return session().readTail(agent.transcriptPath, opts)
}

function usageReport (ctx) {
  return session().usageReport(geminiDir(ctx.env || process.env), ctx)
}

// --- accounts ----------------------------------------------------------------------------------

const AUTH = { 'oauth-personal': 'google', 'gemini-api-key': 'apikey', 'vertex-ai': 'vertex', 'compute-default-credentials': 'adc', gateway: 'gateway' }

// The active Gemini login (decision 8: show only): the Google account
// Gemini names as active (masked), or the kind of key. Never a token.
async function accounts ({ env = process.env } = {}) {
  const dir = geminiDir(env)
  let doc = {}
  try { doc = readSettings(path.join(dir, 'settings.json')).doc } catch {}
  const security = isRecord(doc.security) ? doc.security : {}
  const selected = isRecord(security.auth) && typeof security.auth.selectedType === 'string' ? security.auth.selectedType : null
  let email = null
  try {
    const g = JSON.parse(fs.readFileSync(path.join(dir, 'google_accounts.json'), 'utf8'))
    if (g && typeof g.active === 'string') email = g.active
  } catch {}
  const mode = AUTH[selected] || (email ? 'google' : env.GEMINI_API_KEY ? 'apikey' : null)
  if (!mode) return { present: false, accounts: [] }
  const label = (mode === 'google' && email && cswap().maskEmail(email)) || { google: 'Google login', apikey: 'Gemini API key', vertex: 'Vertex AI', adc: 'Google Cloud credentials', gateway: 'Gateway' }[mode]
  return { present: true, accounts: [{ label, active: true, plan: null, mode }] }
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
  settleObserved,
  toolKind,
  readTranscript,
  readTail,
  usageSection: ID,
  usageReport,
  inputVia: 'pane',
  interruptKey: 'escape',
  accounts,
  // For tests.
  EVENTS,
  HOOK_NAME,
  mergeHooks,
  unmergeHooks,
  installed,
  stripJsonc,
  withHooks,
  settingsPath,
  isGemini,
  parseVersion,
  _announced: announced
}
