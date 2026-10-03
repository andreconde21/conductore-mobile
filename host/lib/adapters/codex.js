'use strict'

// The Codex CLI adapter (CON-068, CON-045 step 3). Checked against Codex
// 0.160.0 run inside Docker against a local mock of the model API (no
// account): the hook payloads, the hook trust state, the session files and
// the `codex exec` brain call. test/fixtures/codex/ has what it wrote.
//
//   registration  our own entries in $CODEX_HOME/hooks.json, merged by the
//                 mark `conductore-hook --agent codex`; never config.toml.
//                 Codex runs a new or changed hook only once the user
//                 trusted it (at start it asks "Hooks need review", or
//                 /hooks then `t`); we never write that trust. doctor()
//                 reads it, read-only, from config.toml [hooks.state].
//   events        the sh hook -> spool (`agent=codex`). Codex's hook input
//                 is Claude Code's (same names and fields, `Bash` for its
//                 exec tool); normalize() maps apply_patch onto Edit and
//                 Interrupt onto Stop
//   liveness      in daemon mode (the default since 0.157) hooks run in the
//                 shared app-server daemon, which outlives the TUIs (its
//                 SessionEnd comes a few seconds after a TUI quits, none
//                 when one is killed): origin() finds the TUI whose
//                 working directory is the session's and takes its pid and
//                 pane from its environment
//   approvals     the blocking PermissionRequest hook prints Claude Code's
//                 decision JSON (verified: allow runs the command, deny
//                 shows "Blocked by hook" with our message). No native
//                 "always": the phone saves a Conductore rule instead
//   chat          codex-rollout.js: the session file -> neutral items
//   usage         usage.js already scans the sessions (`codex` section,
//                 limits from token_count rate_limits); accounts() names
//                 the active login (auth.json, read-only, email masked)
//   brain         `codex exec --ephemeral` with the shell, patches, web
//                 search, plugins and hooks off and a read-only sandbox
//
// Everything is required lazily: the daemon loads this module for every
// Codex event.

const fs = require('fs')
const os = require('os')
const path = require('path')

const lazy = name => { let m; return () => m || (m = require(name)) }
const rollout = lazy('./codex-rollout')
const proc = lazy('../proc')
const summarize = lazy('../summarize')
const pricing = lazy('../pricing')
const cswap = lazy('../cswap')

const ID = 'codex'
const LABEL = 'Codex'
// A small, cheap model of the current catalog (`codex debug models`).
const MODEL = 'gpt-5.6-luna'

