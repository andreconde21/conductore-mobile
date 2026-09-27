'use strict'

// `conductore-hostd <command>`: JSON on stdout, exit 0; {"error"} and exit 1 on failure.

const fs = require('fs')
const os = require('os')
const path = require('path')
const { execFile } = require('child_process')
const paths = require('./paths')
const client = require('./client')
const state = require('./state')
const { log } = require('./log')

// Loaded on first use: the daemon process never needs them.
const lazy = name => { let m; return () => m || (m = require(name)) }
const settingsMod = lazy('./settings')
const transcriptMod = lazy('./transcript')
const paneMod = lazy('./pane')
const statuslineMod = lazy('./statusline')
const spoolMod = lazy('./spool')
const portsMod = lazy('./ports')
const usageMod = lazy('./usage')
const summarizeMod = lazy('./summarize')
const guideMod = lazy('./guide')

const USAGE = `usage: conductore-hostd <command>

  status                          agents and pending permission requests
  events --since <seq> [--timeout 55]
                                  long-poll: one JSON line per change
  decide <requestId> allow|deny|always [--message "..."]
  focus <sessionId>               select the agent's tmux window / Herdr pane
  transcript <sessionId> [--since <offset> | --before <offset>]
             [--tail-bytes N] [--max-bytes 262144]
                                  chat entries from the session's transcript
  send <sessionId> [--text "..." | --text-b64 <base64>] [--no-enter]
                                  type a prompt into the agent's pane (text
                                  from stdin when neither flag is given)
  interrupt <sessionId>           press Escape in the agent's pane
  ports [--since <seq>]           TCP ports your own processes listen on
                                  (dev servers), each with the seq it
                                  first appeared at; --since: only newer
  usage [--days 7] [--since <iso>] [--max-bytes N] [--max-ms N]
                                  Claude Code / Codex limits, context per
                                  session, tokens and estimated cost per
                                  day, project and model (incremental scan)
  summarize [--max-words 45] [--timeout-ms 20000]
                                  a spoken one- or two-sentence summary of
                                  the reply on stdin (claude -p, no tools)
  guide [--timeout-ms 15000]      the voice guide: one action for the
                                  {utterance, context} JSON on stdin
                                  (claude -p, no tools)
  statusline [--chain '<cmd>']    legacy Node statusLine command (install
                                  now registers bin/conductore-statusline)
  install | uninstall             register / remove the Claude Code hooks
  doctor | stop | version
`

function out (obj) {
  process.stdout.write(JSON.stringify(obj) + '\n')
  return 0
}

function fail (msg) {
  process.stdout.write(JSON.stringify({ error: msg }) + '\n')
  return 1
}

function parseFlags (args) {
  const flags = {}
  const positional = []
  for (let i = 0; i < args.length; i++) {
    const a = args[i]
    if (a.startsWith('--')) {
      const eq = a.indexOf('=')
      if (eq !== -1) flags[a.slice(2, eq)] = a.slice(eq + 1)
      else flags[a.slice(2)] = args[i + 1] !== undefined && !args[i + 1].startsWith('--') ? args[++i] : true
    } else positional.push(a)
  }
  return { flags, positional }
}

const binPath = name => path.join(__dirname, '..', 'bin', name)
const hookBinPath = () => binPath('conductore-hook')
const statuslineBinPath = () => binPath('conductore-statusline')

function readSnapshotFile () {
  const snap = JSON.parse(fs.readFileSync(paths.statePath(), 'utf8'))
  const st = state.createState()
  st.seq = Number(snap.seq) || 0
  for (const a of snap.agents || []) if (a && a.sessionId) st.agents[a.sessionId] = a
  state.prune(st)
  return { ...state.snapshot(st), seq: st.seq, source: 'snapshot', writtenAt: snap.writtenAt || null }
}

