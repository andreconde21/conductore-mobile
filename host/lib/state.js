'use strict'

// Pure state reducer: Claude Code hook events -> per-agent state.
//
// State shape (also what `status` prints):
//   { version: 1, seq: N, agents: { [sessionId]: Agent } }
//   Agent = { sessionId, name, cwd, transcriptPath, tmux, herdr, state, lastEvent, lastToolName,
//             lastMessage, startedAt, updatedAt, endedAt, pending: [PendingRequest] }
//   PendingRequest = { id, toolName, summary, toolInput, createdAt,
//                      risk: { level, reason }, batchable, suggestedRules, repo }
//   (the last four only when the daemon assessed the request, see approvals.js)
//
// Every mutation bumps `seq` and yields a change record
//   { seq, type: 'change' | 'remove', sessionId, agent, reason }
// so the daemon can feed long-pollers.

const path = require('path')

const STATES = ['working', 'waiting_input', 'needs_permission', 'ended']
const SUMMARY_MAX = 200
const MESSAGE_MAX = 500
const TOOL_INPUT_MAX = 4096
const PRUNE_AFTER_MS = 60 * 60 * 1000

// Tools that put a question to the human in the terminal.
const QUESTION_TOOLS = new Set(['AskUserQuestion', 'ExitPlanMode'])
// tmux window names that carry no information about the agent.
const GENERIC_WINDOW_NAMES = new Set(['node', 'claude', 'bash', 'zsh', 'fish', 'sh', 'tmux', 'ssh', 'herdr'])

function createState () {
  return { version: 1, seq: 0, agents: {} }
}

function newAgent (sessionId, now) {
  return {
    sessionId,
    name: null,
    cwd: null,
    transcriptPath: null,
    tmux: null,
    herdr: null,
    state: 'working',
    lastEvent: null,
    lastToolName: null,
    lastMessage: null,
    startedAt: now,
    updatedAt: now,
    endedAt: null,
    pending: []
  }
}

function truncate (s, max) {
  if (typeof s !== 'string') return s
  return s.length > max ? s.slice(0, max - 1) + '…' : s
}

function capToolInput (input) {
  if (input === undefined || input === null) return null
  let json
  try { json = JSON.stringify(input) } catch { return null }
  if (json.length <= TOOL_INPUT_MAX) return input
  return { _truncated: true, preview: json.slice(0, TOOL_INPUT_MAX) }
}

// One line describing a tool call, for the phone's list row.
function summarize (toolName, input) {
  if (!input || typeof input !== 'object') return toolName || ''
  const first = (...keys) => {
    for (const k of keys) if (typeof input[k] === 'string' && input[k]) return input[k]
    return null
  }
  const line = first('command', 'file_path', 'notebook_path', 'path', 'url', 'pattern', 'query', 'prompt', 'question', 'description')
  return truncate((line || JSON.stringify(input)).replace(/\s+/g, ' ').trim(), SUMMARY_MAX)
}

// Claude Code prefixes its terminal title (which tmux copies into the window
// name) with status glyphs: "⚠ claude", "✳ Fix tests", "● …". Strip leading
// symbols, emoji, variation selectors and whitespace so names stay readable.
const LEADING_GLYPHS = /^[\s\p{So}\p{Sm}\p{Sk}\p{Po}\p{Pd}\p{Extended_Pictographic}\u2190-\u23ff\u2500-\u27bf\u2800-\u28ff\ufe0f\u200d]+/u

function cleanName (name) {
  if (typeof name !== 'string') return null
  const cleaned = name.replace(LEADING_GLYPHS, '').trim()
  return cleaned || null
}

function pickName (event, cwd) {
  const herdrName = event.herdr && cleanName(event.herdr.name)
  if (herdrName) return herdrName
  const win = event.tmux && cleanName(event.tmux.windowName)
  if (win && !GENERIC_WINDOW_NAMES.has(win.toLowerCase())) return win
  if (cwd) return path.basename(cwd) || cwd
  return null
}

