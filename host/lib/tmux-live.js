'use strict'

// The default tmux server's sessions and windows, pushed by tmux control
// mode instead of `tmux list-sessions` on a timer.
//
// One control client per server:
//   tmux -S <socket> -C attach-session -t <session> -f read-only,ignore-size,no-output
// ignore-size: the client never changes a window's size. no-output: tmux
// sends no pane output, only notifications. read-only does NOT stop
// commands sent in control mode (tmux 3.4 ran `new-window` from such a
// client), so the guard is here: only the read commands in READ_COMMANDS
// are ever written to the client, and assertReadOnly() refuses anything
// else before it reaches tmux.
//
// Notifications (%window-add, %sessions-changed, ...) trigger a debounced
// re-list over the same client (list-sessions, list-windows -a,
// list-clients). Output does not notify (no-output), so activity times
// are refreshed every LAZY_REFRESH_MS while the watch runs; changes that
// only move activity are published as lazy.
//
// What an attached control client does to the user's tmux (tmux 3.4,
// checked on an isolated server, see docs/herdr-live.md): the attached
// session counts one more client (subtracted here from `attached`),
// attaching bumps that session's activity and last-attached time and runs
// client-attached hooks, and a bare `tmux attach` prefers another
// (unattached) session. So the client attaches to a session a person
// already has open when there is one, else to the least recently active
// session, and moves when that changes.

const fs = require('fs')
const path = require('path')
const { spawn, execFile } = require('child_process')
const { log } = require('./log')

const READ_COMMANDS = new Set(['list-sessions', 'list-windows', 'list-clients'])
const REFRESH_DEBOUNCE_MS = 150
const LAZY_REFRESH_MS = 20 * 1000
const RETRY_MS = [1000, 2000, 5000, 10000, 30000]
const NO_SERVER_CHECK_MS = 30 * 1000
const MOVE_MIN_INTERVAL_MS = 10 * 1000
const COMMAND_TIMEOUT_MS = 5000

// Fixed fields first, separated by '|', the free-text name last: tmux turns
// a tab in command output into '_' in control mode.
const SESSION_FORMAT = '#{session_id}|#{session_windows}|#{session_attached}|#{session_activity}|#{session_created}|#{session_name}'
const WINDOW_FORMAT = '#{session_id}|#{window_id}|#{window_index}|#{window_active}|#{window_panes}|#{window_activity}|#{window_activity_flag}|#{window_bell_flag}|#{window_name}'
const CLIENT_FORMAT = '#{client_pid}|#{session_id}|#{client_control_mode}'

const REFRESH_ON = new Set([
  '%sessions-changed', '%session-changed', '%session-renamed', '%session-window-changed',
  '%window-add', '%window-close', '%window-renamed', '%unlinked-window-add', '%unlinked-window-close',
  '%unlinked-window-renamed', '%layout-change', '%window-pane-changed', '%client-session-changed',
  '%client-detached', '%pane-mode-changed'
])

function defaultSocket () {
  if (process.env.CONDUCTORE_TMUX_SOCKET) return process.env.CONDUCTORE_TMUX_SOCKET
  const uid = process.getuid ? process.getuid() : 0
  return path.join(process.env.TMUX_TMPDIR || '/tmp', `tmux-${uid}`, 'default')
}

// Refuses any command that is not one of the read commands (the name is
// the first word; nothing chained with ';').
function assertReadOnly (command) {
  const name = String(command).trim().split(/\s+/)[0]
  if (!READ_COMMANDS.has(name) || /(^|\s);(\s|$)|\\;/.test(command) || /[\r\n]/.test(command)) {
    throw new Error(`tmux-live: refusing to send "${name}" on the control client`)
  }
  return command
}

const listSessions = () => `list-sessions -F '${SESSION_FORMAT}'`
const listWindows = () => `list-windows -a -F '${WINDOW_FORMAT}'`
const listClients = () => `list-clients -F '${CLIENT_FORMAT}'`

function splitFixed (line, n) {
  const parts = line.split('|')
  if (parts.length < n + 1) return null
  return [...parts.slice(0, n), parts.slice(n).join('|')]
}

const num = s => { const n = Number(s); return Number.isFinite(n) ? n : 0 }

