'use strict'

// The live bridge: the machine's Herdr servers and its tmux server as a
// flat map of entities (docs/herdr-live.md), kept current by pushed events
// (herdr-live.js, tmux-live.js) and handed to the daemon as change records
// for the phone's `events` long-poll.
//
// It only runs while a phone asks for it: a status or events request with
// --live, --herdr-agents or --only live starts it. --live (a screen showing
// the machine's live state) keeps all of it for IDLE_STOP_MS after the last
// ask; --herdr-agents alone (the agent monitor's polls, also in the
// background) keeps only the Herdr watches, never the tmux control client,
// and only for AGENTS_STOP_MS. An events long-poll counts as asking until
// it ends. A machine nobody looks at holds no subscription and no control
// client.
//
// It also derives the agents only Herdr knows (any of its agent kinds in a
// pane that no Conductore adapter reports), with a grace period for new
// ones and a hysteresis on short turns, so a Claude session whose hooks
// report it never shows (or notifies) twice.

const { HerdrWatch } = require('./herdr-live')
const { TmuxWatch } = require('./tmux-live')
const herdrApi = require('./herdr-api')
const { log } = require('./log')

const IDLE_STOP_MS = 15 * 60 * 1000
// Long: Android defers a backgrounded app's network work (Doze, app
// standby), and a bridge that stops between two polls makes Herdr-only
// agents vanish and come back (notification churn).
const AGENTS_STOP_MS = 10 * 60 * 1000
const NEW_AGENT_GRACE_MS = 5000
const WORKING_HYSTERESIS_MS = 5000
const DISCOVER_EVERY_MS = 60 * 1000
// Only these fields changing makes a change lazy (see LiveStore.set).
const LAZY_FIELDS = ['activity']

function withoutLazy (entity) {
  if (!entity) return entity
  const copy = { ...entity }
  for (const f of LAZY_FIELDS) delete copy[f]
  return JSON.stringify(copy)
}

// Entities by key. Every change calls onChange({ key, entity, lazy }).
class LiveStore {
  constructor (onChange = () => {}) {
    this.entities = new Map() // key -> { json, entity }
    this.onChange = onChange
  }

  get (key) {
    const e = this.entities.get(key)
    return e ? e.entity : null
  }

  set (key, entity) {
    const json = JSON.stringify(entity)
    const old = this.entities.get(key)
    if (old && old.json === json) return false
    const lazy = !!old && withoutLazy(old.entity) === withoutLazy(entity)
    this.entities.set(key, { json, entity })
    this.onChange({ key, entity, lazy })
    return true
  }

  remove (key) {
    if (!this.entities.has(key)) return false
    this.entities.delete(key)
    this.onChange({ key, entity: null, lazy: false })
    return true
  }

  // Replaces every entity of `server` (its server record aside) with `next`
  // (Map key -> entity): only the differences are reported.
  replaceServer (server, next) {
    for (const [key, e] of [...this.entities]) {
      if (key.startsWith('srv:')) continue
      if (e.entity.server === server && !next.has(key)) this.remove(key)
    }
    for (const [key, entity] of next) this.set(key, entity)
  }

  all () {
    const out = {}
    for (const [key, e] of this.entities) out[key] = e.entity
    return out
  }

  byKind (kind) {
    return [...this.entities.values()].map(e => e.entity).filter(e => e.kind === kind)
  }
}

// Herdr's agent_status -> the Herdr-only agent's state.
const STATES = new Set(['working', 'blocked', 'idle', 'done', 'unknown'])

class LiveBridge {
  // onChange(record): record = { key, entity, lazy } for live entities, or
  // { agent: sessionId, record: agent|null } for Herdr-only agents.
  // companionAgents(): the daemon's agents (for matching). extraSockets():
  // Herdr sockets hooks reported.
  // tmuxEnabled(): the `tmux-live` setting (off by default: the control
  // client shows in the user's tmux, see docs/herdr-live.md).
  // held(): { live, agents }, what the open long-polls ask for: wanted for
  // as long as they wait.
  constructor ({ onChange, companionAgents = () => [], extraSockets = () => [], now = Date.now, makeHerdr, makeTmux, tmuxEnabled = () => false, held = () => ({}) } = {}) {
    this.tmuxEnabled = tmuxEnabled
    this.held = held
    this.onChangeCb = onChange || (() => {})
    this.companionAgents = companionAgents
    this.extraSockets = extraSockets
    this.now = now
    this.makeHerdr = makeHerdr || ((server, store) => new HerdrWatch(server, store))
    this.makeTmux = makeTmux || (store => new TmuxWatch(store))
    this.store = new LiveStore(ch => this.onStoreChange(ch))
    this.running = false
    this.herdr = new Map() // server id -> HerdrWatch
    this.tmux = null
    this.lastWanted = 0
    this.liveUntil = 0 // --live wants everything until then
    this.agentsUntil = 0 // --herdr-agents wants the Herdr watches until then
    this.stopTimer = null
    this.discoverTimer = null
    // Herdr-only agents.
    this.agentSeen = new Map() // sessionId -> { firstSeen, workingSince }
    this.published = new Map() // sessionId -> { json, record }
    this.agentTimer = null
    this.agentsDirty = false
  }

