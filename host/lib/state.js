'use strict'

// Pure state reducer: Claude Code hook events -> per-agent state.
//
// State shape (also what `status` prints):
//   { version: 1, seq: N, agents: { [sessionId]: Agent } }
//   Agent = { sessionId, name, cwd, transcriptPath, tmux, herdr, process, state, lastEvent, lastToolName,
//             lastMessage, startedAt, updatedAt, endedAt, pending: [PendingRequest],
//             lastError?, permissionMode? }
//   lastError = { type, at }: the last turn ended on an API error (StopFailure),
//   until the next prompt
//   process = { pid, startTime } of Claude Code when the daemon could identify it
//   PendingRequest = { id, toolName, summary, toolInput, createdAt,
//                      risk: { level, reason }, batchable, suggestedRules, repo,
//                      questions? }
//   (risk to repo only when the daemon assessed the request, see approvals.js;
//   questions only for AskUserQuestion, see questionsOf)
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
// An agent whose Claude Code process is unknown (no /proc) ends after this
// long without any event: it may have been killed without a SessionEnd.
const STALE_AFTER_MS = 24 * 60 * 60 * 1000

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
  if (toolName === 'AskUserQuestion' && Array.isArray(input.questions)) {
    const q = input.questions.find(q => q && typeof q.question === 'string' && q.question)
    if (q) {
      const more = input.questions.length - 1
      return truncate(q.question.replace(/\s+/g, ' ').trim() + (more > 0 ? ` (+${more} more)` : ''), SUMMARY_MAX)
    }
  }
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
  if (event.tmux) {
    agent.tmux = { session: event.tmux.session, window: event.tmux.window, paneId: event.tmux.paneId, windowName: event.tmux.windowName || null }
    if (event.tmux.socket) agent.tmux.socket = event.tmux.socket
    if (event.tmux.panePid) agent.tmux.panePid = event.tmux.panePid
  }
  if (event.herdr) agent.herdr = event.herdr
  if (event.process) agent.process = event.process
  // Claude Code's current mode (default, plan, acceptEdits, auto,
  // bypassPermissions…), carried by every hook event: Talkbawt refuses to
  // type into an agent that acts without asking.
  if (typeof event.permission_mode === 'string' && event.permission_mode) agent.permissionMode = event.permission_mode
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
      delete agent.lastError
      break
    case 'PreToolUse':
      if (!isSubagent && QUESTION_TOOLS.has(event.tool_name)) {
        // A request already pending (its PermissionRequest was spooled
        // first) keeps the agent in needs_permission.
        if (agent.pending.length === 0) next = 'waiting_input'
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
        const questions = questionsOf(event.tool_name, event.tool_input)
        if (questions) request.questions = questions
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
    case 'StopFailure':
      // The turn ended on an API error (rate limit, auth, overload, ...).
      if (isSubagent) break
      agent.lastError = { type: typeof event.error === 'string' ? truncate(event.error, 40) : 'unknown', at: now }
      if (typeof event.last_assistant_message === 'string' && event.last_assistant_message.trim()) agent.lastMessage = truncate(event.last_assistant_message, MESSAGE_MAX)
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

// The questions of an AskUserQuestion request, for the phone to answer
// (`decide <id> answer`): every question with its kind, header and options
// (label and description; previews left out), whatever toolInput's cap cut.
// Question texts stay whole: Claude Code keys the answers by them.
const QUESTIONS_MAX = 12
const OPTIONS_MAX = 16
const OPTION_TEXT_MAX = 300

function questionsOf (toolName, input) {
  if (toolName !== 'AskUserQuestion' || !input || !Array.isArray(input.questions)) return null
  const text = (v, max = OPTION_TEXT_MAX) => (typeof v === 'string' && v ? truncate(v, max) : undefined)
  const num = v => (typeof v === 'number' && Number.isFinite(v) ? v : undefined)
  const out = []
  for (const q of input.questions.slice(0, QUESTIONS_MAX)) {
    if (!q || typeof q !== 'object' || typeof q.question !== 'string' || !q.question) continue
    const options = []
    if (Array.isArray(q.options)) {
      for (const o of q.options.slice(0, OPTIONS_MAX)) {
        if (o && typeof o.label === 'string' && o.label) options.push(clean({ label: o.label, description: text(o.description) }))
      }
    }
    out.push(clean({
      question: q.question,
      header: text(q.header, 60),
      kind: typeof q.kind === 'string' && q.kind ? q.kind : 'choice',
      multiSelect: q.multiSelect === true,
      options,
      description: text(q.description),
      placeholder: text(q.placeholder),
      min: num(q.min),
      max: num(q.max),
      step: num(q.step),
      defaultValue: num(q.defaultValue),
      unit: text(q.unit, 20)
    }))
  }
  return out.length ? out : null
}

function clean (o) {
  for (const k of Object.keys(o)) if (o[k] === undefined) delete o[k]
  return o
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

// Remove a pending request; `resolution` is 'allow' | 'deny' | 'always' |
// 'answer' | 'auto' | 'timeout' | 'gone'.
function resolvePermission (state, requestId, resolution, now = Date.now()) {
  for (const agent of Object.values(state.agents)) {
    const idx = agent.pending.findIndex(p => p.id === requestId)
    if (idx === -1) continue
    const [request] = agent.pending.splice(idx, 1)
    if (agent.state !== 'ended') {
      if (agent.pending.length) agent.state = 'needs_permission'
      else if (resolution === 'timeout' && QUESTION_TOOLS.has(request.toolName)) {
        // The question (or plan) is still on screen in the terminal: the
        // agent waits for an answer there, like after its PreToolUse.
        agent.state = 'waiting_input'
        agent.lastMessage = request.toolName === 'AskUserQuestion'
          ? `Question is waiting in the terminal: ${request.summary}`
          : 'Plan approval is waiting in the terminal'
      } else if (resolution === 'timeout') {
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
// state or updatedAt, stamped with when it was reported (`at`, ms: the
// limits of an idle session are as old as its last report). Returns
// 'unchanged', 'stored' (agent updated, caller decides when to publish) or
// 'pending' (session not known yet; kept until its first hook event).
function setUsage (state, sessionId, usage, at = Date.now()) {
  const stamped = usage ? { ...usage, at } : null
  const agent = state.agents[sessionId]
  if (!agent) {
    state.pendingUsage = state.pendingUsage || {}
    delete state.pendingUsage[sessionId]
    state.pendingUsage[sessionId] = stamped
    const keys = Object.keys(state.pendingUsage)
    if (keys.length > PENDING_USAGE_MAX) delete state.pendingUsage[keys[0]]
    return 'pending'
  }
  const known = agent.usage ? { ...agent.usage } : null
  if (known) delete known.at
  if (JSON.stringify(known) === JSON.stringify(usage || null)) return 'unchanged'
  if (stamped) agent.usage = stamped
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

// Ends agents that will never send SessionEnd: their Claude Code process is
// gone (killed, crashed, the SSH session or the machine went down), or,
// with no known process, nothing was heard from them for STALE_AFTER_MS.
// isAlive(process) says whether a recorded process still runs.
function expire (state, isAlive, now = Date.now(), staleAfter = STALE_AFTER_MS) {
  const changes = []
  for (const agent of Object.values(state.agents)) {
    if (agent.state === 'ended') continue
    if (agent.process ? isAlive(agent.process) : now - agent.updatedAt <= staleAfter) continue
    agent.state = 'ended'
    agent.endedAt = now
    agent.pending = []
    changes.push(record(state, 'change', agent, 'expired'))
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
  STALE_AFTER_MS,
  createState,
  reduce,
  resolvePermission,
  autoApproved,
  findPending,
  setUsage,
  usageChange,
  prune,
  expire,
  snapshot,
  summarize,
  questionsOf,
  QUESTION_TOOLS,
  cleanName,
  clone
}
