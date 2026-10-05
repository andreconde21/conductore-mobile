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
// A Bash rule matches the parsed command (shell.js), never its text, and
// never a command the parser did not fully understand. Beyond the exact
// command, it covers one statement: a pipeline whose commands each have a
// rule, where leading `cd <dir in the repo> &&` and read-only filters on
// the right of a pipe (`| tail -20`) count as covered. Path rules never
// use `..` and must cover every file a call touches, through symlinks too.
// No rule answers a question or a plan.
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
// The user's own answers: a question, a plan. No rule ever gives them.
const NEVER_RULED = new Set(['AskUserQuestion', 'ExitPlanMode'])
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
//
// Matching works on the parsed command (shell.js), never on its text: a
// command the parser did not fully understand matches no rule at all. A
// pattern is read the same way, word by word: a `*` word stands for any
// number of words, a word with `*` in it for any text inside that word,
// and a trailing ` *` (or legacy `:*`) for any further arguments.

const norm = s => String(s).replace(/\s+/g, ' ').trim()

// A rule's command pattern: { any } | { exact: parsed } | { words, rest },
// or null when it is not a pattern this reader can hold to its meaning.
function bashPattern (content) {
  if (content === null) return { any: true }
  let p = content.trim()
  let rest = false
  if (p.endsWith(':*')) { p = p.slice(0, -2).trimEnd(); rest = true } else if (/(^|\s)\*$/.test(p)) { p = p.slice(0, -1).trimEnd(); rest = true }
  if (!p) return { any: true }
  const parsed = shell.parse(p)
  if (!parsed.complete || parsed.concerns.some(c => c !== 'glob-command')) return null
  const globbed = parsed.segments.some(seg => seg.meta.some(m => m.glob || m.brace))
  if (!rest && !globbed) return parsed.concerns.length ? null : { exact: parsed }
  if (parsed.segments.length !== 1 || parsed.segments[0].redirects.length) return null
  const seg = parsed.segments[0]
  return {
    words: seg.words.map((w, k) => (seg.meta[k].glob && w === '*' ? '*' : seg.meta[k].glob ? wordRegex(w) : w)),
    rest
  }
}

// `test*` in a pattern: any text in that one word.
function wordRegex (w) {
  return new RegExp(`^${w.split('*').map(escapeRe).join('.*').replace(/\?/g, '.')}$`, 's')
}

