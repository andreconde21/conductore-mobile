'use strict'

// The daemon: one per user. Hook events and statusline reports arrive as
// files in the spool directory (written by the sh clients, see spool.js);
// the phone's CLI commands talk to it over the unix socket. State lives in
// memory with a JSON snapshot on disk.
//
// Idle cost matters more than anything here: no polling loops. The process
// sleeps in epoll/kqueue until a spool file appears or a CLI connects. The
// only timers are one-shots tied to activity (snapshot debounce, usage
// throttle, next prune deadline, long-poll timeouts, the idle exit) plus a
// 1 s FIFO liveness probe that runs only while a permission prompt waits.

const fs = require('fs')
const net = require('net')
const path = require('path')
const paths = require('./paths')
const state = require('./state')
const spool = require('./spool')
const context = require('./context')
const { permissionOutput } = require('./permission')
const { Approvals } = require('./approvals')
const { usageFrom } = require('./statusline')
const { log, debug } = require('./log')

const CHANGE_BUFFER = 1000
const MAX_REQUEST_BYTES = 1024 * 1024
const DEFAULT_POLL_TIMEOUT_S = 55
const MAX_POLL_TIMEOUT_S = 600
const DEFAULT_PERMISSION_TIMEOUT_S = 120
const MAX_PERMISSION_TIMEOUT_S = 600
const PROBE_EVERY_MS = 1000
const SNAPSHOT_DEBOUNCE_MS = 1000
const WATCH_FALLBACK_MS = 2000
const TMP_MAX_AGE_MS = 60 * 60 * 1000
const SESSION_ID = /^[A-Za-z0-9_-]{1,128}$/

// At most one usage-only change per session per this interval; also how long
// the sh statusline parks its reports (usage/<sid>.hold) between two wake-ups.
function usageThrottleMs () {
  const v = Number(process.env.CONDUCTORE_USAGE_THROTTLE_MS)
  return Number.isFinite(v) && v >= 0 ? v : 10000
}

function pidAlive (pid) {
  try { process.kill(pid, 0); return true } catch (err) { return err.code === 'EPERM' }
}

function requestId () {
  return Math.floor(Math.random() * 2 ** 48).toString(16).padStart(12, '0')
}

// Exclusive lock (also the pid file the sh clients check).
function acquireLock () {
  const file = paths.lockPath()
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      fs.writeFileSync(file, String(process.pid) + '\n', { flag: 'wx', mode: 0o600 })
      return true
    } catch (err) {
      if (err.code !== 'EEXIST') throw err
      let pid = NaN
      try { pid = parseInt(fs.readFileSync(file, 'utf8'), 10) } catch {}
      if (pid && pid !== process.pid && pidAlive(pid)) return false
      try { fs.unlinkSync(file) } catch {}
    }
  }
  return false
}

function loadSnapshot () {
  const st = state.createState()
  try {
    const snap = JSON.parse(fs.readFileSync(paths.statePath(), 'utf8'))
    if (snap && Array.isArray(snap.agents)) {
      st.seq = Number(snap.seq) || 0
      for (const a of snap.agents) if (a && a.sessionId) st.agents[a.sessionId] = { ...a, pending: [] }
    }
  } catch {}
  return st
}

function writeSnapshotSync (st) {
  const file = paths.statePath()
  const tmp = `${file}.${process.pid}.tmp`
  fs.writeFileSync(tmp, JSON.stringify({ ...state.snapshot(st), writtenAt: Date.now() }), { mode: 0o600 })
  fs.renameSync(tmp, file)
}

// --- FIFOs of waiting PermissionRequest hooks --------------------------------

// Only FIFOs directly inside our tmp dir are ever opened.
function isOurFifo (file) {
  if (typeof file !== 'string' || !path.isAbsolute(file) || path.dirname(file) !== paths.tmpDir()) return false
  try { return fs.lstatSync(file).isFIFO() } catch { return false }
}

// The hook holds its FIFO open read-write while it waits, so a non-blocking
// write-open succeeds exactly while it (or its watchdog) is alive; ENXIO
// means nobody is reading any more.
function openFifo (file) {
  try { return fs.openSync(file, fs.constants.O_WRONLY | fs.constants.O_NONBLOCK) } catch { return null }
}

function fifoAlive (file) {
  const fd = openFifo(file)
  if (fd === null) return false
  try { fs.closeSync(fd) } catch {}
  return true
}