async function status () {
  try {
    const [res] = await client.request({ op: 'status' }, { timeoutMs: 5000 })
    if (res && !res.error) return out(res)
  } catch {}
  // Events are waiting in the spool (the daemon is starting, or exited
  // idle): start it and let it apply them rather than print stale state.
  if (spoolMod().isSpooled(paths.spoolDir())) {
    try {
      await client.ensureDaemon()
      const [res] = await client.request({ op: 'status' }, { timeoutMs: 5000 })
      if (res && !res.error) return out(res)
    } catch {}
  }
  try {
    return out(readSnapshotFile())
  } catch (err) {
    if (err.code === 'ENOENT') return out({ version: paths.PROTOCOL_VERSION, seq: 0, agents: [], source: 'none' })
    return fail(`cannot read snapshot: ${err.message}`)
  }
}

async function events (args) {
  const { flags } = parseFlags(args)
  const since = flags.since !== undefined ? Number(flags.since) : undefined
  const timeout = flags.timeout !== undefined ? Number(flags.timeout) : 55
  if (flags.since !== undefined && !Number.isFinite(since)) return fail('--since must be a number')
  try {
    await client.ensureDaemon()
    await client.request({ op: 'events', since, timeout }, {
      onLine: line => process.stdout.write(JSON.stringify(line) + '\n'),
      timeoutMs: (timeout + 15) * 1000
    })
    return 0
  } catch (err) {
    return fail(err.message)
  }
}

async function decide (args) {
  const { flags, positional } = parseFlags(args)
  const [requestId, decision] = positional
  if (!requestId || !decision) return fail('usage: decide <requestId> allow|deny|always [--message "..."]')
  try {
    const [res] = await client.request({ op: 'decide', requestId, decision, message: flags.message || null }, { timeoutMs: 5000 })
    if (!res || res.error) return fail(res ? res.error : 'no reply')
    return out(res)
  } catch (err) {
    return fail(`daemon not reachable: ${err.message}`)
  }
}

function run (cmd, args) {
  return new Promise(resolve => {
    execFile(cmd, args, { timeout: 5000 }, (err, stdout, stderr) => resolve({ err, stdout, stderr }))
  })
}

// The agent record for sessionId from the daemon, else the snapshot file.
// Resolves { agent } or { error }.
async function findAgent (sessionId) {
  let snap
  try { [snap] = await client.request({ op: 'status' }, { timeoutMs: 5000 }) } catch {}
  if (!snap || snap.error) {
    try { snap = readSnapshotFile() } catch { return { error: 'no state available' } }
  }
  const agent = (snap.agents || []).find(a => a.sessionId === sessionId)
  if (!agent) return { error: `unknown session ${sessionId}` }
  return { agent }
}

async function focus (args) {
  const [sessionId] = args
  if (!sessionId) return fail('usage: focus <sessionId>')
  const found = await findAgent(sessionId)
  if (found.error) return fail(found.error)
  const agent = found.agent
  if (agent.herdr && agent.herdr.paneId) {
    const r = await run('herdr', ['agent', 'focus', agent.herdr.paneId])
    if (!r.err) return out({ ok: true, via: 'herdr', paneId: agent.herdr.paneId })
    log('cli', 'herdr focus failed', (r.stderr || r.err.message).trim())
  }
  if (agent.tmux && agent.tmux.session) {
    const target = `${agent.tmux.session}:${agent.tmux.window}`
    const r1 = await run('tmux', ['select-window', '-t', target])
    if (r1.err) return fail(`tmux select-window failed: ${(r1.stderr || r1.err.message).trim()}`)
    if (agent.tmux.paneId) {
      const r2 = await run('tmux', ['select-pane', '-t', agent.tmux.paneId])
      if (r2.err) return fail(`tmux select-pane failed: ${(r2.stderr || r2.err.message).trim()}`)
    }
    return out({ ok: true, via: 'tmux', target, paneId: agent.tmux.paneId || null })
  }
  return fail('agent has no tmux or Herdr location')
}

const optNumber = (flags, name) => {
  if (flags[name] === undefined) return undefined
  const n = Number(flags[name])
  return Number.isFinite(n) && n >= 0 ? Math.floor(n) : NaN
}