  // A phone asked: start (or keep running). kind 'live' keeps everything
  // for IDLE_STOP_MS more, 'agents' (herdr-agents only) the Herdr watches
  // for AGENTS_STOP_MS more.
  touch (kind = 'live') {
    const now = this.now()
    this.lastWanted = now
    if (kind === 'agents') this.agentsUntil = Math.max(this.agentsUntil, now + AGENTS_STOP_MS)
    else this.liveUntil = Math.max(this.liveUntil, now + IDLE_STOP_MS)
    if (!this.running) this.start()
    else this.syncTmux()
    this.armStop()
  }

  // Whether a --live ask is current (tmux and the full entity set).
  liveWanted () {
    return this.now() < this.liveUntil
  }

  armStop () {
    clearTimeout(this.stopTimer)
    this.stopTimer = null
    if (!this.running) return
    const now = this.now()
    const live = this.liveUntil - now
    const until = Math.max(this.liveUntil, this.agentsUntil) - now
    // Wake when --live lapses (tmux goes) and when nothing is wanted.
    const next = live > 0 && live < until ? live : until
    this.stopTimer = setTimeout(() => this.checkWanted(), Math.max(0, next) + 5)
    if (this.stopTimer.unref) this.stopTimer.unref()
  }

  // Stops what nobody wants any more.
  checkWanted () {
    if (!this.running) return
    const held = this.held() || {}
    if (held.live) this.touch('live')
    if (held.agents) this.touch('agents')
    const now = this.now()
    if (now >= this.liveUntil && now >= this.agentsUntil) return this.stop()
    this.syncTmux()
    this.armStop()
  }

  start () {
    this.running = true
    log('live', 'bridge started')
    this.discover()
    this.syncTmux()
  }

  // Runs the tmux control client only while `tmux-live` is on; off, the
  // server entity says so (`state: "off"`) and the phone polls tmux.
  syncTmux () {
    if (!this.running) return
    if (this.tmuxEnabled() && this.liveWanted()) {
      if (!this.tmux) {
        this.store.remove('srv:tmux')
        this.tmux = this.makeTmux(this.store)
        this.tmux.start()
      }
      return
    }
    if (this.tmux) { this.tmux.stop(); this.tmux = null }
    this.store.set('srv:tmux', { kind: 'server', id: 'tmux', type: 'tmux', default: true, session: '', state: 'off', mode: 'poll', version: null, protocol: null, error: null })
  }

  // Resolves once every watched server reported its state (up, down or
  // none), or after `ms`: a first `status --live` then carries entities.
  ready (ms = 1000) {
    const done = () => [...this.herdr.values()].every(w => this.store.get(`srv:${w.server.id}`)) && (!this.tmux || this.store.get('srv:tmux'))
    return new Promise(resolve => {
      const started = Date.now()
      const check = () => {
        if (!this.running || done() || Date.now() - started >= ms) return resolve()
        setTimeout(check, 20)
      }
      check()
    })
  }

  // Watches every Herdr server that exists now; again every minute (a named
  // session started meanwhile) while running.
  discover () {
    if (!this.running) return
    const servers = herdrApi.discover(this.extraSockets())
    const ids = new Set(servers.map(s => s.id))
    for (const server of servers) {
      if (this.herdr.has(server.id)) continue
      const watch = this.makeHerdr(server, this.store)
      this.herdr.set(server.id, watch)
      watch.start()
    }
    for (const [id, watch] of this.herdr) {
      if (!ids.has(id)) { watch.stop(); this.herdr.delete(id) }
    }
    clearTimeout(this.discoverTimer)
    this.discoverTimer = setTimeout(() => this.discover(), DISCOVER_EVERY_MS)
    if (this.discoverTimer.unref) this.discoverTimer.unref()
  }

  stop () {
    if (!this.running) return
    this.running = false
    log('live', 'bridge stopped (no phone asked for it)')
    this.liveUntil = this.agentsUntil = 0
    clearTimeout(this.stopTimer)
    clearTimeout(this.discoverTimer)
    clearTimeout(this.agentTimer)
    this.stopTimer = this.discoverTimer = this.agentTimer = null
    for (const watch of this.herdr.values()) watch.stop()
    this.herdr.clear()
    if (this.tmux) { this.tmux.stop(); this.tmux = null }
    for (const key of Object.keys(this.store.all())) this.store.remove(key)
    this.recomputeAgents()
  }

  onStoreChange (ch) {
    this.onChangeCb(ch)
    if (ch.key.startsWith('pane:') || ch.key.startsWith('ws:') || ch.key.startsWith('tab:') || ch.key.startsWith('srv:herdr')) this.scheduleAgents()
  }

