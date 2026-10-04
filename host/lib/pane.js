'use strict'

// Typing into an agent's pane: the prompt relay behind `send`, `interrupt`
// and `focus`. Every command runs through execFile/spawn with an argument
// array, never a shell string, so the prompt text is passed to tmux/herdr
// verbatim.
//
// A recorded pane id can point at someone else by now: tmux reuses ids once
// a pane closes or its server restarts, and the agent may run on a tmux
// server or Herdr session other than the default one. So tmux commands go to
// the socket the hook reported (-S), herdr commands to the Herdr server the
// hook ran under (HERDR_SOCKET_PATH), and right before typing each target is
// checked: the tmux pane still runs the process it ran when recorded, the
// Herdr pane still runs this Claude session, and Claude Code itself still
// runs.
// Anything else is refused and nothing is typed.

const crypto = require('crypto')
const { execFile, spawn } = require('child_process')
const { log } = require('./log')
const proc = require('./proc')
const { parsePaneList, herdrEnv } = require('./context')

const MAX_TEXT = 100000

// Pause between the text and the Enter key. Claude Code (Ink) treats one
// terminal read holding text plus CR as a paste and inserts the CR as a
// newline instead of submitting, so Enter goes in a separate write.
function enterDelayMs () {
  const v = Number(process.env.CONDUCTORE_SEND_ENTER_DELAY_MS)
  return Number.isFinite(v) && v >= 0 ? v : 150
}

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms))

function run (cmd, args, input, env = process.env) {
  return new Promise(resolve => {
    if (input === undefined) {
      execFile(cmd, args, { timeout: 10000, env }, (err, stdout, stderr) => resolve({ err, stdout: String(stdout || ''), stderr: String(stderr || '') }))
      return
    }
    let stdout = ''
    let stderr = ''
    let done = false
    const finish = r => { if (!done) { done = true; clearTimeout(timer); resolve(r) } }
    const child = spawn(cmd, args, { stdio: ['pipe', 'pipe', 'pipe'], env })
    const timer = setTimeout(() => { child.kill(); finish({ err: new Error('timed out'), stdout, stderr }) }, 10000)
    child.stdout.on('data', d => { stdout += d })
    child.stderr.on('data', d => { stderr += d })
    child.on('error', err => finish({ err, stdout, stderr }))
    child.on('exit', code => finish({ err: code === 0 ? null : Object.assign(new Error(`exit ${code}`), { code }), stdout, stderr }))
    child.stdin.on('error', () => {})
    child.stdin.end(input)
  })
}

const why = r => (r.stderr || r.stdout || (r.err && r.err.message) || '').trim().split('\n')[0]

// Where input for this agent goes: Herdr pane first (the multiplexer that
// owns the agent), else its tmux pane.
function targets (agent) {
  const list = []
  if (agent.herdr && agent.herdr.paneId) list.push({ via: 'herdr', paneId: agent.herdr.paneId, socket: agent.herdr.socket || null })
  if (agent.tmux && agent.tmux.paneId) {
    list.push({ via: 'tmux', paneId: agent.tmux.paneId, socket: agent.tmux.socket || null, panePid: agent.tmux.panePid || null })
  }
  return list
}

// tmux argv for the agent's own server.
const tmuxArgs = (t, args) => t.socket ? ['-S', t.socket, ...args] : args

// A herdr command on the agent's own Herdr server.
const herdr = (t, args) => run('herdr', args, undefined, herdrEnv(t.socket))

// Null when the target still holds this agent, else why not.
async function verify (agent, t) {
  if (t.via === 'tmux') {
    if (!t.socket || !t.panePid) {
      return `cannot verify tmux pane ${t.paneId} (recorded by an older companion); it is checked again after the agent's next event`
    }
    const r = await run('tmux', tmuxArgs(t, ['display-message', '-p', '-t', t.paneId, '#{pane_pid}']))
    if (r.err) return `tmux pane ${t.paneId} is gone: ${why(r)}`
    if (Number(r.stdout.trim()) !== t.panePid) return `tmux pane ${t.paneId} no longer holds this session (closed, or its id reused)`
    return null
  }
  const r = await herdr(t, ['pane', 'list'])
  const panes = r.err ? null : parsePaneList(r.stdout)
  if (!panes) return `cannot list Herdr panes to verify ${t.paneId}: ${why(r) || 'unexpected output'}`
  const pane = panes.find(p => p.paneId === t.paneId)
  if (!pane) return `Herdr pane ${t.paneId} is gone`
  if (pane.sessionId !== agent.sessionId) return `Herdr pane ${t.paneId} no longer holds this session`
  return null
}

// The targets that still hold the agent, checked now: { list, errors }.
async function verifiedTargets (agent) {
  const all = targets(agent)
  if (!all.length) return { list: [], errors: ['session not in tmux or Herdr'] }
  if (agent.process && !proc.sameProcess(agent.process)) {
    return { list: [], errors: ["the agent's Claude Code process has exited; nothing was typed"] }
  }
  const list = []
  const errors = []
  for (const t of all) {
    const bad = await verify(agent, t)
    if (bad) {
      log('pane', `refused ${agent.sessionId}: ${bad}`)
      errors.push(bad)
    } else list.push(t)
  }
  return { list, errors }
}