async function transcriptCmd (args) {
  const { flags, positional } = parseFlags(args)
  const [sessionId] = positional
  if (!sessionId) return fail('usage: transcript <sessionId> [--since <offset> | --before <offset>] [--tail-bytes N] [--max-bytes N]')
  const opts = {}
  for (const [flag, key] of [['since', 'since'], ['before', 'before'], ['tail-bytes', 'tailBytes'], ['max-bytes', 'maxBytes']]) {
    const n = optNumber(flags, flag)
    if (Number.isNaN(n)) return fail(`--${flag} must be a non-negative number`)
    if (n !== undefined) opts[key] = n
  }
  if (opts.since !== undefined && opts.before !== undefined) return fail('use --since or --before, not both')
  const found = await findAgent(sessionId)
  if (found.error) return fail(found.error)
  const file = found.agent.transcriptPath
  if (!file) return fail('no transcript recorded for this session yet (it appears with the next hook event)')
  if (!path.isAbsolute(file) || !file.endsWith('.jsonl')) return fail('transcript path is not an absolute .jsonl file')
  try {
    const a = found.agent
    // The agent's live status rides along so one poll refreshes the whole view.
    const agent = { name: a.name, state: a.state, lastMessage: a.lastMessage, startedAt: a.startedAt, updatedAt: a.updatedAt, endedAt: a.endedAt, pending: a.pending || [] }
    return out({ sessionId, agent, ...transcriptMod().readTranscript(file, opts) })
  } catch (err) {
    if (err.code === 'ENOENT') return fail(`transcript not found: ${file}`)
    return fail(`cannot read transcript: ${err.message}`)
  }
}

function readStdin () {
  return new Promise((resolve, reject) => {
    if (process.stdin.isTTY) return resolve('')
    let data = ''
    process.stdin.setEncoding('utf8')
    process.stdin.on('data', d => {
      data += d
      if (data.length > paneMod().MAX_TEXT * 4) { process.stdin.destroy(); reject(new Error('text too long')) }
    })
    process.stdin.on('end', () => resolve(data))
    process.stdin.on('error', reject)
  })
}

// An agent that can take typed input: known, alive, in tmux or Herdr.
async function inputAgent (sessionId, { allowPermission = false } = {}) {
  const found = await findAgent(sessionId)
  if (found.error) return found
  const agent = found.agent
  if (agent.state === 'ended') return { error: 'session has ended' }
  if (!allowPermission && agent.state === 'needs_permission') {
    return { error: 'agent is waiting for a permission decision; answer it first' }
  }
  if (!paneMod().targets(agent).length) return { error: 'session not in tmux or Herdr' }
  return { agent }
}

async function send (args) {
  const { flags, positional } = parseFlags(args)
  const [sessionId] = positional
  if (!sessionId) return fail('usage: send <sessionId> [--text "..." | --text-b64 <base64>] [--no-enter]')
  let text
  if (typeof flags['text-b64'] === 'string') text = Buffer.from(flags['text-b64'], 'base64').toString('utf8')
  else if (typeof flags.text === 'string') text = flags.text
  else if (flags.text === true) text = ''
  else {
    try { text = await readStdin() } catch (err) { return fail(err.message) }
    text = text.replace(/\r?\n$/, '')
  }
  text = text.replace(/\r\n?/g, '\n')
  const enter = !flags['no-enter']
  if (!text.length && !enter) return fail('nothing to send')
  if (text.length > paneMod().MAX_TEXT) return fail(`text too long (${text.length} > ${paneMod().MAX_TEXT} characters)`)
  const found = await inputAgent(sessionId)
  if (found.error) return fail(found.error)
  const r = await paneMod().sendText(found.agent, text, { enter })
  if (r.error) return fail(r.error)
  return out({ ok: true, sessionId, via: r.via, paneId: r.paneId, chars: text.length, enter })
}

async function interrupt (args) {
  const [sessionId] = parseFlags(args).positional
  if (!sessionId) return fail('usage: interrupt <sessionId>')
  // Escape also dismisses a permission prompt, so it is allowed then.
  const found = await inputAgent(sessionId, { allowPermission: true })
  if (found.error) return fail(found.error)
  const r = await paneMod().sendKey(found.agent, 'escape')
  if (r.error) return fail(r.error)
  return out({ ok: true, sessionId, via: r.via, paneId: r.paneId, key: 'Escape' })
}

