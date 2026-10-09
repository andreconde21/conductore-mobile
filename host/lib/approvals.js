'use strict'

// The daemon's approval policy: rules (rules.js) plus the log of what they
// answered. Owns ~/.conductore/rules.json and ~/.conductore/auto-approved.json
// (both 0600). Nothing here runs unless a permission request arrives or the
// phone asks: no timers, expiry is checked when a rule is used.

const fs = require('fs')
const os = require('os')
const paths = require('./paths')
const rules = require('./rules')
const risk = require('./risk')
const { summarize } = require('./state')
const { log } = require('./log')

const path = require('path')

const AUDIT_KEEP_MS = 24 * 60 * 60 * 1000
const AUDIT_MAX = 500
// The log never holds tool input (a summary capped at 200 chars), and is
// capped by size too, so it stays small on the daemon's 16 MB heap.
const AUDIT_MAX_BYTES = 128 * 1024

// Features this companion has, for the phone to gate on (`version` and
// `status` report them). Names only ever get added.
//   smart-approvals  risk labels on pending requests, rules and time-boxed
//                    trust (`rules`, `trust`), `approve-low`, `approvals`
//   digest           `digest`: facts, stuck flags and summaries per agent
//   snapshots        per-turn git snapshots: `turns`, `diff`, `undo`, `redo`
//   live             `status`/`events` --live: Herdr and tmux pushed as
//                    entities (docs/herdr-live.md)
//   herdr-agents     --herdr-agents: agents only Herdr detects
//   agent-messaging  `agents`, `agent-send`, `agent-wait`, `agent-read`
//   herdr-sidebar    pending approvals and cost as Herdr sidebar tokens
//   config           `config get|set`
//   question-answers `decide <id> answer --answers <json>` answers an
//                    AskUserQuestion; pending ones carry `questions`
//   request-owner    `decide`, `trust` and `approve-low` take `--session`:
//                    the request must be pending for that agent
const CAPABILITIES = ['smart-approvals', 'digest', 'snapshots', 'live', 'herdr-agents', 'agent-messaging', 'herdr-sidebar', 'config', 'sheprd-sidebar', 'sheprd-view', 'sheprd-view-2', 'question-answers', 'tasks-folder', 'task-runs', 'request-owner']

const rulesFile = () => path.join(paths.homeDir(), 'rules.json')
const auditFile = () => path.join(paths.homeDir(), 'auto-approved.json')

class Approvals {
  constructor ({ rules = rulesFile(), audit = auditFile(), home = os.homedir() } = {}) {
    this.rulesFile = rules
    this.auditFile = audit
    this.home = home
    this.list = []
    this.mtime = -1
    this.audit = null // loaded on first use
  }

  // --- rules ------------------------------------------------------------------

  // Active rules, re-read when the file changed on disk (edited by hand).
  rules (now = Date.now()) {
    let mtime = 0
    try { mtime = fs.statSync(this.rulesFile).mtimeMs } catch {}
    if (mtime !== this.mtime) {
      this.list = rules.load(this.rulesFile)
      this.mtime = mtime
    }
    return this.list.filter(r => rules.isActive(r, now))
  }

  persist (now = Date.now()) {
    const [kept] = rules.prune(this.list, now)
    this.list = kept
    try {
      paths.ensureDirs()
      rules.save(this.rulesFile, this.list)
      this.mtime = fs.statSync(this.rulesFile).mtimeMs
    } catch (err) {
      log('approvals', 'could not save rules', err.message)
    }
  }

  add (spec, now = Date.now()) {
    const rec = rules.makeRule(spec, now)
    const active = this.rules(now)
    if (active.length >= rules.MAX_RULES) throw new Error(`too many rules (${rules.MAX_RULES}); remove some first`)
    this.list = [...active, rec]
    this.persist(now)
    log('approvals', `rule ${rec.id} added: ${rec.rule} (${rec.scope.kind}${rec.expiresAt ? `, until ${new Date(rec.expiresAt).toISOString()}` : ''})`)
    return rec
  }

  remove (id, now = Date.now()) {
    const active = this.rules(now)
    const rec = active.find(r => r.id === id)
    if (!rec) return null
    this.list = active.filter(r => r.id !== id)
    this.persist(now)
    log('approvals', `rule ${id} removed: ${rec.rule}`)
    return rec
  }

  // Changes a rule's pattern, scope or duration; keeps its id and counters.
  edit (id, patch, now = Date.now()) {
    const active = this.rules(now)
    const old = active.find(r => r.id === id)
    if (!old) return null
    const spec = {
      rule: patch.rule !== undefined ? patch.rule : old.rule,
      scope: patch.scope !== undefined ? patch.scope : old.scope,
      source: old.source,
      note: patch.note !== undefined ? patch.note : old.note,
      sessionId: patch.sessionId !== undefined ? patch.sessionId : old.endsWithSession,
      untilSessionEnd: patch.untilSessionEnd !== undefined ? patch.untilSessionEnd : !!old.endsWithSession
    }
    if (patch.minutes !== undefined && patch.minutes !== null) spec.minutes = patch.minutes
    const next = rules.makeRule(spec, now)
    if (patch.minutes === undefined && !patch.forever) next.expiresAt = old.expiresAt
    Object.assign(next, { id: old.id, createdAt: old.createdAt, hits: old.hits || 0, lastUsedAt: old.lastUsedAt || null })
    this.list = active.map(r => (r.id === id ? next : r))
    this.persist(now)
    return next
  }

