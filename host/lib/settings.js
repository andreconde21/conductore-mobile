'use strict'

// Idempotent merge / unmerge of our hook handlers into ~/.claude/settings.json.
// Other people's hooks (moshi-hook, safety hooks, ...) are left exactly as they are.
// Our handlers are recognised by their command, which always ends in
// `conductore-hook <Event>`; that covers the Node hook of 0.3 and older (same
// file name), so a merge migrates it to the sh client in place.

const fs = require('fs')
const os = require('os')
const path = require('path')

const EVENTS = [
  'SessionStart',
  'UserPromptSubmit',
  'PreToolUse',
  'PostToolUse',
  'PermissionRequest',
  'Notification',
  'Stop',
  'SubagentStop',
  'SessionEnd'
]

// Newer events `digest` uses, registered only when the local Claude Code
// knows them: before 2.1.101 one unknown hook event name made Claude Code
// ignore the whole settings.json (its changelog: "an unrecognized hook
// event name in settings.json no longer causes the entire file to be
// ignored"). StopFailure came in 2.1.78; PostToolUseFailure is first named
// in 2.1.119, the version used here (the earliest one we can vouch for).
// Unknown or unreadable version: not registered.
const OPTIONAL_EVENTS = [
  { event: 'PostToolUseFailure', minVersion: '2.1.119' },
  { event: 'StopFailure', minVersion: '2.1.78' }
]
const ALL_EVENTS = [...EVENTS, ...OPTIONAL_EVENTS.map(o => o.event)]

// "2.1.280 (Claude Code)" -> [2, 1, 280], or null.
function parseVersion (text) {
  const m = /(\d+)\.(\d+)\.(\d+)/.exec(String(text || ''))
  return m ? [Number(m[1]), Number(m[2]), Number(m[3])] : null
}

function atLeast (version, min) {
  const v = parseVersion(version)
  const w = parseVersion(min)
  if (!v || !w) return false
  for (let i = 0; i < 3; i++) if (v[i] !== w[i]) return v[i] > w[i]
  return true
}

// Which optional events a Claude Code version supports:
// { events: [...EVENTS, supported optional ones], skipped: [{event, reason}] }.
function eventsFor (claudeVersion) {
  const events = [...EVENTS]
  const skipped = []
  for (const { event, minVersion } of OPTIONAL_EVENTS) {
    if (atLeast(claudeVersion, minVersion)) events.push(event)
    else {
      skipped.push({
        event,
        reason: parseVersion(claudeVersion)
          ? `needs Claude Code ${minVersion}, found ${parseVersion(claudeVersion).join('.')}`
          : 'Claude Code version unknown'
      })
    }
  }
  return { events, skipped }
}

// Events whose hooks must return quickly / block Claude: everything but
// PermissionRequest is async so a slow daemon never stalls the agent.
const BLOCKING = new Set(['PermissionRequest'])

const MARK = 'conductore-hook'

function settingsPath () {
  return process.env.CONDUCTORE_CLAUDE_SETTINGS || path.join(os.homedir(), '.claude', 'settings.json')
}

function hookCommand (hookBin, event) {
  return `'${hookBin.replace(/'/g, "'\\''")}' ${event}`
}

function isOurs (handler) {
  return handler && handler.type === 'command' && typeof handler.command === 'string' &&
    new RegExp(`(^|[/'" ])${MARK}'? [A-Za-z]+$`).test(handler.command)
}

// Claude Code kills a hook at its handler's `timeout` (default 600 s). The
// PermissionRequest hook waits for the phone up to the `permission-wait`
// setting, so its timeout is that plus a minute: Claude Code never kills it
// first (a killed hook reads as "answered in the terminal"). Claude Code
// shows its own dialog at once while the hook waits (checked with 2.1.288).
const DEFAULT_PERMISSION_WAIT_S = 15 * 60
const permissionHookTimeout = waitSeconds => (Number(waitSeconds) > 0 ? Number(waitSeconds) : DEFAULT_PERMISSION_WAIT_S) + 60

