'use strict'

// Approval rules: what the hook may answer by itself, without the phone.
//
// A rule is Claude Code's own permission rule syntax, `Tool` or
// `Tool(content)`, plus where and until when it applies:
//
//   { "id": "r1a2b3c4", "rule": "Bash(npm test *)",
//     "scope": { "kind": "repo", "path": "/home/andre/Projects/app" },
//     "expiresAt": 1790290000000,        // null: until revoked
//     "endsWithSession": null,           // a session id: dropped when it ends
//     "source": "trust",                 // trust | always | cli
//     "createdAt": 1790286400000, "hits": 3, "lastUsedAt": 1790287000000 }
//
// scope.kind: `session` (scope.sessionId; one agent session), `repo`
// (scope.path; any session whose cwd is inside it) or `any`.
//
// Content, as in Claude Code:
//   Bash(npm test)        exactly this command
//   Bash(npm test *)      glob: `*` is any text; a trailing ` *` also
//                         matches the bare command (`npm test`)
//   Bash(npm test:*)      legacy prefix form, same as `npm test *`
//   Edit(src/**)          path glob for Edit, Write, MultiEdit, NotebookEdit;
//   Read(docs/**)         Read, Grep, Glob, LS. `**` any depth, `*` one
//                         segment. Relative to the rule's repo (else the
//                         agent's repo); `//abs/path`, `~/path` absolute.
//                         A pattern without `/` matches at any depth.
//   WebFetch(domain:x.y)  that host (and its subdomains)
//   mcp__server           every tool of an MCP server (or mcp__server__tool)
//   Bash, Edit, …         every call of that tool
//
// A Bash rule never matches a command with $(…), backticks or unbalanced
// quotes (unless the rule is that exact command), and a compound command
// (&&, ;, |) only when each of its commands is covered: `cd <dir>` and
// read-only filters on the right of a pipe (`| tail -20`) count as covered.
//
// matching never looks at risk; the daemon refuses to auto-answer anything
// risk.js rates high before it asks the rules.
//
// Stored in ~/.conductore/rules.json (mode 600): {"version":1,"rules":[…]}.
// Never written into Claude Code's settings.

const fs = require('fs')
const os = require('os')
const path = require('path')
const shell = require('./shell')
const risk = require('./risk')

const MAX_RULES = 200
const MAX_RULE_LENGTH = 500
const MAX_MINUTES = 7 * 24 * 60
const SESSION_ID = /^[A-Za-z0-9_-]{1,128}$/

const EDIT_TOOLS = new Set(['Edit', 'Write', 'MultiEdit', 'NotebookEdit'])
const READ_TOOLS = new Set(['Read', 'Grep', 'Glob', 'LS', 'NotebookRead'])

// --- syntax -------------------------------------------------------------------

function parseRule (text) {
  if (typeof text !== 'string') return null
  const s = text.trim()
  if (!s || s.length > MAX_RULE_LENGTH) return null
  const m = /^([A-Za-z][A-Za-z0-9_-]*)(?:\(([\s\S]*)\))?$/.exec(s)
  if (!m) return null
  const content = m[2] === undefined ? null : m[2].trim()
  return { tool: m[1], content: content === '' || content === '*' ? null : content }
}

function formatRule (tool, content) {
  return content === null || content === undefined ? tool : `${tool}(${content})`
}

function toolCovers (ruleTool, toolName) {
  if (ruleTool === toolName) return true
  if (ruleTool === 'Edit' && EDIT_TOOLS.has(toolName)) return true
  if (ruleTool === 'Read' && READ_TOOLS.has(toolName)) return true
  // mcp__server covers mcp__server__tool.
  if (ruleTool.startsWith('mcp__') && ruleTool.split('__').length === 2 && toolName.startsWith(ruleTool + '__')) return true
  return false
}

// --- Bash ---------------------------------------------------------------------

