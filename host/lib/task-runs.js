'use strict'

// Task runs (CON-037): start tasks as agents, one fresh worktree, branch,
// place and agent each, and follow them until the agent finishes.
//
//   task-start -        {repo, agent, place, tasks: [{ref, key, title,
//                       prompt}], base?, location?, attempts?, cap?,
//                       branchPrefix?, herdrServer?, workspaceId?,
//                       markDone?} on stdin: queues one run per task and
//                       attempt, then starts as many as the cap allows
//   task-runs [list]    every run, linked to its agent
//   task-runs cancel <id> | forget <id> | cap <n>
//
// A run goes queued -> starting -> running -> finished (or failed,
// cancelled). Starting it creates the worktree (worktree.js), writes the
// prompt to a 0600 file under ~/.conductore/task-runs/<id>/, and opens the
// place: a new Herdr tab (socket API tab.create, then the launch line
// typed into its shell), a new tmux window (new-window -d, send-keys), or
// none (the phone opens a terminal on the machine and runs `command`).
// The launch line is `cd <worktree> && <agent> "$(cat <prompt file>)"`, so
// the prompt never goes through the command line of another process nor
// through the pane's keystrokes.
//
// The agent is linked to its run by its working directory: the worktree is
// new, so the first agent reporting a cwd inside it is the run's. The run
// is finished when that agent ends its first turn (a Stop after it worked)
// or its session ends. The cap counts starting and running runs across
// every batch; when one finishes, the daemon starts the next queued run
// (onAgents, called on every agent change) so a batch advances without
// the phone. Nothing here ever kills an agent or removes a worktree.

const fs = require('fs')
const path = require('path')
const crypto = require('crypto')
const { execFile } = require('child_process')
const paths = require('./paths')
const { log } = require('./log')
const worktree = require('./worktree')

const PLACES = ['herdr', 'tmux', 'none']
const MAX_TASKS = 50
const MAX_PROMPT = 100000
const DEFAULT_CAP = 3
const KEEP_DONE = 200
const LOCK_STALE_MS = 30000

// How each agent kind starts interactively with a first prompt; an adapter
// may provide its own `launchArgs(prompt)` instead (lib/adapters).
const LAUNCH = {
  claude: ['claude'],
  codex: ['codex'],
  opencode: ['opencode', '--prompt'],
  gemini: ['gemini', '--prompt-interactive'],
  cursor: ['cursor-agent']
}

class RunError extends Error {
  constructor (code, message) {
    super(message)
    this.code = code
  }
}

const file = () => path.join(paths.homeDir(), 'task-runs.json')
const runDir = id => path.join(paths.homeDir(), 'task-runs', id)
const lockFile = () => path.join(paths.homeDir(), 'task-runs.lock')
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms))

function load () {
  try {
    const data = JSON.parse(fs.readFileSync(file(), 'utf8'))
    return { cap: Number.isInteger(data.cap) ? data.cap : DEFAULT_CAP, runs: Array.isArray(data.runs) ? data.runs : [] }
  } catch {
    return { cap: DEFAULT_CAP, runs: [] }
  }
}

function save (data) {
  paths.ensureDirs()
  const done = data.runs.filter(r => !isActive(r) && r.status !== 'queued')
  if (done.length > KEEP_DONE) {
    const drop = new Set(done.slice(0, done.length - KEEP_DONE).map(r => r.id))
    data.runs = data.runs.filter(r => !drop.has(r.id))
  }
  const tmp = `${file()}.${process.pid}.tmp`
  fs.writeFileSync(tmp, JSON.stringify(data, null, 2) + '\n', { mode: 0o600 })
  fs.renameSync(tmp, file())
}

// Runs fn(data) under the runs lock and saves what it returns true for.
async function locked (fn) {
  paths.ensureDirs()
  const deadline = Date.now() + 10000
  let fd = null
  while (fd === null) {
    try {
      fd = fs.openSync(lockFile(), 'wx', 0o600)
    } catch (err) {
      if (err.code !== 'EEXIST') throw err
      try {
        if (Date.now() - fs.statSync(lockFile()).mtimeMs > LOCK_STALE_MS) { fs.unlinkSync(lockFile()); continue }
      } catch {}
      if (Date.now() > deadline) throw new RunError('busy', 'task runs are locked by another process')
      await sleep(50)
    }
  }
  try {
    const data = load()
    const result = await fn(data)
    if (result !== false) save(data)
    return data
  } finally {
    fs.closeSync(fd)
    try { fs.unlinkSync(lockFile()) } catch {}
  }
}