  // A session ended: its session-scoped and until-session-end rules go.
  endSession (sessionId, now = Date.now()) {
    this.rules(now)
    const [kept, dropped] = rules.prune(this.list, now, sessionId)
    if (!dropped.length) return []
    this.list = kept
    this.persist(now)
    return dropped
  }

  // --- requests ---------------------------------------------------------------

  // { cwd, root, home, realpath }: realpath lets risk and path rules see
  // where symlinks lead.
  context (event) {
    const cwd = typeof event.cwd === 'string' && event.cwd ? event.cwd : null
    return { cwd, root: cwd ? rules.repoRoot(cwd, this.home) : null, home: this.home, realpath: realpathNear }
  }

  // Risk label, rule suggestions and repo of a PermissionRequest, stored on
  // the event (the state reducer copies them into the pending request).
  assess (event) {
    const ctx = this.context(event)
    event.risk = risk.classify(event.tool_name, event.tool_input, ctx)
    event.batchable = risk.batchable(event.tool_name, event.risk)
    event.suggested_rules = rules.suggest(event.tool_name, event.tool_input, ctx)
    event.repo_root = ctx.root
    return ctx
  }

  // The request's risk as of now (the files it names may have changed since
  // it arrived): { risk, batchable }. Updates the event's label.
  recheck (event) {
    const ctx = this.context(event)
    event.risk = risk.classify(event.tool_name, event.tool_input, ctx)
    event.batchable = risk.batchable(event.tool_name, event.risk)
    return { risk: event.risk, batchable: event.batchable }
  }

  // The rule that answers this request by itself, or null. High risk always
  // asks, whatever the rules say, and so do a question, a plan and a
  // request only the agent's own prompt can answer.
  match (event, now = Date.now()) {
    // A question or a plan is the user's to answer: no rule answers it (an
    // allow would run a question with no answers).
    if (event.tool_name === 'AskUserQuestion' || event.tool_name === 'ExitPlanMode' || event.answerable === false) return null
    const active = this.rules(now)
    if (!active.length) return null
    if (this.recheck(event).risk.level === 'high') return null
    return rules.findMatch(active, event, this.context(event), now)
  }

  // A rule answered a request: count it and log it.
  record (rule, event, agent, now = Date.now()) {
    const rec = this.list.find(r => r.id === rule.id)
    if (rec) {
      rec.hits = (rec.hits || 0) + 1
      rec.lastUsedAt = now
      this.persist(now)
    }
    const entries = this.auditEntries(now)
    entries.unshift({
      requestId: event.request_id || null,
      at: now,
      sessionId: event.session_id || null,
      agent: (agent && agent.name) || null,
      cwd: event.cwd || null,
      toolName: event.tool_name || null,
      summary: summarize(event.tool_name, event.tool_input),
      risk: event.risk || null,
      ruleId: rule.id,
      rule: rule.rule,
      scope: rule.scope
    })
    if (entries.length > AUDIT_MAX) entries.length = AUDIT_MAX
    let bytes = 0
    const keep = entries.findIndex(e => (bytes += JSON.stringify(e).length + 1) > AUDIT_MAX_BYTES)
    if (keep !== -1) entries.length = Math.max(keep, 1)
    this.audit = entries
    try {
      const tmp = `${this.auditFile}.${process.pid}.tmp`
      fs.writeFileSync(tmp, JSON.stringify({ version: 1, entries }) + '\n', { mode: 0o600 })
      fs.renameSync(tmp, this.auditFile)
    } catch (err) {
      log('approvals', 'could not save the auto-approved log', err.message)
    }
  }

  // Auto-approved requests of the last 24 h (or `hours`), newest first.
  auditEntries (now = Date.now(), hours = 24) {
    if (this.audit === null) {
      try {
        const data = JSON.parse(fs.readFileSync(this.auditFile, 'utf8'))
        this.audit = Array.isArray(data && data.entries) ? data.entries.filter(e => e && typeof e.at === 'number') : []
      } catch {
        this.audit = []
      }
    }
    this.audit = this.audit.filter(e => now - e.at < AUDIT_KEEP_MS)
    const since = now - Math.min(Math.max(Number(hours) || 24, 0), 24) * 3600000
    return this.audit.filter(e => e.at >= since)
  }
}

// The real path of p (symlinks resolved), also when p does not exist yet:
// its nearest existing parent's real path plus the rest.
function realpathNear (p) {
  if (typeof p !== 'string' || !path.isAbsolute(p)) return null
  const rest = []
  let dir = path.normalize(p)
  for (let i = 0; i < 64; i++) {
    try { return path.join(fs.realpathSync(dir), ...rest) } catch {}
    const up = path.dirname(dir)
    if (up === dir) return null
    rest.unshift(path.basename(dir))
    dir = up
  }
  return null
}

module.exports = { Approvals, CAPABILITIES, AUDIT_KEEP_MS, AUDIT_MAX_BYTES, realpathNear }