function escapeRe (s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

function commandRegex (pattern) {
  let p = pattern.replace(/\s+/g, ' ').trim()
  if (p.endsWith(':*')) p = p.slice(0, -2).trimEnd() + ' *'
  let tail = ''
  if (p.endsWith(' *')) { p = p.slice(0, -2); tail = '(?: .*)?' }
  const body = p.split('*').map(escapeRe).join('.*')
  return new RegExp(`^${body}${tail}$`, 's')
}

const norm = s => String(s).replace(/\s+/g, ' ').trim()

// Segments that need no rule of their own: `cd dir`, and low-risk filters
// fed by a pipe (`| head`, `| grep x`, `| wc -l`).
function neutral (seg, ctx) {
  const words = shell.stripAssignments(seg.words)
  if (!words.length) return true
  if ((words[0] === 'cd' || words[0] === 'pushd' || words[0] === 'popd') && !seg.redirects.length) return true
  if (seg.pipedFrom && !seg.redirects.some(r => r.op.startsWith('>'))) {
    return risk.classify('Bash', { command: seg.raw }, ctx).level === 'low'
  }
  return false
}

// Which of `patterns` (Bash rule contents; null = any command) cover this
// command. Returns the index of the first pattern used, or -1.
function bashCovered (patterns, command, ctx = {}) {
  if (typeof command !== 'string' || !command.trim()) return -1
  const whole = norm(command)
  // The exact command, however complex.
  const exact = patterns.findIndex(p => p !== null && !p.includes('*') && norm(p) === whole)
  if (exact !== -1) return exact
  const parsed = shell.parse(command)
  if (!parsed.complete || parsed.substitutions.length) {
    const any = patterns.indexOf(null)
    return any
  }
  const regexes = patterns.map(p => (p === null ? null : commandRegex(p)))
  let first = -1
  let covered = 0
  for (const seg of parsed.segments) {
    const text = norm(seg.raw)
    const k = regexes.findIndex(re => re === null || re.test(text))
    if (k === -1) {
      if (neutral(seg, ctx)) continue
      return -1
    }
    if (first === -1) first = k
    covered++
  }
  return covered ? first : -1
}

// --- paths --------------------------------------------------------------------

function globRegex (glob) {
  let re = ''
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i]
    if (c === '*') {
      if (glob[i + 1] === '*') {
        if (glob[i + 2] === '/') { re += '(?:.*/)?'; i += 2 } else { re += '.*'; i += 1 }
      } else re += '[^/]*'
    } else if (c === '?') re += '[^/]'
    else re += escapeRe(c)
  }
  return new RegExp(`^${re}$`, 's')
}

// Absolute glob for a path pattern: `//abs`, `~/x`, else relative to base.
function absoluteGlob (pattern, base, home) {
  let p = pattern.trim()
  if (p.startsWith('//')) return path.posix.normalize(p.slice(1))
  if (p === '~' || p.startsWith('~/')) return path.posix.join(home || '/nonexistent-home', p.slice(1))
  if (p.startsWith('./')) p = p.slice(2)
  else if (p.startsWith('/')) p = p.slice(1) // Claude Code: `/x` is project-relative
  if (!p.includes('/') && !p.startsWith('**')) p = '**/' + p
  return path.posix.join(base || '/', p)
}

function pathCovered (pattern, target, base, home) {
  if (!target) return false
  const glob = absoluteGlob(pattern, base, home)
  const re = globRegex(glob)
  // A directory rule `src/**` also covers `src` itself.
  return re.test(target) || (glob.endsWith('/**') && target === glob.slice(0, -3))
}

function toolTarget (toolName, input, ctx) {
  if (!input || typeof input !== 'object') return null
  const p = ['file_path', 'notebook_path', 'path'].map(k => input[k]).find(v => typeof v === 'string' && v)
  if (p) return risk.resolvePath(p, ctx)
  // Glob / Grep without a path search the cwd.
  if (toolName === 'Glob' || toolName === 'Grep' || toolName === 'LS') return ctx.cwd || null
  return null
}

// --- matching -----------------------------------------------------------------