const isActive = r => r.status === 'starting' || r.status === 'running'

function slug (s) {
  return String(s || '').toLowerCase().replace(/[^a-z0-9._-]+/g, '-').replace(/^[-.]+|[-.]+$/g, '').replace(/\.{2,}/g, '.').slice(0, 50) || 'task'
}

const shq = s => `'${String(s).replace(/'/g, "'\\''")}'`

// The line typed into the place's shell.
function launchLine (kind, cwd, promptFile) {
  let argv = LAUNCH[kind]
  try {
    const adapter = require('./adapters').get(kind)
    if (adapter && typeof adapter.launchArgs === 'function') argv = adapter.launchArgs()
  } catch {}
  if (!argv) throw new RunError('bad-agent', `no launch command for ${kind}`)
  return `cd ${shq(cwd)} && ${argv.map(shq).join(' ')} "$(cat ${shq(promptFile)})"`
}

function validate (input) {
  if (!input || typeof input !== 'object') throw new RunError('usage', 'expected a JSON object')
  const { repo, agent, place = 'herdr', tasks } = input
  if (typeof repo !== 'string' || !repo) throw new RunError('bad-repo', 'repo is required')
  if (typeof agent !== 'string' || !LAUNCH[agent]) {
    let known = false
    try { known = !!require('./adapters').get(agent) && typeof require('./adapters').get(agent).launchArgs === 'function' } catch {}
    if (!known) throw new RunError('bad-agent', `unknown agent ${agent} (${Object.keys(LAUNCH).join(', ')})`)
  }
  if (!PLACES.includes(place)) throw new RunError('bad-place', `place is ${PLACES.join(', ')}`)
  if (!Array.isArray(tasks) || !tasks.length || tasks.length > MAX_TASKS) throw new RunError('bad-tasks', `1 to ${MAX_TASKS} tasks`)
  for (const t of tasks) {
    if (!t || typeof t.prompt !== 'string' || !t.prompt.trim()) throw new RunError('bad-tasks', 'every task needs a prompt')
    if (t.prompt.length > MAX_PROMPT) throw new RunError('bad-tasks', `a prompt is over ${MAX_PROMPT} characters`)
  }
  const attempts = input.attempts === undefined ? 1 : input.attempts
  if (!Number.isInteger(attempts) || attempts < 1 || attempts > 5) throw new RunError('bad-attempts', 'attempts is 1 to 5')
  if (input.cap !== undefined && (!Number.isInteger(input.cap) || input.cap < 1 || input.cap > 20)) throw new RunError('bad-cap', 'cap is 1 to 20')
  const prefix = input.branchPrefix === undefined ? 'task' : input.branchPrefix
  if (typeof prefix !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9._/-]{0,39}$/.test(prefix) || prefix.includes('..')) throw new RunError('bad-branch', 'branchPrefix is a short branch prefix')
  return { attempts, prefix }
}

const str = (v, max = 300) => typeof v === 'string' ? v.slice(0, max) : null

// Queues the runs, then starts what the cap allows. Returns the new runs.
async function start (input, deps = {}) {
  const { attempts, prefix } = validate(input)
  const batchId = crypto.randomBytes(6).toString('hex')
  const now = Date.now()
  const created = []
  for (const t of input.tasks) {
    for (let a = 1; a <= attempts; a++) {
      const id = crypto.randomBytes(8).toString('hex')
      const dir = runDir(id)
      fs.mkdirSync(dir, { recursive: true, mode: 0o700 })
      const promptFile = path.join(dir, 'prompt.md')
      fs.writeFileSync(promptFile, t.prompt, { mode: 0o600 })
      created.push({
        id,
        batchId,
        task: { ref: str(t.ref), key: str(t.key, 80), title: str(t.title), url: str(t.url, 500) },
        attempt: a,
        attempts,
        repo: input.repo,
        base: typeof input.base === 'string' && input.base ? input.base : 'HEAD',
        location: typeof input.location === 'string' ? input.location : undefined,
        branch: `${prefix}/${slug(t.key || t.title)}${attempts > 1 ? `-a${a}` : ''}`,
        agent: input.agent,
        place: input.place || 'herdr',
        herdrServer: str(input.herdrServer, 100),
        workspaceId: str(input.workspaceId, 100),
        markDone: input.markDone === true,
        useWorktree: input.worktree !== false,
        promptFile,
        status: 'queued',
        createdAt: now
      })
    }
  }
  await locked(data => {
    if (input.cap !== undefined) data.cap = input.cap
    data.runs.push(...created)
  })
  await advance(deps)
  const data = load()
  const ids = new Set(created.map(r => r.id))
  return { ok: true, batchId, cap: data.cap, runs: data.runs.filter(r => ids.has(r.id)) }
}