function buildHandler (hookBin, event, permissionWait) {
  const h = { type: 'command', command: hookCommand(hookBin, event) }
  if (BLOCKING.has(event)) {
    h.timeout = permissionHookTimeout(permissionWait)
  } else {
    h.async = true
  }
  if (event === 'SessionEnd') {
    delete h.async // async is pointless on exit; keep it short instead
    h.timeout = 5
  }
  return h
}

// Returns a new settings object with our hooks present exactly once per
// event of `events` (default: the base ones), and removed from the
// optional events not in it (a downgraded Claude Code). `permissionWait`:
// the phone's wait in seconds (sets the PermissionRequest hook's timeout).
function merge (settings, hookBin, events = EVENTS, { permissionWait } = {}) {
  const out = clone(settings || {})
  out.hooks = out.hooks && typeof out.hooks === 'object' ? out.hooks : {}
  for (const event of ALL_EVENTS) {
    const wanted = events.includes(event)
    if (!wanted && !Array.isArray(out.hooks[event])) continue
    const groups = Array.isArray(out.hooks[event]) ? out.hooks[event] : []
    // Drop any previous conductore handler, keep everything else.
    const kept = groups
      .map(g => ({ ...g, hooks: (g.hooks || []).filter(h => !isOurs(h)) }))
      .filter(g => g.hooks.length > 0)
    if (wanted) kept.push({ matcher: '', hooks: [buildHandler(hookBin, event, permissionWait)] })
    if (kept.length) out.hooks[event] = kept
    else delete out.hooks[event]
  }
  return out
}

function unmerge (settings) {
  const out = clone(settings || {})
  if (!out.hooks || typeof out.hooks !== 'object') return out
  for (const event of Object.keys(out.hooks)) {
    const groups = Array.isArray(out.hooks[event]) ? out.hooks[event] : []
    const kept = groups
      .map(g => ({ ...g, hooks: (g.hooks || []).filter(h => !isOurs(h)) }))
      .filter(g => g.hooks.length > 0)
    if (kept.length) out.hooks[event] = kept
    else delete out.hooks[event]
  }
  if (Object.keys(out.hooks).length === 0) delete out.hooks
  return out
}

function installed (settings) {
  const hooks = (settings && settings.hooks) || {}
  const present = []
  for (const event of ALL_EVENTS) {
    const groups = Array.isArray(hooks[event]) ? hooks[event] : []
    if (groups.some(g => (g.hooks || []).some(isOurs))) present.push(event)
  }
  return present
}

function readSettings (file = settingsPath()) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'))
  } catch (err) {
    if (err.code === 'ENOENT') return {}
    throw new Error(`cannot parse ${file}: ${err.message}`)
  }
}

// Atomic replace of the file a symlink points to (a dotfiles checkout keeps
// its link), with the original mode: settings can hold API keys, so a new
// file is 0600 and the umask never widens an existing one.
function writeSettings (settings, file = settingsPath()) {
  let target = file
  try { target = fs.realpathSync(file) } catch {}
  let mode = 0o600
  try { mode = fs.statSync(target).mode & 0o7777 } catch {}
  fs.mkdirSync(path.dirname(target), { recursive: true })
  const tmp = `${target}.conductore-${process.pid}.tmp`
  fs.writeFileSync(tmp, JSON.stringify(settings, null, 2) + '\n', { mode })
  fs.chmodSync(tmp, mode)
  try {
    fs.copyFileSync(target, `${file}.bak`)
  } catch {}
  fs.renameSync(tmp, target)
}

function clone (v) {
  return JSON.parse(JSON.stringify(v))
}

// The timeout of our PermissionRequest handler, or null when not installed.
function permissionHookTimeoutOf (settings) {
  const groups = (settings && settings.hooks && settings.hooks.PermissionRequest) || []
  for (const g of Array.isArray(groups) ? groups : []) {
    for (const h of g.hooks || []) if (isOurs(h)) return typeof h.timeout === 'number' ? h.timeout : 600
  }
  return null
}

module.exports = { permissionHookTimeout, permissionHookTimeoutOf, EVENTS, OPTIONAL_EVENTS, ALL_EVENTS, eventsFor, parseVersion, atLeast, settingsPath, merge, unmerge, installed, isOurs, readSettings, writeSettings, hookCommand }
