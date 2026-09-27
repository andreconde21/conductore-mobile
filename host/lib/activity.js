'use strict'

// Per-agent activity log for `digest`: what each agent did, as compact
// entries, so the phone can ask "what happened since <time>" without
// reading transcripts and without Claude.
//
// The daemon feeds it from the hook events it already parses (nothing runs
// at idle) and keeps it in memory, written to ~/.conductore/activity.json
// (0600) on the same debounce as state.json. Bounded: at most
// MAX_ENTRIES entries, MAX_FILES file paths and MAX_LABELS command labels
// per agent, at most MAX_AGENTS agents; an agent is kept KEEP_MS after its
// last entry, so "Done since" still shows agents the state pruned. No tool
// input is kept: a file path, the first line of a command (cut to
// LABEL_MAX), and hashes.
//
// Entry = [t, kind, ...]:
//   [t, 'p']                    UserPromptSubmit (a turn starts)
//   [t, 's']                    Stop (a turn ends)
//   [t, 'x', errorType]         StopFailure (a turn ended on an API error)
//   [t, 'e', file#, +, -]       Edit / Write / MultiEdit / NotebookEdit, with
//                               estimated lines added / removed
//   [t, 'c', cmd#, test]        Bash succeeded (test: 1 when a test runner)
//   [t, 'f', cmd#, test, err#]  a tool failed (PostToolUseFailure): cmd# is
//                               the command (Bash) or tool, err# its error
//   [t, 'S', state]             state change: w working, i waiting_input,
//                               n needs_permission, e ended

const crypto = require('crypto')
const path = require('path')

const MAX_ENTRIES = 300
const MAX_FILES = 200
const MAX_LABELS = 60
const MAX_AGENTS = 64
const LABEL_MAX = 120
const PATH_MAX = 400
const KEEP_MS = 24 * 60 * 60 * 1000

const EDIT_TOOLS = new Set(['Edit', 'Write', 'MultiEdit', 'NotebookEdit'])
const STATE_CODES = { working: 'w', waiting_input: 'i', needs_permission: 'n', ended: 'e' }