const pause = new Int32Array(new SharedArrayBuffer(4))

// Writes one line to a waiting hook. False when it is gone.
function writeFifo (file, text) {
  const fd = openFifo(file)
  if (fd === null) return false
  try {
    const buf = Buffer.from(text)
    let off = 0
    const deadline = Date.now() + 2000
    while (off < buf.length) {
      try {
        off += fs.writeSync(fd, buf, off)
      } catch (err) {
        // A line longer than the pipe buffer: wait for the hook to read.
        if (err.code !== 'EAGAIN' || Date.now() > deadline) return false
        Atomics.wait(pause, 0, 0, 5)
      }
    }
    return true
  } finally {
    try { fs.closeSync(fd) } catch {}
  }
}

class Daemon {
  constructor () {
    this.state = loadSnapshot()
    this.changes = []
    this.waiters = new Map() // requestId -> { fifo, event, sessionId, timer }
    this.approvals = new Approvals()
    this.pollers = new Set() // { socket, since, timer }
    this.usageEmits = new Map() // sessionId -> { at, timer }
    this.holds = new Map() // sessionId -> timer (usage/<sid>.hold exists)
    this.usageSeen = new Map() // sessionId -> mtime of the last applied report
    this.queue = Promise.resolve()
    this.drainScheduled = false
    this.server = null
    this.watcher = null
    this.watchFallback = null
    this.idleTimer = null
    this.snapshotTimer = null
    this.pruneTimer = null
    this.probeTimer = null
    this.stopping = false
  }

  start () {
    paths.ensureDirs()
    if (!acquireLock()) {
      log('daemon', 'another daemon holds the lock, exiting')
      return false
    }
    this.cleanTmp()
    // Never take over a socket another live daemon serves (an older version
    // whose lock lives elsewhere, a second instance): exit instead.
    const probe = net.createConnection(paths.socketPath())
    probe.on('connect', () => {
      probe.destroy()
      log('daemon', `another daemon serves ${paths.socketPath()}, exiting`)
      this.releaseLock()
      process.exit(0)
    })
    probe.on('error', () => this.listen())
    return true
  }

  listen () {
    const sock = paths.socketPath()
    try { fs.unlinkSync(sock) } catch {}
    this.server = net.createServer(c => this.onConnection(c))
    this.server.on('error', err => { log('daemon', 'server error', err.message); this.shutdown(1) })
    this.server.listen(sock, () => {
      try { fs.chmodSync(sock, 0o600) } catch {}
      log('daemon', `listening on ${sock} pid ${process.pid} seq ${this.state.seq} node ${process.version} ${process.execArgv.join(' ')}`)
    })
    this.watchSpool()
    this.touch()
    for (const sig of ['SIGTERM', 'SIGINT', 'SIGHUP']) process.on(sig, () => this.shutdown(0))
    process.on('uncaughtException', err => { log('daemon', 'uncaught', err.stack || String(err)) })
    this.commit(state.prune(this.state))
    this.schedulePrune()
    this.flushSnapshot()
    this.importParkedUsage()
    this.scheduleDrain()
  }

  releaseLock () {
    try {
      if (parseInt(fs.readFileSync(paths.lockPath(), 'utf8'), 10) === process.pid) fs.unlinkSync(paths.lockPath())
    } catch {}
  }

  watchSpool () {
    const fallback = why => {
      if (this.watchFallback) return
      log('daemon', `spool watch unavailable (${why}); scanning every ${WATCH_FALLBACK_MS} ms`)
      this.watchFallback = setInterval(() => this.scheduleDrain(), WATCH_FALLBACK_MS)
    }
    try {
      this.watcher = fs.watch(paths.spoolDir(), { persistent: true }, () => this.scheduleDrain())
      this.watcher.on('error', err => {
        try { this.watcher.close() } catch {}
        this.watcher = null
        fallback(err.message)
      })
    } catch (err) {
      fallback(err.message)
    }
  }

  // Leftovers of hooks that died mid-write, and FIFOs nobody reads.
  cleanTmp () {
    const dir = paths.tmpDir()
    let names = []
    try { names = fs.readdirSync(dir) } catch {}
    const now = Date.now()
    for (const name of names) {
      const file = path.join(dir, name)
      try {
        if (now - fs.lstatSync(file).mtimeMs > TMP_MAX_AGE_MS) fs.unlinkSync(file)
      } catch {}
    }
  }

