'use strict'

// `turns`, `diff`, `undo` and `redo`: the phone's Review mode and "Undo
// this turn", on top of the daemon's per-turn snapshots (turns.js,
// snapshots.js). CLI one-shots: the daemon only supplies the turn records.

const fs = require('fs')
const paths = require('./paths')
const client = require('./client')
const snapshots = require('./snapshots')
const { Turns } = require('./turns')

const BUSY_STATES = new Set(['working', 'needs_permission'])

// The session's turn records: from the daemon (after its queued snapshots
// finished, with `wait`), else turns.json. { agent, record, idle } or { error }.
async function turnData (sessionId, { wait = false, limit = 50 } = {}) {
  const ask = async () => {
    const [res] = await client.request({ op: 'turns', sessionId, wait, limit }, { timeoutMs: wait ? 30000 : 5000 })
    if (res && res.ok) return { agent: res.agent, record: res.record, idle: res.idle, source: 'daemon' }
    if (res && /unknown op/.test(res.error || '')) return { error: 'the running companion predates snapshots; restart it with `conductore-hostd stop` (the next hook event starts the new one)' }
    return null
  }
  try { const r = await ask(); if (r) return r } catch {}
  if (require('./spool').isSpooled(paths.spoolDir())) {
    try { await client.ensureDaemon(); const r = await ask(); if (r) return r } catch {}
  }
  try {
    const t = new Turns(JSON.parse(fs.readFileSync(paths.turnsPath(), 'utf8')))
    return { agent: null, record: t.view(sessionId, limit), idle: true, source: 'file' }
  } catch {
    return { agent: null, record: null, idle: true, source: 'none' }
  }
}

// Undo/redo refs of a session in a repo, by turn: the newest `undo-*` /
// `undofile-*` still waiting for a `redo-*`.
async function undoState (repo, sessionId) {
  const byTurn = new Map()
  for (const r of await snapshots.listRefs(repo, `${snapshots.REF_ROOT}/${sessionId}/`, Date.now() + 5000)) {
    const m = r.ref.slice(snapshots.REF_ROOT.length + sessionId.length + 2).match(/^(\d+)\/(undo|undofile|redo)-(\d+)$/)
    if (!m) continue
    const n = Number(m[1])
    const e = { ref: r.ref, commit: r.commit, kind: m[2], at: Number(m[3]) }
    const cur = byTurn.get(n)
    if (!cur || e.at > cur.at) byTurn.set(n, e)
  }
  const out = new Map()
  for (const [n, e] of byTurn) if (e.kind !== 'redo') out.set(n, e)
  return out
}

// The turn n of a session, with its agent. { agent, turn, record } or { error }.
async function findTurn (sessionId, n, { wait = true } = {}) {
  if (!snapshots.SESSION_RE.test(sessionId)) return { error: `bad session id ${sessionId}` }
  const data = await turnData(sessionId, { wait, limit: 1000 })
  if (data.error) return data
  if (!data.record) return { error: `no turns recorded for session ${sessionId}` }
  const turn = data.record.turns.find(t => t.turn === n)
  if (!turn) return { error: `unknown turn ${n} (kept: the last ${require('./turns').KEEP_TURNS} turns, 7 days)` }
  return { agent: data.agent, turn, record: data.record, idle: data.idle }
}

function snapshotMissing (snap, which) {
  if (!snap) return `the ${which} snapshot of this turn is not taken yet`
  if (snap.skipped) return `no ${which} snapshot for this turn (${snap.skipped})`
  return null
}

