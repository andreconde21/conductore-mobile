'use strict'

// One Herdr server's live state, pushed by Herdr (no polling).
//
// Two subscriptions, each on its own connection, both read-only by
// construction: nothing but the one `events.subscribe` line is ever written
// on them.
//   A: the lifecycle events (workspaces, tabs, panes, layouts, worktrees).
//   C: `pane.agent_status_changed` for every current pane. Status changes
//      produce no pane or workspace event, and this subscription needs one
//      entry per pane id.
// Any event re-reads `session.snapshot` on a fresh connection (debounced),
// the one source of truth, so event payloads that move between versions
// cannot corrupt the model.
//
// Quirks of Herdr 0.9.1, covered here and in test/herdr-live.test.js:
//   - one subscribe per connection: any second request on it (even a
//     ping) makes Herdr reset the connection. A new pane set means a new
//     connection C', then closing C.
//   - an unknown pane id fails the whole subscribe (`pane_not_found`): a
//     pane closed between the snapshot and the subscribe. Re-snapshot and
//     try again.
//   - no replay: the snapshot is read after A is accepted, so nothing
//     between the two is lost.
//   - output matching (`pane.output_matched`) also fires on the prompt's
//     echo; it is never used.
// A safety-net snapshot runs every 60 s while the watch is active.

const net = require('net')
const api = require('./herdr-api')
const { log } = require('./log')

const LIFECYCLE = [
  'workspace.created', 'workspace.updated', 'workspace.metadata_updated', 'workspace.renamed', 'workspace.moved',
  'workspace.reordered', 'workspace.closed', 'workspace.focused',
  'worktree.created', 'worktree.opened', 'worktree.removed',
  'tab.created', 'tab.closed', 'tab.focused', 'tab.renamed', 'tab.moved',
  'pane.created', 'pane.closed', 'pane.updated', 'pane.focused', 'pane.moved', 'pane.exited', 'pane.agent_detected'
]
// Events whose pane set changes: C is renewed after the snapshot.
const PANE_SET_EVENTS = new Set(['pane_created', 'pane_closed', 'pane_moved', 'pane_exited', 'workspace_closed', 'tab_closed'])
const MIN_PROTOCOL = 22
const SNAPSHOT_DEBOUNCE_MS = 150
const SAFETY_SNAPSHOT_MS = 60 * 1000
const BACKOFF_MS = [1000, 2000, 4000, 8000, 16000, 30000, 60000]
// Without events.subscribe (an older Herdr): the snapshot on a timer.
const SNAPSHOT_MODE_MS = 10 * 1000

// Whether a herdr binary is on PATH or in the usual user-local places
// (the phone tells "not installed" from "not running" by it). No spawn.
let installedCache = null
function herdrInstalled () {
  if (installedCache && Date.now() - installedCache.at < 5 * 60 * 1000) return installedCache.value
  const fs = require('fs')
  const path = require('path')
  const home = require('os').homedir()
  const dirs = [...String(process.env.PATH || '').split(':'), path.join(home, '.local', 'bin'), path.join(home, '.local', 'share', 'mise', 'shims'), path.join(home, '.cargo', 'bin'), '/usr/local/bin', '/opt/homebrew/bin']
  const value = dirs.filter(Boolean).some(d => { try { fs.accessSync(path.join(d, 'herdr'), fs.constants.X_OK); return true } catch { return false } })
  installedCache = { at: Date.now(), value }
  return value
}

const str = v => (typeof v === 'string' ? v : null)
const int = v => (Number.isInteger(v) ? v : null)

// A subscription connection: writes the subscribe line once, then only
// reads. Resolves when Herdr accepted it; `onEvent` gets every event,
// `onClose` the end (after acceptance).
function subscribe (socket, subscriptions, { onEvent, onClose, timeoutMs = 5000 }) {
  return new Promise((resolve, reject) => {
    const c = net.createConnection(socket)
    let buf = ''
    let started = false
    let settled = false
    const timer = setTimeout(() => fail(Object.assign(new Error('subscribe timed out'), { code: 'timeout' })), timeoutMs)
    function fail (err) {
      if (settled) return
      settled = true
      clearTimeout(timer)
      c.destroy()
      reject(err)
    }
    c.setEncoding('utf8')
    c.on('connect', () => c.write(JSON.stringify({ id: 'conductore:subscribe', method: 'events.subscribe', params: { subscriptions } }) + '\n'))
    c.on('data', chunk => {
      buf += chunk
      let i
      while ((i = buf.indexOf('\n')) !== -1) {
        const line = buf.slice(0, i)
        buf = buf.slice(i + 1)
        let msg
        try { msg = JSON.parse(line) } catch { continue }
        if (!started) {
          if (msg.error) return fail(Object.assign(new Error(msg.error.message || msg.error.code), { code: msg.error.code || 'error' }))
          if (msg.result && msg.result.type === 'subscription_started') {
            started = true
            settled = true
            clearTimeout(timer)
            resolve(handle)
          }
          continue
        }
        if (msg.event) onEvent(msg)
      }
    })
    c.on('error', err => { if (!started) fail(Object.assign(err, { code: err.code || 'error' })) })
    c.on('close', () => {
      if (!started) return fail(Object.assign(new Error('herdr closed the connection'), { code: 'closed' }))
      if (!handle.closed) { handle.closed = true; onClose && onClose() }
    })
    const handle = {
      closed: false,
      close () { handle.closed = true; c.destroy() }
    }
  })
}