  touch () {
    clearTimeout(this.idleTimer)
    const ms = paths.idleExitMs()
    if (!ms) return
    this.idleTimer = setTimeout(() => { log('daemon', 'idle, exiting'); this.shutdown(0) }, ms)
    this.idleTimer.unref()
  }

  // --- spool ------------------------------------------------------------------

  // Coalesced: any number of watch events while a drain is queued add nothing.
  scheduleDrain () {
    if (this.drainScheduled || this.stopping) return this.queue
    this.drainScheduled = true
    this.queue = this.queue.then(() => {
      this.drainScheduled = false
      return this.drainOnce()
    }).catch(err => log('daemon', 'drain failed', err.stack || String(err)))
    return this.queue
  }

  // Resolves once everything spooled so far has been applied.
  drain () {
    return this.scheduleDrain()
  }

  async drainOnce () {
    const dir = paths.spoolDir()
    for (let round = 0; round < 100; round++) {
      const entries = spool.list(dir)
      if (!entries.length) return
      this.touch()
      for (const entry of entries) {
        const item = spool.take(entry, paths.tmpDir())
        if (!item) continue
        try { await this.process(item) } catch (err) { log('daemon', 'spool entry failed', err.stack || String(err)) }
      }
    }
  }

  async process ({ header, body, mtime }) {
    if (header.kind === 'usage') return this.onUsageReport(body, true, mtime)
    if (header.kind !== 'hook') return
    const event = body && typeof body === 'object' && !Array.isArray(body) ? body : {}
    if (!event.hook_event_name && header.event) event.hook_event_name = header.event
    const fifo = header.fifo || null
    if (!event.session_id || !event.hook_event_name) {
      if (fifo && isOurFifo(fifo)) writeFifo(fifo, '\n')
      return
    }
    if (event.hook_event_name === 'PermissionRequest') {
      event.request_id = requestId()
      this.approvals.assess(event)
      // A rule answers before anything else runs (no tmux lookup first):
      // the hook prints the decision within milliseconds.
      const rule = fifo && isOurFifo(fifo) ? this.approvals.match(event) : null
      if (rule && writeFifo(fifo, JSON.stringify(permissionOutput(event, 'allow')) + '\n')) {
        await context.enrich(event, header)
        this.commit(state.autoApproved(this.state, event))
        this.approvals.record(rule, event, this.state.agents[event.session_id])
        log('permission', `${event.request_id} auto (${rule.id} ${rule.rule})`)
        return
      }
      await context.enrich(event, header)
      return this.onPermission(event, fifo, header.timeout)
    }
    await context.enrich(event, header)
    this.commit(state.reduce(this.state, event))
    if (event.hook_event_name === 'SessionEnd') this.approvals.endSession(event.session_id)
  }

  // --- permission requests ----------------------------------------------------

  onPermission (event, fifo, timeout) {
    const id = event.request_id || requestId()
    event.request_id = id
    this.commit(state.reduce(this.state, event))
    if (!fifo || !isOurFifo(fifo) || !fifoAlive(fifo)) {
      // Nobody is waiting (no FIFO support, or the hook gave up already):
      // the prompt is in the terminal.
      this.commit(state.resolvePermission(this.state, id, 'timeout'))
      return
    }
    let seconds = Number(timeout)
    if (!Number.isFinite(seconds) || seconds <= 0) seconds = DEFAULT_PERMISSION_TIMEOUT_S
    seconds = Math.min(seconds, MAX_PERMISSION_TIMEOUT_S)
    const waiter = { fifo, event, sessionId: event.session_id, timer: null }
    waiter.timer = setTimeout(() => this.settle(id, 'timeout'), seconds * 1000)
    this.waiters.set(id, waiter)
    this.ensureProbe()
  }

  // Notices hooks that were killed while waiting (Claude Code cancelled the
  // prompt, the terminal answered it, the session died).
  ensureProbe () {
    if (this.probeTimer) return
    this.probeTimer = setInterval(() => {
      for (const [id, w] of [...this.waiters]) if (!fifoAlive(w.fifo)) this.settle(id, 'gone')
      if (!this.waiters.size) { clearInterval(this.probeTimer); this.probeTimer = null }
    }, PROBE_EVERY_MS)
    this.probeTimer.unref()
  }

