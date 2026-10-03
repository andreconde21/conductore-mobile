'use strict'

// PermissionRequest decisions: the exact stdout JSON Claude Code expects
// (https://code.claude.com/docs/en/hooks#permissionrequest-decision-control).
// The daemon builds the line and writes it into the waiting hook's FIFO; the
// sh hook prints it unchanged.

const fs = require('fs')
const paths = require('./paths')
const { log } = require('./log')

// Tools whose approval card is itself the user's input (Claude Code's
// requiresUserInteraction): a hook's plain `allow` is ignored for them and
// the terminal dialog stays up. Claude Code takes an allow only with an
// `updatedInput`: the answers for AskUserQuestion, the unchanged input for
// ExitPlanMode (checked in Claude Code 2.1.285).
const INTERACTIVE_TOOLS = new Set(['AskUserQuestion', 'ExitPlanMode'])

// updatedPermissions for an "always" decision: prefer what Claude Code itself
// suggested, else a rule scoped to this exact command/path.
function alwaysPermissions (event) {
  // A plan's "always" is "approve and auto-accept edits", Claude Code's own
  // second plan option: a mode for this session, never a rule that would
  // approve every later plan.
  if (event.tool_name === 'ExitPlanMode') return [{ type: 'setMode', mode: 'acceptEdits', destination: 'session' }]
  const suggested = (event.permission_suggestions || []).filter(s => s && s.type === 'addRules' && s.behavior === 'allow' && Array.isArray(s.rules) && s.rules.length)
  if (suggested.length) return [suggested[0]]
  const input = event.tool_input || {}
  const rule = { toolName: event.tool_name }
  if (event.tool_name === 'Bash' && typeof input.command === 'string') rule.ruleContent = input.command
  else if (typeof input.file_path === 'string') rule.ruleContent = input.file_path
  return [{ type: 'addRules', rules: [rule], behavior: 'allow', destination: 'localSettings' }]
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
    recordAlwaysRule(event, updatedPermissions)
    return { hookSpecificOutput: { hookEventName: 'PermissionRequest', decision: { behavior: 'allow', ...echo, updatedPermissions } } }
  }
  if (decision === 'deny') {
    const d = { behavior: 'deny', message: message || 'Denied from Conductore Mobile' }
    return { hookSpecificOutput: { hookEventName: 'PermissionRequest', decision: d } }
  }
  return null
}

module.exports = { alwaysPermissions, permissionOutput, answerInput, INTERACTIVE_TOOLS }