  // The daemon's agents changed (a Claude session appeared or ended).
  companionChanged () {
    if (this.published.size || this.agentSeen.size || this.running) this.scheduleAgents()
  }

  scheduleAgents () {
    if (this.agentsDirty) return
    this.agentsDirty = true
    setImmediate(() => { this.agentsDirty = false; this.recomputeAgents() })
  }

  // Herdr-only agents now: published after NEW_AGENT_GRACE_MS, and a turn
  // shows as working only once it lasted WORKING_HYSTERESIS_MS.
  recomputeAgents () {
    const now = this.now()
    const companion = this.companionAgents().filter(a => a && a.state !== 'ended')
    const claimedSessions = new Set(companion.map(a => a.sessionId))
    const claimedPanes = new Set(companion.filter(a => a.herdr && a.herdr.paneId).map(a => `${herdrApi.idForSocket(a.herdr.socket || null)}/${a.herdr.paneId}`))
    const wanted = new Map()
    let nextDue = Infinity
    const labels = new Map()
    for (const e of this.store.byKind('workspace')) labels.set(`${e.server}/${e.id}`, e.label)
    for (const pane of this.store.byKind('pane')) {
      if (!pane.agent) continue
      const target = `${pane.server}/${pane.id}`
      if (claimedPanes.has(target) || (pane.sessionId && claimedSessions.has(pane.sessionId))) continue
      let seen = this.agentSeen.get(target)
      if (!seen) { seen = { firstSeen: now, workingSince: null }; this.agentSeen.set(target, seen) }
      const herdrState = STATES.has(pane.agentStatus) ? pane.agentStatus : 'unknown'
      if (now - seen.firstSeen < NEW_AGENT_GRACE_MS) { nextDue = Math.min(nextDue, seen.firstSeen + NEW_AGENT_GRACE_MS); continue }
      const before = this.published.get(target)
      const prevState = before ? before.record.state : null
      let state = herdrState
      if (herdrState === 'working') {
        if (seen.workingSince === null) seen.workingSince = now
        if (prevState !== 'working' && now - seen.workingSince < WORKING_HYSTERESIS_MS) {
          state = prevState || 'idle'
          nextDue = Math.min(nextDue, seen.workingSince + WORKING_HYSTERESIS_MS)
        }
      } else {
        seen.workingSince = null
        // A short turn never showed as working: it ends where it began
        // (idle), not as a finished turn to notify.
        if (prevState === 'idle' && herdrState === 'done') state = 'idle'
      }
      const server = this.herdr.get(pane.server)
      const label = labels.get(`${pane.server}/${pane.workspaceId}`) || null
      const record = {
        sessionId: target,
        source: 'herdr',
        kind: pane.agent,
        // Like the companion's own agents (CON-116): the pane's live name,
        // else its workspace; the terminal title is the per-agent line.
        name: pane.name || label || pane.title || null,
        title: pane.title || null,
        cwd: pane.cwd || null,
        project: label,
        herdr: { server: pane.server, workspaceId: pane.workspaceId, tabId: pane.tabId, paneId: pane.id, name: pane.name || null, workspaceLabel: label, socket: server ? server.server.socket : null },
        state,
        stateSeq: pane.seq,
        pending: [],
        startedAt: seen.firstSeen,
        updatedAt: before && before.record.state === state ? before.record.updatedAt : now
      }
      wanted.set(target, record)
    }
    for (const target of [...this.agentSeen.keys()]) {
      const pane = this.store.get(`pane:${target.slice(0, target.indexOf('/'))}:${target.slice(target.indexOf('/') + 1)}`)
      if (!pane || !pane.agent) this.agentSeen.delete(target)
    }
    for (const [target, record] of wanted) {
      const json = JSON.stringify({ ...record, updatedAt: 0 })
      const before = this.published.get(target)
      if (before && before.json === json) continue
      this.published.set(target, { json, record })
      this.onChangeCb({ agent: target, record })
    }
    for (const target of [...this.published.keys()]) {
      if (wanted.has(target)) continue
      this.published.delete(target)
      this.onChangeCb({ agent: target, record: null })
    }
    clearTimeout(this.agentTimer)
    this.agentTimer = null
    if (nextDue !== Infinity) {
      this.agentTimer = setTimeout(() => { this.agentTimer = null; this.recomputeAgents() }, Math.max(50, nextDue - now + 10))
      if (this.agentTimer.unref) this.agentTimer.unref()
    }
  }

  herdrAgents () {
    return [...this.published.values()].map(p => p.record)
  }

  entities () {
    return this.store.all()
  }
}

module.exports = { LiveStore, LiveBridge, IDLE_STOP_MS, AGENTS_STOP_MS, NEW_AGENT_GRACE_MS, WORKING_HYSTERESIS_MS }