  // Resolves a waiting hook. decision: allow | deny | always | timeout | gone.
  // `rule`: the approval rule that answered it (logged as auto-approved).
  // Returns whether the hook received the answer.
  settle (id, decision, message, rule = null) {
    const waiter = this.waiters.get(id)
    if (!waiter) return false
    this.waiters.delete(id)
    clearTimeout(waiter.timer)
    let delivered = false
    if (decision !== 'gone') {
      const out = permissionOutput(waiter.event, decision, message)
      delivered = writeFifo(waiter.fifo, out ? JSON.stringify(out) + '\n' : '\n')
    }
    if (!delivered) {
      // The hook is gone; its FIFO would otherwise linger.
      try { if (isOurFifo(waiter.fifo)) fs.unlinkSync(waiter.fifo) } catch {}
    }
    const resolution = delivered || decision === 'timeout' ? (rule && delivered ? 'auto' : decision) : 'gone'
    this.commit(state.resolvePermission(this.state, id, resolution))
    if (rule && delivered) this.approvals.record(rule, waiter.event, this.state.agents[waiter.sessionId])
    log('permission', `${id} ${resolution}${rule ? ` (${rule.id} ${rule.rule})` : ''}`)
    if (!this.waiters.size && this.probeTimer) { clearInterval(this.probeTimer); this.probeTimer = null }
    return delivered
  }

  // --- usage ------------------------------------------------------------------

  // A statusline report (raw statusline JSON). From the spool it also opens a
  // hold window: until it closes, the sh statusline parks newer reports as
  // usage/<sid>.<pid> instead of waking us; the newest is applied on close.
  // Reports older than one already applied are ignored.
  onUsageReport (input, fromSpool, mtime = Date.now()) {
    if (!input || typeof input !== 'object' || typeof input.session_id !== 'string' || !input.session_id) return
    const sid = input.session_id
    if (mtime < (this.usageSeen.get(sid) || 0)) return
    this.usageSeen.set(sid, mtime)
    this.handleUsage({ sessionId: sid, usage: usageFrom(input) })
    if (fromSpool) this.hold(sid)
  }

  hold (sid) {
    if (!SESSION_ID.test(sid) || this.holds.has(sid) || this.stopping) return
    const ms = usageThrottleMs()
    if (!ms) return
    const file = path.join(paths.usageDir(), `${sid}.hold`)
    try { fs.writeFileSync(file, '', { mode: 0o600 }) } catch { return }
    const timer = setTimeout(() => {
      this.holds.delete(sid)
      try { fs.unlinkSync(file) } catch {}
      this.applyParked(sid)
    }, ms)
    timer.unref()
    this.holds.set(sid, timer)
  }

  // Applies the newest parked report of a session (or of all, at start) and
  // drops the others.
  applyParked (sid) {
    const newest = new Map()
    for (const entry of spool.list(paths.usageDir(), sid ? `${sid}.` : '')) {
      if (entry.name.endsWith('.hold')) continue
      const item = spool.take(entry, paths.tmpDir())
      if (!item || item.header.kind !== 'usage' || !item.body || typeof item.body.session_id !== 'string') continue
      newest.set(item.body.session_id, item) // list() is oldest first
    }
    for (const item of newest.values()) this.onUsageReport(item.body, true, item.mtime)
  }

  // At start: holds from a previous run are stale; parked reports still count.
  importParkedUsage () {
    for (const entry of spool.list(paths.usageDir())) {
      if (entry.name.endsWith('.hold')) { try { fs.unlinkSync(entry.file) } catch {} }
    }
    this.applyParked(null)
  }

  // Stores a usage record now, publishes it throttled so the long-poll does
  // not churn on every assistant message.
  handleUsage (req) {
    const sid = req.sessionId
    if (typeof sid !== 'string' || !sid) return 'ignored'
    const usage = req.usage && typeof req.usage === 'object' ? req.usage : null
    const result = state.setUsage(this.state, sid, usage)
    if (result !== 'stored') return result
    const entry = this.usageEmits.get(sid) || { at: 0, timer: null }
    this.usageEmits.set(sid, entry)
    if (entry.timer) return 'scheduled'
    const wait = entry.at + usageThrottleMs() - Date.now()
    const emit = () => {
      entry.timer = null
      entry.at = Date.now()
      this.commit(state.usageChange(this.state, sid))
    }
    if (wait <= 0) { emit(); return 'published' }
    entry.timer = setTimeout(emit, wait)
    entry.timer.unref()
    return 'scheduled'
  }