// Starts queued runs while fewer than the cap are active.
async function advance (deps = {}) {
  const picked = []
  await locked(data => {
    let active = data.runs.filter(isActive).length
    for (const r of data.runs) {
      if (active >= data.cap) break
      if (r.status !== 'queued') continue
      r.status = 'starting'
      r.startedAt = Date.now()
      picked.push({ ...r })
      active++
    }
    return picked.length > 0
  })
  for (const run of picked) {
    let patch
    try {
      patch = await launch(run, deps)
      patch.status = 'running'
    } catch (err) {
      log('task-runs', `run ${run.id} failed: ${err.message}`)
      patch = { ...(err.patch || {}), status: 'failed', error: err.message, errorCode: err.code || 'failed', finishedAt: Date.now() }
    }
    await locked(data => {
      const r = data.runs.find(x => x.id === run.id)
      if (!r) return false
      if (r.status === 'cancelled') patch.status = r.status
      Object.assign(r, patch)
    })
  }
  // A failed start frees its slot: try the next queued run.
  if (picked.length) {
    const data = load()
    if (data.runs.some(r => r.status === 'queued') && data.runs.filter(isActive).length < data.cap) return advance(deps)
  }
  return load()
}

// Creates the worktree and opens the place. Resolves the run's new fields.
async function launch (run, deps) {
  let wt
  let branch = run.branch
  if (run.useWorktree === false) {
    // In the repository itself, on whatever it has checked out.
    const root = await worktree.repoRoot(run.repo)
    wt = { path: root, repo: root, head: null }
    branch = null
  }
  for (let i = 2; !wt; i++) {
    try {
      wt = await worktree.create({ repo: run.repo, branch, base: run.base, location: run.location })
      break
    } catch (err) {
      if ((err.code === 'branch-exists' || err.code === 'path-exists') && i <= 9) { branch = `${run.branch}-${i}`; continue }
      throw err
    }
  }
  const command = launchLine(run.agent, wt.path, run.promptFile)
  const label = `${run.task.key || 'task'}${run.attempts > 1 ? ` #${run.attempt}` : ''}`.slice(0, 60)
  const out = { branch, worktree: wt.path, repo: wt.repo, head: wt.head, command }
  try {
    if (run.place === 'herdr') out.herdr = await (deps.openHerdr || openHerdr)(run, wt.path, label, command)
    else if (run.place === 'tmux') out.tmux = await (deps.openTmux || openTmux)(wt.path, label, command)
  } catch (err) {
    // The worktree stays (nothing here removes one): say where it is.
    err.patch = { branch, worktree: wt.path, repo: wt.repo, command }
    throw err
  }
  return out
}

// The batch's Herdr workspace: the one asked for, else the one an earlier
// run of the batch created (runs of a batch start one after the other).
function batchWorkspace (run) {
  if (run.workspaceId) return run.workspaceId
  const other = load().runs.find(r => r.batchId === run.batchId && r.id !== run.id && r.herdr && r.herdr.workspaceId)
  return other ? other.herdr.workspaceId : null
}

// A tab in the batch's workspace; the batch's first run creates the
// workspace (unfocused) and uses its first pane.
async function openHerdr (run, cwd, label, command) {
  const api = require('./herdr-api')
  const server = run.herdrServer ? api.serverById(run.herdrServer) : api.discover()[0]
  if (!server) throw new RunError('no-herdr', 'no Herdr server')
  const workspaceId = batchWorkspace(run)
  const res = workspaceId
    ? await api.request(server.socket, 'tab.create', { cwd, label, focus: false, workspace_id: workspaceId })
    : await api.request(server.socket, 'workspace.create', { cwd, label: `Tasks ${new Date().toISOString().slice(5, 16).replace('T', ' ')}`, focus: false })
  const pane = res && res.root_pane && res.root_pane.pane_id
  if (!pane) throw new RunError('herdr-failed', 'Herdr made no pane for the task')
  if (!workspaceId && res.tab && res.tab.tab_id) {
    try { await api.request(server.socket, 'tab.rename', { tab_id: res.tab.tab_id, label }) } catch {}
  }
  await api.request(server.socket, 'pane.send_text', { pane_id: pane, text: command })
  await api.request(server.socket, 'pane.send_keys', { pane_id: pane, keys: ['enter'] })
  const ws = (res.workspace && res.workspace.workspace_id) || (res.tab && res.tab.workspace_id) || workspaceId
  return { server: server.id, socket: server.socket, workspaceId: ws, tabId: res.tab && res.tab.tab_id, paneId: pane }
}

