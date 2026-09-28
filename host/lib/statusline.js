'use strict'

// Claude Code statusline integration: context and rate-limit usage per session.
//
// Claude Code pipes a JSON document to the statusline command on stdin
// (https://code.claude.com/docs/en/statusline). bin/conductore-statusline
// (sh) spools it for the daemon, which maps it into a `usage` record with
// usageFrom(), and prints a status line: its own (the sh twin of
// defaultLine()) or, with --chain, the output of the user's previous
// statusline command fed the same stdin. `conductore-hostd statusline` is
// the Node version from 0.3; install migrates it to the sh one.

const path = require('path')

// Ours: the sh client, or the Node command of 0.3.
const MARK = /(^|[/'" ])(conductore-statusline|conductore-hostd'? statusline)'?( |$)/
const LEGACY = /(^|[/'" ])conductore-hostd'? statusline( |$)/

function num (v) {
  return typeof v === 'number' && Number.isFinite(v) ? v : null
}

function windowLabel (size) {
  const n = num(size)
  if (!n || n <= 0) return null
  if (n >= 1000000) return `${+(n / 1000000).toFixed(1)}M`
  if (n >= 1000) return `${Math.round(n / 1000)}k`
  return String(n)
}

const LIMITS = [['five_hour', '5h'], ['seven_day', '7d'], ['spend_limit', 'spend']]

// Statusline JSON -> the `usage` record (docs/usage-proposal.md), or null.
function usageFrom (input) {
  if (!input || typeof input !== 'object') return null
  const usage = {}
  const cw = input.context_window
  if (cw && typeof cw === 'object') {
    const pct = num(cw.used_percentage)
    if (pct !== null) usage.contextUsedPct = Math.max(0, Math.min(100, pct))
    const tokens = num(cw.total_input_tokens)
    if (tokens !== null) usage.contextTokens = tokens
    const label = windowLabel(cw.context_window_size)
    if (label) usage.windowLabel = label
  }
  const rl = input.rate_limits
  if (rl && typeof rl === 'object') {
    const limits = []
    for (const [key, label] of LIMITS) {
      const w = rl[key]
      if (!w || typeof w !== 'object') continue
      const used = num(w.used_percentage)
      if (used === null) continue
      const entry = { label, usedPct: Math.max(0, Math.min(100, used)) }
      const resets = num(w.resets_at)
      if (resets !== null) entry.resetsAt = Math.round(resets * 1000)
      limits.push(entry)
    }
    if (limits.length) usage.limits = limits
  }
  // The session's estimated cost so far (the Herdr sidebar's tokens).
  const cost = input.cost && num(input.cost.total_cost_usd)
  if (cost !== null && cost !== undefined && cost >= 0) usage.costUsd = Math.round(cost * 10000) / 10000
  return Object.keys(usage).length ? usage : null
}

// The line printed when there is no chained statusline.
function defaultLine (input) {
  if (!input || typeof input !== 'object') return 'conductore'
  const parts = []
  const model = input.model && input.model.display_name
  if (typeof model === 'string' && model) parts.push(model)
  const dir = (input.workspace && input.workspace.current_dir) || input.cwd
  if (typeof dir === 'string' && dir) parts.push(path.basename(dir) || dir)
  const usage = usageFrom(input)
  if (usage && usage.contextUsedPct !== undefined) parts.push(`${Math.round(usage.contextUsedPct)}% ctx`)
  const fiveHour = usage && (usage.limits || []).find(l => l.label === '5h')
  if (fiveHour) parts.push(`5h ${Math.round(fiveHour.usedPct)}%`)
  return parts.length ? parts.join(' · ') : 'conductore'
}

const quote = s => `'${s.replace(/'/g, "'\\''")}'`

// slBin: path of bin/conductore-statusline.
function command (slBin, chain) {
  return quote(slBin) + (chain ? ` --chain ${quote(chain)}` : '')
}

function isOurs (statusLine) {
  return !!(statusLine && typeof statusLine.command === 'string' && MARK.test(statusLine.command))
}

// The wrapped command of one of our statusLine entries, or null.
function chainOf (statusLine) {
  if (!isOurs(statusLine)) return null
  const m = /statusline'? --chain '((?:[^']|'\\'')*)'\s*$/.exec(statusLine.command)
  return m ? m[1].replace(/'\\''/g, "'") : null
}

// Sets statusLine to ours: plain when unset, wrapping the user's command with
// --chain otherwise (its other fields, e.g. padding, are kept). Idempotent.
// Returns { settings, action: 'set' | 'wrapped' | 'updated' | 'unchanged' }.
function merge (settings, slBin) {
  const out = JSON.parse(JSON.stringify(settings || {}))
  const current = out.statusLine
  let action
  if (!current || typeof current !== 'object' || typeof current.command !== 'string' || !current.command.trim()) {
    out.statusLine = { type: 'command', command: command(slBin) }
    action = 'set'
  } else if (isOurs(current)) {
    const next = command(slBin, chainOf(current))
    action = next === current.command ? 'unchanged' : 'updated'
    out.statusLine = { ...current, command: next }
  } else {
    out.statusLine = { ...current, type: 'command', command: command(slBin, current.command) }
    action = 'wrapped'
  }
  return { settings: out, action }
}

// Removes ours, restoring the wrapped command when there was one.
function unmerge (settings) {
  const out = JSON.parse(JSON.stringify(settings || {}))
  if (!isOurs(out.statusLine)) return out
  const chain = chainOf(out.statusLine)
  if (chain) out.statusLine = { ...out.statusLine, command: chain }
  else delete out.statusLine
  return out
}

function describe (settings) {
  const sl = settings && settings.statusLine
  if (!sl) return { wired: false, detail: 'not set (usage is not reported)' }
  if (!isOurs(sl)) return { wired: false, detail: `another statusline is set: ${sl.command}; run install to wrap it` }
  const chain = chainOf(sl)
  const legacy = LEGACY.test(sl.command) ? ' (Node statusline from 0.3; run install to switch to the sh one)' : ''
  return { wired: true, detail: (chain ? `wired, wrapping: ${chain}` : 'wired') + legacy }
}

module.exports = { usageFrom, defaultLine, command, isOurs, chainOf, merge, unmerge, describe, windowLabel }