function parseSessions (lines) {
  const out = []
  for (const line of lines) {
    const f = splitFixed(line, 5)
    if (!f || !f[0].startsWith('$')) continue
    out.push({ id: f[0], windows: num(f[1]), attached: num(f[2]), activity: num(f[3]), created: num(f[4]), name: f[5] })
  }
  return out
}

function parseWindows (lines) {
  const out = []
  for (const line of lines) {
    const f = splitFixed(line, 8)
    if (!f || !f[0].startsWith('$') || !f[1].startsWith('@')) continue
    out.push({ sessionId: f[0], id: f[1], index: num(f[2]), active: f[3] === '1', panes: num(f[4]), activity: num(f[5]), activityFlag: f[6] === '1', bellFlag: f[7] === '1', name: f[8] })
  }
  return out
}

function parseClients (lines) {
  const out = []
  for (const line of lines) {
    const f = line.split('|')
    if (f.length < 3) continue
    out.push({ pid: num(f[0]), sessionId: f[1], control: f[2] === '1' })
  }
  return out
}

// The entities of one listing; `ownPid` is our control client's.
function entitiesFrom (serverId, sessions, windows, clients, ownPid) {
  const entities = new Map()
  const names = new Map(sessions.map(s => [s.id, s.name]))
  for (const s of sessions) {
    const ours = clients.filter(c => c.pid === ownPid && c.sessionId === s.id).length
    entities.set(`tses:${serverId}:${s.id}`, {
      kind: 'tmuxSession', server: serverId, id: s.id, name: s.name, windows: s.windows,
      attached: Math.max(0, s.attached - ours), activity: s.activity, created: s.created
    })
  }
  for (const w of windows) {
    entities.set(`twin:${serverId}:${w.sessionId}:${w.id}`, {
      kind: 'tmuxWindow', server: serverId, id: w.id, sessionId: w.sessionId, session: names.get(w.sessionId) || '',
      index: w.index, name: w.name, active: w.active, panes: w.panes, activity: w.activity,
      activityFlag: w.activityFlag, bellFlag: w.bellFlag
    })
  }
  return entities
}

// Where the control client should sit: a session someone else has open,
// else the least recently active one (a bare `tmux attach` picks the most
// recent unattached session, which stays untouched).
function pickSession (sessions, clients, ownPid) {
  if (!sessions.length) return null
  const people = new Set(clients.filter(c => !c.control && c.pid !== ownPid).map(c => c.sessionId))
  const attended = sessions.filter(s => people.has(s.id))
  const pool = attended.length ? attended : sessions
  return pool.slice().sort((a, b) => a.activity - b.activity || a.id.localeCompare(b.id))[0].id
}

// Parses control-mode output: command replies between %begin/%end (or
// %error) with flag 1 are ours, in order; other lines are notifications.
class ControlParser {
  constructor ({ onReply, onNotification }) {
    this.onReply = onReply
    this.onNotification = onNotification
    this.buf = ''
    this.block = null
  }

  push (chunk) {
    this.buf += chunk
    let i
    while ((i = this.buf.indexOf('\n')) !== -1) {
      const line = this.buf.slice(0, i).replace(/\r$/, '')
      this.buf = this.buf.slice(i + 1)
      this.line(line)
    }
  }

  line (line) {
    if (this.block) {
      const m = /^%(end|error) \S+ \S+ (\d+)$/.exec(line)
      if (m) {
        const block = this.block
        this.block = null
        if (block.flags === '1') this.onReply({ ok: m[1] === 'end', lines: block.lines })
        return
      }
      this.block.lines.push(line)
      return
    }
    const b = /^%begin \S+ \S+ (\d+)$/.exec(line)
    if (b) { this.block = { flags: b[1], lines: [] }; return }
    if (line.startsWith('%')) this.onNotification(line.split(' ')[0], line)
  }
}

class TmuxWatch {
  constructor (store, { socket = defaultSocket(), id = 'tmux', spawnFn = spawn, execFileFn = execFile, tmuxBin = 'tmux' } = {}) {
    this.store = store
    this.socket = socket
    this.id = id
    this.spawn = spawnFn
    this.execFile = execFileFn
    this.bin = tmuxBin
    this.stopped = true
    this.child = null
    this.attachedTo = null
    this.pending = []
    this.timers = { refresh: null, lazy: null, retry: null, check: null }
    this.failures = 0
    this.version = null
    this.dirWatcher = null
    this.lastMove = 0
    this.refreshing = null
    this.again = false
  }

  get key () { return `srv:${this.id}` }

