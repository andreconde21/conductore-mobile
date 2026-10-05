'use strict'

// Per-turn snapshots of each agent's repository (`turns`, `diff`, `undo`).
//
// The daemon feeds this from the hook events it already parses: a
// UserPromptSubmit starts a turn and queues its "before" snapshot, Stop /
// StopFailure end it and queue the "after" one (a turn interrupted with
// Escape sends no Stop: the next prompt's "before" is its "after"). The
// snapshots themselves are git plumbing in child processes (snapshots.js),
// one at a time at nice 10, never awaited by the event path: a hook is
// spooled and answered long before any git runs.
//
// The record of turns lives in memory and in ~/.conductore/turns.json
// (0600, the state snapshot's debounce). Bounded: KEEP_TURNS turns per
// session, MAX_SESSIONS sessions, MAX_FILES file entries per turn; turns
// older than KEEP_MS go, with their refs. Every repo is also swept for
// snapshot refs older than KEEP_MS (at most once per SWEEP_EVERY_MS), so
// refs whose record was lost still go. Deleted refs leave unreachable
// objects (no reflog keeps them): after a prune that deleted refs, at most
// once per GC_EVERY_MS per repo, snapshots.collect() prunes the unreachable
// loose objects past the keep time and packs the rest, in the same queue
// (one git at a time, nice 10).

const snapshots = require('./snapshots')
const { log, debug } = require('./log')

const KEEP_TURNS = 50
const KEEP_MS = 7 * 24 * 60 * 60 * 1000
const MAX_SESSIONS = 100
const MAX_FILES = 50
const MAX_QUEUE = 100
const PROMPT_MAX = 160
const SWEEP_EVERY_MS = 6 * 60 * 60 * 1000
const GC_EVERY_MS = 24 * 60 * 60 * 1000
const WAIT_MAX_MS = 25000
const CHANGING_TOOLS = new Set(['Edit', 'Write', 'MultiEdit', 'NotebookEdit', 'Bash'])

const envInt = (name, fallback) => {
  const v = Number(process.env[name])
  return Number.isFinite(v) && v >= 0 ? v : fallback
}

function headline (prompt) {
  if (typeof prompt !== 'string') return ''
  const line = prompt.split('\n').map(l => l.trim()).find(Boolean) || ''
  const s = line.replace(/\s+/g, ' ')
  return s.length > PROMPT_MAX ? s.slice(0, PROMPT_MAX - 1) + '…' : s
}

// What the store keeps of one snapshot result.
function snapInfo (r) {
  if (!r.ok) return { skipped: r.reason, ms: r.ms, at: Date.now() }
  return { ref: r.ref, commit: r.commit, head: r.head, ms: r.ms, untracked: r.untracked, excluded: r.excluded.length, at: Date.now() }
}

class Turns {
  // The git operations are injectable for tests.
  constructor (data, { snapshot = snapshots.snapshot, changes = snapshots.changes, listRefs = snapshots.listRefs, deleteRefs = snapshots.deleteRefs, collect = snapshots.collect } = {}) {
    this.sessions = {}
    this.swept = {}
    this.collected = {} // repo -> when collect() last ran there
    this.dirty = false
    this.queue = []
    this.running = null
    this.pendingBySession = new Map()
    this.waiters = []
    this.ops = { snapshot, changes, listRefs, deleteRefs, collect }
    this.onDirty = null // the daemon's snapshot debounce
    this.enabled = process.env.CONDUCTORE_SNAPSHOTS !== '0'
    if (data && data.sessions && typeof data.sessions === 'object') {
      for (const [sid, s] of Object.entries(data.sessions)) {
        if (s && Array.isArray(s.turns)) this.sessions[sid] = { cwd: s.cwd || null, lastAt: Number(s.lastAt) || 0, endedAt: s.endedAt || null, next: Number(s.next) || 1, turns: s.turns }
      }
      if (data.swept && typeof data.swept === 'object') this.swept = data.swept
      if (data.collected && typeof data.collected === 'object') this.collected = data.collected
    }
  }

