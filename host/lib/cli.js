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
const digestMod = lazy('./digest')
const cswapMod = lazy('./cswap')
const rulesMod = lazy('./rules')
const riskMod = lazy('./risk')
const reviewMod = lazy('./review')

const USAGE = `usage: conductore-hostd <command>

  status                          agents and pending permission requests
  events --since <seq> [--timeout 55]
                                  long-poll: one JSON line per change
  decide <requestId> allow|deny|always [--message "..."]
  approve-low [--ids <id,id,...>] [--session <sessionId>]
                                  allow every waiting low-risk request (only
                                  the listed ones with --ids); others skipped
  trust <requestId> [--rule 'Tool(pattern)'] [--scope repo|session|any]
        [--minutes 60 | --until-session-end | --forever] [--path <dir>]
                                  save a rule from a waiting request, allow it
                                  and every waiting request the rule covers
  rules [list]                    approval rules and time-boxed trust
  rules add 'Tool(pattern)' [--scope any|repo|session] [--path <dir>]
            [--session <id>] [--minutes N | --until-session-end]
  rules edit <ruleId> [--rule '…'] [--scope …] [--path …] [--minutes N | --forever]
  rules remove <ruleId>           revoke a rule (also: rm, revoke)
  approvals [--hours 24]          rules plus what they auto-approved
  classify [--tool Bash] [--command '…' | --file <path> | --url <url>]
           [--cwd <dir>]          risk label and rule suggestions for a tool
                                  call (JSON {tool_name, tool_input, cwd} on
                                  stdin when no --tool); runs no daemon
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
                                  day, project and model (incremental scan);
                                  with cswap, every Claude account's limits
  cswap-switch <slot> | --best    switch the Claude account for new
                                  sessions (cswap switch)
  summarize [--max-words 45] [--timeout-ms 20000]
                                  a spoken one- or two-sentence summary of
                                  the reply on stdin (claude -p, no tools)
  digest [--since <ms>] [--summaries] [--max-agents 10] [--max-ms 30000]
         [--lang en|pt] [--stuck-working-min 30] [--stuck-errors 3]
         [--stuck-repeats 5] [--stuck-approval-min 60]
                                  every agent's facts since a time, stuck
                                  flags, and (--summaries) a short summary of
                                  the agents that changed (claude -p, no tools)
  turns <sessionId> [--limit 20]  the session's recent turns: prompt, time,
                                  files changed, snapshot refs, undo state
  diff <sessionId> <turn> [--file <path>]... [--max-bytes 1048576]
       [--max-file-bytes 65536] [--context 3]
                                  per-file unified diff of one turn (between
                                  its before and after snapshots)
  undo <sessionId> <turn> [--file <path>]... [--dry-run] [--keep-commits]
                                  restore the work tree (or those files) to
                                  before the turn; snapshots the current
                                  state first (see redo); never touches
                                  commits, branches, HEAD or the index
  redo <sessionId> <turn> [--dry-run]
                                  put back what the last undo of that turn
                                  changed
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

// One request to the daemon (started when needed); prints its reply.
async function daemonOp (req, timeoutMs = 5000) {
  try {
    await client.ensureDaemon()
    const [res] = await client.request(req, { timeoutMs })
    if (!res || res.error) return fail(res ? res.error : 'no reply')
    return out(res)
  } catch (err) {
    return fail(`daemon not reachable: ${err.message}`)
  }
}

function minutesFlag (flags) {
  if (flags.minutes === undefined) return undefined
  const m = Number(flags.minutes)
  return Number.isFinite(m) ? m : NaN
}

function scopeFlags (flags, fallbackKind) {
  const kind = typeof flags.scope === 'string' ? flags.scope : fallbackKind
  if (kind === 'repo' || kind === 'path' || kind === 'workspace') {
    const dir = typeof flags.path === 'string' ? path.resolve(flags.path) : rulesMod().repoRoot(process.cwd())
    return { kind: 'repo', path: dir }
  }
  if (kind === 'session') return { kind: 'session', sessionId: typeof flags.session === 'string' ? flags.session : undefined }
  return { kind: kind || 'any' }
}

async function approveLow (args) {
  const { flags } = parseFlags(args)
  const ids = typeof flags.ids === 'string' ? flags.ids.split(',').map(x => x.trim()).filter(Boolean) : undefined
  return daemonOp({ op: 'approve-low', ids, sessionId: typeof flags.session === 'string' ? flags.session : undefined })
}

async function trustCmd (args) {
  const { flags, positional } = parseFlags(args)
  const [requestId] = positional
  if (!requestId) return fail("usage: trust <requestId> [--rule 'Tool(pattern)'] [--scope repo|session|any] [--minutes N | --until-session-end | --forever]")
  const minutes = minutesFlag(flags)
  if (Number.isNaN(minutes)) return fail('--minutes must be a number')
  return daemonOp({
    op: 'trust',
    requestId,
    rule: typeof flags.rule === 'string' ? flags.rule : undefined,
    scope: typeof flags.scope === 'string' ? flags.scope : undefined,
    path: typeof flags.path === 'string' ? path.resolve(flags.path) : undefined,
    minutes,
    untilSessionEnd: !!flags['until-session-end'],
    forever: !!flags.forever,
    source: typeof flags.source === 'string' ? flags.source : undefined
  })
}

async function rulesCmd (args) {
  const [action = 'list', ...rest] = args
  const { flags, positional } = parseFlags(rest)
  const minutes = minutesFlag(flags)
  if (Number.isNaN(minutes)) return fail('--minutes must be a number')
  switch (action) {
    case 'list': case 'ls':
      return daemonOp({ op: 'rules', action: 'list' })
    case 'add': {
      const rule = positional[0] || flags.rule
      if (typeof rule !== 'string') return fail("usage: rules add 'Tool(pattern)' [--scope any|repo|session] [--path <dir>] [--minutes N]")
      const scope = scopeFlags(flags, 'any')
      return daemonOp({
        op: 'rules',
        action: 'add',
        spec: { rule, scope, minutes, untilSessionEnd: !!flags['until-session-end'], sessionId: typeof flags.session === 'string' ? flags.session : undefined, note: typeof flags.note === 'string' ? flags.note : undefined, source: typeof flags.source === 'string' ? flags.source : 'cli' }
      })
    }
    case 'edit': {
      const [id] = positional
      if (!id) return fail("usage: rules edit <ruleId> [--rule '…'] [--scope …] [--minutes N | --forever]")
      const patch = {}
      if (typeof flags.rule === 'string') patch.rule = flags.rule
      if (typeof flags.scope === 'string') patch.scope = scopeFlags(flags, flags.scope)
      if (minutes !== undefined) patch.minutes = minutes
      if (flags.forever) { patch.forever = true; patch.minutes = null }
      if (typeof flags.note === 'string') patch.note = flags.note
      return daemonOp({ op: 'rules', action: 'edit', id, patch })
    }
    case 'remove': case 'rm': case 'revoke': case 'delete': {
      const [id] = positional
      if (!id) return fail('usage: rules remove <ruleId>')
      return daemonOp({ op: 'rules', action: 'remove', id })
    }
    default:
      return fail(`unknown rules action ${action} (list, add, edit, remove)`)
  }
}

async function approvalsCmd (args) {
  const { flags } = parseFlags(args)
  return daemonOp({ op: 'approvals', hours: flags.hours !== undefined ? Number(flags.hours) : 24 })
}

// Pure: risk label and suggestions, no daemon.
async function classifyCmd (args) {
  const { flags } = parseFlags(args)
  let event
  if (typeof flags.tool === 'string') {
    const input = {}
    if (typeof flags.command === 'string') input.command = flags.command
    if (typeof flags.file === 'string') input.file_path = flags.file
    if (typeof flags.url === 'string') input.url = flags.url
    if (typeof flags.pattern === 'string') input.pattern = flags.pattern
    event = { tool_name: flags.tool, tool_input: input, cwd: typeof flags.cwd === 'string' ? path.resolve(flags.cwd) : process.cwd() }
  } else {
    try { event = JSON.parse(await readStdin()) } catch { return fail('classify: pass --tool, or JSON {tool_name, tool_input, cwd} on stdin') }
    if (!event || typeof event !== 'object') return fail('classify: expected a JSON object')
    if (typeof event.cwd !== 'string') event.cwd = process.cwd()
  }
  const root = rulesMod().repoRoot(event.cwd)
  const ctx = { cwd: event.cwd, root, home: os.homedir() }
  const r = riskMod().classify(event.tool_name, event.tool_input, ctx)
  return out({ risk: r, batchable: riskMod().batchable(event.tool_name, r), suggestedRules: rulesMod().suggest(event.tool_name, event.tool_input, ctx), repo: root })
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
  if (!paneMod().targets(found.agent).length) return fail('agent has no tmux or Herdr location')
  // Checks the panes first, like send (the ids may belong to someone else by now).
  const r = await paneMod().focus(found.agent)
  return r.error ? fail(r.error) : out(r)
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
    // --max-ms caps the whole call, Node's start included.
    opts.startedAt = Math.round(performance.timeOrigin)
    const result = usageMod().compute(opts)
    // Every cswap account's limits; nothing at all without cswap.
    let cswap = null
    try { cswap = await cswapMod().accounts({ cacheFile: cswapCachePath() }) } catch {}
    if (cswap) {
      const { accounts, ...meta } = cswap
      result.claude.accounts = accounts
      result.claude.cswap = meta
    }
    // The companion's own claude calls for `digest --summaries` (not in any
    // transcript: they run without session persistence).
    const digestToday = digestMod().loadStore(paths.digestPath()).usage
    if (digestToday && digestToday.date === result.today) result.companion = { digest: digestToday }
    return out({ version: paths.VERSION, ...result })
  } catch (err) {
    return fail(`usage failed: ${err.message}`)
  }
}

const cswapCachePath = () => path.join(paths.homeDir(), 'cswap-cache.json')

async function cswapSwitchCmd (args) {
  const { flags, positional } = parseFlags(args)
  const best = flags.best === true
  const slot = positional[0]
  if (best === (slot !== undefined) || (slot !== undefined && !/^[1-9][0-9]{0,3}$/.test(slot))) {
    return fail('usage: cswap-switch <slot> | --best')
  }
  try { os.setPriority(0, 10) } catch {}
  try {
    paths.ensureDirs()
    const r = await cswapMod().switchAccount({ slot: best ? undefined : Number(slot), best, cacheFile: cswapCachePath() })
    if (!r.ok) return fail(r.message)
    return out(r)
  } catch (err) {
    return fail(`cswap-switch failed: ${err.message}`)
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

// The agents and their activity: the daemon when it runs (started when
// events wait in the spool, like `status`), else state.json and
// activity.json. A daemon from before `digest` answers `status` only.
async function digestData () {
  const ask = async () => {
    const [res] = await client.request({ op: 'digest' }, { timeoutMs: 5000 })
    if (res && !res.error) return { status: res, activity: (res.activity && res.activity.agents) || {}, source: 'daemon', hasActivity: true }
    if (res && /unknown op/.test(res.error || '')) {
      const [st] = await client.request({ op: 'status' }, { timeoutMs: 5000 })
      if (st && !st.error) return { status: st, activity: {}, source: 'daemon', hasActivity: false }
    }
    return null
  }
  try { const r = await ask(); if (r) return r } catch {}
  if (spoolMod().isSpooled(paths.spoolDir())) {
    try {
      await client.ensureDaemon()
      const r = await ask()
      if (r) return r
    } catch {}
  }
  let activity = {}
  let hasActivity = false
  try {
    const a = JSON.parse(fs.readFileSync(paths.activityPath(), 'utf8'))
    if (a && a.agents) { activity = a.agents; hasActivity = true }
  } catch {}
  try {
    return { status: readSnapshotFile(), activity, source: 'snapshot', hasActivity }
  } catch {
    return { status: { agents: [] }, activity, source: 'none', hasActivity }
  }
}

// Always exits 0 with one JSON document (errors as {error, message}).
async function digestCmd (args) {
  const dm = digestMod()
  const sm = summarizeMod()
  const { flags } = parseFlags(args)
  const bad = message => out({ schema: dm.SCHEMA, error: 'failed', message })
  const opts = { summaries: flags.summaries === true, lang: flags.lang === 'pt' ? 'pt' : 'en', thresholds: {} }
  if (flags.since !== undefined) {
    const n = optNumber(flags, 'since')
    if (Number.isNaN(n)) return bad('--since must be epoch milliseconds')
    opts.since = n
  }
  for (const [flag, key, min, max] of [['max-agents', 'maxAgents', 1, 30], ['max-ms', 'maxMs', 5000, 120000]]) {
    const n = optNumber(flags, flag)
    if (n === undefined) continue
    if (Number.isNaN(n) || n < min || n > max) return bad(`--${flag} must be between ${min} and ${max}`)
    opts[key] = n
  }
  for (const [flag, key, max] of [['stuck-working-min', 'workingMin', 1440], ['stuck-errors', 'sameError', 100], ['stuck-repeats', 'sameCommand', 100], ['stuck-approval-min', 'approvalMin', 1440]]) {
    const n = optNumber(flags, flag)
    if (n === undefined) continue
    if (Number.isNaN(n) || n < 1 || n > max) return bad(`--${flag} must be between 1 and ${max}`)
    opts.thresholds[key] = n
  }
  // Background work: never compete with the agents (claude and git inherit it).
  try { os.setPriority(0, 10) } catch {}
  let child = null
  const onSignal = () => {
    if (child) sm.killGroup(child, 'SIGKILL')
    process.exit(1)
  }
  for (const sig of ['SIGHUP', 'SIGINT', 'SIGTERM']) process.once(sig, onSignal)
  try {
    paths.ensureDirs()
    const data = await digestData()
    // The newer hooks this machine has registered; without them failures
    // and API errors are read from the transcripts.
    let registered = []
    try { registered = settingsMod().installed(settingsMod().readSettings()) } catch {}
    return out({
      version: paths.VERSION,
      ...await dm.digest({
        ...opts,
        data,
        hooks: { failures: registered.includes('PostToolUseFailure'), stopFailure: registered.includes('StopFailure') },
        storeFile: paths.digestPath(),
        lockFile: path.join(paths.homeDir(), 'digest.lock'),
        onChild: c => { child = c }
      })
    })
  } catch (err) {
    return bad(String(err.message).slice(0, 200))
  } finally {
    for (const sig of ['SIGHUP', 'SIGINT', 'SIGTERM']) process.removeListener(sig, onSignal)
  }
}

// --file may repeat.
function fileFlags (args) {
  const files = []
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--file' && typeof args[i + 1] === 'string') files.push(args[++i])
    else if (args[i].startsWith('--file=')) files.push(args[i].slice(7))
  }
  return files
}

function turnArg (value) {
  const n = Number(value)
  return Number.isInteger(n) && n > 0 ? n : null
}

async function reviewCmd (cmd, args) {
  const { flags, positional } = parseFlags(args)
  const [sessionId, turnText] = positional
  const n = turnArg(turnText)
  const usage = {
    turns: 'usage: turns <sessionId> [--limit 20]',
    diff: 'usage: diff <sessionId> <turn> [--file <path>]... [--max-bytes N] [--max-file-bytes N] [--context 3]',
    undo: 'usage: undo <sessionId> <turn> [--file <path>]... [--dry-run] [--keep-commits]',
    redo: 'usage: redo <sessionId> <turn> [--dry-run]'
  }[cmd]
  if (!sessionId || (cmd !== 'turns' && !n)) return fail(usage)
  const num = name => (flags[name] === undefined ? undefined : optNumber(flags, name))
  for (const name of ['limit', 'max-bytes', 'max-file-bytes', 'context']) if (Number.isNaN(num(name))) return fail(`--${name} must be a non-negative number`)
  const review = reviewMod()
  let res
  switch (cmd) {
    case 'turns': res = await review.turnsCmd(sessionId, { limit: Math.min(num('limit') || 20, 50) }); break
    case 'diff': res = await review.diffCmd(sessionId, n, { files: fileFlags(args), maxBytes: num('max-bytes'), maxFileBytes: num('max-file-bytes'), context: num('context') }); break
    case 'undo': res = await review.undoCmd(sessionId, n, { files: fileFlags(args), dryRun: !!flags['dry-run'], keepCommits: !!flags['keep-commits'] }); break
    case 'redo': res = await review.redoCmd(sessionId, n, { dryRun: !!flags['dry-run'] }); break
  }
  if (res.error) {
    process.stdout.write(JSON.stringify(res.code ? { error: res.error, code: res.code } : { error: res.error }) + '\n')
    return 1
  }
  return out(res)
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

// The local Claude Code's version, for the hooks only newer versions
// know: { bin, version } or null (not found, no answer in 5 s, unreadable).
function claudeVersion () {
  const bin = summarizeMod().findClaude()
  if (!bin) return null
  const env = { ...process.env }
  delete env.CLAUDECODE
  try {
    const text = require('child_process').execFileSync(bin, ['--version'], { encoding: 'utf8', timeout: 5000, stdio: ['ignore', 'pipe', 'ignore'], env })
    const version = settingsMod().parseVersion(text)
    return version ? { bin, version: version.join('.') } : null
  } catch { return null }
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
  // The newer events only where this Claude Code knows them; a merge also
  // takes ours off optional events a downgraded one would not know.
  const claude = claudeVersion()
  const { events, skipped } = settings.eventsFor(claude && claude.version)
  const merged = settings.merge(current, hookBin, events)
  const sl = statusline.merge(merged, slBin)
  const before = JSON.stringify(current)
  if (JSON.stringify(sl.settings) !== before) {
    try { settings.writeSettings(sl.settings, file) } catch (err) { return fail(`cannot write ${file}: ${err.message}`) }
  }
  paths.ensureDirs()
  try { recordNodePath() } catch (err) { return fail(`cannot write ${paths.nodePathFile()}: ${err.message}`) }
  return out({ ok: true, settings: file, hook: hookBin, statusline: slBin, events, skipped, claudeVersion: claude ? claude.version : null, statusLine: sl.action })
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
  const local = claudeVersion()
  const { skipped } = settings.eventsFor(local && local.version)
  const optionalOn = settings.OPTIONAL_EVENTS.map(o => o.event).filter(e => present.includes(e))
  add('optional hooks', true, [
    optionalOn.length ? `registered: ${optionalOn.join(', ')}` : 'none registered',
    ...skipped.map(x => `${x.event} skipped (${x.reason})`),
    ...skipped.filter(x => present.includes(x.event)).map(x => `${x.event} is registered but this Claude Code may not know it: run install`),
    local ? `Claude Code ${local.version}` : 'Claude Code not found'
  ].join('; '))
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
    case 'approve-low': return approveLow(args)
    case 'trust': return trustCmd(args)
    case 'rules': return rulesCmd(args)
    case 'approvals': return approvalsCmd(args)
    case 'classify': return classifyCmd(args)
    case 'focus': return focus(args)
    case 'transcript': return transcriptCmd(args)
    case 'send': return send(args)
    case 'interrupt': return interrupt(args)
    case 'ports': return portsCmd(args)
    case 'usage': return usageCmd(args)
    case 'summarize': return summarizeCmd(args)
    case 'guide': return guideCmd(args)
    case 'digest': return digestCmd(args)
    case 'cswap-switch': return cswapSwitchCmd(args)
    case 'turns': case 'diff': case 'undo': case 'redo': return reviewCmd(cmd, args)
    case 'statusline': return statuslineCmd(args)
    case 'install': return install()
    case 'uninstall': return uninstall()
    case 'doctor': return doctor()
    case 'stop': return stop()
    case 'version': return out({ version: paths.VERSION, protocol: paths.PROTOCOL_VERSION, node: process.versions.node, capabilities: require('./approvals').CAPABILITIES })
    case 'help': case '--help': case '-h': case undefined:
      process.stdout.write(USAGE); return cmd === undefined ? 1 : 0
    default: return fail(`unknown command ${cmd}\n${USAGE}`)
  }
}

module.exports = { main }