// The hooks we register, with Codex's limits: SessionEnd and Interrupt run
// at most 3 s; PermissionRequest blocks until the phone answers (bounded by
// CONDUCTORE_PERMISSION_TIMEOUT in the sh hook).
const EVENTS = ['SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'PermissionRequest', 'Stop', 'Interrupt', 'SessionEnd']
const TIMEOUTS = { PermissionRequest: 600, SessionEnd: 3, Interrupt: 3 }
const ASYNC = new Set(['SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'Stop'])

// The setup step the phone explains (status `adapters.codex.setup`).
const SETUP = ['trust-hooks']

function capabilities () {
  return {
    events: 'hooks',
    approvals: 'hook',
    always: false,
    questions: false,
    plans: false,
    chat: 'items',
    send: 'pane',
    interrupt: 'pane',
    liveUsage: false,
    limits: true,
    history: true,
    brain: true,
    brainSchema: true,
    accounts: 'show',
    facts: 'partial',
    undo: true,
    setup: SETUP
  }
}

// --- paths -----------------------------------------------------------------------

const codexHome = (env = process.env) => env.CODEX_HOME || path.join(env.HOME || os.homedir(), '.codex')
const hooksPath = env => path.join(codexHome(env), 'hooks.json')
const configPath = env => path.join(codexHome(env), 'config.toml')

// --- detection --------------------------------------------------------------------

function findCodex (env = process.env) {
  if (env.CONDUCTORE_CODEX_BIN) return env.CONDUCTORE_CODEX_BIN
  for (const dir of String(env.PATH || '').split(':')) {
    if (!dir) continue
    const file = path.join(dir, 'codex')
    try { fs.accessSync(file, fs.constants.X_OK); if (fs.statSync(file).isFile()) return file } catch {}
  }
  return null
}

// "codex-cli 0.160.0" -> '0.160.0', or null.
function parseVersion (text) {
  const m = /(\d+)\.(\d+)\.(\d+)/.exec(String(text || ''))
  return m ? `${m[1]}.${m[2]}.${m[3]}` : null
}

function detect (env = process.env) {
  const bin = findCodex(env)
  if (!bin) return { present: false, version: null, bin: null }
  try {
    const text = require('child_process').execFileSync(bin, ['--version'], { encoding: 'utf8', timeout: 5000, stdio: ['ignore', 'pipe', 'ignore'], env })
    return { present: true, version: parseVersion(text), bin }
  } catch {
    return { present: true, version: null, bin }
  }
}

// --- hooks.json -------------------------------------------------------------------

const MARK = /(^|[/'" ])conductore-hook'? --agent codex [A-Za-z]+$/

function isOurs (handler) {
  return !!handler && handler.type === 'command' && typeof handler.command === 'string' && MARK.test(handler.command)
}

function hookCommand (hookBin, event) {
  return `'${hookBin.replace(/'/g, "'\\''")}' --agent codex ${event}`
}

function buildHandler (hookBin, event) {
  const h = { type: 'command', command: hookCommand(hookBin, event), timeout: TIMEOUTS[event] || 30 }
  if (ASYNC.has(event)) h.async = true
  return h
}

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
// copy of the previous version in hooks.json.bak.
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

// Our handler for every event of EVENTS, in place where one is already
// registered (a hook's trust is keyed by its position: other people's
// hooks keep theirs), else in a group of its own at the end. Handlers of
// ours on events we no longer register are removed.
function merge (doc, hookBin) {
  const out = JSON.parse(JSON.stringify(doc || {}))
  const hooks = out.hooks && typeof out.hooks === 'object' && !Array.isArray(out.hooks) ? out.hooks : {}
  out.hooks = hooks
  for (const event of new Set([...EVENTS, ...Object.keys(hooks)])) {
    const groups = Array.isArray(hooks[event]) ? hooks[event] : []
    const wanted = EVENTS.includes(event)
    let placed = false
    for (const g of groups) {
      if (!g || !Array.isArray(g.hooks)) continue
      g.hooks = g.hooks.flatMap(h => {
        if (!isOurs(h)) return [h]
        if (!wanted || placed) return []
        placed = true
        return [buildHandler(hookBin, event)]
      })
    }
    const kept = groups.filter(g => !g || !Array.isArray(g.hooks) || g.hooks.length)
    if (wanted && !placed) kept.push({ hooks: [buildHandler(hookBin, event)] })
    if (kept.length) hooks[event] = kept
    else delete hooks[event]
  }
  return out
}

function unmerge (doc) {
  const out = JSON.parse(JSON.stringify(doc || {}))
  if (!out.hooks || typeof out.hooks !== 'object') return out
  for (const event of Object.keys(out.hooks)) {
    const groups = Array.isArray(out.hooks[event]) ? out.hooks[event] : []
    const kept = groups
      .map(g => (g && Array.isArray(g.hooks) ? { ...g, hooks: g.hooks.filter(h => !isOurs(h)) } : g))
      .filter(g => !g || !Array.isArray(g.hooks) || g.hooks.length)
    if (kept.length) out.hooks[event] = kept
    else delete out.hooks[event]
  }
  if (!Object.keys(out.hooks).length) delete out.hooks
  return out
}

// Where our handlers sit: [{ event, group, handler }].
function installed (doc) {
  const found = []
  const hooks = (doc && doc.hooks) || {}
  for (const [event, groups] of Object.entries(hooks)) {
    if (!Array.isArray(groups)) continue
    groups.forEach((g, gi) => {
      if (g && Array.isArray(g.hooks)) g.hooks.forEach((h, hi) => { if (isOurs(h)) found.push({ event, group: gi, handler: hi }) })
    })
  }
  return found
}

// Registers our hooks in hooks.json. The trust step is the user's.
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
  const trust = trustState(env, merged)
  return {
    hooks: file,
    events: EVENTS,
    changed,
    trusted: trust.trusted,
    // Shown by `install`: what the user still has to do.
    next: trust.trusted ? null : 'Start Codex and trust the Conductore hooks when it asks ("Hooks need review": Trust all), or open /hooks in Codex and press t'
  }
}

function uninstall ({ env = process.env } = {}) {
  const file = hooksPath(env)
  let current
  try { current = readHooks(file) } catch (err) { return { error: err.message } }
  const removed = [...new Set(installed(current).map(h => h.event))]
  if (removed.length) {
    try { writeHooks(unmerge(current), file) } catch (err) { return { error: `cannot write ${file}: ${err.message}` } }
  }
  return { hooks: file, removed }
}

// --- trust (read-only) ---------------------------------------------------------------

const snake = s => s.replace(/([a-z0-9])([A-Z])/g, '$1_$2').toLowerCase()

// config.toml's [hooks.state."<file>:<event>:<group>:<handler>"] tables:
// key -> { trusted, enabled }. A line scan: only these tables are read.
function hookStates (text) {
  const states = new Map()
  let current = null
  for (const raw of String(text || '').split('\n')) {
    const line = raw.trim()
    if (line.startsWith('[')) {
      const m = /^\[\s*hooks\.state\.(?:"((?:[^"\\]|\\.)*)"|'([^']*)')\s*\]$/.exec(line)
      current = m ? (m[1] !== undefined ? m[1].replace(/\\(.)/g, '$1') : m[2]) : null
      if (current !== null && !states.has(current)) states.set(current, { trusted: false, enabled: true })
      continue
    }
    if (current === null) continue
    const kv = /^([A-Za-z_]+)\s*=\s*(.+)$/.exec(line)
    if (!kv) continue
    if (kv[1] === 'trusted_hash' && /^"sha256:[0-9a-f]{64}"/.test(kv[2])) states.get(current).trusted = true
    if (kv[1] === 'enabled' && /^false\b/.test(kv[2])) states.get(current).enabled = false
  }
  return states
}

// Whether each of our handlers has a trust entry in config.toml. Codex
// asks again when a handler changes (its hash no longer matches); that
// hash is Codex's to compute, so a recorded entry is reported as trusted.
function trustState (env = process.env, doc = null) {
  const file = hooksPath(env)
  let hooks = doc
  if (!hooks) { try { hooks = readHooks(file) } catch { hooks = {} } }
  const ours = installed(hooks)
  let text = ''
  try { text = fs.readFileSync(configPath(env), 'utf8') } catch {}
  const states = hookStates(text)
  const names = new Set([file])
  try { names.add(fs.realpathSync(file)) } catch {}
  const missing = []
  const disabled = []
  for (const h of ours) {
    let st = null
    for (const n of names) st = st || states.get(`${n}:${snake(h.event)}:${h.group}:${h.handler}`) || null
    if (!st || !st.trusted) missing.push(h.event)
    else if (!st.enabled) disabled.push(h.event)
  }
  return { registered: ours.length, trusted: ours.length > 0 && !missing.length && !disabled.length, missing, disabled }
}

async function doctor () {
  const found = detect()
  const checks = []
  checks.push({ name: 'codex', ok: found.present, detail: found.present ? `${found.bin}${found.version ? ` (${found.version})` : ''}` : 'not found on PATH (optional)' })
  if (!found.present) return checks
  let doc = {}
  try { doc = readHooks(hooksPath()) } catch (err) {
    checks.push({ name: 'codex hooks', ok: false, detail: err.message })
    return checks
  }
  const ours = installed(doc)
  const events = [...new Set(ours.map(h => h.event))]
  const absent = EVENTS.filter(e => !events.includes(e))
  checks.push({ name: 'codex hooks', ok: !absent.length, detail: absent.length ? `missing ${absent.join(', ')} in ${hooksPath()}; run install` : `${events.length} registered in ${hooksPath()}` })
  if (ours.length) {
    const t = trustState(process.env, doc)
    let detail = 'trusted in Codex'
    if (t.missing.length) detail = `not trusted yet (${t.missing.join(', ')}): start Codex and choose "Trust all" when it asks, or open /hooks and press t`
    else if (t.disabled.length) detail = `turned off in Codex /hooks: ${t.disabled.join(', ')}`
    checks.push({ name: 'codex hooks trusted', ok: t.trusted, detail })
  }
  return checks
}

// --- events -----------------------------------------------------------------------

// Codex's hook events onto the daemon's (types.js). Interrupt (Esc in the
// TUI) ends the turn like Stop; compaction and subagent starts are not
// registered and dropped if they come.
const EVENT_MAP = {
  SessionStart: 'SessionStart',
  UserPromptSubmit: 'UserPromptSubmit',
  PreToolUse: 'PreToolUse',
  PostToolUse: 'PostToolUse',
  PermissionRequest: 'PermissionRequest',
  Stop: 'Stop',
  Interrupt: 'Stop',
  SubagentStop: 'SubagentStop',
  SessionEnd: 'SessionEnd'
}

// apply_patch's input ({ command: "*** Begin Patch ..." }) as an Edit:
// risk.js and rules.js judge an edit by its file_path.
function patchAsEdit (input, cwd) {
  const patch = input && typeof input.command === 'string' ? input.command : input && typeof input.input === 'string' ? input.input : ''
  const files = rollout().patchFiles(patch).map(f => (path.isAbsolute(f) || !cwd ? f : path.join(cwd, f)))
  const out = { file_path: files[0] || '', patch }
  if (files.length > 1) out.files = files
  return out
}

function normalize (event, header = {}) {
  if (!event || typeof event !== 'object' || Array.isArray(event)) return null
  const name = EVENT_MAP[event.hook_event_name || header.event]
  if (!name || typeof event.session_id !== 'string' || !event.session_id) return null
  const out = { ...event, hook_event_name: name, agent_kind: ID }
  if ((event.hook_event_name || header.event) === 'Interrupt') out.interrupted = true
  if (event.tool_name === 'apply_patch') {
    out.tool_name = 'Edit'
    out.tool_input = patchAsEdit(event.tool_input, event.cwd)
    out.codex_tool_name = 'apply_patch'
  }
  if (name === 'PermissionRequest') out.tool_kind = toolKind(out.tool_name)
  return out
}

// Kinds of the tool names a normalized event carries (Claude Code's, which
// Codex's hooks use too) and of Codex's own.
const EVENT_TOOL_KINDS = { Bash: 'bash', Edit: 'edit', Write: 'write', Read: 'read', WebSearch: 'web', WebFetch: 'web' }

function toolKind (toolName) {
  if (typeof toolName !== 'string' || !toolName) return 'other'
  if (Object.prototype.hasOwnProperty.call(EVENT_TOOL_KINDS, toolName)) return EVENT_TOOL_KINDS[toolName]
  return rollout().toolKind(toolName)
}

// --- process and location -----------------------------------------------------------

// Codex subcommands that are not an interactive session.
const NOT_A_SESSION = new Set(['app-server', 'exec-server', 'mcp', 'mcp-server', 'login', 'logout', 'doctor', 'debug', 'features', 'sandbox', 'apply', 'a', 'queue', 'cloud', 'completion', 'update', 'plugin', 'archive', 'unarchive', 'delete', 'migrate-rollouts', 'agents', 'remote-control', 'review', 'help'])

function argvOf (pid) {
  try { return fs.readFileSync(`/proc/${pid}/cmdline`, 'utf8').split('\0').filter(Boolean) } catch { return [] }
}

// The subcommand of a codex command line ('' for the TUI).
function subcommand (argv) {
  for (const a of argv.slice(1)) {
    if (a.startsWith('-')) continue
    return a
  }
  return ''
}

// What a codex process is: 'daemon' (the app-server), 'session' (a TUI or
// `codex exec`), or null when it is not Codex at all.
function roleOf (pid) {
  const st = proc().stat(pid)
  if (!st || !/^codex/.test(st.comm)) return null
  const sub = subcommand(argvOf(pid))
  if (sub === 'app-server') return 'daemon'
  return NOT_A_SESSION.has(sub) ? null : 'session'
}

// The Codex session process a hook reported: a TUI or `codex exec` (whose
// hooks run in their own process). Never the shared daemon: it outlives
// every session.
function identifyProcess (pid) {
  pid = Number(pid)
  if (!Number.isInteger(pid) || pid <= 1 || !proc().hasProc()) return null
  if (roleOf(pid) !== 'session') return null
  const st = proc().stat(pid)
  return st && st.startTime ? { pid, startTime: st.startTime } : null
}

const LOCATION_KEYS = ['tmux', 'tmux_pane', 'herdr_workspace', 'herdr_tab', 'herdr_pane', 'herdr_name', 'herdr_socket']
const ENV_KEYS = { TMUX: 'tmux', TMUX_PANE: 'tmux_pane', HERDR_WORKSPACE_ID: 'herdr_workspace', HERDR_TAB_ID: 'herdr_tab', HERDR_PANE_ID: 'herdr_pane', HERDR_AGENT_NAME: 'herdr_name', HERDR_SOCKET_PATH: 'herdr_socket' }

function locationOf (pid) {
  let text = ''
  try { text = fs.readFileSync(`/proc/${pid}/environ`, 'utf8') } catch { return {} }
  const out = {}
  for (const kv of text.split('\0')) {
    const eq = kv.indexOf('=')
    if (eq <= 0) continue
    const key = ENV_KEYS[kv.slice(0, eq)]
    if (key && kv.length > eq + 1) out[key] = kv.slice(eq + 1)
  }
  return out
}

const sameDir = (a, b) => {
  if (!a || !b) return false
  if (a === b) return true
  try { return fs.realpathSync(a) === fs.realpathSync(b) } catch { return false }
}

// TUIs (not exec) running in `cwd`: [pid].
function tuisIn (cwd) {
  const found = []
  let names
  try { names = fs.readdirSync('/proc') } catch { return found }
  for (const name of names) {
    if (!/^\d+$/.test(name)) continue
    const pid = Number(name)
    const st = proc().stat(pid)
    if (!st || !/^codex/.test(st.comm)) continue
    const argv = argvOf(pid)
    const sub = subcommand(argv)
    if (sub === 'exec' || sub === 'e' || NOT_A_SESSION.has(sub)) continue
    // The npm wrapper (node) runs the native binary as its child: both
    // pass the comm test only when the binary is the codex one.
    let dir = null
    try { dir = fs.readlinkSync(`/proc/${pid}/cwd`) } catch { continue }
    if (sameDir(dir, cwd)) found.push(pid)
  }
  return found
}

// session id -> { pid, startTime, location } once found.
const origins = new Map()

// Where a hook event really comes from. A hook run by Codex's shared
// daemon reports the daemon's pid and the environment the daemon was
// started in (the first TUI's pane), not the TUI of this session: the
// session's TUI is the one Codex process running in the session's cwd,
// and its own environment names its pane. With two TUIs in one directory
// nothing is reported (no pane beats a wrong one). Returns the header to
// use; a hook run by a TUI or `codex exec` keeps its own.
function origin (event, header) {
  if (!header || !proc().hasProc()) return header
  const pid = Number(header.agent_pid || header.claude_pid)
  if (!Number.isInteger(pid) || pid <= 1 || roleOf(pid) !== 'daemon') return header
  const sid = event.session_id
  let known = origins.get(sid)
  if (known && !proc().sameProcess(known)) { origins.delete(sid); known = null }
  if (!known && typeof event.cwd === 'string') {
    const tuis = tuisIn(event.cwd)
    if (tuis.length === 1) {
      const st = proc().stat(tuis[0])
      if (st && st.startTime) {
        known = { pid: tuis[0], startTime: st.startTime, location: locationOf(tuis[0]) }
        if (origins.size > 500) origins.delete(origins.keys().next().value)
        origins.set(sid, known)
      }
    }
  }
  const out = { ...header }
  for (const k of LOCATION_KEYS) delete out[k]
  delete out.agent_pid
  delete out.claude_pid
  if (!known) return out
  out.claude_pid = String(known.pid)
  Object.assign(out, known.location)
  return out
}

// --- approvals --------------------------------------------------------------------

// The PermissionRequest hook's stdout: Claude Code's decision JSON, which
// Codex reads as is. "always" is an allow (Codex has no rule to write
// through a hook; the phone saves a Conductore rule).
function hookAnswer (event, decision, message) {
  let d = null
  if (decision === 'allow' || decision === 'always') d = { behavior: 'allow' }
  else if (decision === 'deny') d = { behavior: 'deny', message: message || 'Denied from Conductore Mobile' }
  return d ? JSON.stringify({ hookSpecificOutput: { hookEventName: 'PermissionRequest', decision: d } }) + '\n' : '\n'
}

// --- chat and facts -------------------------------------------------------------------

const isRollout = file => typeof file === 'string' && path.isAbsolute(file) && file.endsWith('.jsonl')

function readTranscript (agent, opts = {}) {
  const file = agent && agent.transcriptPath
  if (!file) return { error: 'no session file recorded for this Codex session yet (it appears with the next hook event)' }
  if (!isRollout(file)) return { error: 'session file path is not an absolute .jsonl file' }
  try {
    return rollout().readPage(file, opts)
  } catch (err) {
    if (err.code === 'ENOENT') return { error: `session file not found: ${file}` }
    return { error: `cannot read session file: ${err.message}` }
  }
}

function readTail (agent, opts) {
  if (!agent || !isRollout(agent.transcriptPath)) return null
  const cost = (model, t) => pricing().costUsd('codex', model, { input: t.input, output: t.output, cacheRead: t.cacheRead })
  return rollout().readTail(agent.transcriptPath, opts, cost)
}

// --- accounts -------------------------------------------------------------------------

// The JWT payload of an id token (not verified: only the email and plan
// are shown, never sent anywhere).
function jwtPayload (token) {
  if (typeof token !== 'string') return null
  const part = token.split('.')[1]
  if (!part) return null
  try { return JSON.parse(Buffer.from(part.replace(/-/g, '+').replace(/_/g, '/'), 'base64').toString('utf8')) } catch { return null }
}

// The active Codex login: { present, account: { label, plan, mode } } with
// the email masked, or { present: false }. Never a token. Codex has no
// account switcher, so this is the one account (decision 8: show only).
async function accounts ({ env = process.env } = {}) {
  let auth
  try { auth = JSON.parse(fs.readFileSync(path.join(codexHome(env), 'auth.json'), 'utf8')) } catch { return { present: false, accounts: [] } }
  if (!auth || typeof auth !== 'object') return { present: false, accounts: [] }
  const tokens = auth.tokens && typeof auth.tokens === 'object' ? auth.tokens : null
  const claims = tokens ? jwtPayload(tokens.id_token) : null
  const openai = claims && claims['https://api.openai.com/auth'] && typeof claims['https://api.openai.com/auth'] === 'object' ? claims['https://api.openai.com/auth'] : {}
  const apiKey = typeof auth.OPENAI_API_KEY === 'string' && auth.OPENAI_API_KEY.length > 0
  const mode = typeof auth.auth_mode === 'string' ? auth.auth_mode.toLowerCase() : tokens ? 'chatgpt' : apiKey ? 'apikey' : null
  if (!mode) return { present: false, accounts: [] }
  const email = claims && typeof claims.email === 'string' ? claims.email : null
  const plan = typeof openai.chatgpt_plan_type === 'string' ? openai.chatgpt_plan_type.slice(0, 32) : null
  const label = (email && cswap().maskEmail(email)) || (mode === 'apikey' ? 'API key' : 'ChatGPT login')
  return { present: true, accounts: [{ label, active: true, plan, mode: mode === 'apikey' || mode === 'api_key' ? 'apikey' : 'chatgpt' }] }
}

// --- brain ------------------------------------------------------------------------------

// Everything that could act or reach out, off: the shell and patch tools,
// web search, plugins, apps, subagents, images, hooks, the user's config
// and rules. Read-only sandbox, no session file (--ephemeral).
const BRAIN_OFF = ['shell_tool', 'unified_exec', 'multi_agent', 'apps', 'plugins', 'goals', 'image_generation', 'browser_use', 'computer_use', 'view_image']

function brainArgs ({ schemaFile, model = MODEL, outFile }) {
  const args = ['exec', '--ephemeral', '--json', '--sandbox', 'read-only', '--skip-git-repo-check', '--ignore-user-config', '--ignore-rules']
  for (const f of BRAIN_OFF) args.push('--disable', f)
  args.push('-c', 'web_search="disabled"', '-c', 'include_apply_patch_tool=false', '-c', 'hooks={}', '-c', 'approval_policy="never"')
  if (schemaFile) args.push('--output-schema', schemaFile)
  if (outFile) args.push('-o', outFile)
  args.push('-m', model, '-')
  return args
}

const NOT_LOGGED_IN = /not logged in|log ?in|401|unauthori[sz]ed|OPENAI_API_KEY/i

// The JSONL `codex exec --json` printed: the last agent message, usage and
// the first error.
function parseExecJson (stdout) {
  let text = null
  let usage = null
  let error = null
  for (const line of String(stdout || '').split('\n')) {
    if (!line.trim()) continue
    let o
    try { o = JSON.parse(line) } catch { continue }
    if (o.type === 'item.completed' && o.item && o.item.type === 'agent_message' && typeof o.item.text === 'string') text = o.item.text
    else if (o.type === 'turn.completed' && o.usage) usage = o.usage
    else if ((o.type === 'error' || o.type === 'turn.failed') && !error) error = String((o.error && o.error.message) || o.message || 'error')
  }
  return { text, usage, error }
}

function usageOf (u, model) {
  const n = v => (typeof v === 'number' && v > 0 ? v : 0)
  const cacheRead = n(u && u.cached_input_tokens)
  const t = { input: Math.max(0, n(u && u.input_tokens) - cacheRead), output: n(u && u.output_tokens), cacheWrite: 0, cacheRead }
  t.total = t.input + t.output + t.cacheRead
  return { tokens: t, costUsd: pricing().costUsd('codex', model, { input: t.input, output: t.output, cacheRead: t.cacheRead }) }
}

// One locked-down `codex exec` call, the HZ-020 rules for `claude -p`
// carried over: no tools that act, nothing written, the prompt on stdin.
// CONDUCTORE_BRAIN=1 makes our hook ignore the call should a user's
// hooks still fire. Resolves a BrainOutcome (types.js).
async function runBrain (bin, env, { system, prompt, schema, model = MODEL, timeoutMs, onChild }) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'conductore-codex-'))
  try {
    let schemaFile = null
    if (schema) {
      schemaFile = path.join(dir, 'schema.json')
      fs.writeFileSync(schemaFile, typeof schema === 'string' ? schema : JSON.stringify(schema), { mode: 0o600 })
    }
    const childEnv = { ...env, CONDUCTORE_BRAIN: '1' }
    const input = `${system}\n\n${prompt}`
    // An empty working directory: nothing to read even with a read tool.
    const r = await summarize().runClaude(bin, input, { args: brainArgs({ schemaFile, model }), timeoutMs, env: childEnv, onChild, cwd: dir })
    if (r.spawnError) {
      if (r.spawnError.code === 'ENOENT' || r.spawnError.code === 'EACCES') return { ok: false, error: 'agent-missing', message: `cannot run ${bin}` }
      return { ok: false, error: 'failed', message: `cannot run codex: ${r.spawnError.code || r.spawnError.message}` }
    }
    if (r.timedOut) return { ok: false, error: 'timeout', message: `codex did not answer within ${timeoutMs} ms` }
    const res = parseExecJson(r.stdout)
    if (r.code !== 0 || res.error) {
      const why = [res.error, r.stderr].filter(Boolean).join('\n')
      if (NOT_LOGGED_IN.test(why)) return { ok: false, error: 'not-logged-in', message: 'codex is not logged in on this machine: run codex login' }
      return { ok: false, error: 'failed', message: `codex failed (${String(res.error || `exit ${r.code === null ? r.signal : r.code}`).slice(0, 80)})` }
    }
    let answer = null
    if (schema && typeof res.text === 'string') {
      try { answer = JSON.parse(res.text.trim().replace(/^```(?:json)?\s*|\s*```$/g, '')) } catch {}
    }
    return { ok: true, text: res.text, answer, model, noTextReason: 'no agent message', ...usageOf(res.usage, model) }
  } finally {
    try { fs.rmSync(dir, { recursive: true, force: true }) } catch {}
  }
}

const brain = {
  defaultModel: MODEL,
  missing: { error: 'agent-missing', message: 'codex is not installed or not on PATH' },
  locate (env = process.env) {
    const bin = findCodex(env)
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
  origin,
  approvals: 'hook',
  hookAnswer,
  toolKind,
  readTranscript,
  readTail,
  usageSection: 'codex',
  inputVia: 'pane',
  interruptKey: 'escape',
  brain,
  accounts,
  // For tests.
  EVENTS,
  merge,
  unmerge,
  installed,
  hookStates,
  trustState,
  hooksPath,
  parseExecJson,
  brainArgs,
  roleOf,
  _origins: origins
}