// The agents the daemon knows (their statusline usage), without starting
// it: the daemon when it runs, else the last snapshot.
async function knownAgents () {
  try {
    const [res] = await client.request({ op: 'status' }, { timeoutMs: 2000 })
    if (res && !res.error) return res.agents || []
  } catch {}
  try { return readSnapshotFile().agents || [] } catch { return [] }
}

async function usageCmd (args) {
  const { flags } = parseFlags(args)
  const opts = {}
  for (const [flag, key] of [['days', 'days'], ['max-bytes', 'maxBytes'], ['max-ms', 'maxMs']]) {
    const n = optNumber(flags, flag)
    if (Number.isNaN(n) || n === 0) return fail(`--${flag} must be a positive number`)
    if (n !== undefined) opts[key] = n
  }
  if (flags.since !== undefined) {
    const since = Date.parse(flags.since)
    if (!Number.isFinite(since)) return fail('--since must be an ISO date or time')
    opts.since = since
  }
  // Scanning is background work: never compete with the agents.
  try { os.setPriority(0, 10) } catch {}
  try {
    paths.ensureDirs()
    opts.agents = await knownAgents()
    opts.cacheFile = paths.usageCachePath()
    return out({ version: paths.VERSION, ...usageMod().compute(opts) })
  } catch (err) {
    return fail(`usage failed: ${err.message}`)
  }
}

// Always exits 0 with one JSON line: {summary} or {error, message}.
async function summarizeCmd (args) {
  const sm = summarizeMod()
  const { flags } = parseFlags(args)
  const opts = {}
  for (const [flag, key, min, max] of [['max-words', 'maxWords', 5, 200], ['timeout-ms', 'timeoutMs', 1000, 120000]]) {
    const n = optNumber(flags, flag)
    if (n === undefined) continue
    if (Number.isNaN(n) || n < min || n > max) return out({ schema: sm.SCHEMA, error: 'failed', message: `--${flag} must be between ${min} and ${max}` })
    opts[key] = n
  }
  const timeoutMs = opts.timeoutMs || sm.DEFAULT_TIMEOUT_MS
  // Background work: never compete with the agents (claude inherits it).
  try { os.setPriority(0, 10) } catch {}
  let child = null
  const onSignal = () => {
    if (child) sm.killGroup(child, 'SIGKILL')
    process.exit(1)
  }
  for (const sig of ['SIGHUP', 'SIGINT', 'SIGTERM']) process.once(sig, onSignal)
  try {
    paths.ensureDirs()
    const { text } = await sm.readInput(process.stdin, timeoutMs)
    return out(await sm.summarize({
      ...opts,
      input: text,
      timeoutMs,
      lockFile: path.join(paths.homeDir(), 'summarize.lock'),
      onChild: c => { child = c }
    }))
  } catch (err) {
    return out({ schema: sm.SCHEMA, error: 'failed', message: String(err.message).slice(0, 200) })
  } finally {
    for (const sig of ['SIGHUP', 'SIGINT', 'SIGTERM']) process.removeListener(sig, onSignal)
  }
}

// Always exits 0 with one JSON line: {action} or {error, message}.
async function guideCmd (args) {
  const gm = guideMod()
  const sm = summarizeMod()
  const { flags } = parseFlags(args)
  let timeoutMs = gm.DEFAULT_TIMEOUT_MS
  const n = optNumber(flags, 'timeout-ms')
  if (n !== undefined) {
    if (Number.isNaN(n) || n < 1000 || n > 120000) return out({ schema: gm.SCHEMA, error: 'failed', message: '--timeout-ms must be between 1000 and 120000' })
    timeoutMs = n
  }
  // Background work: never compete with the agents (claude inherits it).
  try { os.setPriority(0, 10) } catch {}
  let child = null
  const onSignal = () => {
    if (child) sm.killGroup(child, 'SIGKILL')
    process.exit(1)
  }
  for (const sig of ['SIGHUP', 'SIGINT', 'SIGTERM']) process.once(sig, onSignal)
  try {
    paths.ensureDirs()
    const { text, truncated } = await sm.readInput(process.stdin, timeoutMs)
    if (truncated) return out({ schema: gm.SCHEMA, error: 'failed', message: `stdin is larger than ${gm.MAX_INPUT_BYTES} bytes` })
    return out(await gm.guide({
      input: text,
      timeoutMs,
      lockFile: path.join(paths.homeDir(), 'guide.lock'),
      onChild: c => { child = c }
    }))
  } catch (err) {
    return out({ schema: gm.SCHEMA, error: 'failed', message: String(err.message).slice(0, 200) })
  } finally {
    for (const sig of ['SIGHUP', 'SIGINT', 'SIGTERM']) process.removeListener(sig, onSignal)
  }
}

