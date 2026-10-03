'use strict'

// The Claude Code adapter: the first agent behind the adapter interface
// (types.js), and the reference for the others. It wraps the modules that
// did all of this before adapters existed, so Claude Code's behaviour and
// every JSON document the companion prints for it stay the same:
//
//   registration  settings.js + statusline.js (~/.claude/settings.json)
//   events        bin/conductore-hook -> spool; the daemon's event vocabulary
//                 IS Claude Code's hook vocabulary, so normalize() only
//                 tags the event
//   liveness      proc.identifyClaude
//   approvals     the blocking PermissionRequest hook; permission.js builds
//                 the stdout line
//   chat          transcript.js (Claude's own entry format, which the app
//                 parses; new agents send neutral items, chat-items.js)
//   facts         digest.js readTail
//   usage         statusline.js usageFrom (live), usage.js scans
//                 ~/.claude/projects (the `claude` section of `usage`)
//   brain         `claude -p` with no tools and safe mode (HZ-020)
//   accounts      cswap.js
//
// Everything is required lazily: the daemon loads this module for every
// event and must stay small.

const fs = require('fs')
const path = require('path')

const lazy = name => { let m; return () => m || (m = require(name)) }
const permission = lazy('../permission')
const proc = lazy('../proc')
const transcript = lazy('../transcript')
const statusline = lazy('../statusline')
const settings = lazy('../settings')
const summarize = lazy('../summarize')
const digest = lazy('../digest')
const cswap = lazy('../cswap')

const ID = 'claude'
const LABEL = 'Claude Code'
const MODEL = 'haiku'

// What Claude Code supports, for the phone (status `adapters.claude`).
// Values: see types.js Capabilities.
function capabilities () {
  return {
    events: 'hooks',
    approvals: 'hook',
    always: true,
    questions: true,
    plans: true,
    chat: 'entries',
    send: 'pane',
    interrupt: 'pane',
    liveUsage: true,
    limits: true,
    history: true,
    brain: true,
    brainSchema: true,
    accounts: 'cswap',
    facts: 'full',
    undo: true
  }
}

// --- detection and registration -----------------------------------------------

// The local Claude Code: { present, version, bin }. version is null when it
// did not answer `--version` within 5 s or the answer was unreadable.
function detect (env = process.env) {
  const bin = summarize().findClaude(env)
  if (!bin) return { present: false, version: null, bin: null }
  const childEnv = { ...env }
  delete childEnv.CLAUDECODE
  try {
    const text = require('child_process').execFileSync(bin, ['--version'], { encoding: 'utf8', timeout: 5000, stdio: ['ignore', 'pipe', 'ignore'], env: childEnv })
    const version = settings().parseVersion(text)
    return { present: true, version: version ? version.join('.') : null, bin }
  } catch {
    return { present: true, version: null, bin }
  }
}

// Registers the hooks and the statusline in ~/.claude/settings.json.
// Replaces every earlier conductore handler (any path, the Node hook of 0.3
// and older) and moves a `conductore-hostd statusline` line to the sh
// statusline, keeping the command it wraps. The newer events only where
// this Claude Code knows them; a merge also takes ours off optional events
// a downgraded one would not know.
// Returns the fields `install` prints, or { error }.
function install ({ hookBin, statuslineBin, env = process.env }) {
  const s = settings()
  const sl = statusline()
  const file = s.settingsPath()
  let current
  try { current = s.readSettings(file) } catch (err) { return { error: err.message } }
  for (const bin of [hookBin, statuslineBin]) if (!fs.existsSync(bin)) return { error: `client not found at ${bin}` }
  const found = detect(env)
  const version = found.present ? found.version : null
  const { events, skipped } = s.eventsFor(version)
  const merged = s.merge(current, hookBin, events)
  const withStatusline = sl.merge(merged, statuslineBin)
  if (JSON.stringify(withStatusline.settings) !== JSON.stringify(current)) {
    try { s.writeSettings(withStatusline.settings, file) } catch (err) { return { error: `cannot write ${file}: ${err.message}` } }
  }
  return { settings: file, hook: hookBin, statusline: statuslineBin, events, skipped, claudeVersion: version, statusLine: withStatusline.action }
}

