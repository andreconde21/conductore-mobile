'use strict'

// Conductore facts in Herdr's sidebar: for every agent the companion tracks
// in a Herdr pane, `pane.report_metadata` tokens the user can put in a
// sidebar row (`$conductore_pending`, ...):
//   conductore_pending  permission requests waiting for an answer
//   conductore_cost     the session's estimated cost so far (Claude Code's
//                       statusline `cost.total_cost_usd`), e.g. "$1.20"
//   conductore_today    the machine's estimated cost today: the sessions
//                       active today, summed (a session that began
//                       yesterday counts whole: an approximation)
// At most one report per pane every THROTTLE_MS, only when a value
// changed (and again before the TTL runs out); the tokens expire with the
// TTL if the daemon goes away. A Herdr without the method is left alone.
// Off with `config set herdr-sidebar off`.
//
// Only panes the live bridge sees, holding this very session (Herdr's
// agent_session), get tokens: a pane id reused by someone else is never
// written to, and nothing is reported while no phone keeps the bridge up.

const api = require('./herdr-api')
const { log } = require('./log')

const THROTTLE_MS = 10 * 1000
const TTL_MS = 60 * 60 * 1000
const SOURCE = 'conductore'

function money (usd) {
  if (typeof usd !== 'number' || !Number.isFinite(usd)) return null
  return `$${usd.toFixed(2)}`
}

function startOfToday (now) {
  const d = new Date(now)
  d.setHours(0, 0, 0, 0)
  return d.getTime()
}

// The tokens for every Herdr pane of `agents` (the daemon's state.agents):
// Map "<socket>\0<paneId>" -> { socket, paneId, tokens }.
function tokensFor (agents, now = Date.now(), holds = () => true) {
  const list = Object.values(agents || {})
  const today = startOfToday(now)
  let total = 0
  let any = false
  for (const a of list) {
    const cost = a.usage && a.usage.costUsd
    if (typeof cost === 'number' && a.updatedAt >= today) { total += cost; any = true }
  }
  const out = new Map()
  for (const a of list) {
    if (!a.herdr || !a.herdr.paneId || a.state === 'ended' || !holds(a)) continue
    const tokens = {
      conductore_pending: String((a.pending || []).length),
      conductore_cost: money(a.usage && a.usage.costUsd),
      conductore_today: any ? money(total) : null
    }
    out.set(`${a.herdr.socket || ''}\0${a.herdr.paneId}`, { socket: a.herdr.socket || null, paneId: a.herdr.paneId, tokens })
  }
  return out
}

class Sidebar {
  // holds(agent): whether the agent's Herdr pane is known to hold it now.
  constructor ({ enabled = () => true, holds = () => false, request = api.request, now = Date.now, throttleMs = THROTTLE_MS } = {}) {
    this.enabled = enabled
    this.holds = holds
    this.request = request
    this.now = now
    this.throttleMs = throttleMs
    this.sent = new Map() // key -> { json, at }
    this.timers = new Map() // key -> timer
    this.latest = new Map() // key -> entry waiting for its slot
    this.unsupported = new Set() // sockets without the method
    this.cleared = true
  }

  // Called whenever the daemon's agents changed.
  update (agents, { force = false } = {}) {
    if (!this.enabled()) {
      if (!this.cleared) this.clearAll()
      return
    }
    this.cleared = false
    const wanted = tokensFor(agents, this.now(), this.holds)
    for (const [key, entry] of wanted) this.schedule(key, entry, force)
  }

  schedule (key, entry, force) {
    const socket = entry.socket || api.defaultServer().socket
    if (this.unsupported.has(socket)) return
    const json = JSON.stringify(entry.tokens)
    const sent = this.sent.get(key)
    const now = this.now()
    const stale = !sent || now - sent.at > TTL_MS / 2
    if (!force && sent && sent.json === json && !stale) return
    this.latest.set(key, entry)
    if (this.timers.has(key)) return
    const wait = sent ? Math.max(0, sent.at + this.throttleMs - now) : 0
    const timer = setTimeout(() => {
      this.timers.delete(key)
      const next = this.latest.get(key)
      this.latest.delete(key)
      if (next) this.send(key, next)
    }, wait)
    if (timer.unref) timer.unref()
    this.timers.set(key, timer)
  }

  async send (key, entry) {
    const socket = entry.socket || api.defaultServer().socket
    const json = JSON.stringify(entry.tokens)
    this.sent.set(key, { json, at: this.now() })
    try {
      await this.request(socket, 'pane.report_metadata', { pane_id: entry.paneId, source: SOURCE, tokens: entry.tokens, ttl_ms: TTL_MS }, { timeoutMs: 2000 })
    } catch (err) {
      if (api.unknownMethod(err)) {
        this.unsupported.add(socket)
        log('sidebar', `${socket}: no pane.report_metadata; sidebar tokens off for it`)
      } else if (err.code !== 'pane_not_found') {
        log('sidebar', `report_metadata ${entry.paneId} failed: ${err.message}`)
      }
    }
  }

  // Setting turned off: the tokens go now rather than at their TTL.
  clearAll () {
    this.cleared = true
    for (const t of this.timers.values()) clearTimeout(t)
    this.timers.clear()
    this.latest.clear()
    for (const key of this.sent.keys()) {
      const [socket, paneId] = key.split('\0')
      const tokens = { conductore_pending: null, conductore_cost: null, conductore_today: null }
      this.request(socket || api.defaultServer().socket, 'pane.report_metadata', { pane_id: paneId, source: SOURCE, tokens, ttl_ms: 1 }, { timeoutMs: 2000 }).catch(() => {})
    }
    this.sent.clear()
  }

  stop () {
    for (const t of this.timers.values()) clearTimeout(t)
    this.timers.clear()
    this.latest.clear()
  }
}

module.exports = { Sidebar, tokensFor, THROTTLE_MS, TTL_MS }