async function portsCmd (args) {
  const { flags } = parseFlags(args)
  const since = optNumber(flags, 'since')
  if (Number.isNaN(since)) return fail('--since must be a non-negative number')
  try {
    return out(await portsMod().ports({ since, file: paths.portsPath() }))
  } catch (err) {
    return fail(`cannot list ports: ${err.message}`)
  }
}

function readAll (stream, timeoutMs) {
  return new Promise(resolve => {
    if (stream.isTTY) return resolve('')
    let data = ''
    const timer = setTimeout(() => resolve(data), timeoutMs)
    stream.setEncoding('utf8')
    stream.on('data', d => { if (data.length < 1024 * 1024) data += d })
    stream.on('end', () => { clearTimeout(timer); resolve(data) })
    stream.on('error', () => { clearTimeout(timer); resolve(data) })
  })
}

// Runs the user's previous statusline command with the same stdin and
// returns its stdout unchanged ('' if it fails).
function runChain (cmd, input) {
  return new Promise(resolve => {
    const { spawn } = require('child_process')
    let stdout = ''
    let done = false
    const finish = () => { if (!done) { done = true; clearTimeout(timer); resolve(stdout) } }
    // The chained command is the user's own shell command line, as Claude
    // Code itself would run it, so it goes through sh -c.
    const child = spawn('sh', ['-c', cmd], { stdio: ['pipe', 'pipe', 'ignore'] })
    const timer = setTimeout(() => { child.kill(); finish() }, 5000)
    child.stdout.on('data', d => { stdout += d })
    child.on('error', finish)
    child.on('close', finish)
    child.stdin.on('error', () => {})
    child.stdin.end(input)
  })
}

// Never fails visibly: Claude Code shows whatever this prints.
async function statuslineCmd (args) {
  const { flags } = parseFlags(args)
  const raw = await readAll(process.stdin, 2000)
  let input = null
  try { input = JSON.parse(raw) } catch {}
  const report = (async () => {
    if (!input || typeof input.session_id !== 'string') return
    const req = { op: 'usage', sessionId: input.session_id, usage: statuslineMod().usageFrom(input) }
    try {
      await client.request(req, { timeoutMs: 1500 })
    } catch (err) {
      // Daemon down: start it for the next report, like the hooks do.
      log('statusline', 'usage report failed', err.message)
      try { client.spawnDaemon() } catch {}
    }
  })()
  let line
  if (typeof flags.chain === 'string' && flags.chain.trim()) line = await runChain(flags.chain, raw)
  else line = statuslineMod().defaultLine(input) + '\n'
  await report
  process.stdout.write(line)
  return 0
}

// The node binary the sh clients use to start the daemon: hooks may run
// with a PATH that has no node (Claude Code's native build).
function recordNodePath () {
  const file = paths.nodePathFile()
  try {
    if (fs.readFileSync(file, 'utf8').trim() === process.execPath) return
  } catch {}
  fs.writeFileSync(file, process.execPath + '\n', { mode: 0o600 })
}