// Removes our hooks and restores the statusline we wrapped.
// Returns the fields `uninstall` prints, or { error }.
function uninstall () {
  const s = settings()
  const sl = statusline()
  const file = s.settingsPath()
  let current
  try { current = s.readSettings(file) } catch (err) { return { error: err.message } }
  const removed = s.installed(current)
  const hadStatusLine = sl.isOurs(current.statusLine)
  if (removed.length || hadStatusLine) {
    try { s.writeSettings(sl.unmerge(s.unmerge(current)), file) } catch (err) { return { error: `cannot write ${file}: ${err.message}` } }
  }
  return { settings: file, removed, statusLineRestored: hadStatusLine }
}

// The hooks this machine registered (for `digest`: without the newer
// failure events, failures are read from the transcripts).
function registeredEvents () {
  try { return settings().installed(settings().readSettings()) } catch { return [] }
}

// --- events -------------------------------------------------------------------

// One spool entry's JSON -> the event the daemon reduces. Claude Code's hook
// input already is the daemon's vocabulary; the hook name comes from argv
// (the header) when the JSON lacks it.
function normalize (event, header = {}) {
  if (!event || typeof event !== 'object' || Array.isArray(event)) return null
  if (!event.hook_event_name && header.event) event.hook_event_name = header.event
  event.agent_kind = ID
  return event
}

// The Claude Code process a hook reported (/proc comm must say claude).
function identifyProcess (pid) {
  return proc().identifyClaude(pid)
}

// --- approvals ----------------------------------------------------------------

// The line the waiting PermissionRequest hook prints: Claude Code's decision
// JSON, or an empty line to let the terminal ask.
function hookAnswer (event, decision, message, answers) {
  const out = permission().permissionOutput(event, decision, message, answers)
  return out ? JSON.stringify(out) + '\n' : '\n'
}

// The phone's answers to an AskUserQuestion: { updatedInput } or { error }.
function checkAnswers (event, answers) {
  return permission().answerInput(event, answers)
}

// Claude Code's tool names are the neutral tool vocabulary (risk.js,
// rules.js and activity.js work on them); this maps them to the coarse
// kinds the phone draws (types.js ToolKind).
const TOOL_KINDS = {
  Bash: 'bash', BashOutput: 'bash', KillShell: 'bash', KillBash: 'bash', PowerShell: 'bash',
  Edit: 'edit', MultiEdit: 'edit', NotebookEdit: 'edit',
  Write: 'write',
  Read: 'read', NotebookRead: 'read',
  Grep: 'search', Glob: 'search', LS: 'search',
  WebFetch: 'web', WebSearch: 'web',
  Task: 'task', Agent: 'task',
  TodoWrite: 'todo',
  AskUserQuestion: 'question',
  ExitPlanMode: 'plan'
}

function toolKind (toolName) {
  if (typeof toolName !== 'string' || !toolName) return 'other'
  if (Object.prototype.hasOwnProperty.call(TOOL_KINDS, toolName)) return TOOL_KINDS[toolName]
  return toolName.startsWith('mcp__') ? 'mcp' : 'other'
}

// --- chat and facts -----------------------------------------------------------

const isTranscriptFile = file => typeof file === 'string' && path.isAbsolute(file) && file.endsWith('.jsonl')

// The session's chat page: Claude Code's entries (transcript.js), or
// { error } with the message `transcript` prints.
function readTranscript (agent, opts = {}) {
  const file = agent && agent.transcriptPath
  if (!file) return { error: 'no transcript recorded for this session yet (it appears with the next hook event)' }
  if (!isTranscriptFile(file)) return { error: 'transcript path is not an absolute .jsonl file' }
  try {
    return transcript().readTranscript(file, opts)
  } catch (err) {
    if (err.code === 'ENOENT') return { error: `transcript not found: ${file}` }
    return { error: `cannot read transcript: ${err.message}` }
  }
}

// The transcript's recent prompts, replies, tokens and failures for the
// dashboard (digest.js readTail), or null without a readable transcript.
function readTail (agent, opts) {
  if (!agent || !isTranscriptFile(agent.transcriptPath)) return null
  return digest().readTail(agent.transcriptPath, opts)
}

// --- usage --------------------------------------------------------------------

// Context and limits from Claude Code's statusline input.
function liveUsage (input) {
  return statusline().usageFrom(input)
}

// --- brain --------------------------------------------------------------------

function brainArgs ({ system, schema, model = MODEL }) {
  const args = ['-p', '--tools', '', '--safe-mode', '--no-session-persistence', '--output-format', 'json', '--model', model, '--system-prompt', system]
  if (schema) args.push('--json-schema', typeof schema === 'string' ? schema : JSON.stringify(schema))
  return args
}