// session.snapshot -> { entities: Map(key -> entity), paneIds }.
function entitiesFrom (serverId, snap) {
  const entities = new Map()
  const agents = new Map()
  for (const a of snap.agents || []) if (a && str(a.pane_id)) agents.set(a.pane_id, a)
  for (const w of snap.workspaces || []) {
    const id = str(w && w.workspace_id)
    if (!id) continue
    entities.set(`ws:${serverId}:${id}`, {
      kind: 'workspace',
      server: serverId,
      id,
      label: str(w.label) || '',
      number: int(w.number),
      focused: w.focused === true,
      agentStatus: str(w.agent_status) || '',
      activeTabId: str(w.active_tab_id) || '',
      tabCount: int(w.tab_count)
    })
  }
  for (const t of snap.tabs || []) {
    const id = str(t && t.tab_id)
    if (!id) continue
    entities.set(`tab:${serverId}:${id}`, {
      kind: 'tab',
      server: serverId,
      id,
      workspaceId: str(t.workspace_id) || '',
      label: str(t.label) || '',
      number: int(t.number),
      focused: t.focused === true,
      agentStatus: str(t.agent_status) || '',
      paneCount: int(t.pane_count)
    })
  }
  const paneIds = []
  for (const p of snap.panes || []) {
    const id = str(p && p.pane_id)
    if (!id) continue
    paneIds.push(id)
    const a = agents.get(id) || {}
    const session = p.agent_session || a.agent_session
    entities.set(`pane:${serverId}:${id}`, {
      kind: 'pane',
      server: serverId,
      id,
      workspaceId: str(p.workspace_id) || '',
      tabId: str(p.tab_id) || '',
      focused: p.focused === true,
      title: str(a.terminal_title_stripped) || str(p.terminal_title_stripped) || '',
      cwd: str(p.foreground_cwd) || str(p.cwd) || '',
      agent: str(p.agent) || str(a.agent),
      agentStatus: str(p.agent_status) || str(a.agent_status) || '',
      name: str(a.name) || str(p.name),
      sessionId: session && typeof session === 'object' ? str(session.value) : null,
      seq: int(a.state_change_seq)
    })
  }
  return { entities, paneIds }
}

class HerdrWatch {
  // server: { id, socket, session, isDefault }; store: LiveStore.
  constructor (server, store, { request = api.request, subscribeFn = subscribe } = {}) {
    this.server = server
    this.store = store
    this.request = request
    this.subscribe = subscribeFn
    this.a = null
    this.c = null
    this.cPanes = ''
    this.paneIds = []
    this.stopped = true
    this.failures = 0
    this.timers = { snapshot: null, safety: null, retry: null }
    this.snapshotting = null
    this.again = false
    this.info = { version: null, protocol: null }
    this.mode = 'events'
  }

  get key () { return `srv:${this.server.id}` }

  setServerState (state, error = null) {
    this.store.set(this.key, {
      kind: 'server',
      id: this.server.id,
      type: 'herdr',
      default: !!this.server.isDefault,
      session: this.server.session || '',
      state,
      mode: this.mode,
      version: this.info.version,
      protocol: this.info.protocol,
      error
    })
  }

  start () {
    if (!this.stopped) return
    this.stopped = false
    this.connect()
  }

  async connect () {
    if (this.stopped) return
    let pong
    try {
      pong = await this.request(this.server.socket, 'ping', {}, { timeoutMs: 2000 })
    } catch (err) {
      return this.down(err, err.code === 'ENOENT' ? 'none' : 'down')
    }
    this.info = { version: str(pong && pong.version), protocol: Number.isInteger(pong && pong.protocol) ? pong.protocol : null }
    if (this.info.protocol !== null && this.info.protocol < MIN_PROTOCOL) this.mode = 'snapshot'
    if (this.mode === 'events') {
      try {
        this.a = await this.subscribe(this.server.socket, LIFECYCLE.map(type => ({ type })), {
          onEvent: msg => this.onEvent(msg),
          onClose: () => this.lost('lifecycle subscription closed')
        })
      } catch (err) {
        if (api.unknownMethod(err) || err.code === 'unsupported') {
          // No events here: fall back to reading the snapshot on a timer.
          this.mode = 'snapshot'
        } else {
          return this.down(err, 'down')
        }
      }
    }
    this.failures = 0
    await this.snapshot()
    this.armSafety()
  }