function install () {
  const settings = settingsMod()
  const statusline = statuslineMod()
  const file = settings.settingsPath()
  let current
  try { current = settings.readSettings(file) } catch (err) { return fail(err.message) }
  const hookBin = hookBinPath()
  const slBin = statuslineBinPath()
  for (const bin of [hookBin, slBin]) if (!fs.existsSync(bin)) return fail(`client not found at ${bin}`)
  // Replaces every earlier conductore handler (any path, the Node hook of
  // 0.3 and older) and moves a `conductore-hostd statusline` line to the sh
  // statusline, keeping the command it wraps.
  const merged = settings.merge(current, hookBin)
  const sl = statusline.merge(merged, slBin)
  const before = JSON.stringify(current)
  if (JSON.stringify(sl.settings) !== before) {
    try { settings.writeSettings(sl.settings, file) } catch (err) { return fail(`cannot write ${file}: ${err.message}`) }
  }
  paths.ensureDirs()
  try { recordNodePath() } catch (err) { return fail(`cannot write ${paths.nodePathFile()}: ${err.message}`) }
  return out({ ok: true, settings: file, hook: hookBin, statusline: slBin, events: settings.EVENTS, statusLine: sl.action })
}

async function uninstall () {
  const settings = settingsMod()
  const statusline = statuslineMod()
  const file = settings.settingsPath()
  let current
  try { current = settings.readSettings(file) } catch (err) { return fail(err.message) }
  const before = settings.installed(current)
  const hadStatusLine = statusline.isOurs(current.statusLine)
  if (before.length || hadStatusLine) {
    try { settings.writeSettings(statusline.unmerge(settings.unmerge(current)), file) } catch (err) { return fail(`cannot write ${file}: ${err.message}`) }
  }
  let stopped = false
  try { await client.request({ op: 'stop' }, { timeoutMs: 3000 }); stopped = true } catch {}
  return out({ ok: true, settings: file, removed: before, statusLineRestored: hadStatusLine, daemonStopped: stopped })
}

async function stop () {
  try {
    await client.request({ op: 'stop' }, { timeoutMs: 3000 })
    return out({ ok: true, running: true, stopped: true })
  } catch {
    return out({ ok: true, running: false })
  }
}

const median = xs => xs.slice().sort((a, b) => a - b)[Math.floor(xs.length / 2)]

// Wall time of one no-op hook event (no session_id, so the daemon drops it),
// median of five runs, measured around the spawn.
function hookLatencyMs (hookBin) {
  const { spawnSync } = require('child_process')
  const input = JSON.stringify({ hook_event_name: 'DoctorPing' }) + '\n'
  const runs = []
  for (let i = 0; i < 5; i++) {
    const t0 = process.hrtime.bigint()
    const r = spawnSync(hookBin, ['DoctorPing'], { input, stdio: ['pipe', 'ignore', 'ignore'], timeout: 5000 })
    if (r.error || r.status !== 0) return null
    runs.push(Number(process.hrtime.bigint() - t0) / 1e6)
  }
  return median(runs)
}