function isActive (rule, now = Date.now()) {
  return !!rule && (rule.expiresAt === null || rule.expiresAt === undefined || rule.expiresAt > now)
}

function scopeApplies (scope, event, ctx) {
  if (!scope || scope.kind === 'any') return true
  if (scope.kind === 'session') return !!event.session_id && scope.sessionId === event.session_id
  if (scope.kind === 'repo') return !!ctx.cwd && risk.inside(ctx.cwd, scope.path)
  return false
}

// The rule record (from `rules`) that answers this request, or null.
// event: { session_id, tool_name, tool_input }; ctx: { cwd, root, home }.
function findMatch (rules, event, ctx, now = Date.now()) {
  const tool = event.tool_name
  if (typeof tool !== 'string' || !tool) return null
  const input = event.tool_input && typeof event.tool_input === 'object' ? event.tool_input : {}
  if (input._truncated) return null
  const candidates = []
  for (const rec of rules) {
    if (!isActive(rec, now) || !scopeApplies(rec.scope, event, ctx)) continue
    const parsed = parseRule(rec.rule)
    if (!parsed || !toolCovers(parsed.tool, tool)) continue
    candidates.push({ rec, parsed })
  }
  if (!candidates.length) return null
  if (tool === 'Bash') {
    const k = bashCovered(candidates.map(c => c.parsed.content), input.command, ctx)
    return k === -1 ? null : candidates[k].rec
  }
  for (const { rec, parsed } of candidates) {
    if (parsed.content === null) return rec
    if (EDIT_TOOLS.has(tool) || READ_TOOLS.has(tool)) {
      const base = rec.scope && rec.scope.kind === 'repo' ? rec.scope.path : ctx.root || ctx.cwd
      if (pathCovered(parsed.content, toolTarget(tool, input, ctx), base, ctx.home)) return rec
      continue
    }
    if (tool === 'WebFetch' && parsed.content.startsWith('domain:')) {
      const want = parsed.content.slice(7).trim().toLowerCase().replace(/^\*\./, '')
      const host = risk.hostOf(input.url)
      if (host && (host === want || host.endsWith('.' + want))) return rec
      continue
    }
  }
  return null
}

// --- suggestions --------------------------------------------------------------

// Programs whose first argument is a subcommand worth keeping in a rule.
const SUBCOMMANDS = new Set(['git', 'npm', 'pnpm', 'yarn', 'bun', 'npx', 'pnpx', 'bunx', 'cargo', 'go', 'docker', 'podman', 'kubectl', 'helm', 'flutter', 'dart', 'make', 'just', 'gh', 'pip', 'pip3', 'uv', 'poetry', 'dotnet', 'mvn', 'gradle', './gradlew', 'terraform', 'swift', 'deno', 'bundle', 'rails', 'composer', 'mix', 'brew', 'apt', 'systemctl'])
const TWO_LEVEL = { npm: ['run', 'run-script', 'exec'], pnpm: ['run', 'exec', 'dlx'], yarn: ['run', 'dlx'], bun: ['run', 'x'], docker: ['compose'], uv: ['run', 'pip'], poetry: ['run'], python: ['-m'], python3: ['-m'], dotnet: ['ef'], flutter: ['pub'], dart: ['pub', 'run'] }

