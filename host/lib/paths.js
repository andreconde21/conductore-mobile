'use strict'

// Where the companion keeps its socket, snapshot, spool, lock and log.
//
// Overrides (mainly for tests):
//   CONDUCTORE_HOME    state dir (default ~/.conductore)
//   CONDUCTORE_SOCKET  socket path (default <state dir>/hostd.sock)
//
// The sh clients (bin/conductore-hook, bin/conductore-statusline) hard-code
// the same layout under the state dir: spool/, tmp/, usage/, hostd.pid,
// spawn.at and node. Keep them in sync.

const fs = require('fs')
const os = require('os')
const path = require('path')

const PROTOCOL_VERSION = 1
const VERSION = '0.9.0'

// V8 flags the daemon runs with (measured in README "Footprint"). It holds a
// few hundred KB of state, but a burst of changes while long permission
// prompts wait peaks at several MB: the old-space limit is only a ceiling
// (16 MB aborted there), idle RSS does not depend on it. The small semi
// space keeps V8 from growing, lite mode
// (no optimizing compiler; CPU per event stays far below a millisecond)
// touches ~6 MB less of the node binary, one V8 worker thread instead of 4.
// --no-expose-wasm only silences lite mode's startup warning.
const DAEMON_NODE_FLAGS = ['--max-old-space-size=64', '--max-semi-space-size=1', '--lite-mode', '--no-expose-wasm', '--v8-pool-size=1']

function homeDir () {
  return process.env.CONDUCTORE_HOME || path.join(os.homedir(), '.conductore')
}

// The socket sits beside the lock, whatever the environment of whoever
// started the daemon: a tmux server started from cron or su has no
// XDG_RUNTIME_DIR while the phone's SSH shell has one, and both must agree.
function socketPath () {
  return process.env.CONDUCTORE_SOCKET || path.join(homeDir(), 'hostd.sock')
}

function runtimeDir () {
  return path.dirname(socketPath())
}

// Where daemons up to 0.7 listened when their starter had XDG_RUNTIME_DIR.
// Clients fall back to these, so a daemon still running from before an
// upgrade stays reachable (and stoppable) until it exits.
function legacySocketPaths () {
  if (process.env.CONDUCTORE_SOCKET || process.env.CONDUCTORE_HOME) return []
  const xdg = process.env.XDG_RUNTIME_DIR
  return xdg && isOwnedDir(xdg) ? [path.join(xdg, 'conductore', 'hostd.sock')] : []
}

function isOwnedDir (p) {
  try {
    const st = fs.statSync(p)
    return st.isDirectory() && (process.getuid === undefined || st.uid === process.getuid())
  } catch {
    return false
  }
}

function ensureDir (p) {
  fs.mkdirSync(p, { recursive: true, mode: 0o700 })
  try { fs.chmodSync(p, 0o700) } catch {}
  return p
}

let ensured = null
function ensureDirs () {
  const key = `${homeDir()}\0${runtimeDir()}`
  if (ensured === key) return
  const home = ensureDir(homeDir())
  ensureDir(runtimeDir())
  for (const sub of ['spool', 'tmp', 'usage']) ensureDir(path.join(home, sub))
  ensured = key
}

// Seconds of inactivity before the daemon exits (0 = never).
function idleExitMs () {
  const v = Number(process.env.CONDUCTORE_IDLE_EXIT_S)
  return (Number.isFinite(v) && v >= 0 ? v : 6 * 60 * 60) * 1000
}

module.exports = {
  PROTOCOL_VERSION,
  VERSION,
  DAEMON_NODE_FLAGS,
  homeDir,
  runtimeDir,
  socketPath,
  legacySocketPaths,
  ensureDirs,
  ensureDir,
  idleExitMs,
  statePath: () => path.join(homeDir(), 'state.json'),
  // Exclusive lock + pid of the running daemon; the sh clients read it.
  lockPath: () => path.join(homeDir(), 'hostd.pid'),
  logPath: () => path.join(homeDir(), 'hostd.log'),
  rulesPath: () => path.join(homeDir(), 'always-rules.json'),
  spoolDir: () => path.join(homeDir(), 'spool'),
  tmpDir: () => path.join(homeDir(), 'tmp'),
  usageDir: () => path.join(homeDir(), 'usage'),
  spawnStampPath: () => path.join(homeDir(), 'spawn.at'),
  nodePathFile: () => path.join(homeDir(), 'node'),
  // `ports`: listening ports with the seq each first appeared at.
  portsPath: () => path.join(homeDir(), 'ports.json'),
  // `usage`: per-file offsets and daily token buckets of the transcripts.
  usageCachePath: () => path.join(homeDir(), 'usage-cache.json'),
  // The daemon's per-agent activity log (what `digest` counts).
  activityPath: () => path.join(homeDir(), 'activity.json'),
  // `digest --summaries`: rolling summary per agent and its token use.
  digestPath: () => path.join(homeDir(), 'digest.json'),
  // Per-turn snapshot records (`turns`, `diff`, `undo`).
  turnsPath: () => path.join(homeDir(), 'turns.json')
}
