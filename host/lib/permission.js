'use strict'

// PermissionRequest decisions: the exact stdout JSON Claude Code expects
// (https://code.claude.com/docs/en/hooks#permissionrequest-decision-control).
// The daemon builds the line and writes it into the waiting hook's FIFO; the
// sh hook prints it unchanged.

const fs = require('fs')
const path = require('path')
const paths = require('./paths')
const { log } = require('./log')

// Tools whose approval card is itself the user's input (Claude Code's
// requiresUserInteraction): a hook's plain `allow` is ignored for them and
// the terminal dialog stays up. Claude Code takes an allow only with an
// `updatedInput`: the answers for AskUserQuestion, the unchanged input for
// ExitPlanMode (checked in Claude Code 2.1.285).
const INTERACTIVE_TOOLS = new Set(['AskUserQuestion', 'ExitPlanMode'])

const EDIT_TOOLS = new Set(['Edit', 'Write', 'MultiEdit', 'NotebookEdit'])
const READ_TOOLS = new Set(['Read', 'NotebookRead'])
const DIR_TOOLS = new Set(['Grep', 'Glob', 'LS'])

// The Claude Code rule that allows exactly this call and nothing more, or
// null when its syntax cannot say that (a `*` would be a wildcard there; a
// path with glob characters; a multi-line command).
function exactRule (event) {
  const tool = event.tool_name
  const input = event.tool_input && typeof event.tool_input === 'object' ? event.tool_input : {}
  if (typeof tool !== 'string' || !tool || input._truncated) return null
  const abs = p => (typeof p === 'string' && p ? path.resolve(typeof event.cwd === 'string' && event.cwd ? event.cwd : '/', p) : null)
  const plainPath = p => p && !/[*?[\]{}\n]/.test(p)
  if (tool === 'Bash') {
    const c = typeof input.command === 'string' ? input.command.trim() : ''
    return c && !/[*\n\r]/.test(c) && !c.endsWith(':') ? { toolName: 'Bash', ruleContent: c } : null
  }
  if (EDIT_TOOLS.has(tool) || READ_TOOLS.has(tool)) {
    if (Array.isArray(input.files) && input.files.length > 1) return null
    const p = abs(input.file_path || input.notebook_path || input.path)
    return plainPath(p) ? { toolName: EDIT_TOOLS.has(tool) ? 'Edit' : 'Read', ruleContent: `/${p}` } : null
  }
  if (DIR_TOOLS.has(tool)) {
    const p = abs(input.path || event.cwd)
    return plainPath(p) ? { toolName: 'Read', ruleContent: `/${p}/**` } : null
  }
  if (tool === 'WebFetch') {
    let host = null
    try { host = new URL(String(input.url)).hostname.toLowerCase() } catch {}
    return host && /^[a-z0-9.-]+$/.test(host) ? { toolName: 'WebFetch', ruleContent: `domain:${host}` } : null
  }
  return { toolName: tool }
}

// updatedPermissions for an "always" decision: a rule for exactly this
// call (never Claude Code's own suggestion, which may cover more than the
// user saw), or none when no rule can say just that (then it is an allow
// once).
function alwaysPermissions (event) {
  // A plan's "always" is "approve and auto-accept edits", Claude Code's own
  // second plan option: a mode for this session, never a rule that would
  // approve every later plan.
  if (event.tool_name === 'ExitPlanMode') return [{ type: 'setMode', mode: 'acceptEdits', destination: 'session' }]
  const rule = exactRule(event)
  return rule ? [{ type: 'addRules', rules: [rule], behavior: 'allow', destination: 'localSettings' }] : null
}

function recordAlwaysRule (event, updatedPermissions) {
  try {
    paths.ensureDirs()
    const file = paths.rulesPath()
    let rules = []
    try { rules = JSON.parse(fs.readFileSync(file, 'utf8')) } catch {}
    if (!Array.isArray(rules)) rules = []
    rules.push({ at: new Date().toISOString(), sessionId: event.session_id, cwd: event.cwd, toolName: event.tool_name, updatedPermissions })
    fs.writeFileSync(file, JSON.stringify(rules, null, 2) + '\n', { mode: 0o600 })
  } catch (err) {
    log('permission', 'could not record always rule', err.message)
  }
}

// The answers of the phone for an AskUserQuestion request, as Claude Code
// takes them in `updatedInput`: the tool input unchanged plus `answers`,
// question text -> answer (a multiSelect question's labels joined with
// ", ", "Other" as its free text). Claude Code refuses an updatedInput that
// changes the questions or adds unknown fields, so nothing else is added.
// Returns { updatedInput } or { error }.
const ANSWER_MAX = 4000

function answerInput (event, answers) {
  const input = event.tool_input
  if (event.tool_name !== 'AskUserQuestion' || !input || !Array.isArray(input.questions)) {
    return { error: 'only a question takes answers' }
  }
  if (!answers || typeof answers !== 'object' || Array.isArray(answers)) return { error: 'answers must be an object: question -> answer' }
  const asked = new Set(input.questions.filter(q => q && typeof q.question === 'string').map(q => q.question))
  const out = {}
  for (const [question, raw] of Object.entries(answers)) {
    if (!asked.has(question)) return { error: `no such question: ${question.slice(0, 80)}` }
    const parts = (Array.isArray(raw) ? raw : [raw]).map(v => (typeof v === 'number' ? String(v) : v))
    if (!parts.every(v => typeof v === 'string')) return { error: 'an answer must be text or a list of texts' }
    const text = parts.map(v => v.trim()).filter(Boolean).join(', ')
    if (!text) continue
    if (text.length > ANSWER_MAX) return { error: 'answer too long' }
    out[question] = text
  }
  if (!Object.keys(out).length) return { error: 'no answer given' }
  return { updatedInput: { ...input, answers: out } }
}

// The stdout JSON for a decision, or null for "let the terminal ask".
// `answers` only for 'answer' (see answerInput).
function permissionOutput (event, decision, message, answers) {
  if (decision === 'answer') {
    const { updatedInput } = answerInput(event, answers)
    if (!updatedInput) return null
    return { hookSpecificOutput: { hookEventName: 'PermissionRequest', decision: { behavior: 'allow', updatedInput } } }
  }
  // A plan takes an allow only with its input, unchanged. (A question's plain
  // allow is refused before it gets here: echoed, it would run the tool with
  // no answers.)
  const echo = event.tool_name === 'ExitPlanMode' && event.tool_input && typeof event.tool_input === 'object'
    ? { updatedInput: event.tool_input }
    : {}
  if (decision === 'allow') {
    return { hookSpecificOutput: { hookEventName: 'PermissionRequest', decision: { behavior: 'allow', ...echo } } }
  }
  if (decision === 'always') {
    const updatedPermissions = alwaysPermissions(event)
    if (!updatedPermissions) return { hookSpecificOutput: { hookEventName: 'PermissionRequest', decision: { behavior: 'allow', ...echo } } }
    recordAlwaysRule(event, updatedPermissions)
    return { hookSpecificOutput: { hookEventName: 'PermissionRequest', decision: { behavior: 'allow', ...echo, updatedPermissions } } }
  }
  if (decision === 'deny') {
    const d = { behavior: 'deny', message: message || 'Denied from Conductore Mobile' }
    return { hookSpecificOutput: { hookEventName: 'PermissionRequest', decision: d } }
  }
  return null
}

module.exports = { alwaysPermissions, exactRule, permissionOutput, answerInput, INTERACTIVE_TOOLS }