  // --- state ------------------------------------------------------------------

  // Record change records, notify pollers, schedule snapshot.
  commit (changes) {
    if (!changes.length) return
    let pruneRelevant = false
    for (const ch of changes) {
      if (ch.type === 'remove') {
        const e = this.usageEmits.get(ch.sessionId)
        if (e) { clearTimeout(e.timer); this.usageEmits.delete(ch.sessionId) }
        this.usageSeen.delete(ch.sessionId)
      }
      if (ch.type === 'remove' || ch.reason === 'SessionEnd') pruneRelevant = true
      this.changes.push(ch)
      debug('change', `${ch.type} ${ch.sessionId} ${ch.reason} -> ${ch.agent ? ch.agent.state : 'removed'} seq ${ch.seq}`)
    }
    if (this.changes.length > CHANGE_BUFFER) this.changes.splice(0, this.changes.length - CHANGE_BUFFER)
    for (const p of [...this.pollers]) this.servePoller(p)
    if (pruneRelevant) this.schedulePrune()
    if (!this.snapshotTimer) {
      this.snapshotTimer = setTimeout(() => { this.snapshotTimer = null; this.flushSnapshot() }, SNAPSHOT_DEBOUNCE_MS)
      this.snapshotTimer.unref()
    }
  }

  // One timer for the next ended agent to fall out of the list.
  schedulePrune () {
    clearTimeout(this.pruneTimer)
    this.pruneTimer = null
    let next = Infinity
    for (const a of Object.values(this.state.agents)) {
      if (a.state === 'ended' && a.endedAt) next = Math.min(next, a.endedAt + state.PRUNE_AFTER_MS)
    }
    if (next === Infinity) return
    this.pruneTimer = setTimeout(() => {
      this.pruneTimer = null
      this.commit(state.prune(this.state))
      this.schedulePrune()
    }, Math.max(1000, next - Date.now() + 1000))
    this.pruneTimer.unref()
  }

  flushSnapshot () {
    try { writeSnapshotSync(this.state) } catch (err) { log('daemon', 'snapshot failed', err.message) }
  }

  // --- socket -----------------------------------------------------------------

  onConnection (c) {
    this.touch()
    let buf = ''
    let handled = false
    c.setEncoding('utf8')
    c.on('error', () => {})
    c.on('data', chunk => {
      if (handled) return
      buf += chunk
      if (buf.length > MAX_REQUEST_BYTES) { this.reply(c, { error: 'request too large' }); c.end(); return }
      const i = buf.indexOf('\n')
      if (i === -1) return
      handled = true
      let req
      try { req = JSON.parse(buf.slice(0, i)) } catch { this.reply(c, { error: 'bad json' }); c.end(); return }
      Promise.resolve().then(() => this.handle(req, c)).catch(err => {
        log('daemon', 'handler error', err.stack || String(err))
        this.reply(c, { error: err.message })
        c.end()
      })
    })
  }

  reply (c, obj) {
    if (c.destroyed) return
    c.write(JSON.stringify(obj) + '\n')
  }

  async handle (req, c) {
    switch (req.op) {
      case 'ping': {
        const cpu = process.cpuUsage()
        this.reply(c, {
          ok: true,
          pid: process.pid,
          seq: this.state.seq,
          version: paths.VERSION,
          rss: process.memoryUsage.rss(),
          cpuMs: Math.round((cpu.user + cpu.system) / 1000),
          uptimeS: Math.round(process.uptime()),
          execArgv: process.execArgv
        })
        c.end(); return
      }
      case 'status':
        await this.drain()
        this.commit(state.prune(this.state))
        this.reply(c, { ...state.snapshot(this.state), source: 'daemon', capabilities: paths.CAPABILITIES }); c.end(); return
      case 'events':
        await this.drain()
        return this.handleEvents(req, c)
      case 'decide':
        return this.handleDecide(req, c)
      case 'approve-low':
        return this.done(c, this.approveLow(req))
      case 'trust':
        return this.done(c, this.trust(req))
      case 'rules':
        return this.done(c, this.rulesOp(req))
      case 'approvals':
        return this.done(c, {
          rules: this.approvals.rules(),
          autoApproved: this.approvals.auditEntries(Date.now(), req.hours),
          now: Date.now()
        })
      case 'usage':
        // Legacy Node statusline (`conductore-hostd statusline`).
        this.reply(c, { ok: true, result: this.handleUsage(req) }); c.end(); return
      case 'stop':
        this.reply(c, { ok: true }); c.end()
        setImmediate(() => this.shutdown(0))
        return
      default:
        this.reply(c, { error: `unknown op ${req.op}` }); c.end()
    }
  }

