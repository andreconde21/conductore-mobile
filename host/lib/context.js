'use strict'

// Where an agent runs, resolved by the daemon from what the sh hook passed
// in its spool header ($TMUX, $TMUX_PANE, $HERDR_*). The hook itself forks
// nothing for this; the daemon asks tmux once per pane and caches the answer
// for a few seconds, so a burst of Pre/PostToolUse events costs one `tmux`.

const { execFile } = require('child_process')
const { log } = require('./log')

const TTL_MS = 5000
const CACHE_MAX = 64
// Fixed-shape fields first, free text last. tmux 3.3+ prints a tab as `_`
// when it thinks the client is not UTF-8 (LANG/LC_* unset or C, as under
// systemd or in a minimal container), which would leave one unsplittable
// field; `-u` makes it pass tabs through on every version, and
// parseTmuxContext still recovers the pane from the `_` form.
const FORMAT = '#{pane_id}\t#{pane_pid}\t#{window_index}\t#{session_name}\t#{window_name}\t#{pane_current_path}'
const MANGLED = /^(%\d+)_(\d+)_(\d+)_/

const cache = new Map() // `${socket}\0${pane}` -> { at, value }

// $TMUX is "<socket path>,<server pid>,<session index>".
function tmuxSocket (tmuxEnv) {
  const parts = String(tmuxEnv).split(',')
  if (parts.length >= 3) parts.splice(-2, 2)
  return parts.join(',') || null
}

function tmuxContext (header, now = Date.now()) {
  if (!header.tmux) return Promise.resolve(null)
  const socket = tmuxSocket(header.tmux)
  const pane = header.tmux_pane || ''
  const key = `${socket}\0${pane}`
  const hit = cache.get(key)
  if (hit && now - hit.at < TTL_MS) return Promise.resolve(hit.value)
  const args = ['-u']
  if (socket) args.push('-S', socket)
  args.push('display-message', '-p')
  if (pane) args.push('-t', pane)
  args.push(FORMAT)
  return new Promise(resolve => {
    execFile('tmux', args, { timeout: 1500, encoding: 'utf8' }, (err, stdout) => {
      let value = null
      if (err) log('context', 'tmux context failed', err.message)
      else {
        value = parseTmuxContext(stdout, socket)
        if (!value) log('context', 'tmux context unparsable', JSON.stringify(String(stdout).slice(0, 200)))
      }
      cache.delete(key)
      cache.set(key, { at: Date.now(), value })
      if (cache.size > CACHE_MAX) cache.delete(cache.keys().next().value)
      resolve(value)
    })
  })
}

// Parses one line of FORMAT. The server's socket and the pane's process let
// the prompt relay check, before typing, that the pane still is this
// agent's. A tab-mangled line (see FORMAT) still yields the pane, its
// process and window index; the free-text fields are then unknown (null),
// since `_` is also a common character in them.
function parseTmuxContext (stdout, socket = null) {
  const line = String(stdout).replace(/\n$/, '')
  const parts = line.split('\t')
  if (parts.length >= 6 && /^%\d+$/.test(parts[0])) {
    const [paneId, panePid, window, session, windowName] = parts
    const currentPath = parts.slice(5).join('\t')
    return { session, window: Number(window), paneId, currentPath, windowName, socket, panePid: Number(panePid) || null }
  }
  const m = MANGLED.exec(line)
  if (m) return { session: null, window: Number(m[3]), paneId: m[1], currentPath: null, windowName: null, socket, panePid: Number(m[2]) || null }
  return null
}

function herdrContext (header) {
  if (!header.herdr_workspace && !header.herdr_pane) return null
  return {
    workspaceId: header.herdr_workspace || null,
    tabId: header.herdr_tab || null,
    paneId: header.herdr_pane || null,
    name: header.herdr_name || null,
    // The agent's Herdr server; null is the default one.
    socket: header.herdr_socket || null
  }
}

// The environment for a herdr command aimed at `socket` (null: as is).
function herdrEnv (socket) {
  return socket ? { ...process.env, HERDR_SOCKET_PATH: socket } : process.env
}

// --- Herdr's own view: `herdr pane list` ------------------------------------
//
// Used only when the hook's environment did not carry the full location
// (HERDR_* missing, e.g. Claude Code started by a wrapper that drops them,
// or only HERDR_PANE_ID set). Herdr knows each pane's agent session id, so
// the Claude session id finds the pane. One call serves every lookup for
// PANE_LIST_TTL_MS; when herdr is missing or not running, nothing is asked
// again for HERDR_DOWN_MS. Sessions found in no pane are not asked about
// again until their next SessionStart. Each Herdr server (socket) has its
// own list.

const PANE_LIST_TTL_MS = 10000
const HERDR_DOWN_MS = 5 * 60 * 1000
const paneLists = new Map() // socket ('' = default) -> { at, panes, pending, downUntil }
const notInHerdr = new Set()