function applyContext (agent, event) {
  if (event.cwd) agent.cwd = event.cwd
  if (typeof event.transcript_path === 'string' && event.transcript_path) agent.transcriptPath = event.transcript_path
  if (event.tmux) agent.tmux = { session: event.tmux.session, window: event.tmux.window, paneId: event.tmux.paneId, windowName: event.tmux.windowName || null }
  if (event.herdr) agent.herdr = event.herdr
  const name = pickName(event, agent.cwd)
  if (name) agent.name = name
}

function reduce (state, event, now = Date.now()) {
  const changes = []
  if (!event || typeof event !== 'object' || !event.session_id) return changes
  const kind = event.hook_event_name
  if (!kind) return changes
  const sid = event.session_id
  const isSubagent = !!event.agent_id
  let agent = state.agents[sid]
  if (!agent) {
    agent = newAgent(sid, now)
    state.agents[sid] = agent
    // A statusline report can arrive before the session's first hook event.
    if (state.pendingUsage && state.pendingUsage[sid]) {
      agent.usage = state.pendingUsage[sid]
      delete state.pendingUsage[sid]
    }
  }
  applyContext(agent, event)
  agent.lastEvent = kind
  if (event.tool_name) agent.lastToolName = event.tool_name
  if (agent.state === 'ended' && kind !== 'SessionEnd') agent.endedAt = null

  let next = agent.state
  let reason = kind
  switch (kind) {
    case 'SessionStart':
      next = 'waiting_input'
      agent.pending = []
      break
    case 'UserPromptSubmit':
      next = 'working'
      agent.lastMessage = null
      agent.pending = []
      break
    case 'PreToolUse':
      if (!isSubagent && QUESTION_TOOLS.has(event.tool_name)) {
        next = 'waiting_input'
        agent.lastMessage = questionText(event)
      } else if (agent.pending.length === 0) {
        next = 'working'
      }
      break
    case 'PostToolUse':
    case 'PostToolUseFailure':
      next = agent.pending.length ? 'needs_permission' : 'working'
      break
    case 'PermissionRequest': {
      const id = event.request_id || `${sid}:${now}`
      if (!agent.pending.some(p => p.id === id)) {
        const request = {
          id,
          toolName: event.tool_name || null,
          summary: summarize(event.tool_name, event.tool_input),
          toolInput: capToolInput(event.tool_input),
          createdAt: now
        }
        if (event.risk) {
          request.risk = event.risk
          request.batchable = !!event.batchable
          request.suggestedRules = Array.isArray(event.suggested_rules) ? event.suggested_rules : []
          request.repo = event.repo_root || null
        }
        agent.pending.push(request)
      }
      next = 'needs_permission'
      break
    }
    case 'PermissionDenied':
      next = agent.pending.length ? 'needs_permission' : 'working'
      break
    case 'Notification': {
      const t = event.notification_type
      if (typeof event.message === 'string') agent.lastMessage = truncate(event.message, MESSAGE_MAX)
      if (isSubagent) break
      if (t === 'idle_prompt' || t === 'agent_needs_input') next = 'waiting_input'
      else if (t === 'permission_prompt') next = 'needs_permission'
      break
    }
    case 'Stop':
      if (typeof event.last_assistant_message === 'string') agent.lastMessage = truncate(event.last_assistant_message, MESSAGE_MAX)
      next = agent.pending.length ? 'needs_permission' : 'waiting_input'
      break
    case 'SubagentStop':
      // The parent is still driving; nothing changes but lastEvent.
      break
    case 'SessionEnd':
      next = 'ended'
      agent.endedAt = now
      agent.pending = []
      break
    default:
      break
  }
  if (STATES.includes(next)) agent.state = next
  agent.updatedAt = now
  changes.push(record(state, 'change', agent, reason))
  return changes
}

function questionText (event) {
  const input = event.tool_input || {}
  if (Array.isArray(input.questions) && input.questions[0] && input.questions[0].question) {
    return truncate(input.questions[0].question, MESSAGE_MAX)
  }
  if (typeof input.plan === 'string') return truncate(input.plan, MESSAGE_MAX)
  return null
}