function commandPrefix (words) {
  const w = shell.stripAssignments(words)
  if (!w.length) return []
  const prog = w[0]
  const base = prog.replace(/^.*\//, '')
  const plain = x => typeof x === 'string' && x && !x.startsWith('-') && !x.includes('/') && !x.includes('=') && !/^[0-9]/.test(x) && x.length <= 40 && !x.includes('$(')
  if (TWO_LEVEL[base] && TWO_LEVEL[base].includes(w[1]) && typeof w[2] === 'string' && (w[1] === '-m' || plain(w[2]))) return w.slice(0, 3)
  if (SUBCOMMANDS.has(prog) || SUBCOMMANDS.has(base)) {
    // git -C dir status: keep the global options with the subcommand.
    let k = 1
    if (base === 'git') while (k < w.length && w[k].startsWith('-')) k += w[k] === '-C' || w[k] === '-c' ? 2 : 1
    if (plain(w[k])) return w.slice(0, k + 1)
  }
  return [prog]
}

// Rules offered for a request, most specific (usually the best) first.
function suggest (toolName, toolInput, ctx = {}) {
  const tool = typeof toolName === 'string' ? toolName : ''
  const input = toolInput && typeof toolInput === 'object' ? toolInput : {}
  const out = []
  const add = r => { if (r && !out.includes(r) && r.length <= MAX_RULE_LENGTH) out.push(r) }
  if (!tool) return out
  if (tool === 'Bash' && typeof input.command === 'string' && !input._truncated) {
    const command = norm(input.command)
    const parsed = shell.parse(input.command)
    const real = parsed.complete && !parsed.substitutions.length ? parsed.segments.filter(s => !neutral(s, ctx)) : []
    if (real.length === 1) {
      const prefix = commandPrefix(real[0].words)
      if (prefix.length) {
        add(`Bash(${prefix.join(' ')} *)`)
        if (prefix.length > 1) add(`Bash(${prefix[0]} *)`)
      }
    }
    if (command.length <= 200) add(`Bash(${command})`)
    add('Bash')
    return out
  }
  if (EDIT_TOOLS.has(tool) || READ_TOOLS.has(tool)) {
    const family = EDIT_TOOLS.has(tool) ? 'Edit' : 'Read'
    const target = toolTarget(tool, input, ctx)
    const root = ctx.root || ctx.cwd
    if (target && root && risk.inside(target, root) && target !== root) {
      const rel = path.relative(root, target)
      const dir = path.dirname(rel)
      const isDir = tool === 'LS' || tool === 'Glob' || tool === 'Grep'
      if (isDir) add(`${family}(${rel}/**)`)
      else if (dir !== '.') add(`${family}(${dir}/**)`)
      else add(`${family}(${rel})`)
      const top = rel.split('/')[0]
      if (top !== rel && top !== dir) add(`${family}(${top}/**)`)
      add(`${family}(**)`)
    } else if (target) {
      const dir = tool === 'LS' ? target : path.dirname(target)
      add(`${family}(/${dir}/**)`)
    } else {
      add(`${family}(**)`)
    }
    return out
  }
  if (tool === 'WebFetch') {
    const host = risk.hostOf(input.url)
    if (host) add(`WebFetch(domain:${host})`)
    add('WebFetch')
    return out
  }
  if (tool.startsWith('mcp__')) {
    add(tool)
    const parts = tool.split('__')
    if (parts.length > 2) add(`mcp__${parts[1]}`)
    return out
  }
  add(tool)
  return out
}

// --- repo ---------------------------------------------------------------------

const rootCache = new Map()

// The git work tree containing cwd (a `.git` dir or file), else cwd itself.
// Never climbs to or above the home directory.
function repoRoot (cwd, home = os.homedir()) {
  if (typeof cwd !== 'string' || !path.isAbsolute(cwd)) return null
  const hit = rootCache.get(cwd)
  if (hit && Date.now() - hit.at < 60000) return hit.root
  let dir = path.normalize(cwd)
  let root = dir
  for (let i = 0; i < 40; i++) {
    if (dir === home || dir === '/') break
    try { fs.statSync(path.join(dir, '.git')); root = dir; break } catch {}
    const up = path.dirname(dir)
    if (up === dir) break
    dir = up
  }
  if (rootCache.size > 256) rootCache.clear()
  rootCache.set(cwd, { at: Date.now(), root })
  return root
}

// --- records ------------------------------------------------------------------

function newId () {
  return 'r' + Math.floor(Math.random() * 2 ** 40).toString(16).padStart(10, '0')
}

// Validates and builds a rule record. Throws Error with a user-facing message.
// spec: { rule, scope: { kind, path?, sessionId?, label? }, minutes?, untilSessionEnd?, sessionId?, source?, note? }
function makeRule (spec, now = Date.now()) {
  if (!spec || typeof spec !== 'object') throw new Error('missing rule')
  const parsed = parseRule(spec.rule)
  if (!parsed) throw new Error(`not a rule: ${JSON.stringify(spec.rule)} (expected Tool or Tool(pattern), e.g. Bash(npm test *))`)
  const scope = normalizeScope(spec.scope)
  let expiresAt = null
  if (spec.minutes !== undefined && spec.minutes !== null) {
    const m = Number(spec.minutes)
    if (!Number.isFinite(m) || m <= 0 || m > MAX_MINUTES) throw new Error(`minutes must be between 1 and ${MAX_MINUTES}`)
    expiresAt = now + Math.round(m * 60000)
  }
  let endsWithSession = null
  if (spec.untilSessionEnd || scope.kind === 'session') {
    endsWithSession = scope.kind === 'session' ? scope.sessionId : spec.sessionId
    if (typeof endsWithSession !== 'string' || !SESSION_ID.test(endsWithSession)) throw new Error('until the session ends needs the session id')
  }
  return {
    id: newId(),
    rule: formatRule(parsed.tool, parsed.content),
    scope,
    expiresAt,
    endsWithSession,
    source: ['trust', 'always', 'cli', 'voice'].includes(spec.source) ? spec.source : 'cli',
    note: typeof spec.note === 'string' && spec.note.trim() ? spec.note.trim().slice(0, 200) : null,
    createdAt: now,
    hits: 0,
    lastUsedAt: null
  }
}

function normalizeScope (scope) {
  const s = scope && typeof scope === 'object' ? scope : { kind: 'any' }
  const label = typeof s.label === 'string' && s.label.trim() ? s.label.trim().slice(0, 100) : null
  switch (s.kind) {
    case 'any': case undefined: case null:
      return { kind: 'any' }
    case 'repo': case 'path': case 'workspace': {
      if (typeof s.path !== 'string' || !path.isAbsolute(s.path)) throw new Error('a repo scope needs an absolute path')
      const p = path.normalize(s.path).replace(/\/+$/, '') || '/'
      if (p === '/') throw new Error('a repo scope cannot be /; use scope any')
      return label ? { kind: 'repo', path: p, label } : { kind: 'repo', path: p }
    }
    case 'session':
      if (typeof s.sessionId !== 'string' || !SESSION_ID.test(s.sessionId)) throw new Error('a session scope needs a session id')
      return label ? { kind: 'session', sessionId: s.sessionId, label } : { kind: 'session', sessionId: s.sessionId }
    default:
      throw new Error(`unknown scope ${s.kind} (session, repo or any)`)
  }
}

// --- store --------------------------------------------------------------------

function load (file) {
  try {
    const data = JSON.parse(fs.readFileSync(file, 'utf8'))
    const list = Array.isArray(data) ? data : data && Array.isArray(data.rules) ? data.rules : []
    return list.filter(r => r && typeof r.id === 'string' && parseRule(r.rule))
  } catch {
    return []
  }
}

function save (file, rules) {
  const tmp = `${file}.${process.pid}.tmp`
  fs.writeFileSync(tmp, JSON.stringify({ version: 1, rules }, null, 2) + '\n', { mode: 0o600 })
  try { fs.chmodSync(tmp, 0o600) } catch {}
  fs.renameSync(tmp, file)
}

// Drops expired rules and those tied to ended sessions; returns [kept, dropped].
function prune (rules, now = Date.now(), endedSession = null) {
  const kept = []
  const dropped = []
  for (const r of rules) {
    if (!isActive(r, now) || (endedSession && r.endsWithSession === endedSession)) dropped.push(r)
    else kept.push(r)
  }
  return [kept, dropped]
}

module.exports = {
  MAX_RULES,
  MAX_MINUTES,
  parseRule,
  formatRule,
  commandRegex,
  bashCovered,
  pathCovered,
  findMatch,
  suggest,
  repoRoot,
  makeRule,
  normalizeScope,
  isActive,
  load,
  save,
  prune
}