  session (sid, now) {
    let s = this.sessions[sid]
    if (!s) {
      s = this.sessions[sid] = { cwd: null, lastAt: now, endedAt: null, next: 1, turns: [] }
      const sids = Object.keys(this.sessions)
      if (sids.length > MAX_SESSIONS) {
        const victim = sids.filter(x => x !== sid).sort((a, b) => this.sessions[a].lastAt - this.sessions[b].lastAt)[0]
        this.dropSession(victim)
      }
    }
    return s
  }

  current (sid) {
    const s = this.sessions[sid]
    return s && s.turns.length ? s.turns[s.turns.length - 1] : null
  }

  // One hook event (after the reducer ran).
  onEvent (event, now = Date.now()) {
    if (!this.enabled || !event || !event.session_id || !snapshots.SESSION_RE.test(event.session_id)) return
    const sid = event.session_id
    const kind = event.hook_event_name
    const sub = !!event.agent_id
    switch (kind) {
      case 'UserPromptSubmit': {
        if (sub || typeof event.cwd !== 'string' || !event.cwd) return
        const s = this.session(sid, now)
        const prev = this.current(sid)
        if (prev && !prev.endedAt) {
          // Interrupted (no Stop): it ends where the next one starts.
          prev.endedAt = now
          prev.afterFromNext = true
        }
        const turn = { n: s.next++, prompt: headline(event.prompt), startedAt: now, endedAt: null, cwd: event.cwd, before: null, after: null, files: null, filesTotal: null, added: null, removed: null, late: false }
        s.turns.push(turn)
        s.cwd = event.cwd
        s.lastAt = now
        s.endedAt = null
        this.dirty = true
        this.enqueue({ kind: 'before', sid, n: turn.n })
        this.pruneSession(sid, now)
        break
      }
      case 'Stop': case 'StopFailure': {
        if (sub) return
        const turn = this.current(sid)
        if (!turn || turn.endedAt) return
        turn.endedAt = now
        this.sessions[sid].lastAt = now
        this.dirty = true
        this.enqueue({ kind: 'after', sid, n: turn.n })
        break
      }
      case 'PreToolUse': case 'PostToolUse': {
        // A change made before the "before" snapshot finished may be in it.
        const turn = this.current(sid)
        if (turn && !turn.endedAt && !turn.before && !turn.late && CHANGING_TOOLS.has(event.tool_name)) {
          turn.late = true
          this.dirty = true
        }
        break
      }
      case 'SessionEnd': {
        const s = this.sessions[sid]
        if (s) { s.endedAt = now; s.lastAt = now; this.dirty = true }
        break
      }
      default:
        break
    }
  }

  // --- jobs -------------------------------------------------------------------

  enqueue (job) {
    if (this.queue.length >= MAX_QUEUE) {
      log('snapshot', `queue full, skipped ${job.kind} of ${job.sid} turn ${job.n}`)
      const t = this.turn(job.sid, job.n)
      if (t && job.kind !== 'prune' && job.kind !== 'collect') { t[job.kind] = { skipped: 'busy', ms: 0, at: Date.now() }; this.dirty = true }
      return
    }
    this.queue.push(job)
    if (job.sid) this.pendingBySession.set(job.sid, (this.pendingBySession.get(job.sid) || 0) + 1)
    this.pump()
  }

  turn (sid, n) {
    const s = this.sessions[sid]
    return s ? s.turns.find(t => t.n === n) || null : null
  }

  pump () {
    if (this.running || !this.queue.length) return
    const job = this.queue.shift()
    this.running = this.runJob(job)
      .catch(err => log('snapshot', `${job.kind} failed`, err.stack || String(err)))
      .then(() => {
        this.running = null
        if (job.sid) {
          const left = (this.pendingBySession.get(job.sid) || 1) - 1
          if (left > 0) this.pendingBySession.set(job.sid, left)
          else this.pendingBySession.delete(job.sid)
        }
        this.wake()
        if (this.onDirty && this.dirty) this.onDirty()
        this.pump()
      })
  }