// A PermissionRequest a rule answered at once: it never becomes pending.
// The agent keeps working; `lastAutoApprovedAt` tells the phone to refresh
// its auto-approved list.
function autoApproved (state, event, now = Date.now()) {
  if (!event || !event.session_id) return []
  const sid = event.session_id
  let agent = state.agents[sid]
  if (!agent) {
    agent = newAgent(sid, now)
    state.agents[sid] = agent
  }
  applyContext(agent, event)
  agent.lastEvent = 'PermissionRequest'
  if (event.tool_name) agent.lastToolName = event.tool_name
  if (agent.state === 'ended') agent.endedAt = null
  if (!agent.pending.length) agent.state = 'working'
  agent.lastAutoApprovedAt = now
  agent.updatedAt = now
  return [record(state, 'change', agent, 'decision:auto')]
}

// Remove a pending request; `resolution` is 'allow' | 'deny' | 'always' | 'auto' | 'timeout' | 'gone'.
function resolvePermission (state, requestId, resolution, now = Date.now()) {
  for (const agent of Object.values(state.agents)) {
    const idx = agent.pending.findIndex(p => p.id === requestId)
    if (idx === -1) continue
    agent.pending.splice(idx, 1)
    if (agent.state !== 'ended') {
      if (agent.pending.length) agent.state = 'needs_permission'
      else if (resolution === 'timeout') {
        agent.state = 'needs_permission'
        agent.lastMessage = 'Permission prompt is waiting in the terminal'
      } else agent.state = 'working'
    }
    if (resolution === 'auto') agent.lastAutoApprovedAt = now
    agent.updatedAt = now
    return [record(state, 'change', agent, `decision:${resolution}`)]
  }
  return []
}

const PENDING_USAGE_MAX = 50

// Stores a statusline usage record on the session without touching its
// state or updatedAt. Returns 'unchanged', 'stored' (agent updated, caller
// decides when to publish) or 'pending' (session not known yet; kept until
// its first hook event).
function setUsage (state, sessionId, usage) {
  const agent = state.agents[sessionId]
  if (!agent) {
    state.pendingUsage = state.pendingUsage || {}
    delete state.pendingUsage[sessionId]
    state.pendingUsage[sessionId] = usage
    const keys = Object.keys(state.pendingUsage)
    if (keys.length > PENDING_USAGE_MAX) delete state.pendingUsage[keys[0]]
    return 'pending'
  }
  if (JSON.stringify(agent.usage || null) === JSON.stringify(usage || null)) return 'unchanged'
  if (usage) agent.usage = usage
  else delete agent.usage
  return 'stored'
}

// The change record that publishes an agent's current usage.
function usageChange (state, sessionId) {
  const agent = state.agents[sessionId]
  return agent ? [record(state, 'change', agent, 'usage')] : []
}

function findPending (state, requestId) {
  for (const agent of Object.values(state.agents)) {
    const p = agent.pending.find(p => p.id === requestId)
    if (p) return { agent, request: p }
  }
  return null
}

function prune (state, now = Date.now(), maxAge = PRUNE_AFTER_MS) {
  const changes = []
  for (const [sid, agent] of Object.entries(state.agents)) {
    if (agent.state === 'ended' && agent.endedAt && now - agent.endedAt > maxAge) {
      delete state.agents[sid]
      changes.push(record(state, 'remove', agent, 'prune'))
    }
  }
  return changes
}

function record (state, type, agent, reason) {
  state.seq += 1
  return { seq: state.seq, type, sessionId: agent.sessionId, reason, agent: type === 'remove' ? null : clone(agent) }
}

function clone (v) {
  return JSON.parse(JSON.stringify(v))
}

// Public shape for `status`.
function snapshot (state) {
  return {
    version: state.version,
    seq: state.seq,
    agents: Object.values(state.agents).map(clone).sort((a, b) => b.updatedAt - a.updatedAt)
  }
}

module.exports = {
  STATES,
  PRUNE_AFTER_MS,
  createState,
  reduce,
  resolvePermission,
  autoApproved,
  findPending,
  setUsage,
  usageChange,
  prune,
  snapshot,
  summarize,
  cleanName,
  clone
}