  env () {
    const env = { ...process.env }
    delete env.TMUX
    delete env.TMUX_PANE
    return env
  }

  setServerState (state, error = null) {
    this.store.set(this.key, { kind: 'server', id: this.id, type: 'tmux', default: true, session: '', state, mode: 'control', version: this.version, protocol: null, error })
  }

  start () {
    if (!this.stopped) return
    this.stopped = false
    this.execFile(this.bin, ['-V'], { timeout: 2000, env: this.env() }, (err, stdout) => {
      if (this.stopped) return
      if (err && err.code === 'ENOENT') { this.setServerState('none', 'tmux is not installed'); return }
      this.version = String(stdout || '').trim().replace(/^tmux\s+/, '') || null
      this.connect()
    })
  }

  // One-shot read over its own process, before a control client exists.
  oneShot (args) {
    return new Promise(resolve => {
      this.execFile(this.bin, ['-S', this.socket, ...args], { timeout: COMMAND_TIMEOUT_MS, env: this.env() }, (err, stdout) => {
        resolve(err ? null : String(stdout || '').split('\n').filter(Boolean))
      })
    })
  }

  async connect () {
    if (this.stopped) return
    this.closeChild()
    if (!fs.existsSync(this.socket)) return this.noServer()
    const sessionLines = await this.oneShot(['list-sessions', '-F', SESSION_FORMAT])
    if (this.stopped) return
    if (!sessionLines || !sessionLines.length) return this.noServer()
    const clientLines = await this.oneShot(['list-clients', '-F', CLIENT_FORMAT])
    if (this.stopped) return
    const target = pickSession(parseSessions(sessionLines), parseClients(clientLines || []), -1)
    if (!target) return this.noServer()
    this.attach(target)
  }

  attach (sessionId) {
    const args = ['-S', this.socket, '-C', 'attach-session', '-t', sessionId, '-f', 'read-only,ignore-size,no-output']
    let child
    try {
      child = this.spawn(this.bin, args, { stdio: ['pipe', 'pipe', 'ignore'], env: this.env() })
    } catch (err) {
      return this.retry(err.message)
    }
    this.child = child
    this.attachedTo = sessionId
    this.pending = []
    const parser = new ControlParser({
      onReply: reply => {
        const next = this.pending.shift()
        if (next) { clearTimeout(next.timer); next.resolve(reply) }
      },
      onNotification: (name) => {
        if (name === '%exit') return
        if (REFRESH_ON.has(name)) this.scheduleRefresh()
      }
    })
    child.stdout.setEncoding('utf8')
    child.stdout.on('data', d => parser.push(d))
    child.stdin.on('error', () => {})
    child.on('error', err => { if (this.child === child) this.lost(err.message) })
    child.on('exit', () => { if (this.child === child) this.lost('control client exited') })
    this.failures = 0
    this.refresh()
    this.armLazy()
  }

  // Sends one read command on the control client.
  command (command) {
    return new Promise(resolve => {
      const child = this.child
      if (!child || !child.stdin.writable) return resolve(null)
      let line
      try { line = assertReadOnly(command) } catch (err) { log('tmux-live', err.message); return resolve(null) }
      const entry = { resolve, timer: null }
      entry.timer = setTimeout(() => {
        const i = this.pending.indexOf(entry)
        if (i !== -1) this.pending.splice(i, 1)
        resolve(null)
      }, COMMAND_TIMEOUT_MS)
      this.pending.push(entry)
      child.stdin.write(line + '\n')
    })
  }

  scheduleRefresh (ms = REFRESH_DEBOUNCE_MS) {
    if (this.stopped || this.timers.refresh) return
    this.timers.refresh = setTimeout(() => { this.timers.refresh = null; this.refresh() }, ms)
  }

  armLazy () {
    clearTimeout(this.timers.lazy)
    if (this.stopped) return
    this.timers.lazy = setTimeout(async () => {
      this.timers.lazy = null
      await this.refresh()
      this.armLazy()
    }, LAZY_REFRESH_MS)
  }

