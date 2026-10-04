'use strict'

// Temp dirs and daemons of one test file. Every dir made with tempDir() is
// removed, and every daemon living in one is stopped, by cleanup(), which
// each file runs from test.after: after hooks run even when a test fails.
//
// A daemon is found two ways: the pid in a hostd.pid under one of the dirs,
// and a /proc scan for conductore-hostd processes whose environment points
// into one (CONDUCTORE_HOME, CONDUCTORE_SOCKET or HOME), which also finds a
// daemon that lost its lock file. cleanup() fails the run when one survives
// SIGKILL, and reports (by failing) daemons the tests left running.

const fs = require('fs')
const os = require('os')
const path = require('path')
const proc = require('../../lib/proc')

const dirs = []

function tempDir (prefix) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), prefix))
  dirs.push(dir)
  return dir
}

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms))

const inside = (value, roots) => !!value && roots.some(root => value === root || value.startsWith(root + path.sep))

// hostd.pid files under dir, a few levels deep.
function lockPids (dir, depth = 3) {
  const pids = []
  let entries
  try { entries = fs.readdirSync(dir, { withFileTypes: true }) } catch { return pids }
  for (const e of entries) {
    const p = path.join(dir, e.name)
    if (e.isFile() && e.name === 'hostd.pid') {
      const pid = parseInt(fs.readFileSync(p, 'utf8'), 10)
      if (Number.isInteger(pid)) pids.push(pid)
    } else if (e.isDirectory() && !e.isSymbolicLink() && depth > 0) {
      pids.push(...lockPids(p, depth - 1))
    }
  }
  return pids
}

// Live conductore-hostd processes whose environment points into roots.
function scanProc (roots) {
  if (!proc.hasProc()) return []
  const found = []
  for (const name of fs.readdirSync('/proc')) {
    const pid = Number(name)
    if (!Number.isInteger(pid) || pid === process.pid) continue
    if (!proc.commandLine(pid).includes(proc.DAEMON_TITLE)) continue
    let environ
    try { environ = fs.readFileSync(`/proc/${pid}/environ`, 'utf8').split('\0') } catch { continue }
    const vars = Object.fromEntries(environ.map(kv => [kv.slice(0, kv.indexOf('=')), kv.slice(kv.indexOf('=') + 1)]))
    if (['CONDUCTORE_HOME', 'CONDUCTORE_SOCKET', 'HOME'].some(k => inside(vars[k], roots))) found.push(pid)
  }
  return found
}

// The daemons (and CLI runs, which carry the same title) living in roots.
function daemonsIn (roots) {
  const pids = new Set(scanProc(roots))
  for (const root of roots) for (const pid of lockPids(root)) if (proc.isDaemon(pid)) pids.add(pid)
  pids.delete(process.pid)
  return [...pids]
}

async function waitGone (pids, ms) {
  for (let t = 0; t < ms; t += 50) {
    if (!pids.some(proc.pidAlive)) return []
    await sleep(50)
  }
  return pids.filter(proc.pidAlive)
}

// Stops the daemons in roots (SIGTERM, then SIGKILL) and waits for them.
// Resolves the pids that were running; throws if one is still alive.
async function stopDaemons (roots) {
  const pids = daemonsIn(roots)
  if (!pids.length) return []
  for (const pid of pids) try { process.kill(pid, 'SIGTERM') } catch {}
  let alive = await waitGone(pids, 3000)
  for (const pid of alive) try { process.kill(pid, 'SIGKILL') } catch {}
  alive = await waitGone(alive, 3000)
  if (alive.length) throw new Error(`test daemons still running after SIGKILL: ${alive.join(', ')}`)
  return pids
}

// Stops every daemon in this file's temp dirs, then removes the dirs. Run
// it last in test.after, after the file's own `stop`. A daemon still
// running 2 s later (a `stop` returns before the daemon is gone) was left
// behind by the tests: it is stopped and, unless strict is false, the run
// fails, because a leak is a bug.
async function cleanup ({ strict = true } = {}) {
  const roots = dirs.splice(0)
  let leaked = []
  try {
    const left = await waitGone(daemonsIn(roots), 2000)
    leaked = left.length ? await stopDaemons(roots) : []
  } finally {
    for (const dir of roots) fs.rmSync(dir, { recursive: true, force: true })
  }
  if (strict && leaked.length) {
    throw new Error(`the tests left ${leaked.length} daemon(s) running in their temp dirs (pids ${leaked.join(', ')}); they were stopped`)
  }
}

// The user's real agent configs, which no test may write: install and
// uninstall run every present adapter. Only what an install could change
// is watched, by content: the hook (and statusline) entries of the agents'
// settings, the hook files, the OpenCode plugins, sheprd's view state
// (which `sheprd-view-update` appends to). Never mtimes, and never
// ~/.claude.json: the agents themselves rewrite their files all the time.
// Returns a check that fails when any of them changed.
const REAL_CONFIGS = [
  ['.claude/settings.json', ['hooks', 'statusLine']],
  ['.codex/hooks.json'],
  ['.gemini/settings.json', ['hooks', 'hooksConfig']],
  ['.cursor/hooks.json'],
  ['.config/opencode/plugins'],
  ['.local/state/sheprd']
]

const sha = text => require('crypto').createHash('sha256').update(text).digest('hex').slice(0, 16)

// One entry's fingerprint: '-' when absent; the listed keys of a JSON file
// (the whole file when it does not parse); a directory's files and their
// contents.
function fingerprint (file, keys) {
  let st
  try { st = fs.statSync(file) } catch { return '-' }
  if (st.isDirectory()) {
    let names = []
    try { names = fs.readdirSync(file).sort() } catch { return 'd?' }
    return names.map(n => `${n}=${fingerprint(path.join(file, n))}`).join(',')
  }
  let text
  try { text = fs.readFileSync(file, 'utf8') } catch { return '?' }
  if (keys) {
    try {
      const doc = JSON.parse(text)
      return sha(JSON.stringify(keys.map(k => (doc && typeof doc === 'object' ? doc[k] : undefined) ?? null)))
    } catch {}
  }
  return sha(text)
}

function guardRealConfigs (home = os.homedir()) {
  const snap = () => REAL_CONFIGS.map(([rel, keys]) => `${rel}:${fingerprint(path.join(home, rel), keys)}`).join('\n')
  const before = snap()
  return () => {
    const after = snap()
    if (after !== before) throw new Error(`a test touched the real agent config under ${home}:\n${before}\n---\n${after}`)
  }
}

module.exports = { tempDir, cleanup, stopDaemons, daemonsIn, guardRealConfigs, fingerprint }
