'use strict'

// The agent adapter registry (CON-045). Everything that differs between
// coding agents (Claude Code, Codex, OpenCode, ...) lives in one adapter
// module per agent in this directory; the daemon, the CLI and the brain
// commands only talk to the registry. See adapters/README.md for the
// interface and how to add an agent, and types.js for the shapes.
//
// Adapters load on first use: the daemon only ever requires the ones whose
// events it sees (an idle daemon with only Claude Code sessions never loads
// another). Adding an agent = one module here plus one line in MODULES.

// Order matters where the registry picks "the first" adapter (the brain
// runner, `install`): Claude Code first, as before adapters existed.
const MODULES = {
  claude: './claude',
  codex: './codex'
}

// Events and records with no agent id are Claude Code's: hooks registered
// before adapters existed write no `agent=` header line, and agent records
// in an older state.json carry no `kind`.
const DEFAULT_KIND = 'claude'

const ID = /^[a-z][a-z0-9-]{0,31}$/

const loaded = new Map()

// The adapter with this id, or null when there is none.
function get (id) {
  const key = id === undefined || id === null || id === '' ? DEFAULT_KIND : String(id)
  if (loaded.has(key)) return loaded.get(key)
  if (!ID.test(key) || !Object.prototype.hasOwnProperty.call(MODULES, key)) return null
  const adapter = require(MODULES[key])
  loaded.set(key, adapter)
  return adapter
}

// Every registered adapter (loads them all: for `version`, `status`,
// `install`, `doctor`, never per event).
function all () {
  return Object.keys(MODULES).map(get).filter(Boolean)
}

function ids () {
  return Object.keys(MODULES)
}

// The adapter that owns a spool entry: its `agent=` header line, Claude
// Code when there is none. Null for an agent this companion does not know
// (a newer hook, a typo): the daemon drops the event.
function forHeader (header) {
  return get(header && header.agent)
}

// The adapter of an event normalize() returned, or of an agent record.
function of (eventOrAgent) {
  if (!eventOrAgent) return get(DEFAULT_KIND)
  return get(eventOrAgent.agent_kind || eventOrAgent.kind) || get(DEFAULT_KIND)
}

// Per agent kind, what it supports, for the phone to gate its UI on
// (`status` and `version` report it as `adapters`). Static: no detection,
// so it costs nothing per poll. Names and values only ever get added.
function capabilityMap () {
  const out = {}
  for (const a of all()) out[a.id] = { label: a.label, ...a.capabilities() }
  return out
}

// The brain runner: the first adapter (or `preferred`) with a brain that
// is installed here. Resolves { adapter, runner } or null when none is.
function brain (env = process.env, preferred = null) {
  const order = preferred ? [preferred, ...ids().filter(id => id !== preferred)] : ids()
  for (const id of order) {
    const adapter = get(id)
    if (!adapter || !adapter.brain) continue
    const runner = adapter.brain.locate(env)
    if (runner) return { adapter, runner }
  }
  return null
}

// Tests only: a fake adapter under an id (removed with unregister).
function register (adapter, modulePath = null) {
  if (!adapter || !ID.test(adapter.id)) throw new Error('adapter needs an id')
  loaded.set(adapter.id, adapter)
  MODULES[adapter.id] = modulePath || MODULES[adapter.id] || null
}

function unregister (id) {
  loaded.delete(id)
  if (id !== DEFAULT_KIND) delete MODULES[id]
}

module.exports = { DEFAULT_KIND, get, all, ids, forHeader, of, capabilityMap, brain, register, unregister }