async function doctor () {
  const settings = settingsMod()
  const statusline = statuslineMod()
  const checks = []
  const add = (name, ok, detail) => checks.push({ name, ok, detail })
  const major = Number(process.versions.node.split('.')[0])
  add('node', major >= 18, `node ${process.versions.node} (need >= 18)`)
  let recorded = null
  try { recorded = fs.readFileSync(paths.nodePathFile(), 'utf8').trim() } catch {}
  add('node for hooks', !!recorded && fs.existsSync(recorded), recorded ? `${recorded} (${paths.nodePathFile()})` : 'not recorded; run install')
  const hookBin = hookBinPath()
  const slBin = statuslineBinPath()
  add('hook client', fs.existsSync(hookBin), hookBin)
  add('statusline client', fs.existsSync(slBin), slBin)
  const mkfifo = await run('sh', ['-c', 'command -v mkfifo'])
  add('mkfifo', !mkfifo.err, mkfifo.err ? 'not found: permission prompts cannot wait for the phone' : mkfifo.stdout.trim())
  for (const bin of ['conductore-hostd', 'conductore-hook']) {
    const r = await run('sh', ['-c', `command -v ${bin}`])
    add(`${bin} on PATH`, !r.err, r.err ? 'not found in a non-login shell PATH (see README: SSH exec PATH)' : r.stdout.trim())
  }
  let cfg = {}
  try { cfg = settings.readSettings(); add('settings.json', true, settings.settingsPath()) } catch (err) { add('settings.json', false, err.message) }
  const present = settings.installed(cfg)
  const missing = settings.EVENTS.filter(e => !present.includes(e))
  add('hooks registered', missing.length === 0, missing.length ? `missing: ${missing.join(', ')}` : `${present.length} events`)
  const sl = statusline.describe(cfg)
  add('statusline (usage)', sl.wired, sl.detail)
  try {
    const [res] = await client.request({ op: 'ping' }, { timeoutMs: 2000 })
    add('daemon', !!(res && res.ok), `pid ${res && res.pid}, seq ${res && res.seq}, ${paths.socketPath()}`)
    if (res && typeof res.rss === 'number') {
      add('daemon memory', true, `${(res.rss / 1048576).toFixed(1)} MB RSS, ${res.cpuMs} ms CPU in ${res.uptimeS} s, version ${res.version}`)
    }
  } catch (err) {
    add('daemon', false, `not running (${err.code || err.message}); it starts on the next hook event`)
  }
  // After the ping: with no daemon, this starts one.
  if (fs.existsSync(hookBin)) {
    const ms = hookLatencyMs(hookBin)
    add('hook latency', ms !== null, ms === null ? 'the hook client failed' : `${ms.toFixed(1)} ms per event (median of 5, no-op event)`)
  }
  try {
    const st = fs.statSync(paths.socketPath())
    add('socket mode', (st.mode & 0o077) === 0, `${paths.socketPath()} mode ${(st.mode & 0o777).toString(8)}`)
  } catch {}
  add('state file', fs.existsSync(paths.statePath()), paths.statePath())
  add('log file', true, paths.logPath())
  const tmux = await run('tmux', ['-V'])
  add('tmux', !tmux.err, tmux.err ? 'not found (tmux focus unavailable)' : tmux.stdout.trim())
  const herdr = await run('herdr', ['--version'])
  add('herdr', !herdr.err, herdr.err ? 'not found (optional)' : herdr.stdout.trim().split('\n')[0])
  const claude = await run('claude', ['--version'])
  add('claude', !claude.err, claude.err ? 'not found on PATH' : claude.stdout.trim())
  const optional = ['herdr', 'tmux', 'daemon', 'daemon memory', 'state file', 'claude', 'statusline (usage)', 'hook latency', 'node for hooks']
  const ok = checks.filter(c => !c.ok && !optional.includes(c.name)).length === 0
  return out({ ok, user: os.userInfo().username, checks })
}

// `daemon`: runs the daemon in this process. `daemon --detach`: starts it in
// the background with the memory flags and returns at once (what the sh
// clients call).
function daemonCmd (args) {
  if (args.includes('--detach')) {
    client.spawnDaemon()
    return 0
  }
  require('./daemon').run()
  return null
}

async function main (argv) {
  const [cmd, ...args] = argv
  switch (cmd) {
    case 'daemon': return daemonCmd(args)
    case 'status': return status()
    case 'events': return events(args)
    case 'decide': return decide(args)
    case 'focus': return focus(args)
    case 'transcript': return transcriptCmd(args)
    case 'send': return send(args)
    case 'interrupt': return interrupt(args)
    case 'ports': return portsCmd(args)
    case 'usage': return usageCmd(args)
    case 'summarize': return summarizeCmd(args)
    case 'guide': return guideCmd(args)
    case 'statusline': return statuslineCmd(args)
    case 'install': return install()
    case 'uninstall': return uninstall()
    case 'doctor': return doctor()
    case 'stop': return stop()
    case 'version': return out({ version: paths.VERSION, protocol: paths.PROTOCOL_VERSION, node: process.versions.node })
    case 'help': case '--help': case '-h': case undefined:
      process.stdout.write(USAGE); return cmd === undefined ? 1 : 0
    default: return fail(`unknown command ${cmd}\n${USAGE}`)
  }
}

module.exports = { main }
