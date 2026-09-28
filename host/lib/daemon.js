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
const proc = require('./proc')
const { permissionOutput } = require('./permission')
const { Approvals, CAPABILITIES } = require('./approvals')
const approvalOps = require('./approval-ops')
const { usageFrom } = require('./statusline')
const { Activity } = require('./activity')
const { Turns } = require('./turns')
const { LiveBridge } = require('./live')
const { Sidebar } = require('./sidebar')
const config = require('./config')
const { log, debug } = require('./log')

const CHANGE_BUFFER = 1000
// The buffered change lines are also bounded in characters: every record
// carries the agent's pending prompts (toolInput up to 4 KB each), so a few
// long prompts times 1000 changes outgrew the heap. A poller whose cursor
// fell out of the buffer resyncs with a snapshot.
const CHANGE_BUFFER_CHARS = 2 * 1024 * 1024
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

function requestId () {
  return Math.floor(Math.random() * 2 ** 48).toString(16).padStart(12, '0')
}

// Exclusive lock (also the pid file the sh clients check). A pid that is not
// a running daemon (a stale file after a reboot or crash, the pid since
// reused) does not hold it.
//
// There is never a moment without a whole lock file while a daemon holds
// it: the file is published complete (a hard link of a temp file holding our
// pid, never an empty file another starting daemon could read as stale), and
// a stale one is replaced by rename, not removed first. Only the caller that
// creates the takeover marker may replace it, after checking it still names
// the stale holder: two daemons starting at once (the hook's and the CLI's)
// cannot both take it.
const TAKEOVER_STALE_MS = 10000
const pause = new Int32Array(new SharedArrayBuffer(4))

function readPid (file) {
  try { return parseInt(fs.readFileSync(file, 'utf8'), 10) } catch { return NaN }
}

// Publishes tmp as file unless file exists. False when it does.
function publishNew (tmp, file) {
  try {
    fs.linkSync(tmp, file)
    return true
  } catch (err) {
    if (err.code === 'EEXIST') return false
  }
  // No hard links on this filesystem: exclusive create.
  try {
    fs.writeFileSync(file, String(process.pid) + '\n', { flag: 'wx', mode: 0o600 })
    return true
  } catch (err) {
    if (err.code === 'EEXIST') return false
    throw err
  }
}