  async refresh () {
    if (this.stopped || !this.child) return
    if (this.refreshing) { this.again = true; return this.refreshing }
    this.refreshing = (async () => {
      do {
        this.again = false
        const [s, w, c] = await Promise.all([this.command(listSessions()), this.command(listWindows()), this.command(listClients())])
        if (this.stopped || !this.child) return
        if (!s || !w || !c || !s.ok || !w.ok || !c.ok) return
        const sessions = parseSessions(s.lines)
        const clients = parseClients(c.lines)
        const ownPid = this.child.pid
        this.store.replaceServer(this.id, entitiesFrom(this.id, sessions, parseWindows(w.lines), clients, ownPid))
        this.setServerState('up')
        this.maybeMove(sessions, clients, ownPid)
      } while (this.again && !this.stopped)
    })()
    try { await this.refreshing } finally { this.refreshing = null }
  }

  // Someone opened another session and nobody else sits in ours: follow
  // them, so the sessions they left keep their plain "unattached" state.
  maybeMove (sessions, clients, ownPid) {
    const best = pickSession(sessions, clients, ownPid)
    if (!best || best === this.attachedTo) return
    const peopleHere = clients.some(c => !c.control && c.pid !== ownPid && c.sessionId === this.attachedTo)
    const stillThere = sessions.some(s => s.id === this.attachedTo)
    if (peopleHere && stillThere) return
    if (Date.now() - this.lastMove < MOVE_MIN_INTERVAL_MS) return
    this.lastMove = Date.now()
    this.closeChild()
    this.attach(best)
  }

  lost (why) {
    this.child = null
    this.attachedTo = null
    for (const p of this.pending.splice(0)) { clearTimeout(p.timer); p.resolve(null) }
    if (this.stopped) return
    debugLog(`${why}; listing again`)
    this.retry(why)
  }

  retry (why) {
    clearTimeout(this.timers.retry)
    const ms = RETRY_MS[Math.min(this.failures, RETRY_MS.length - 1)]
    this.failures += 1
    this.timers.retry = setTimeout(() => { this.timers.retry = null; this.connect() }, ms)
  }

  // No server (or no session): nothing to list. Wait for the socket to
  // appear: a watch on its directory, else a stat every 30 s.
  noServer () {
    this.closeChild()
    this.store.replaceServer(this.id, new Map())
    this.setServerState('none')
    clearTimeout(this.timers.lazy)
    this.timers.lazy = null
    if (this.stopped) return
    this.watchDir()
  }

  watchDir () {
    if (this.dirWatcher || this.timers.check) return
    const dir = path.dirname(this.socket)
    try {
      this.dirWatcher = fs.watch(dir, { persistent: false }, () => {
        if (fs.existsSync(this.socket)) { this.unwatchDir(); this.scheduleConnect() }
      })
      this.dirWatcher.on('error', () => { this.unwatchDir(); this.checkLater() })
    } catch {
      this.checkLater()
    }
    // A server can exist with its socket already there (it had no session).
    if (fs.existsSync(this.socket)) this.checkLater()
  }

  checkLater () {
    if (this.timers.check || this.stopped) return
    this.timers.check = setTimeout(() => { this.timers.check = null; this.unwatchDir(); this.connect() }, NO_SERVER_CHECK_MS)
  }

  scheduleConnect () {
    clearTimeout(this.timers.retry)
    this.timers.retry = setTimeout(() => { this.timers.retry = null; this.connect() }, 300)
  }

  unwatchDir () {
    if (this.dirWatcher) { try { this.dirWatcher.close() } catch {} this.dirWatcher = null }
  }

  closeChild () {
    const child = this.child
    this.child = null
    this.attachedTo = null
    for (const p of this.pending.splice(0)) { clearTimeout(p.timer); p.resolve(null) }
    if (child) {
      // Closing stdin detaches a control client; the kill is the fallback.
      try { child.stdin.end() } catch {}
      setTimeout(() => { try { child.kill() } catch {} }, 1000).unref()
    }
  }

  stop ({ forget = true } = {}) {
    this.stopped = true
    for (const t of Object.values(this.timers)) clearTimeout(t)
    this.timers = { refresh: null, lazy: null, retry: null, check: null }
    this.unwatchDir()
    this.closeChild()
    if (forget) {
      this.store.replaceServer(this.id, new Map())
      this.store.remove(this.key)
    }
  }
}

function debugLog (msg) { log('tmux-live', msg) }

module.exports = { TmuxWatch, ControlParser, assertReadOnly, parseSessions, parseWindows, parseClients, entitiesFrom, pickSession, defaultSocket, READ_COMMANDS, SESSION_FORMAT, WINDOW_FORMAT, CLIENT_FORMAT }