async function tmuxType (t, text, enter) {
  const paneId = t.paneId
  if (text.length) {
    if (text.includes('\n')) {
      // Multiline: one bracketed paste, so newlines stay newlines.
      const buffer = `conductore-${crypto.randomBytes(4).toString('hex')}`
      const load = await run('tmux', tmuxArgs(t, ['load-buffer', '-b', buffer, '-']), text)
      if (load.err) return { error: `tmux load-buffer failed: ${why(load)}` }
      const paste = await run('tmux', tmuxArgs(t, ['paste-buffer', '-p', '-d', '-b', buffer, '-t', paneId]))
      if (paste.err) return { error: `tmux paste-buffer failed: ${why(paste)}` }
    } else {
      const r = await run('tmux', tmuxArgs(t, ['send-keys', '-t', paneId, '-l', '--', text]))
      if (r.err) return { error: `tmux send-keys failed: ${why(r)}` }
    }
  }
  if (enter) {
    if (text.length) await sleep(enterDelayMs())
    const r = await run('tmux', tmuxArgs(t, ['send-keys', '-t', paneId, 'Enter']))
    if (r.err) return { error: `tmux send-keys Enter failed: ${why(r)}` }
  }
  return { ok: true }
}

async function herdrType (t, text, enter) {
  const paneId = t.paneId
  if (enter && text.length) {
    // Herdr's own submit: handles multiline and refuses a blocked agent.
    const r = await herdr(t, ['agent', 'prompt', paneId, text])
    if (r.err) return { error: `herdr agent prompt failed: ${why(r)}` }
    return { ok: true }
  }
  if (text.length) {
    const r = await herdr(t, ['pane', 'send-text', paneId, text])
    if (r.err) return { error: `herdr pane send-text failed: ${why(r)}` }
  }
  if (enter) {
    const r = await herdr(t, ['pane', 'send-keys', paneId, 'enter'])
    if (r.err) return { error: `herdr pane send-keys failed: ${why(r)}` }
  }
  return { ok: true }
}

// Types `text` into the agent's pane, then Enter unless enter === false.
// Resolves { ok, via, paneId } or { error }.
async function sendText (agent, text, { enter = true } = {}) {
  const { list, errors } = await verifiedTargets(agent)
  for (const t of list) {
    const r = t.via === 'herdr' ? await herdrType(t, text, enter) : await tmuxType(t, text, enter)
    if (r.ok) return { ok: true, via: t.via, paneId: t.paneId }
    log('pane', r.error)
    errors.push(r.error)
    // A blocked agent is showing a prompt; typing there through tmux would
    // answer it. Stop instead.
    if (/agent_blocked/.test(r.error)) break
  }
  return { error: errors.join('; ') }
}

// Sends one key (Escape for `interrupt`).
async function sendKey (agent, key) {
  const names = { escape: { tmux: 'Escape', herdr: 'esc' } }[key]
  if (!names) return { error: `unknown key ${key}` }
  const { list, errors } = await verifiedTargets(agent)
  for (const t of list) {
    const r = t.via === 'herdr'
      ? await herdr(t, ['pane', 'send-keys', t.paneId, names.herdr])
      : await run('tmux', tmuxArgs(t, ['send-keys', '-t', t.paneId, names.tmux]))
    if (!r.err) return { ok: true, via: t.via, paneId: t.paneId }
    errors.push(`${t.via} send-keys failed: ${why(r)}`)
  }
  return { error: errors.join('; ') }
}

// Brings the agent's pane to the front (Herdr, else its tmux window and pane).
// Resolves { ok, via, paneId, target? } or { error }.
async function focus (agent) {
  const { list, errors } = await verifiedTargets(agent)
  for (const t of list) {
    if (t.via === 'herdr') {
      const r = await herdr(t, ['agent', 'focus', t.paneId])
      if (!r.err) return { ok: true, via: 'herdr', paneId: t.paneId }
      log('pane', 'herdr focus failed', why(r))
      errors.push(`herdr agent focus failed: ${why(r)}`)
      continue
    }
    // By pane id: the recorded session:window may have been renumbered.
    const r1 = await run('tmux', tmuxArgs(t, ['select-window', '-t', t.paneId]))
    if (r1.err) return { error: `tmux select-window failed: ${why(r1)}` }
    const r2 = await run('tmux', tmuxArgs(t, ['select-pane', '-t', t.paneId]))
    if (r2.err) return { error: `tmux select-pane failed: ${why(r2)}` }
    const target = agent.tmux.session != null ? `${agent.tmux.session}:${agent.tmux.window}` : null
    return { ok: true, via: 'tmux', target, paneId: t.paneId }
  }
  return { error: errors.join('; ') }
}

module.exports = { sendText, sendKey, focus, targets, verifiedTargets, MAX_TEXT }