function escapeRe (s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

// The same commands: segment by segment, words, redirections, operators.
function sameStructure (a, b) {
  if (a.segments.length !== b.segments.length) return false
  return a.segments.every((x, k) => {
    const y = b.segments[k]
    return x.sep === y.sep && x.words.length === y.words.length && x.words.every((w, j) => w === y.words[j]) &&
      x.redirects.length === y.redirects.length && x.redirects.every((r, j) => r.op === y.redirects[j].op && r.target === y.redirects[j].target)
  })
}

const HARMLESS_TARGETS = new Set(['/dev/null', '/dev/stdout', '/dev/stderr'])

// Whether a pattern of words covers one simple command.
function segmentMatches (pattern, seg) {
  if (seg.redirects.some(r => !HARMLESS_TARGETS.has(r.target))) return false
  const pw = pattern.rest ? [...pattern.words, '*'] : pattern.words
  const w = seg.words
  // Word sequence match; '*' takes any number of words.
  const memo = new Map()
  const at = (i, j) => {
    const key = i * 4096 + j
    if (memo.has(key)) return memo.get(key)
    let ok
    if (i === pw.length) ok = j === w.length
    else if (pw[i] === '*') ok = at(i + 1, j) || (j < w.length && at(i, j + 1))
    else ok = j < w.length && (pw[i] instanceof RegExp ? pw[i].test(w[j]) : pw[i] === w[j]) && at(i + 1, j + 1)
    memo.set(key, ok)
    return ok
  }
  return w.length < 4096 && at(0, 0)
}

// A plain `cd <dir>` into a folder of the repo: the directory, else null.
function repoCd (seg, ctx) {
  const w = seg.words
  if (seg.assigns || seg.redirects.length || w.length !== 2 || w[0] !== 'cd' || seg.meta[1].glob || seg.meta[1].brace || w[1].startsWith('-')) return null
  const dir = risk.resolvePath(w[1], ctx)
  const root = ctx.root || ctx.cwd
  return dir && root && root !== '/' && root !== ctx.home && risk.inside(dir, root) ? dir : null
}

// A low-risk filter fed by a pipe (`| head`, `| grep x`) needs no rule.
function neutralFilter (seg, ctx) {
  return seg.pipedFrom && !seg.redirects.length && risk.classify('Bash', { command: seg.raw }, ctx).level === 'low'
}

// Which of `patterns` (Bash rule contents; null = any command) cover this
// command. Returns the index of the first pattern used, or -1. Besides
// the exact command, only one statement is covered: a pipeline whose
// commands each have a rule (or are low-risk filters), after leading
// `cd <dir in the repo> &&`.
function bashCovered (patterns, command, ctx = {}) {
  if (typeof command !== 'string' || !command.trim()) return -1
  const parsed = shell.parse(command)
  if (!parsed.understood || !parsed.segments.length) return -1
  const compiled = patterns.map(p => (typeof p === 'string' || p === null ? bashPattern(p) : null))
  const exact = compiled.findIndex(p => p && p.exact && sameStructure(p.exact, parsed))
  if (exact !== -1) return exact
  const segs = parsed.segments
  let here = ctx
  let k = 0
  while (k < segs.length - 1 && segs[k + 1].sep === '&&') {
    const dir = repoCd(segs[k], here)
    if (!dir) break
    here = { ...here, cwd: dir }
    k++
  }
  let first = -1
  for (let j = k; j < segs.length; j++) {
    const seg = segs[j]
    if (j > k && !seg.pipedFrom) return -1
    const i = compiled.findIndex(p => p && (p.any || (p.words && segmentMatches(p, seg))))
    if (i === -1) {
      if (j > k && neutralFilter(seg, here)) continue
      return -1
    }
    if (first === -1) first = i
  }
  return first
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

// A `..` segment: path rules never climb out of where they are anchored.
const TRAVERSAL = /(^|\/)\.\.(\/|$)/

// Absolute glob for a path pattern: `//abs`, `~/x`, else relative to base.
// Null for a pattern with `..` in it.
function absoluteGlob (pattern, base, home) {
  let p = pattern.trim()
  if (TRAVERSAL.test(p) || p.includes('\0')) return null
  if (p.startsWith('//')) return path.posix.normalize(p.slice(1))
  if (p === '~' || p.startsWith('~/')) return path.posix.join(home || '/nonexistent-home', p.slice(1))
  // Claude Code: `/x` (and `./x`) is anchored at the project; a bare
  // name without `/` matches at any depth.
  const anchored = p.startsWith('./') || p.startsWith('/')
  p = p.replace(/^\.?\//, '')
  if (!anchored && !p.includes('/') && !p.startsWith('**')) p = '**/' + p
  return path.posix.join(base || '/', p)
}

function pathCovered (pattern, target, base, home) {
  if (!target) return false
  const glob = absoluteGlob(pattern, base, home)
  if (!glob) return false
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

// Every path a call touches, absolute; null when one cannot be pinned down
// (a Glob pattern that climbs out with `..` or is absolute).
function toolTargets (toolName, input, ctx) {
  if (!input || typeof input !== 'object') return null
  if (toolName === 'Glob' && typeof input.pattern === 'string' && (TRAVERSAL.test(input.pattern) || input.pattern.startsWith('/') || input.pattern.startsWith('~'))) return null
  if (toolName === 'Grep' && typeof input.glob === 'string' && (TRAVERSAL.test(input.glob) || input.glob.startsWith('/'))) return null
  const first = toolTarget(toolName, input, ctx)
  if (!first) return null
  const all = [first]
  if (Array.isArray(input.files)) {
    for (const f of input.files) {
      if (typeof f !== 'string' || !f) return null
      all.push(risk.resolvePath(f, ctx))
    }
  }
  return all
}

// A path rule covers a call when it covers every path it touches, both as
// written and, when ctx.realpath can tell, where symlinks really lead.
function pathsCovered (pattern, targets, base, ctx) {
  if (!targets || !targets.length) return false
  const real = typeof ctx.realpath === 'function' ? ctx.realpath : null
  const realBase = real && base ? safeReal(real, base) : null
  return targets.every(t => {
    if (!pathCovered(pattern, t, base, ctx.home)) return false
    if (!real) return true
    const r = safeReal(real, t)
    if (!r) return false
    return r === t || pathCovered(pattern, r, realBase || base, ctx.home)
  })
}

function safeReal (real, p) {
  try { return real(p) || null } catch { return null }
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
  if (typeof tool !== 'string' || !tool || NEVER_RULED.has(tool)) return null
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
      if (pathsCovered(parsed.content, toolTargets(tool, input, ctx), base, ctx)) return rec
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

// A word as a pattern holds it: quoted when it has anything but plain
// characters.
function quoteWord (w) {
  return /^[A-Za-z0-9_@%+=:,./-]+$/.test(w) ? w : `'${w.replace(/'/g, "'\\''")}'`
}

function commandPrefix (seg) {
  if (seg.assigns || seg.redirects.length) return []
  const w = seg.words
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

// Rules offered for a request, narrowest first (exactly this call, which
// the phone offers by default), then broader ones the user may pick. A
// request no rule may answer (a question, a plan, a command the parser
// did not fully understand) gets none.
function suggest (toolName, toolInput, ctx = {}) {
  const tool = typeof toolName === 'string' ? toolName : ''
  const input = toolInput && typeof toolInput === 'object' ? toolInput : {}
  const out = []
  const add = r => { if (r && !out.includes(r) && r.length <= MAX_RULE_LENGTH) out.push(r) }
  if (!tool || NEVER_RULED.has(tool) || input._truncated) return out
  if (tool === 'Bash') {
    if (typeof input.command !== 'string') return out
    const parsed = shell.parse(input.command)
    if (!parsed.understood) return out
    if (input.command.trim().length <= 200) add(narrowest(tool, input, ctx))
    // The one command of a pipeline that needs a rule (after leading cds).
    const segs = parsed.segments
    let k = 0
    let here = ctx
    while (k < segs.length - 1 && segs[k + 1].sep === '&&') {
      const dir = repoCd(segs[k], here)
      if (!dir) break
      here = { ...here, cwd: dir }
      k++
    }
    const rest = segs.slice(k)
    const real = rest.every((seg, j) => j === 0 || seg.pipedFrom) ? rest.filter((seg, j) => j === 0 || !neutralFilter(seg, here)) : []
    if (real.length === 1 && !real[0].meta.some(m => m.glob || m.brace)) {
      const prefix = commandPrefix(real[0])
      if (prefix.length) {
        add(`Bash(${prefix.map(quoteWord).join(' ')} *)`)
        if (prefix.length > 1) add(`Bash(${quoteWord(prefix[0])} *)`)
      }
    }
    add('Bash')
    // Only rules that really answer this request.
    return out.filter(rule => bashCovered([parseRule(rule).content], input.command, ctx) !== -1)
  }
  if (EDIT_TOOLS.has(tool) || READ_TOOLS.has(tool)) {
    const family = EDIT_TOOLS.has(tool) ? 'Edit' : 'Read'
    const target = toolTarget(tool, input, ctx)
    const root = ctx.root || ctx.cwd
    const isDir = tool === 'LS' || tool === 'Glob' || tool === 'Grep'
    if (!isDir) add(narrowest(tool, input, ctx))
    if (target && root && risk.inside(target, root) && target !== root) {
      const rel = path.relative(root, target)
      const dir = path.dirname(rel)
      if (isDir) add(`${family}(${rel}/**)`)
      else if (dir !== '.') add(`${family}(${dir}/**)`)
      else add(`${family}(/${rel})`)
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

// The narrowest rule that covers exactly this call (what a trust saves when
// the user did not pick one): the exact command, the exact file, the host.
// Null when no rule can say just that: truncated input, a command the
// parser did not fully understand or with a `*`, a multi-file patch, a
// question or a plan.
function narrowest (toolName, toolInput, ctx = {}) {
  const tool = typeof toolName === 'string' ? toolName : ''
  const input = toolInput && typeof toolInput === 'object' ? toolInput : {}
  if (!tool || input._truncated || NEVER_RULED.has(tool)) return null
  if (tool === 'Bash') {
    if (typeof input.command !== 'string' || !input.command.trim()) return null
    const command = input.command.trim()
    if (command.includes('*') || !shell.parse(command).understood) return null
    const rule = `Bash(${command})`
    return rule.length <= MAX_RULE_LENGTH ? rule : null
  }
  if (EDIT_TOOLS.has(tool) || READ_TOOLS.has(tool)) {
    const family = EDIT_TOOLS.has(tool) ? 'Edit' : 'Read'
    const target = toolTarget(tool, input, ctx)
    if (!target || /[*?[\]{}]/.test(target) || (Array.isArray(input.files) && input.files.length > 1)) return null
    const root = ctx.root || ctx.cwd
    const pattern = root && risk.inside(target, root) && target !== root ? path.relative(root, target) : `/${target}`
    return `${family}(${pattern.includes('/') ? pattern : `/${pattern}`})`
  }
  if (tool === 'WebFetch') {
    const host = risk.hostOf(input.url)
    return host ? `WebFetch(domain:${host})` : null
  }
  return tool
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
  if (NEVER_RULED.has(parsed.tool)) throw new Error(`${parsed.tool} always asks: it takes the user's own answer`)
  if (parsed.tool === 'Bash' && !bashPattern(parsed.content)) throw new Error(`not a command pattern this companion can match: ${JSON.stringify(parsed.content)} (no $(…), variables, subshells or here-docs)`)
  if ((EDIT_TOOLS.has(parsed.tool) || READ_TOOLS.has(parsed.tool)) && parsed.content !== null && (TRAVERSAL.test(parsed.content) || parsed.content.includes('\0'))) throw new Error('a path rule cannot use ..')
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
  bashPattern,
  bashCovered,
  pathCovered,
  findMatch,
  suggest,
  narrowest,
  repoRoot,
  makeRule,
  normalizeScope,
  isActive,
  load,
  save,
  prune
}