// Test runners (the command's first real word, or `<tool> test`).
const TEST_COMMAND = /(^|[\s;&|(])(npm (run )?test|yarn (run )?test|pnpm (run )?test|bun test|deno test|npx (jest|vitest|mocha|playwright test)|jest|vitest|mocha|pytest|py\.test|python3? -m (pytest|unittest)|tox|nox|go test|cargo (test|nextest)|flutter test|dart test|node --test|rspec|bundle exec rspec|rake test|phpunit|dotnet test|mvn( -\S+)* (test|verify)|gradle(w)?( -\S+)* test|\.\/gradlew( -\S+)* test|make (test|check)|ctest|swift test|mix test|elixir test|bats|busted|zig build test)(\s|$|;|&|\|)/

const hash = s => crypto.createHash('sha1').update(String(s)).digest('base64url').slice(0, 10)

function isTestCommand (command) {
  if (typeof command !== 'string') return false
  // Environment assignments and `cd dir &&` in front do not hide the runner.
  const text = command.replace(/(^|[;&|]\s*)(\w+=\S+\s+)+/g, '$1')
  return TEST_COMMAND.test(text)
}

// The first line of a command, whitespace squeezed, capped.
function commandLabel (command) {
  const line = String(command).split('\n').find(l => l.trim()) || ''
  const s = line.replace(/\s+/g, ' ').trim()
  return s.length > LABEL_MAX ? s.slice(0, LABEL_MAX - 1) + '…' : s
}

// A failure's identity: its first meaningful line with numbers, hex ids and
// paths' line:column parts blanked, so "the same error" matches across runs.
function errorSignature (error) {
  const text = typeof error === 'string' ? error : (error ? JSON.stringify(error) : '')
  const lines = text.split('\n').map(l => l.trim()).filter(l => l && !/^exit code \d+$/i.test(l))
  const first = lines[0] || text.trim()
  return first.replace(/0x[0-9a-f]+|\b[0-9a-f]{8,}\b|\d+(\.\d+)?/gi, '#').slice(0, 200)
}

const lineCount = s => (typeof s === 'string' && s.length ? s.split('\n').length - (s.endsWith('\n') ? 1 : 0) : 0)

// Lines added and removed by replacing `before` with `after`: the lines the
// two do not share at the start and the end.
function lineDelta (before, after) {
  const a = typeof before === 'string' && before.length ? before.split('\n') : []
  const b = typeof after === 'string' && after.length ? after.split('\n') : []
  let head = 0
  while (head < a.length && head < b.length && a[head] === b[head]) head++
  let tail = 0
  while (tail < a.length - head && tail < b.length - head && a[a.length - 1 - tail] === b[b.length - 1 - tail]) tail++
  return [b.length - head - tail, a.length - head - tail]
}

// [added, removed] estimated from an edit tool's input.
function editDelta (tool, input) {
  if (!input || typeof input !== 'object') return [0, 0]
  switch (tool) {
    case 'Write': return [lineCount(input.content), 0]
    case 'Edit': return lineDelta(input.old_string, input.new_string)
    case 'MultiEdit': {
      let add = 0; let del = 0
      for (const e of Array.isArray(input.edits) ? input.edits : []) {
        const [x, y] = lineDelta(e && e.old_string, e && e.new_string)
        add += x; del += y
      }
      return [add, del]
    }
    case 'NotebookEdit':
      return input.edit_mode === 'delete' ? [0, lineCount(input.old_source)] : [lineCount(input.new_source), 0]
    default: return [0, 0]
  }
}

function editPath (input) {
  if (!input || typeof input !== 'object') return null
  const p = input.file_path || input.notebook_path || input.path
  return typeof p === 'string' && p ? p.slice(0, PATH_MAX) : null
}

class Activity {
  constructor (data) {
    this.agents = {}
    this.dirty = false
    if (data && data.agents && typeof data.agents === 'object') {
      for (const [sid, a] of Object.entries(data.agents)) {
        if (a && Array.isArray(a.ev)) this.agents[sid] = { ev: a.ev, files: Array.isArray(a.files) ? a.files : [], labels: a.labels && typeof a.labels === 'object' ? a.labels : {}, state: a.state || null, meta: a.meta || null, dropped: Number(a.dropped) || 0, since: Number(a.since) || null }
      }
    }
  }

  agent (sid) {
    let a = this.agents[sid]
    if (!a) {
      a = this.agents[sid] = { ev: [], files: [], labels: {}, state: null, meta: null, dropped: 0, since: null }
      const sids = Object.keys(this.agents)
      if (sids.length > MAX_AGENTS) {
        // Drop the agent heard from least recently.
        const last = s => { const ev = this.agents[s].ev; return ev.length ? ev[ev.length - 1][0] : 0 }
        const victim = sids.filter(s => s !== sid).sort((x, y) => last(x) - last(y))[0]
        delete this.agents[victim]
      }
    }
    return a
  }

  push (sid, entry) {
    const a = this.agent(sid)
    if (a.since === null) a.since = entry[0]
    a.ev.push(entry)
    if (a.ev.length > MAX_ENTRIES) {
      const cut = a.ev.length - MAX_ENTRIES
      a.ev.splice(0, cut)
      a.dropped += cut
      a.since = a.ev[0][0]
    }
    this.dirty = true
  }

  fileIndex (a, file) {
    let i = a.files.indexOf(file)
    if (i !== -1) return i
    if (a.files.length >= MAX_FILES) {
      // Reuse the slot of the file no kept entry refers to any more, else the oldest.
      const used = new Set(a.ev.filter(e => e[1] === 'e').map(e => e[2]))
      i = a.files.findIndex((_, k) => !used.has(k))
      if (i === -1) i = 0
      a.files[i] = file
      return i
    }
    a.files.push(file)
    return a.files.length - 1
  }

  label (a, text) {
    const h = hash(text)
    if (!(h in a.labels)) {
      const keys = Object.keys(a.labels)
      if (keys.length >= MAX_LABELS) delete a.labels[keys[0]]
      a.labels[h] = commandLabel(text)
    }
    return h
  }

  // One hook event (after the reducer ran). Only what `digest` counts.
  onEvent (event, now = Date.now()) {
    if (!event || !event.session_id) return
    const sid = event.session_id
    const kind = event.hook_event_name
    const tool = event.tool_name
    const input = event.tool_input
    const sub = !!event.agent_id
    switch (kind) {
      case 'UserPromptSubmit':
        this.push(sid, [now, 'p'])
        break
      case 'Stop':
        this.push(sid, [now, 's'])
        break
      case 'StopFailure':
        if (!sub) this.push(sid, [now, 'x', String(event.error || 'unknown').slice(0, 40)])
        break
      case 'PostToolUse':
        if (EDIT_TOOLS.has(tool)) {
          const file = editPath(input)
          if (!file) break
          const a = this.agent(sid)
          const [add, del] = editDelta(tool, input)
          this.push(sid, [now, 'e', this.fileIndex(a, file), add, del])
        } else if (tool === 'Bash' && input && typeof input.command === 'string') {
          const a = this.agent(sid)
          this.push(sid, [now, 'c', this.label(a, input.command), isTestCommand(input.command) ? 1 : 0])
        }
        break
      case 'PostToolUseFailure': {
        if (event.is_interrupt === true) break
        const a = this.agent(sid)
        const command = tool === 'Bash' && input && typeof input.command === 'string' ? input.command : null
        const what = command || `${tool || 'tool'}${editPath(input) ? ' ' + editPath(input) : ''}`
        const sig = errorSignature(event.error)
        this.push(sid, [now, 'f', this.label(a, what), command && isTestCommand(command) ? 1 : 0, this.label(a, sig)])
        break
      }
      default:
        break
    }
  }

  // Agent records after a state change (from the daemon's change records):
  // logs state transitions and remembers who the agent is, so an agent the
  // state pruned can still be reported.
  onChange (ch, now = Date.now()) {
    if (!ch || ch.type !== 'change' || !ch.agent) return
    const ag = ch.agent
    const a = this.agents[ch.sessionId]
    const code = STATE_CODES[ag.state]
    if (!a && !code) return
    const rec = a || this.agent(ch.sessionId)
    if (code && rec.state !== code) {
      rec.state = code
      this.push(ch.sessionId, [ag.updatedAt || now, 'S', code])
    }
    const meta = { name: ag.name || null, cwd: ag.cwd || null, transcriptPath: ag.transcriptPath || null, startedAt: ag.startedAt || null, endedAt: ag.endedAt || null, lastMessage: typeof ag.lastMessage === 'string' ? ag.lastMessage.slice(0, 500) : null }
    if (JSON.stringify(meta) !== JSON.stringify(rec.meta)) { rec.meta = meta; this.dirty = true }
  }

  // Forget agents with nothing newer than KEEP_MS.
  prune (now = Date.now()) {
    for (const [sid, a] of Object.entries(this.agents)) {
      const last = a.ev.length ? a.ev[a.ev.length - 1][0] : 0
      if (now - last > KEEP_MS) { delete this.agents[sid]; this.dirty = true }
    }
  }

  toJSON () {
    return { v: 1, agents: this.agents }
  }
}

module.exports = { Activity, isTestCommand, errorSignature, commandLabel, lineDelta, editDelta, hash, MAX_ENTRIES, MAX_FILES, MAX_AGENTS, KEEP_MS, STATE_CODES }