  async runJob (job) {
    if (job.kind === 'prune') return this.runPrune(job)
    if (job.kind === 'collect') return this.runCollect(job)
    const turn = this.turn(job.sid, job.n)
    if (!turn) return
    const ref = snapshots.refFor(job.sid, job.n, job.kind)
    const r = await this.ops.snapshot(turn.cwd, { ref, meta: { session: job.sid, turn: job.n, kind: job.kind, at: Date.now() } })
    const info = snapInfo(r)
    turn[job.kind] = info
    if (r.ok) turn.repo = r.repo
    else if (r.reason !== 'not a git repo' && r.reason !== 'no cwd') log('snapshot', `skipped ${job.kind} of ${job.sid} turn ${job.n}: ${r.detail}`)
    debug('snapshot', `${job.kind} ${job.sid} turn ${job.n} ${r.ok ? r.commit.slice(0, 10) : r.reason} ${r.ms} ms`)
    this.dirty = true
    if (job.kind === 'before') {
      const prev = this.turn(job.sid, job.n - 1)
      if (prev && prev.afterFromNext && !prev.after) {
        prev.after = { ...info, fromNext: true }
        await this.summarize(prev)
      }
    }
    if (job.kind === 'after') await this.summarize(turn)
    if (r.ok) this.maybeSweep(r.repo)
  }

  // Files changed between a turn's two snapshots (kept with the turn, so
  // `turns` answers without git).
  async summarize (turn) {
    if (!turn.before || !turn.after || !turn.before.commit || !turn.after.commit) return
    try {
      const files = await this.ops.changes(turn.repo, turn.before.commit, turn.after.commit, { deadline: Date.now() + 10000 })
      turn.filesTotal = files.length
      turn.added = files.reduce((n, f) => n + f.added, 0)
      turn.removed = files.reduce((n, f) => n + f.removed, 0)
      turn.files = files.slice(0, MAX_FILES).map(f => ({ path: f.path, status: f.status, added: f.added, removed: f.removed, binary: f.binary || undefined }))
      turn.committed = !!(turn.before.head !== turn.after.head)
      this.dirty = true
    } catch (err) {
      log('snapshot', `diff of turn ${turn.n} failed: ${err.message}`)
    }
  }

  // Resolves once no job for sid is queued or running (at most WAIT_MAX_MS).
  idle (sid, maxMs = WAIT_MAX_MS) {
    if (!this.pendingBySession.get(sid)) return Promise.resolve(true)
    return new Promise(resolve => {
      const w = { sid, resolve, timer: null }
      w.timer = setTimeout(() => { this.waiters = this.waiters.filter(x => x !== w); resolve(false) }, maxMs)
      w.timer.unref && w.timer.unref()
      this.waiters.push(w)
    })
  }

  wake () {
    for (const w of [...this.waiters]) {
      if (!this.pendingBySession.get(w.sid)) {
        clearTimeout(w.timer)
        this.waiters = this.waiters.filter(x => x !== w)
        w.resolve(true)
      }
    }
  }

  pending (sid) {
    return this.pendingBySession.get(sid) || 0
  }

  // --- pruning ------------------------------------------------------------------

  // Turns over KEEP_TURNS or older than KEEP_MS leave with their refs.
  pruneSession (sid, now = Date.now()) {
    const s = this.sessions[sid]
    if (!s) return
    const keepFrom = Math.max(0, s.turns.length - envInt('CONDUCTORE_SNAPSHOT_KEEP_TURNS', KEEP_TURNS))
    const gone = s.turns.filter((t, i) => i < keepFrom || now - (t.endedAt || t.startedAt) > keepMs())
    if (!gone.length) return
    s.turns = s.turns.filter(t => !gone.includes(t))
    this.dirty = true
    for (const t of gone) if (t.repo) this.enqueue({ kind: 'prune', repo: t.repo, prefix: `${snapshots.REF_ROOT}/${sid}/${t.n}/` })
  }

  dropSession (sid) {
    const s = this.sessions[sid]
    if (!s) return
    delete this.sessions[sid]
    this.dirty = true
    const repos = new Set(s.turns.map(t => t.repo).filter(Boolean))
    for (const repo of repos) this.enqueue({ kind: 'prune', repo, prefix: `${snapshots.REF_ROOT}/${sid}/` })
  }