function tmux (args) {
  return new Promise(resolve => {
    execFile('tmux', args, { timeout: 10000 }, (err, stdout, stderr) => resolve({ ok: !err, stdout: String(stdout).trim(), stderr: String(stderr).trim() }))
  })
}

// A new window in the default tmux server (a detached `conductore` session
// when none runs), never selected: the user's current window stays.
async function openTmux (cwd, label, command) {
  // tmux prints control characters as '_': spaces, the session name last.
  const fmt = '#{pane_id} #{window_id} #{session_name}'
  let r = await tmux(['new-window', '-d', '-P', '-F', fmt, '-n', label, '-c', cwd])
  if (!r.ok) r = await tmux(['new-session', '-d', '-P', '-F', fmt, '-s', `conductore-tasks-${process.pid}`, '-n', label, '-c', cwd])
  if (!r.ok) throw new RunError('tmux-failed', `tmux: ${r.stderr}`)
  const [paneId, windowId, ...name] = r.stdout.split(' ')
  const session = name.join(' ')
  if (!/^%\d+$/.test(paneId || '')) throw new RunError('tmux-failed', `tmux gave no pane: ${r.stdout}`)
  const typed = await tmux(['send-keys', '-t', paneId, '-l', '--', command])
  if (!typed.ok) throw new RunError('tmux-failed', `tmux send-keys: ${typed.stderr}`)
  const enter = await tmux(['send-keys', '-t', paneId, 'Enter'])
  if (!enter.ok) throw new RunError('tmux-failed', `tmux send-keys: ${enter.stderr}`)
  return { session, windowId, paneId }
}

const realpath = p => { try { return fs.realpathSync(p) } catch { return p } }

// Links runs to the agents (a list or the daemon's map) and finishes the
// runs whose agent ended its first turn. True when anything changed.
function link (data, agents) {
  const list = Array.isArray(agents) ? agents : Object.values(agents || {})
  let changed = false
  for (const r of data.runs) {
    if (!isActive(r) || !r.worktree) continue
    const wt = realpath(r.worktree)
    // Without a worktree the repository is shared: only an agent that
    // started with the run, and no other run's.
    const claimed = new Set(data.runs.filter(x => x !== r && x.sessionId).map(x => x.sessionId))
    const fresh = a => r.useWorktree !== false || ((a.startedAt || 0) >= (r.startedAt || 0) - 2000 && !claimed.has(a.sessionId))
    const mine = list.filter(a => a && a.cwd && (a.sessionId === r.sessionId || (!r.sessionId && fresh(a) && (realpath(a.cwd) === wt || realpath(a.cwd).startsWith(wt + path.sep)))))
    const agent = mine.sort((a, b) => (b.startedAt || 0) - (a.startedAt || 0))[0]
    if (!agent) {
      // Its agent was linked and is gone from the list (pruned): over.
      if (r.sessionId) {
        r.status = 'finished'
        r.finishedAt = Date.now()
        r.outcome = r.sawWorking ? 'gone' : 'error'
        changed = true
      }
      continue
    }
    const before = JSON.stringify([r.sessionId, r.agentState, r.sawWorking, r.status])
    r.sessionId = agent.sessionId
    r.agentKind = agent.kind || 'claude'
    r.agentState = agent.state
    if (agent.state === 'working' || agent.state === 'needs_permission') r.sawWorking = true
    const turnEnded = r.sawWorking && agent.state === 'waiting_input' && (agent.lastEvent === 'Stop' || agent.lastEvent === 'StopFailure')
    if (turnEnded || agent.state === 'ended') {
      r.status = 'finished'
      r.finishedAt = Date.now()
      r.outcome = agent.lastEvent === 'StopFailure' || (agent.state === 'ended' && !r.sawWorking) ? 'error' : 'done'
      if (typeof agent.lastMessage === 'string') r.lastMessage = agent.lastMessage.slice(0, 500)
    }
    if (JSON.stringify([r.sessionId, r.agentState, r.sawWorking, r.status]) !== before) changed = true
  }
  return changed
}