// `turns <sessionId> [--limit 20]`
async function turnsCmd (sessionId, { limit = 20 } = {}) {
  if (!snapshots.SESSION_RE.test(sessionId || '')) return { error: 'usage: turns <sessionId> [--limit 20]' }
  const data = await turnData(sessionId, { limit })
  if (data.error) return data
  const record = data.record || { cwd: null, turns: [], pending: 0 }
  const repos = [...new Set(record.turns.map(t => t.repo).filter(Boolean))]
  const undone = new Map()
  for (const repo of repos) for (const [n, e] of await undoState(repo, sessionId)) undone.set(`${repo}\0${n}`, e)
  const turns = record.turns.map(t => {
    const u = t.repo ? undone.get(`${t.repo}\0${t.turn}`) : null
    return { ...t, undone: u ? { at: u.at, kind: u.kind === 'undofile' ? 'file' : 'turn', ref: u.ref } : null }
  })
  return { sessionId, snapshots: true, source: data.source, agent: data.agent, cwd: record.cwd, pending: record.pending || 0, turns }
}

// `diff <sessionId> <turn> [--file <path>…] [--max-bytes N] [--max-file-bytes N] [--context 3]`
async function diffCmd (sessionId, n, { files = [], maxBytes, maxFileBytes, context } = {}) {
  const found = await findTurn(sessionId, n)
  if (found.error) return found
  const t = found.turn
  const missing = snapshotMissing(t.before, 'before')
  if (missing) return { error: missing }
  const deadline = Date.now() + 30000
  let to = t.after && t.after.commit
  let live = false
  if (!to) {
    // Still running (or its end was not captured): against the work tree now.
    try {
      to = (await snapshots.captureTree(t.repo, { deadline })).tree
      live = true
    } catch (err) {
      return { error: `cannot read the work tree: ${err.message}` }
    }
  }
  try {
    const d = await snapshots.diff(t.repo, t.before.commit, to, { deadline, paths: files.length ? files : null, maxBytes, maxFileBytes, context })
    return {
      sessionId,
      turn: n,
      prompt: t.prompt,
      repo: t.repo,
      startedAt: t.startedAt,
      endedAt: t.endedAt,
      live,
      committed: !!t.committed,
      late: !!t.late,
      others: t.others || [],
      added: d.files.reduce((s, f) => s + f.added, 0),
      removed: d.files.reduce((s, f) => s + f.removed, 0),
      truncated: d.truncated,
      files: d.files.map(({ oldMode, newMode, ...f }) => ({ ...f, mode: newMode !== '000000' ? newMode : oldMode }))
    }
  } catch (err) {
    return { error: `diff failed: ${err.message}` }
  }
}

function busyError (agent) {
  if (agent && BUSY_STATES.has(agent.state)) {
    return agent.state === 'needs_permission'
      ? 'the agent is waiting for a permission decision; answer it and let the turn end before undoing'
      : 'the agent is working; wait for its turn to end (or interrupt it) before undoing'
  }
  return null
}

// HEAD must still be where the snapshot was taken from: files are restored,
// commits never. { error } or null.
async function headCheck (repo, t, keepCommits) {
  const loc = await snapshots.locate(repo, Date.now() + 5000)
  const startHead = t.before.head || null
  if (loc.head === startHead || keepCommits) return { head: loc.head, moved: loc.head !== startHead }
  const short = h => (h ? h.slice(0, 10) : 'none')
  const during = t.after && t.after.commit && t.after.head !== startHead
  let count = ''
  if (startHead && loc.head) {
    const r = await snapshots.git(['rev-list', '--count', `${startHead}..${loc.head}`], { cwd: repo, deadline: Date.now() + 5000 })
    if (r.code === 0) count = ` (${r.stdout.toString().trim()} commit(s))`
  }
  const why = during
    ? `the agent committed during this turn: HEAD moved from ${short(startHead)} to ${short(loc.head)}${count}`
    : `HEAD moved since this turn started, from ${short(startHead)} to ${short(loc.head)}${count}`
  return { error: `${why}. Undo restores files and never touches commits or branches, so it was refused. Pass --keep-commits to restore the files anyway (the commits stay; the work tree will show their changes reverted), or reset the branch yourself.`, code: 'head-moved' }
}