function acquireLock () {
  const file = paths.lockPath()
  const tmp = `${file}.${process.pid}.tmp`
  const marker = `${file}.takeover`
  fs.writeFileSync(tmp, String(process.pid) + '\n', { mode: 0o600 })
  try {
    for (let attempt = 0; attempt < 50; attempt++) {
      if (publishNew(tmp, file)) return true
      const holder = readPid(file)
      if (holder === process.pid) return true
      if (holder && proc.isDaemon(holder)) return false
      try {
        fs.writeFileSync(marker, String(process.pid), { flag: 'wx', mode: 0o600 })
      } catch {
        // Another daemon is taking over: see who wins. A marker left by a
        // crash expires.
        try { if (Date.now() - fs.statSync(marker).mtimeMs > TAKEOVER_STALE_MS) fs.unlinkSync(marker) } catch {}
        Atomics.wait(pause, 0, 0, 20)
        continue
      }
      try {
        if (Object.is(readPid(file), holder)) {
          fs.renameSync(tmp, file)
          return true
        }
      } finally {
        try { fs.unlinkSync(marker) } catch {}
      }
    }
    return false
  } finally {
    try { fs.unlinkSync(tmp) } catch {}
  }
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

function loadActivity () {
  try { return new Activity(JSON.parse(fs.readFileSync(paths.activityPath(), 'utf8'))) } catch { return new Activity() }
}

function loadTurns () {
  try { return new Turns(JSON.parse(fs.readFileSync(paths.turnsPath(), 'utf8'))) } catch { return new Turns() }
}

function writeTurnsSync (turns) {
  if (!turns.dirty) return
  const file = paths.turnsPath()
  const tmp = `${file}.${process.pid}.tmp`
  fs.writeFileSync(tmp, JSON.stringify(turns), { mode: 0o600 })
  fs.renameSync(tmp, file)
  turns.dirty = false
}

function writeActivitySync (activity) {
  if (!activity.dirty) return
  const file = paths.activityPath()
  const tmp = `${file}.${process.pid}.tmp`
  fs.writeFileSync(tmp, JSON.stringify(activity), { mode: 0o600 })
  fs.renameSync(tmp, file)
  activity.dirty = false
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
    this.activity = loadActivity()
    this.turns = loadTurns()
    this.turns.onDirty = () => this.scheduleSnapshot()
    this.changes = [] // { seq, line }: each change record serialized once
    this.changeChars = 0
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
    // With seq, names one exact state: a restarted daemon (whose seq may
    // repeat after reloading state.json) never matches an older etag.
    this.epoch = `${process.pid.toString(36)}${Date.now().toString(36)}`
    // Herdr and tmux pushed to the phone while one asks (docs/herdr-live.md).
    this.live = new LiveBridge({
      onChange: r => this.onLive(r),
      companionAgents: () => Object.values(this.state.agents),
      tmuxEnabled: () => config.get('tmux-live') === 'on',
      extraSockets: () => [...new Set(Object.values(this.state.agents).map(a => a.herdr && a.herdr.socket).filter(Boolean))]
    })
    this.sidebar = new Sidebar({
      enabled: () => config.get('herdr-sidebar') !== 'off',
      holds: a => {
        const pane = this.live.store.get(`pane:${require('./herdr-api').idForSocket(a.herdr.socket || null)}:${a.herdr.paneId}`)
        return !!pane && pane.sessionId === a.sessionId
      }
    })
    this.sidebarQueued = false
  }

  start () {
    process.title = proc.DAEMON_TITLE
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
    // Any exit that still runs JS (process.exit, a fatal error handler) frees
    // the lock; a V8 abort cannot, and the next start sees a dead pid.
    process.on('exit', () => this.releaseLock())
    this.expireAgents()
    this.commit(state.prune(this.state))
    this.turns.prune()
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

  async process ({ header, body, mtime, oversize }) {
    if (header.kind === 'usage') return this.onUsageReport(body, true, mtime)
    if (header.kind !== 'hook') return
    if (oversize) log('daemon', `dropped an oversized ${header.event} event`)
    const event = body && typeof body === 'object' && !Array.isArray(body) ? body : {}
    if (!event.hook_event_name && header.event) event.hook_event_name = header.event
    const fifo = header.fifo || null
    if (!event.session_id || !event.hook_event_name) {
      if (fifo && isOurFifo(fifo)) writeFifo(fifo, '\n')
      return
    }
    // Before the auto-approve path too: an agent first seen through an
    // auto-approved request still gets its process (M20, M18).
    const known = this.state.agents[event.session_id]
    if (header.claude_pid && !(known && known.process && known.process.pid === Number(header.claude_pid))) {
      const claude = proc.identifyClaude(header.claude_pid)
      if (claude) event.process = claude
    }
    if (event.hook_event_name === 'PermissionRequest') {
      event.request_id = requestId()
      if (await approvalOps.autoApprove(this, event, fifo, header)) return
    }
    await context.enrich(event, header)
    if (event.hook_event_name === 'PermissionRequest') return this.onPermission(event, fifo, header.timeout)
    this.commit(state.reduce(this.state, event))
    this.activity.onEvent(event)
    // Queues git snapshots in the background; never awaited here.
    this.turns.onEvent(event)
    this.scheduleSnapshot()
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
    log('permission', `${id} ${resolution}`)
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
      if (ch.type === 'remove' || ch.reason === 'SessionEnd' || ch.reason === 'expired') pruneRelevant = true
      this.activity.onChange(ch)
      const line = JSON.stringify(ch)
      this.changes.push({ seq: ch.seq, sessionId: ch.sessionId, line, kind: 'agent' })
      this.changeChars += line.length
      debug('change', `${ch.type} ${ch.sessionId} ${ch.reason} -> ${ch.agent ? ch.agent.state : 'removed'} seq ${ch.seq}`)
    }
    this.trimChanges()
    for (const p of [...this.pollers]) this.servePoller(p)
    this.live.companionChanged()
    this.sidebar.update(this.state.agents)
    if (pruneRelevant) this.schedulePrune()
    if (!this.snapshotTimer) {
      this.snapshotTimer = setTimeout(() => { this.snapshotTimer = null; this.flushSnapshot() }, SNAPSHOT_DEBOUNCE_MS)
      this.snapshotTimer.unref()
    }
  }

  trimChanges () {
    while (this.changes.length > CHANGE_BUFFER || (this.changes.length > 1 && this.changeChars > CHANGE_BUFFER_CHARS)) {
      this.changeChars -= this.changes.shift().line.length
    }
  }

  // A live entity or a Herdr-only agent changed: one record in the same
  // sequence as the agents' changes, for the pollers that asked for it.
  // Only the live bridge's own agents go to `herdr` pollers.
  onLive (r) {
    this.state.seq += 1
    const seq = this.state.seq
    let entry
    if (r.agent !== undefined) {
      const ch = r.record
        ? { seq, type: 'change', sessionId: r.agent, reason: 'herdr', agent: r.record }
        : { seq, type: 'remove', sessionId: r.agent, reason: 'herdr', agent: null }
      entry = { seq, sessionId: r.agent, line: JSON.stringify(ch), kind: 'herdr' }
    } else {
      const ch = { seq, type: 'live', key: r.key, entity: r.entity }
      if (r.lazy) ch.lazy = true
      entry = { seq, sessionId: `live:${r.key}`, line: JSON.stringify(ch), kind: 'live', lazy: !!r.lazy }
    }
    this.changes.push(entry)
    this.changeChars += entry.line.length
    this.trimChanges()
    for (const p of [...this.pollers]) this.servePoller(p)
    if (r.key && r.key.startsWith('pane:') && !this.sidebarQueued) {
      this.sidebarQueued = true
      setImmediate(() => { this.sidebarQueued = false; this.sidebar.update(this.state.agents) })
    }
  }

  // Agents that will never send SessionEnd (their Claude Code is gone). Runs
  // at start and whenever the phone asks, so it costs nothing at idle.
  expireAgents () {
    const changes = state.expire(this.state, proc.sameProcess)
    this.commit(changes)
    // Rules that end with the session end with it, as on SessionEnd.
    for (const ch of changes) this.approvals.endSession(ch.sessionId)
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
      this.expireAgents()
      this.commit(state.prune(this.state))
      this.schedulePrune()
    }, Math.max(1000, next - Date.now() + 1000))
    this.pruneTimer.unref()
  }

  flushSnapshot () {
    try { writeSnapshotSync(this.state) } catch (err) { log('daemon', 'snapshot failed', err.message) }
    try { writeActivitySync(this.activity) } catch (err) { log('daemon', 'activity snapshot failed', err.message) }
    try { writeTurnsSync(this.turns) } catch (err) { log('daemon', 'turns snapshot failed', err.message) }
  }

  // The turn store changes after the event path returned (a snapshot
  // finished); the same debounce writes it.
  scheduleSnapshot () {
    if (this.snapshotTimer || !this.turns.dirty) return
    this.snapshotTimer = setTimeout(() => { this.snapshotTimer = null; this.flushSnapshot() }, SNAPSHOT_DEBOUNCE_MS)
    this.snapshotTimer.unref()
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
        if (req.live || req.herdrAgents) {
          this.live.touch()
          await this.live.ready()
        }
        this.expireAgents()
        this.commit(state.prune(this.state))
        this.replyStatus(req, c); c.end(); return
      case 'digest':
        // Everything `digest` needs in one answer: the agents and their activity.
        await this.drain()
        this.expireAgents()
        this.commit(state.prune(this.state))
        this.activity.prune()
        this.reply(c, { ...state.snapshot(this.state), source: 'daemon', capabilities: CAPABILITIES, activity: this.activity.toJSON(), now: Date.now() }); c.end(); return
      case 'events':
        await this.drain()
        if (req.live || req.herdrAgents) this.live.touch()
        this.expireAgents()
        return this.handleEvents(req, c)
      case 'decide':
        return this.handleDecide(req, c)
      case 'usage':
        // Legacy Node statusline (`conductore-hostd statusline`).
        this.reply(c, { ok: true, result: this.handleUsage(req) }); c.end(); return
      case 'turns': {
        // `turns`, `diff`, `undo`: the session's turn records, after its
        // queued snapshots finished when asked to wait.
        await this.drain()
        const sid = String(req.sessionId || '')
        const idle = req.wait ? await this.turns.idle(sid) : this.turns.pending(sid) === 0
        this.turns.prune()
        this.scheduleSnapshot()
        const a = this.state.agents[sid]
        const agent = a ? { name: a.name, state: a.state, cwd: a.cwd, endedAt: a.endedAt } : null
        this.reply(c, { ok: true, sessionId: sid, idle, agent, record: this.turns.view(sid, Number(req.limit) || 20) }); c.end(); return
      }
      case 'approve-low': case 'trust': case 'rules': case 'approvals':
        this.reply(c, approvalOps.handle(this, req)); c.end(); return
      case 'agents':
        // The messaging commands' view: the daemon's agents with the
        // Herdr-only ones the bridge knows (none while it is not running).
        await this.drain()
        this.reply(c, { ok: true, agents: state.snapshot(this.state).agents, herdrAgents: this.live.herdrAgents(), live: this.live.running }); c.end(); return
      case 'config':
        this.reply(c, { ok: true, config: config.reload() }); c.end()
        this.sidebar.update(this.state.agents, { force: true })
        this.live.syncTmux()
        return
      case 'stop':
        this.reply(c, { ok: true }); c.end()
        setImmediate(() => this.shutdown(0))
        return
      default:
        this.reply(c, { error: `unknown op ${req.op}` }); c.end()
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
    const verdict = approvalOps.decideVerdict(found.request, decision)
    if (!this.settle(requestId, verdict.decision, message)) {
      this.reply(c, { error: 'request expired; answer it in the terminal' }); c.end(); return
    }
    this.reply(c, { ok: true, requestId, decision: verdict.decision, sessionId: found.agent.sessionId, ...(verdict.note ? { note: verdict.note } : {}) }); c.end()
  }

  // `status`; with the etag of the phone's last copy, only a marker when
  // nothing changed since (an idle machine's poll stays a few bytes).
  replyStatus (req, c) {
    const variant = `${req.live ? 'l' : ''}${req.herdrAgents ? 'h' : ''}`
    const etag = `${this.epoch}.${this.state.seq}${variant ? '.' + variant : ''}`
    if (typeof req.etag === 'string' && req.etag === etag) {
      this.reply(c, { version: this.state.version, seq: this.state.seq, etag, unchanged: true, source: 'daemon', capabilities: CAPABILITIES })
      return
    }
    this.reply(c, { ...this.snapshotFor(req), etag, source: 'daemon', capabilities: CAPABILITIES })
  }

  // `status` / a resync snapshot, with what the request asked for.
  snapshotFor (req) {
    const snap = state.snapshot(this.state)
    if (req.herdrAgents) snap.agents = snap.agents.concat(this.live.herdrAgents())
    if (req.live) snap.live = { running: this.live.running, entities: this.live.entities() }
    return snap
  }

  // Whether a poller asked for this buffered change.
  wants (poller, ch) {
    if (ch.kind === 'live') return poller.live
    if (poller.onlyLive) return false
    return ch.kind !== 'herdr' || poller.herdrAgents
  }

  handleEvents (req, c) {
    const since = req.since !== undefined && req.since !== null && Number.isFinite(Number(req.since)) ? Number(req.since) : this.state.seq
    let timeout = Number(req.timeout)
    if (!Number.isFinite(timeout) || timeout < 0) timeout = DEFAULT_POLL_TIMEOUT_S
    timeout = Math.min(timeout, MAX_POLL_TIMEOUT_S)
    const poller = { socket: c, since, timer: null, live: !!req.live, herdrAgents: !!req.herdrAgents, onlyLive: !!req.onlyLive }
    // If the client's cursor is not covered by our buffer, resync with a snapshot.
    const oldest = this.changes.length ? this.changes[0].seq : this.state.seq + 1
    if (since > this.state.seq || (since < oldest - 1 && this.changes.length)) {
      this.reply(c, { type: 'snapshot', ...this.snapshotFor(poller) }); c.end(); return
    }
    if (this.servePoller(poller)) return
    this.pollers.add(poller)
    poller.timer = setTimeout(() => {
      this.pollers.delete(poller)
      // Lazy changes (activity times only) waited for this moment.
      if (this.servePoller(poller, { flushLazy: true })) return
      this.reply(c, { type: 'timeout', seq: this.state.seq }); c.end()
    }, timeout * 1000)
    c.on('close', () => { this.pollers.delete(poller); clearTimeout(poller.timer) })
  }

  // Writes the buffered changes after poller.since and closes; true if it
  // did. Each change carries the whole agent, so only the last one per
  // session is sent (in seq order): a phone back after a few minutes gets
  // one line per busy agent, not one per tool call.
  // Lazy changes alone do not answer a waiting poll (flushLazy: the
  // timeout, which then delivers them).
  servePoller (poller, { flushLazy = false } = {}) {
    const seen = new Set()
    const batch = []
    let urgent = false
    for (let i = this.changes.length - 1; i >= 0 && this.changes[i].seq > poller.since; i--) {
      const ch = this.changes[i]
      if (!this.wants(poller, ch)) continue
      if (seen.has(ch.sessionId)) continue
      seen.add(ch.sessionId)
      batch.push(ch)
      if (!ch.lazy) urgent = true
    }
    if (!batch.length || (!urgent && !flushLazy)) return false
    batch.reverse()
    this.pollers.delete(poller)
    clearTimeout(poller.timer)
    if (!poller.socket.destroyed) poller.socket.write(batch.map(ch => ch.line).join('\n') + '\n')
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
    this.live.stop()
    this.sidebar.stop()
    for (const [sid, timer] of this.holds) {
      clearTimeout(timer)
      try { fs.unlinkSync(path.join(paths.usageDir(), `${sid}.hold`)) } catch {}
    }
    for (const t of [this.snapshotTimer, this.pruneTimer, this.idleTimer]) clearTimeout(t)
    clearInterval(this.probeTimer)
    clearInterval(this.watchFallback)
    // A snapshot still running is dropped (its temp index goes with tmp/'s
    // hourly clean-up); the next turn takes a new one.
    require('./snapshots').killAll()
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

module.exports = { Daemon, run, loadSnapshot, writeFifo, fifoAlive, isOurFifo }
