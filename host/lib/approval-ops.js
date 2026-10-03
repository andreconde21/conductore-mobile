'use strict'

// The daemon's smart-approval operations, kept out of daemon.js: answering
// a request by rule, "approve all safe", trust, rules and the auto-approved
// log. Each takes the Daemon and works through its state, waiters and
// settle(), so daemon.js only has a few hooks.
//
// Nothing here copies tool input anywhere new: pending requests gain only a
// risk label, suggestions and the repo (state.js), and the auto-approved log
// lives in approvals.js, outside the daemon's change buffer.

const state = require('./state')
const rules = require('./rules')
const context = require('./context')
const { permissionOutput } = require('./permission')
const { log } = require('./log')

// daemon.js requires this module; its FIFO helpers are read at call time.
const fifo = () => require('./daemon')

// Rates a PermissionRequest and, when an active rule covers it (never when
// rated high), answers the waiting hook at once, before any tmux or Herdr
// lookup. Returns true when answered.
async function autoApprove (daemon, event, fifoPath, header) {
  daemon.approvals.assess(event)
  const { isOurFifo, writeFifo } = fifo()
  const rule = fifoPath && isOurFifo(fifoPath) ? daemon.approvals.match(event) : null
  if (!rule || !writeFifo(fifoPath, JSON.stringify(permissionOutput(event, 'allow')) + '\n')) return false
  await context.enrich(event, header)
  daemon.commit(state.autoApproved(daemon.state, event))
  daemon.approvals.record(rule, event, daemon.state.agents[event.session_id])
  log('permission', `${event.request_id} auto (${rule.id} ${rule.rule})`)
  return true
}

// Waiting requests a rule now covers (one was just added) are answered.
function applyRules (daemon) {
  const approved = []
  for (const [id, w] of [...daemon.waiters]) {
    const rule = daemon.approvals.match(w.event)
    if (rule && daemon.settle(id, 'allow', null, rule)) approved.push(id)
  }
  return approved
}

// "Always" on a high-risk request would let Claude Code skip asking for
// good: it is answered as a one-time allow instead.
function decideVerdict (request, decision) {
  if (decision === 'always' && request && request.risk && request.risk.level === 'high') {
    return { decision: 'allow', note: 'high-risk requests always ask: allowed once, no rule saved' }
  }
  return { decision, note: null }
}

// "Approve all N safe": allows every waiting request rated low (only those
// listed in `ids`, when given; only one session's, with `sessionId`).
// Anything else is skipped with a reason, never allowed.
function approveLow (daemon, req) {
  const wanted = Array.isArray(req.ids) ? new Set(req.ids.map(String)) : null
  const approved = []
  const skipped = []
  const expired = { reason: 'expired; answer it in the terminal' }
  for (const agent of Object.values(daemon.state.agents)) {
    if (req.sessionId && agent.sessionId !== req.sessionId) continue
    for (const p of [...agent.pending]) {
      if (wanted && !wanted.delete(p.id)) continue
      if (!p.batchable || !p.risk || p.risk.level !== 'low') {
        skipped.push({ id: p.id, reason: `${(p.risk && p.risk.level) || 'unrated'} risk: review it` })
      } else if (!daemon.waiters.has(p.id)) {
        daemon.commit(state.resolvePermission(daemon.state, p.id, 'gone'))
        skipped.push({ id: p.id, ...expired })
      } else if (daemon.settle(p.id, 'allow')) {
        approved.push({ id: p.id, sessionId: agent.sessionId, toolName: p.toolName, summary: p.summary })
      } else {
        skipped.push({ id: p.id, ...expired })
      }
    }
  }
  if (wanted) for (const id of wanted) skipped.push({ id, reason: 'unknown request' })
  return { ok: true, approved, skipped }
}

// "Trust this for N minutes": saves a rule from a waiting request, allows
// the request and every other waiting one the rule covers. High-risk
// requests are refused: they always ask.
function trust (daemon, req) {
  const found = state.findPending(daemon.state, req.requestId)
  if (!found) return { error: `unknown request ${req.requestId}` }
  const { agent, request } = found
  if (request.toolName === 'AskUserQuestion') return { error: 'a question takes an answer; nothing was trusted' }
  if (!request.risk || request.risk.level === 'high') {
    return { error: `high-risk requests always ask (${request.risk ? request.risk.reason : 'not rated'}); nothing was trusted` }
  }
  if (!daemon.waiters.has(request.id)) {
    daemon.commit(state.resolvePermission(daemon.state, request.id, 'gone'))
    return { error: 'request expired; answer it in the terminal' }
  }
  const kind = req.scope || 'repo'
  const scope = kind === 'session'
    ? { kind: 'session', sessionId: agent.sessionId, label: agent.name || null }
    : kind === 'repo'
      ? { kind: 'repo', path: req.path || request.repo || agent.cwd }
      : { kind: 'any' }
  const untilSessionEnd = !!req.untilSessionEnd
  const minutes = req.minutes !== undefined && req.minutes !== null ? req.minutes : req.forever || untilSessionEnd ? null : 60
  // Without an explicit rule, only this exact call: never broader than
  // what the user confirmed.
  const pattern = req.rule || rules.narrowest(request.toolName, request.toolInput, daemon.approvals.context({ cwd: agent.cwd }))
  if (!pattern) return { error: 'this request is too long to trust as is; pass a rule' }
  let rule
  try {
    rule = daemon.approvals.add({
      rule: pattern,
      scope,
      minutes,
      untilSessionEnd,
      sessionId: agent.sessionId,
      source: ['trust', 'always', 'voice'].includes(req.source) ? req.source : 'trust'
    })
  } catch (err) {
    return { error: err.message }
  }
  const approved = []
  if (daemon.settle(request.id, 'allow')) approved.push(request.id)
  approved.push(...applyRules(daemon))
  return { ok: true, rule, approved }
}

function rulesOp (daemon, req) {
  const approvals = daemon.approvals
  switch (req.action) {
    case 'list': case undefined:
      return { rules: approvals.rules(), now: Date.now() }
    case 'add': {
      const rule = approvals.add({ ...req.spec, source: (req.spec && req.spec.source) || 'cli' })
      return { ok: true, rule, approved: applyRules(daemon) }
    }
    case 'remove': {
      const rule = approvals.remove(req.id)
      return rule ? { ok: true, removed: rule } : { error: `unknown rule ${req.id}` }
    }
    case 'edit': {
      const rule = approvals.edit(req.id, req.patch || {})
      return rule ? { ok: true, rule, approved: applyRules(daemon) } : { error: `unknown rule ${req.id}` }
    }
    default:
      return { error: `unknown rules action ${req.action}` }
  }
}

// Socket ops: the reply object ({error} on failure).
function handle (daemon, req) {
  try {
    switch (req.op) {
      case 'approve-low': return approveLow(daemon, req)
      case 'trust': return trust(daemon, req)
      case 'rules': return rulesOp(daemon, req)
      case 'approvals':
        return { rules: daemon.approvals.rules(), autoApproved: daemon.approvals.auditEntries(Date.now(), req.hours), now: Date.now() }
      default: return { error: `unknown op ${req.op}` }
    }
  } catch (err) {
    return { error: err.message }
  }
}

module.exports = { autoApprove, applyRules, decideVerdict, handle }