  // Sessions quiet for KEEP_MS (ended or not) and old turns. Called by the
  // daemon at start and when an agent is pruned; cheap, no git unless
  // something goes.
  prune (now = Date.now()) {
    for (const [sid, s] of Object.entries(this.sessions)) {
      if (now - s.lastAt > keepMs()) this.dropSession(sid)
      else this.pruneSession(sid, now)
    }
  }

  maybeSweep (repo, now = Date.now()) {
    if (now - (this.swept[repo] || 0) < SWEEP_EVERY_MS) return
    this.swept[repo] = now
    for (const [r, at] of Object.entries(this.swept)) if (now - at > KEEP_MS) delete this.swept[r]
    this.dirty = true
    this.enqueue({ kind: 'prune', repo, sweep: true })
  }

  async runPrune (job) {
    const deadline = Date.now() + 15000
    const refs = await this.ops.listRefs(job.repo, job.sweep ? `${snapshots.REF_ROOT}/` : job.prefix, deadline)
    const old = Date.now() - keepMs()
    const doomed = job.sweep ? refs.filter(r => r.at < old).map(r => r.ref) : refs.map(r => r.ref)
    const n = await this.ops.deleteRefs(job.repo, doomed, deadline)
    if (n) debug('snapshot', `pruned ${n} refs in ${job.repo}`)
    if (n) this.maybeCollect(job.repo)
  }

  // Objects the deleted refs left: queued behind whatever is waiting (a
  // turn's snapshot goes first), once per GC_EVERY_MS per repo.
  maybeCollect (repo, now = Date.now()) {
    if (now - (this.collected[repo] || 0) < envInt('CONDUCTORE_SNAPSHOT_GC_EVERY_MS', GC_EVERY_MS)) return
    if (this.queue.some(j => j.kind === 'collect' && j.repo === repo)) return
    this.collected[repo] = now
    for (const [r, at] of Object.entries(this.collected)) if (now - at > KEEP_MS) delete this.collected[r]
    this.dirty = true
    this.enqueue({ kind: 'collect', repo })
  }

  async runCollect (job) {
    const r = await this.ops.collect(job.repo, { expireMs: keepMs() })
    if (r && !r.ok) log('snapshot', `gc of ${job.repo} skipped: ${r.skipped}`)
    else if (r && !r.skipped) debug('snapshot', `gc of ${job.repo}: ${r.before} -> ${r.after} loose objects`)
  }

  // --- reading --------------------------------------------------------------------

  // Other sessions with a turn in the same repo overlapping [from, to]:
  // their changes are in this turn's snapshots too.
  overlapping (sid, turn) {
    if (!turn.repo) return []
    const from = turn.startedAt
    const to = turn.endedAt || Date.now()
    const out = []
    for (const [other, s] of Object.entries(this.sessions)) {
      if (other === sid) continue
      if (s.turns.some(t => t.repo === turn.repo && t.startedAt <= to && (t.endedAt || Date.now()) >= from)) out.push(other)
    }
    return out
  }

  // The record `turns` prints (newest first).
  view (sid, limit = 20) {
    const s = this.sessions[sid]
    if (!s) return null
    const turns = s.turns.slice(-limit).reverse().map(t => ({
      turn: t.n,
      prompt: t.prompt,
      startedAt: t.startedAt,
      endedAt: t.endedAt,
      running: !t.endedAt,
      repo: t.repo || null,
      files: t.files,
      filesTotal: t.filesTotal,
      added: t.added,
      removed: t.removed,
      committed: !!t.committed,
      late: !!t.late,
      before: t.before,
      after: t.after,
      others: this.overlapping(sid, t)
    }))
    return { cwd: s.cwd, endedAt: s.endedAt, turns, pending: this.pending(sid) }
  }

  toJSON () {
    return { v: 1, sessions: this.sessions, swept: this.swept, collected: this.collected }
  }
}

function keepMs () {
  return envInt('CONDUCTORE_SNAPSHOT_KEEP_MS', KEEP_MS)
}

module.exports = { Turns, headline, KEEP_TURNS, KEEP_MS, MAX_SESSIONS, MAX_FILES }