async function withStaged (repo, result) {
  if (!result.restored.length) return result
  const staged = new Set(await snapshots.stagedPaths(repo, Date.now() + 5000))
  const still = result.restored.map(r => r.path).filter(p => staged.has(p))
  return still.length ? { ...result, staged: still, note: 'the index still stages changes to these files (undo never touches the index)' } : result
}

// `undo <sessionId> <turn> [--file <path>…] [--dry-run] [--keep-commits]`
async function undoCmd (sessionId, n, { files = [], dryRun = false, keepCommits = false } = {}) {
  const found = await findTurn(sessionId, n)
  if (found.error) return found
  const busy = busyError(found.agent)
  if (busy) return { error: busy, code: 'busy' }
  const t = found.turn
  const missing = snapshotMissing(t.before, 'before')
  if (missing) return { error: missing }
  const repo = t.repo
  let head
  try {
    head = await headCheck(repo, t, keepCommits)
  } catch (err) {
    return { error: `cannot read the repository: ${err.message}` }
  }
  if (head.error) return { error: head.error, code: head.code }
  let meta = {}
  try { meta = (await snapshots.readCommit(repo, t.before.commit, Date.now() + 5000)).meta } catch {}
  const kind = files.length ? 'undofile' : 'undo'
  const at = Date.now()
  try {
    const r = await snapshots.restore(repo, t.before.commit, {
      only: files.length ? files : null,
      dryRun,
      redoRef: snapshots.refFor(sessionId, n, `${kind}-${at}`),
      redoMeta: { kind, session: sessionId, turn: n },
      protect: (meta.excluded || []).map(e => e.path)
    })
    const later = found.record.turns.filter(x => x.turn > n).map(x => x.turn).sort((a, b) => a - b)
    const out = { ok: true, sessionId, turn: n, dryRun, repo, restored: r.restored, skipped: r.skipped, redo: r.redo ? { ref: r.redo.ref } : null, headMoved: head.moved, laterTurns: files.length ? [] : later, others: t.others || [] }
    return dryRun ? out : await withStaged(repo, out)
  } catch (err) {
    return { error: `undo failed: ${err.message}` }
  }
}

// `redo <sessionId> <turn> [--dry-run]`: puts back what the last undo of
// that turn changed (only those paths), from the snapshot the undo took.
async function redoCmd (sessionId, n, { dryRun = false } = {}) {
  const found = await findTurn(sessionId, n)
  if (found.error) return found
  const busy = busyError(found.agent)
  if (busy) return { error: busy, code: 'busy' }
  const t = found.turn
  if (!t.repo) return { error: 'nothing to redo' }
  const u = (await undoState(t.repo, sessionId)).get(n)
  if (!u) return { error: 'nothing to redo for this turn' }
  try {
    const c = await snapshots.readCommit(t.repo, u.commit, Date.now() + 5000)
    const head = await snapshots.locate(t.repo, Date.now() + 5000)
    if (head.head !== c.parent) return { error: 'HEAD moved since the undo; redo refused (it restores files only)', code: 'head-moved' }
    const only = Array.isArray(c.meta.paths) && c.meta.paths.length ? c.meta.paths : null
    const r = await snapshots.restore(t.repo, u.commit, {
      only,
      dryRun,
      redoRef: snapshots.refFor(sessionId, n, `redo-${Date.now()}`),
      redoMeta: { kind: 'redo', session: sessionId, turn: n, undo: u.ref },
      protect: (c.meta.excluded || []).map(e => e.path)
    })
    const out = { ok: true, sessionId, turn: n, dryRun, repo: t.repo, restored: r.restored, skipped: r.skipped, from: u.ref }
    return dryRun ? out : await withStaged(t.repo, out)
  } catch (err) {
    return { error: `redo failed: ${err.message}` }
  }
}

module.exports = { turnsCmd, diffCmd, undoCmd, redoCmd, turnData, undoState }