// Every run, after linking them to agents.
async function list (agents, deps = {}) {
  let finished = false
  let hasQueued = false
  if (fs.existsSync(file())) {
    await locked(data => {
      const before = data.runs.filter(r => r.status === 'finished').length
      const changed = agents ? link(data, agents) : false
      finished = data.runs.filter(r => r.status === 'finished').length > before
      hasQueued = data.runs.some(r => r.status === 'queued')
      return changed
    })
  }
  if (finished || hasQueued) await advance(deps)
  const data = load()
  return { ok: true, cap: data.cap, runs: data.runs }
}

// The daemon's hook: every agent change (debounced), only while runs are
// active or queued.
let pending = null
let idleMtime = null
function onAgents (agents, deps = {}) {
  if (pending) return
  let mtime
  try { mtime = fs.statSync(file()).mtimeMs } catch { return }
  // Nothing to follow since the file last changed: no read per event.
  if (mtime === idleMtime) return
  const data = load()
  if (!data.runs.some(r => isActive(r) || r.status === 'queued')) { idleMtime = mtime; return }
  idleMtime = null
  pending = setTimeout(() => {
    pending = null
    list(agents, deps).catch(err => log('task-runs', `update failed: ${err.message}`))
  }, deps.debounceMs === undefined ? 500 : deps.debounceMs)
  if (pending.unref) pending.unref()
}

async function cancel (id) {
  let found = null
  await locked(data => {
    const r = data.runs.find(x => x.id === id)
    if (!r) return false
    found = r
    if (r.status === 'queued' || isActive(r)) {
      r.status = 'cancelled'
      r.finishedAt = Date.now()
    }
  })
  if (!found) throw new RunError('not-found', `no run ${id}`)
  return { ok: true, run: found }
}

async function forget (id) {
  let found = false
  await locked(data => {
    const r = data.runs.find(x => x.id === id)
    if (!r || r.status === 'queued' || isActive(r)) return false
    found = true
    data.runs = data.runs.filter(x => x.id !== id)
  })
  if (!found) throw new RunError('not-found', `no finished run ${id}`)
  try { fs.rmSync(runDir(id), { recursive: true, force: true }) } catch {}
  return { ok: true }
}

async function setCap (n) {
  if (!Number.isInteger(n) || n < 1 || n > 20) throw new RunError('bad-cap', 'cap is 1 to 20')
  await locked(data => { data.cap = n })
  await advance()
  return { ok: true, cap: n }
}

const START_USAGE = `usage: conductore-hostd task-start -

  One JSON object on stdin:
    {repo, agent: claude|codex|opencode|gemini|cursor, place: herdr|tmux|none,
     tasks: [{ref?, key, title?, url?, prompt}], base?: "HEAD",
     location?: next-to-repo|herdr|<template>, attempts?: 1, cap?: 3,
     branchPrefix?: "task", herdrServer?, workspaceId?, markDone?: false,
     worktree?: true (false: run in the repository as it is)}
`

async function startCli (args, { readStdin }) {
  const write = obj => { process.stdout.write(JSON.stringify(obj) + '\n'); return obj.error ? 1 : 0 }
  if (args[0] !== '-') return write({ error: START_USAGE.trim(), code: 'usage' })
  let input
  try { input = JSON.parse(await readStdin()) } catch { return write({ error: 'task-start: expected one JSON object on stdin', code: 'usage' }) }
  try {
    return write(await start(input))
  } catch (err) {
    return write({ error: err.message, code: err.code || 'failed' })
  }
}

async function runsCli (args, { agents }) {
  const write = obj => { process.stdout.write(JSON.stringify(obj) + '\n'); return obj.error ? 1 : 0 }
  const [op = 'list', arg] = args
  try {
    if (op === 'list') return write(await list(await agents()))
    if (op === 'cancel') return write(await cancel(arg))
    if (op === 'forget') return write(await forget(arg))
    if (op === 'cap') return write(await setCap(Number(arg)))
  } catch (err) {
    return write({ error: err.message, code: err.code || 'failed' })
  }
  return write({ error: 'usage: conductore-hostd task-runs [list | cancel <id> | forget <id> | cap <n>]', code: 'usage' })
}

module.exports = { start, advance, list, link, onAgents, cancel, forget, setCap, launchLine, slug, startCli, runsCli, RunError, LAUNCH, file }
