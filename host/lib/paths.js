'use strict'

// Where the companion keeps its socket, snapshot, spool, lock and log.
//
// Overrides (mainly for tests):
//   CONDUCTORE_HOME    state dir (default ~/.conductore)
//   CONDUCTORE_SOCKET  socket path (default $XDG_RUNTIME_DIR/conductore/hostd.sock,
//                      else <state dir>/hostd.sock; always <state dir>/hostd.sock
//                      when CONDUCTORE_HOME is set)
//
// The sh clients (bin/conductore-hook, bin/conductore-statusline) hard-code
// the same layout under the state dir: spool/, tmp/, usage/, hostd.pid,
// spawn.at and node. Keep them in sync.

const fs = require('fs')
const os = require('os')
const path = require('path')

const PROTOCOL_VERSION = 1
const VERSION = '0.7.0'

// V8 flags the daemon runs with (measured in README "Footprint"). It holds a
// few hundred KB of state: small heap limits keep V8 from growing, lite mode
// (no optimizing compiler; CPU per event stays far below a millisecond)
// touches ~6 MB less of the node binary, one V8 worker thread instead of 4.
// --no-expose-wasm only silences lite mode's startup warning.
const DAEMON_NODE_FLAGS = ['--max-old-space-size=16', '--max-semi-space-size=1', '--lite-mode', '--no-expose-wasm', '--v8-pool-size=1']

function homeDir () {
  return process.env.CONDUCTORE_HOME || path.join(os.homedir(), '.conductore')
}

function runtimeDir () {
  if (process.env.CONDUCTORE_SOCKET) return path.dirname(process.env.CONDUCTORE_SOCKET)
  // A custom state dir (tests, a second instance) keeps its socket with it,
  // never the default instance's one.
  if (process.env.CONDUCTORE_HOME) return homeDir()
  const xdg = process.env.XDG_RUNTIME_DIR
  if (xdg && isOwnedDir(xdg)) return path.join(xdg, 'conductore')
  return homeDir()
}

function socketPath () {
  return process.env.CONDUCTORE_SOCKET || path.join(runtimeDir(), 'hostd.sock')
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
  usageCachePath: () => path.join(homeDir(), 'usage-cache.json')
}