  onEvent (msg) {
    if (this.stopped) return
    const name = String(msg.event)
    if (PANE_SET_EVENTS.has(name)) this.paneSetDirty = true
    this.scheduleSnapshot()
  }

  scheduleSnapshot (ms = SNAPSHOT_DEBOUNCE_MS) {
    if (this.stopped || this.timers.snapshot) return
    this.timers.snapshot = setTimeout(() => { this.timers.snapshot = null; this.snapshot() }, ms)
  }

  armSafety () {
    clearTimeout(this.timers.safety)
    if (this.stopped) return
    const ms = this.mode === 'snapshot' ? SNAPSHOT_MODE_MS : SAFETY_SNAPSHOT_MS
    this.timers.safety = setTimeout(async () => {
      this.timers.safety = null
      await this.snapshot()
      this.armSafety()
    }, ms)
  }

  // Reads the snapshot and installs it; one at a time, another after it
  // when asked meanwhile.
  async snapshot () {
    if (this.stopped) return
    if (this.snapshotting) { this.again = true; return this.snapshotting }
    this.snapshotting = (async () => {
      let rounds = 0
      do {
        this.again = false
        rounds += 1
        let snap
        try {
          snap = api.snapshotOf(await this.request(this.server.socket, 'session.snapshot', {}, { timeoutMs: 5000 }))
        } catch (err) {
          if (!this.stopped) this.down(err, err.code === 'ENOENT' ? 'none' : 'down')
          return
        }
        if (this.stopped) return
        if (!snap) { log('herdr-live', `${this.server.id}: unexpected snapshot shape`); return }
        const { entities, paneIds } = entitiesFrom(this.server.id, snap)
        this.store.replaceServer(this.server.id, entities)
        this.setServerState('up')
        this.paneIds = paneIds
        if (this.mode === 'events') await this.renewStatusSubscription()
        // Panes closing faster than we subscribe: the next event or the
        // safety net tries again.
      } while (this.again && !this.stopped && rounds < 5)
    })()
    try { await this.snapshotting } finally { this.snapshotting = null }
  }

  // C for exactly the current panes. A pane that closed since the snapshot
  // fails the whole subscribe: re-snapshot (which renews C again).
  async renewStatusSubscription () {
    const wanted = [...this.paneIds].sort().join(',')
    if (this.c && !this.c.closed && wanted === this.cPanes) return
    if (!this.paneIds.length) {
      if (this.c) this.c.close()
      this.c = null
      this.cPanes = ''
      return
    }
    let next
    try {
      next = await this.subscribe(this.server.socket, this.paneIds.map(id => ({ type: 'pane.agent_status_changed', pane_id: id })), {
        onEvent: msg => this.onEvent(msg),
        onClose: () => { if (this.c === next) this.lost('status subscription closed') }
      })
    } catch (err) {
      if (err.code === 'pane_not_found') { this.again = true; return }
      return this.down(err, 'down')
    }
    if (this.stopped) { next.close(); return }
    const old = this.c
    this.c = next
    this.cPanes = wanted
    if (old) old.close()
  }

  lost (why) {
    if (this.stopped) return
    log('herdr-live', `${this.server.id}: ${why}`)
    this.down(Object.assign(new Error(why), { code: 'closed' }), 'down')
  }

  // Marks the server down (keeping its last entities) and retries with a
  // backoff; the safety net stops meanwhile.
  down (err, state) {
    this.closeConnections()
    clearTimeout(this.timers.safety)
    this.timers.safety = null
    if (this.stopped) return
    // A server that never ran: nothing to show. One that went away: its
    // workspaces go too (Herdr's own client dims them; the phone shows the
    // "not running" state instead).
    this.store.replaceServer(this.server.id, new Map())
    const why = state === 'none'
      ? (herdrInstalled() ? null : 'herdr is not installed')
      : String((err && (err.message || err.code)) || '').slice(0, 200) || null
    this.setServerState(state, why)
    const ms = BACKOFF_MS[Math.min(this.failures, BACKOFF_MS.length - 1)]
    this.failures += 1
    clearTimeout(this.timers.retry)
    this.timers.retry = setTimeout(() => { this.timers.retry = null; this.connect() }, ms)
  }

  closeConnections () {
    for (const k of ['a', 'c']) {
      if (this[k]) { this[k].close(); this[k] = null }
    }
    this.cPanes = ''
  }

  stop ({ forget = true } = {}) {
    this.stopped = true
    for (const t of Object.values(this.timers)) clearTimeout(t)
    this.timers = { snapshot: null, safety: null, retry: null }
    this.closeConnections()
    if (forget) {
      this.store.replaceServer(this.server.id, new Map())
      this.store.remove(this.key)
    }
  }
}

module.exports = { HerdrWatch, entitiesFrom, subscribe, LIFECYCLE }