  // Replies with a result object, or {error} when it threw.
  done (c, fn) {
    this.reply(c, fn)
    c.end()
  }

  // Waiting requests a rule now covers (one was just added) are answered.
  applyRules () {
    const approved = []
    for (const [id, w] of [...this.waiters]) {
      const rule = this.approvals.match(w.event)
      if (rule && this.settle(id, 'allow', null, rule)) approved.push(id)
    }
    return approved
  }

  // "Approve all N safe": allows every waiting request rated low (only those
  // listed in `ids`, when given; only one session's, with `sessionId`).
  // Anything else is skipped with a reason, never allowed.
  approveLow (req) {
    const wanted = Array.isArray(req.ids) ? new Set(req.ids.map(String)) : null
    const approved = []
    const skipped = []
    for (const agent of Object.values(this.state.agents)) {
      if (req.sessionId && agent.sessionId !== req.sessionId) continue
      for (const p of [...agent.pending]) {
        if (wanted && !wanted.has(p.id)) continue
        wanted && wanted.delete(p.id)
        if (!p.batchable || !p.risk || p.risk.level !== 'low') { skipped.push({ id: p.id, reason: `${(p.risk && p.risk.level) || 'unrated'} risk: review it` }); continue }
        if (!this.waiters.has(p.id)) {
          this.commit(state.resolvePermission(this.state, p.id, 'gone'))
          skipped.push({ id: p.id, reason: 'expired; answer it in the terminal' })
          continue
        }
        if (this.settle(p.id, 'allow')) approved.push({ id: p.id, sessionId: agent.sessionId, toolName: p.toolName, summary: p.summary })
        else skipped.push({ id: p.id, reason: 'expired; answer it in the terminal' })
      }
    }
    if (wanted) for (const id of wanted) skipped.push({ id, reason: 'unknown request' })
    return { ok: true, approved, skipped }
  }