// Tokens and cost of one `claude -p` result.
function usageOf (res) {
  const u = (res && res.usage) || {}
  const n = v => (typeof v === 'number' && v > 0 ? v : 0)
  const t = { input: n(u.input_tokens), output: n(u.output_tokens), cacheWrite: n(u.cache_creation_input_tokens), cacheRead: n(u.cache_read_input_tokens) }
  t.total = t.input + t.output + t.cacheWrite + t.cacheRead
  return { tokens: t, costUsd: typeof res?.total_cost_usd === 'number' ? res.total_cost_usd : null }
}

// The structured answer: `structured_output`, else `result` as JSON.
function answerOf (res) {
  if (res && res.structured_output && typeof res.structured_output === 'object') return res.structured_output
  if (res && typeof res.result === 'string') {
    try { return JSON.parse(res.result.trim().replace(/^```(?:json)?\s*|\s*```$/g, '')) } catch {}
  }
  return null
}

// One locked-down `claude -p` call (host policy HZ-020): `--tools ""`, safe
// mode (no hooks: it never shows up as an agent), no session persistence,
// the prompt on stdin. Resolves a BrainOutcome (types.js).
async function runBrain (bin, env, { system, prompt, schema, model, timeoutMs, onChild, args }) {
  const sm = summarize()
  const childEnv = { ...env }
  // A nested call must not look like it runs inside a Claude Code session.
  delete childEnv.CLAUDECODE
  delete childEnv.CLAUDE_CODE_ENTRYPOINT
  // Haiku's extended thinking took 5-55 s for a 45-word summary; without
  // it a call takes about 3 s.
  childEnv.MAX_THINKING_TOKENS = '0'
  const r = await sm.runClaude(bin, prompt, { args: args || brainArgs({ system, schema, model }), timeoutMs, env: childEnv, onChild })
  if (r.spawnError) {
    if (r.spawnError.code === 'ENOENT' || r.spawnError.code === 'EACCES') return { ok: false, error: 'claude-missing', message: `cannot run ${bin}` }
    return { ok: false, error: 'failed', message: `cannot run claude: ${r.spawnError.code || r.spawnError.message}` }
  }
  if (r.timedOut) return { ok: false, error: 'timeout', message: `claude did not answer within ${timeoutMs} ms` }
  let res = null
  try { res = JSON.parse(r.stdout.trim().split('\n').pop()) } catch {}
  const errText = [res && typeof res.result === 'string' && res.is_error ? res.result : '', r.stderr, res ? '' : r.stdout].join('\n')
  if ((!res || res.is_error || r.code !== 0) && sm.NOT_LOGGED_IN.test(errText)) {
    return { ok: false, error: 'not-logged-in', message: 'claude is not logged in on this machine: run claude and /login' }
  }
  const exit = r.code !== 0 ? `exit ${r.code === null ? r.signal : r.code}` : 'unreadable output'
  if (!res || res.is_error) {
    const reason = res && res.is_error ? (res.subtype || 'error') : exit
    return { ok: false, error: 'failed', message: `claude failed (${String(reason).slice(0, 80)})`, ...(res ? usageOf(res) : {}) }
  }
  return {
    ok: true,
    text: typeof res.result === 'string' ? res.result : null,
    answer: answerOf(res),
    model: sm.modelFrom(res),
    noTextReason: exit,
    ...usageOf(res)
  }
}

const brain = {
  defaultModel: MODEL,
  // What callers report when no brain is installed (the error code old
  // phones know).
  missing: { error: 'claude-missing', message: 'claude is not installed or not on PATH' },
  // A runner when `claude` is installed here, else null.
  locate (env = process.env) {
    const bin = summarize().findClaude(env)
    if (!bin) return null
    return { agent: ID, bin, run: req => runBrain(bin, env, req) }
  },
  args: brainArgs
}

// --- accounts -----------------------------------------------------------------

function accounts (opts) {
  return cswap().accounts(opts)
}

function switchAccount (opts) {
  return cswap().switchAccount(opts)
}

module.exports = {
  id: ID,
  label: LABEL,
  capabilities,
  detect,
  install,
  uninstall,
  registeredEvents,
  normalize,
  identifyProcess,
  approvals: 'hook',
  hookAnswer,
  checkAnswers,
  toolKind,
  readTranscript,
  readTail,
  usageSection: 'claude',
  liveUsage,
  inputVia: 'pane',
  interruptKey: 'escape',
  brain,
  accounts,
  switchAccount,
  // For tests and the other adapters' reference.
  brainArgs,
  usageOf,
  answerOf
}