function parsePaneList (stdout) {
  let doc
  try { doc = JSON.parse(stdout) } catch { return null }
  const panes = doc && doc.result && Array.isArray(doc.result.panes) ? doc.result.panes : null
  if (!panes) return null
  return panes.filter(p => p && typeof p.pane_id === 'string').map(p => ({
    workspaceId: typeof p.workspace_id === 'string' ? p.workspace_id : null,
    tabId: typeof p.tab_id === 'string' ? p.tab_id : null,
    paneId: p.pane_id,
    sessionId: p.agent_session && typeof p.agent_session.value === 'string' ? p.agent_session.value : null
  }))
}

function herdrPanes (socket = null, now = Date.now()) {
  const key = socket || ''
  let paneList = paneLists.get(key)
  if (!paneList) {
    paneList = { at: 0, panes: null, pending: null, downUntil: 0 }
    paneLists.set(key, paneList)
  }
  if (now < paneList.downUntil) return Promise.resolve(null)
  if (paneList.panes && now - paneList.at < PANE_LIST_TTL_MS) return Promise.resolve(paneList.panes)
  if (paneList.pending) return paneList.pending
  paneList.pending = new Promise(resolve => {
    execFile('herdr', ['pane', 'list'], { timeout: 2000, encoding: 'utf8', maxBuffer: 4 * 1024 * 1024, env: herdrEnv(socket) }, (err, stdout) => {
      const panes = err ? null : parsePaneList(stdout)
      paneList.pending = null
      if (!panes) {
        paneList.downUntil = Date.now() + HERDR_DOWN_MS
        paneList.panes = null
      } else {
        paneList.at = Date.now()
        paneList.panes = panes
      }
      resolve(panes)
    })
  })
  return paneList.pending
}

// `herdr pane get <id>` (read-only): Herdr still answers for a pane's old
// id after `herdr pane move` gave it a new one, with the pane as it is now.
// Cached per old id like the pane list; null when Herdr does not know it.
const moved = new Map() // `${socket}\0${paneId}` -> { at, pane }

function herdrPane (paneId, socket = null, now = Date.now()) {
  const key = `${socket || ''}\0${paneId}`
  const hit = moved.get(key)
  if (hit && now - hit.at < PANE_LIST_TTL_MS) return Promise.resolve(hit.pane)
  return new Promise(resolve => {
    execFile('herdr', ['pane', 'get', paneId], { timeout: 2000, encoding: 'utf8', env: herdrEnv(socket) }, (err, stdout) => {
      let pane = null
      if (!err) {
        try {
          const p = JSON.parse(stdout).result.pane
          if (p && typeof p.pane_id === 'string') pane = parsePaneList(JSON.stringify({ result: { panes: [p] } }))[0] || null
        } catch {}
      }
      moved.delete(key)
      moved.set(key, { at: Date.now(), pane })
      if (moved.size > CACHE_MAX) moved.delete(moved.keys().next().value)
      resolve(pane)
    })
  })
}

// The Herdr location of a hook event, checked against Herdr's pane list
// (one cached `herdr pane list` per server every PANE_LIST_TTL_MS, only
// while events arrive). $HERDR_* are fixed when the pane's shell starts: a
// pane moved since (`herdr pane move` to another tab or workspace) has a new
// id while Claude Code still reports the old one, and opening that old
// place lands on another workspace. So the pane that holds this Claude
// session wins, then the header's pane (followed through a move), then the
// header as is. Never uses the cwd.
async function herdrLocation (header, event) {
  const fromEnv = herdrContext(header)
  const sid = event.session_id
  if (event.hook_event_name === 'SessionStart') notInHerdr.delete(sid)
  if (!fromEnv && (header.tmux || notInHerdr.has(sid))) return null
  const socket = header.herdr_socket || null
  const panes = await herdrPanes(socket)
  if (!panes) return fromEnv
  let pane = panes.find(p => p.sessionId === sid)
  if (!pane && fromEnv && fromEnv.paneId) {
    // A pane known to hold another session is not this agent's any more.
    pane = panes.find(p => p.paneId === fromEnv.paneId && (!p.sessionId || p.sessionId === sid))
    if (!pane && !panes.some(p => p.paneId === fromEnv.paneId)) {
      const now = await herdrPane(fromEnv.paneId, socket)
      if (now && (!now.sessionId || now.sessionId === sid)) pane = now
    }
  }
  if (!pane) {
    if (!fromEnv) notInHerdr.add(sid)
    return fromEnv
  }
  return {
    workspaceId: pane.workspaceId,
    tabId: pane.tabId,
    paneId: pane.paneId,
    name: (fromEnv && fromEnv.name) || null,
    socket
  }
}

// Adds `tmux` / `herdr` to a hook event, as the old Node hook did.
async function enrich (event, header) {
  const tmux = await tmuxContext(header)
  const herdr = await herdrLocation(header, event)
  if (tmux) event.tmux = tmux
  if (herdr) event.herdr = herdr
  return event
}

function _reset () {
  paneLists.clear()
  moved.clear()
  notInHerdr.clear()
  cache.clear()
}

module.exports = { enrich, tmuxContext, parseTmuxContext, FORMAT, herdrContext, herdrLocation, herdrEnv, parsePaneList, tmuxSocket, _reset }