  // "Trust this for N minutes": saves a rule from a waiting request, allows
  // the request and every other waiting one the rule covers. High-risk
  // requests are refused: they always ask.
  trust (req) {
    const found = state.findPending(this.state, req.requestId)
    if (!found) return { error: `unknown request ${req.requestId}` }
    const { agent, request } = found
    if (!request.risk || request.risk.level === 'high') {
      return { error: `high-risk requests always ask (${request.risk ? request.risk.reason : 'not rated'}); nothing was trusted` }
    }
    if (!this.waiters.has(request.id)) {
      this.commit(state.resolvePermission(this.state, request.id, 'gone'))
      return { error: 'request expired; answer it in the terminal' }
    }
    const kind = req.scope || 'repo'
    const scope = kind === 'session'
      ? { kind: 'session', sessionId: agent.sessionId, label: agent.name || null }
      : kind === 'repo'
        ? { kind: 'repo', path: req.path || request.repo || agent.cwd }
        : { kind: 'any' }
    const forever = !!req.forever
    const untilSessionEnd = !!req.untilSessionEnd
    const minutes = req.minutes !== undefined && req.minutes !== null ? req.minutes : forever || untilSessionEnd ? null : 60
    let rule
    try {
      rule = this.approvals.add({
        rule: req.rule || (request.suggestedRules || [])[0] || request.toolName,
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
    if (this.settle(request.id, 'allow')) approved.push(request.id)
    approved.push(...this.applyRules())
    return { ok: true, rule, approved }
  }

  rulesOp (req) {
    try {
      switch (req.action) {
        case 'list': case undefined:
          return { rules: this.approvals.rules(), now: Date.now() }
        case 'add': {
          const rule = this.approvals.add({ ...req.spec, source: (req.spec && req.spec.source) || 'cli' })
          return { ok: true, rule, approved: this.applyRules() }
        }
        case 'remove': {
          const rule = this.approvals.remove(req.id)
          return rule ? { ok: true, removed: rule } : { error: `unknown rule ${req.id}` }
        }
        case 'edit': {
          const rule = this.approvals.edit(req.id, req.patch || {})
          return rule ? { ok: true, rule, approved: this.applyRules() } : { error: `unknown rule ${req.id}` }
        }
        default:
          return { error: `unknown rules action ${req.action}` }
      }
    } catch (err) {
      return { error: err.message }
    }
  }

  handleDecide (req, c) {
    const { requestId, decision, message } = req
    if (!['allow', 'deny', 'always'].includes(decision)) {
      this.reply(c, { error: 'decision must be allow, deny or always' }); c.end(); return
    }
    const found = state.findPending(this.state, requestId)
    if (!found) { this.reply(c, { error: `unknown request ${requestId}` }); c.end(); return }
    if (!this.waiters.has(requestId)) {
      // Pending but nobody waiting: the hook died; clean up.
      this.commit(state.resolvePermission(this.state, requestId, 'gone'))
      this.reply(c, { error: 'request expired; answer it in the terminal' }); c.end(); return
    }
    // "Always" on a high-risk request would let Claude Code skip asking for
    // good: it is answered as a one-time allow instead.
    const high = decision === 'always' && found.request.risk && found.request.risk.level === 'high'
    if (!this.settle(requestId, high ? 'allow' : decision, message)) {
      this.reply(c, { error: 'request expired; answer it in the terminal' }); c.end(); return
    }
    const res = { ok: true, requestId, decision: high ? 'allow' : decision, sessionId: found.agent.sessionId }
    if (high) res.note = 'high-risk requests always ask: allowed once, no rule saved'
    this.reply(c, res); c.end()
  }

  handleEvents (req, c) {
    const since = req.since !== undefined && req.since !== null && Number.isFinite(Number(req.since)) ? Number(req.since) : this.state.seq
    let timeout = Number(req.timeout)
    if (!Number.isFinite(timeout) || timeout < 0) timeout = DEFAULT_POLL_TIMEOUT_S
    timeout = Math.min(timeout, MAX_POLL_TIMEOUT_S)
    const poller = { socket: c, since, timer: null }
    // If the client's cursor is not covered by our buffer, resync with a snapshot.
    const oldest = this.changes.length ? this.changes[0].seq : this.state.seq + 1
    if (since > this.state.seq || (since < oldest - 1 && this.changes.length)) {
      this.reply(c, { type: 'snapshot', ...state.snapshot(this.state) }); c.end(); return
    }
    if (this.servePoller(poller)) return
    this.pollers.add(poller)
    poller.timer = setTimeout(() => {
      this.pollers.delete(poller)
      this.reply(c, { type: 'timeout', seq: this.state.seq }); c.end()
    }, timeout * 1000)
    c.on('close', () => { this.pollers.delete(poller); clearTimeout(poller.timer) })
  }

  // Writes all buffered changes after poller.since and closes; true if it did.
  servePoller (poller) {
    const batch = this.changes.filter(ch => ch.seq > poller.since)
    if (!batch.length) return false
    this.pollers.delete(poller)
    clearTimeout(poller.timer)
    for (const ch of batch) this.reply(poller.socket, ch)
    poller.socket.end()
    return true
  }

  shutdown (code) {
    if (this.stopping) return
    this.stopping = true
    log('daemon', `shutting down (${code})`)
    for (const id of [...this.waiters.keys()]) this.settle(id, 'timeout')
    for (const p of this.pollers) { this.reply(p.socket, { type: 'timeout', seq: this.state.seq }); p.socket.end() }
    for (const e of this.usageEmits.values()) clearTimeout(e.timer)
    for (const [sid, timer] of this.holds) {
      clearTimeout(timer)
      try { fs.unlinkSync(path.join(paths.usageDir(), `${sid}.hold`)) } catch {}
    }
    for (const t of [this.snapshotTimer, this.pruneTimer, this.idleTimer]) clearTimeout(t)
    clearInterval(this.probeTimer)
    clearInterval(this.watchFallback)
    try { this.watcher && this.watcher.close() } catch {}
    this.flushSnapshot()
    try { this.server && this.server.close() } catch {}
    try { fs.unlinkSync(paths.socketPath()) } catch {}
    // A clean exit lets the next hook start a daemon at once.
    try { fs.unlinkSync(paths.spawnStampPath()) } catch {}
    this.releaseLock()
    setTimeout(() => process.exit(code), 50).unref()
  }
}

function run () {
  const d = new Daemon()
  if (!d.start()) process.exit(0)
  return d
}

module.exports = { Daemon, run, loadSnapshot, writeFifo, fifoAlive }
