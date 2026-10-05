'use strict'

// Per-turn snapshots, `turns`, `diff`, `undo` and `redo`: the snapshot
// never touches the index, the stash, HEAD or the branch (checked with git
// status, git stash list and the index's bytes), untracked files are in it
// and ignored ones are not, the hook stays async and fast while a slow
// snapshot runs, undo / per-file undo / redo, refusal while the agent works
// and after it committed, pruning, and the size limits. Every repo is a
// throwaway in a temp dir; every daemon runs on a temp state dir.

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('fs')
const path = require('path')
const { execFile, execFileSync } = require('child_process')
const snapshots = require('../lib/snapshots')
const { Turns, headline } = require('../lib/turns')
const { tempDir, cleanup } = require('./helpers/cleanup')

const HOSTD = path.join(__dirname, '..', 'bin', 'conductore-hostd')
const HOOK = path.join(__dirname, '..', 'bin', 'conductore-hook')
const root = tempDir('cnd-snap-')
const home = path.join(root, 'home')
fs.mkdirSync(home)

// The in-process snapshots (first tests) use this state dir's tmp/ for their
// temporary index, never ~/.conductore.
process.env.CONDUCTORE_HOME = path.join(root, 'inproc')
process.env.HOME = home
const baseEnv = { ...process.env, HOME: home, TMUX_TMPDIR: root, CONDUCTORE_IDLE_EXIT_S: '60' }
for (const k of Object.keys(baseEnv)) if (/^(HERDR_|TMUX$|TMUX_PANE|GIT_)/.test(k)) delete baseEnv[k]

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms))

function g (repo, args, opts = {}) {
  return execFileSync('git', args, { cwd: repo, env: { ...baseEnv, GIT_AUTHOR_NAME: 't', GIT_AUTHOR_EMAIL: 't@t', GIT_COMMITTER_NAME: 't', GIT_COMMITTER_EMAIL: 't@t', ...opts.env }, encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] })
}

// A repo with a commit, a staged change, an unstaged change, an untracked
// file, an ignored file and a stash entry.
function makeRepo (name = 'repo') {
  const repo = path.join(tempDir('cnd-snaprepo-'), name)
  fs.mkdirSync(repo)
  g(repo, ['init', '-q', '-b', 'main'])
  fs.writeFileSync(path.join(repo, '.gitignore'), 'build/\n*.log\n')
  fs.writeFileSync(path.join(repo, 'a.txt'), 'one\ntwo\nthree\n')
  fs.writeFileSync(path.join(repo, 'b.txt'), 'bee\n')
  fs.mkdirSync(path.join(repo, 'src'))
  fs.writeFileSync(path.join(repo, 'src', 'lib.js'), 'module.exports = 1\n')
  g(repo, ['add', '-A'])
  g(repo, ['commit', '-qm', 'init'])
  fs.writeFileSync(path.join(repo, 'b.txt'), 'stashed\n')
  g(repo, ['stash', '-q'])
  fs.writeFileSync(path.join(repo, 'staged.txt'), 'staged\n')
  g(repo, ['add', 'staged.txt'])
  fs.writeFileSync(path.join(repo, 'a.txt'), 'one\ntwo\nthree\nfour (unstaged)\n')
  fs.writeFileSync(path.join(repo, 'untracked.txt'), 'untracked\n')
  fs.mkdirSync(path.join(repo, 'build'))
  fs.writeFileSync(path.join(repo, 'build', 'out.bin'), 'ignored')
  fs.writeFileSync(path.join(repo, 'debug.log'), 'ignored')
  return realRepo(repo)
}

const realRepo = repo => fs.realpathSync(repo)

// Everything the user could see of their repo's git state.
function gitState (repo) {
  return {
    status: g(repo, ['status', '--porcelain=v1', '-uall', '--ignored']),
    stash: g(repo, ['stash', 'list']),
    head: g(repo, ['rev-parse', 'HEAD']),
    branch: g(repo, ['symbolic-ref', 'HEAD']),
    heads: g(repo, ['for-each-ref', 'refs/heads', 'refs/stash', 'refs/tags']),
    staged: g(repo, ['diff', '--cached', '--name-status'])
  }
}

// A daemon of its own: env, hook(), cli().
function companion (extraEnv = {}) {
  const state = tempDir('cnd-snapstate-')
  const env = { ...baseEnv, CONDUCTORE_HOME: state, CONDUCTORE_SOCKET: path.join(state, 'hostd.sock'), ...extraEnv }
  const hook = (event, body) => execFileSync(HOOK, [event], { env, input: JSON.stringify({ hook_event_name: event, ...body }) })
  const cli = (args, extra = {}) => new Promise((resolve, reject) => {
    execFile(process.execPath, [HOSTD, ...args], { env: { ...env, ...extra }, timeout: 60000, maxBuffer: 16 << 20 }, (err, stdout) => {
      if (err && err.code === undefined) return reject(err)
      resolve({ code: err ? err.code : 0, json: JSON.parse(stdout.trim().split('\n').pop()) })
    })
  })
  return { state, env, hook, cli }
}

// Runs one turn: prompt, edits (fn), Stop; waits for both snapshots.
async function turn (c, sid, repo, prompt, fn) {
  c.hook('UserPromptSubmit', { session_id: sid, cwd: repo, prompt })
  await waitFor(c, sid, t => t.before)
  if (fn) fn()
  c.hook('Stop', { session_id: sid, cwd: repo, last_assistant_message: 'done' })
  return waitFor(c, sid, t => t.after && t.files)
}

async function waitFor (c, sid, pred, ms = 15000) {
  let last
  for (const until = Date.now() + ms; Date.now() < until;) {
    last = await c.cli(['turns', sid])
    const t = last.json.turns && last.json.turns[0]
    if (t && pred(t)) return last.json
    await sleep(50)
  }
  assert.fail(`turn never got there: ${JSON.stringify(last && last.json)}`)
}

test.after(async () => { await cleanup() })

// --- the snapshot itself ------------------------------------------------------

test('a snapshot leaves the index, stash, HEAD, branch and work tree alone', async () => {
  const repo = makeRepo()
  const before = gitState(repo)
  const index = fs.readFileSync(path.join(repo, '.git', 'index'))
  const mtimes = ['a.txt', 'staged.txt', 'untracked.txt'].map(f => fs.statSync(path.join(repo, f)).mtimeMs)
  const r = await snapshots.snapshot(repo, { ref: 'refs/conductore/snapshots/t1/1/before', meta: { kind: 'before' } })
  assert.equal(r.ok, true, r.detail)
  assert.deepEqual(gitState(repo), before)
  assert.ok(fs.readFileSync(path.join(repo, '.git', 'index')).equals(index), 'index bytes unchanged')
  assert.deepEqual(['a.txt', 'staged.txt', 'untracked.txt'].map(f => fs.statSync(path.join(repo, f)).mtimeMs), mtimes)
  // No reflog for the snapshot ref, and the stash still has its entry.
  assert.equal(fs.existsSync(path.join(repo, '.git', 'logs', 'refs', 'conductore')), false)
  assert.equal(before.stash.split('\n').filter(Boolean).length, 1)
  // Its parent is HEAD; its tree has the work tree as it is on disk.
  assert.equal(g(repo, ['rev-parse', `${r.commit}^`]).trim(), before.head.trim())
  const files = g(repo, ['ls-tree', '-r', '--name-only', r.commit]).trim().split('\n')
  assert.deepEqual(files.sort(), ['.gitignore', 'a.txt', 'b.txt', 'src/lib.js', 'staged.txt', 'untracked.txt'])
  assert.equal(g(repo, ['show', `${r.commit}:a.txt`]), 'one\ntwo\nthree\nfour (unstaged)\n')
  assert.equal(g(repo, ['show', `${r.commit}:untracked.txt`]), 'untracked\n')
  assert.equal(g(repo, ['rev-parse', 'refs/conductore/snapshots/t1/1/before']).trim(), r.commit)
  // No temp index left behind.
  assert.deepEqual(fs.readdirSync(path.join(process.env.CONDUCTORE_HOME, 'tmp')), [])
})

test('snapshot skips: not a repo, a missing dir, a repo over the index limit, huge untracked files', async () => {
  const plain = tempDir('cnd-plain-')
  assert.equal((await snapshots.snapshot(plain)).reason, 'not a git repo')
  assert.equal((await snapshots.snapshot(path.join(plain, 'nope'))).reason, 'no cwd')
  const repo = makeRepo()
  const big = await snapshots.snapshot(repo, { maxIndexBytes: 10 })
  assert.equal(big.ok, false)
  assert.equal(big.reason, 'repo too large')
  const many = await snapshots.snapshot(repo, { maxUntrackedFiles: 0 })
  assert.equal(many.reason, 'too many untracked files')
  fs.writeFileSync(path.join(repo, 'huge.bin'), Buffer.alloc(4096))
  const one = await snapshots.snapshot(repo, { maxFileBytes: 1024 })
  assert.equal(one.ok, true)
  assert.deepEqual(one.excluded.map(e => e.path), ['huge.bin'])
  assert.equal(g(repo, ['ls-tree', '--name-only', one.commit]).includes('huge.bin'), false)
  const sized = await snapshots.snapshot(repo, { maxUntrackedBytes: 100 })
  assert.equal(sized.reason, 'untracked files too large')
})

test('a nested repository is left out, not a failure; an unborn branch works', async () => {
  const repo = realRepo(tempDir('cnd-unborn-'))
  g(repo, ['init', '-q'])
  fs.writeFileSync(path.join(repo, 'x.txt'), 'x\n')
  fs.mkdirSync(path.join(repo, 'inner'))
  g(path.join(repo, 'inner'), ['init', '-q'])
  fs.writeFileSync(path.join(repo, 'inner', 'y.txt'), 'y\n')
  const r = await snapshots.snapshot(repo)
  assert.equal(r.ok, true, r.detail)
  assert.equal(r.head, null)
  assert.deepEqual(r.excluded.map(e => e.path), ['inner/'])
  assert.equal(g(repo, ['ls-tree', '-r', '--name-only', r.commit]).trim(), 'x.txt')
})

test('diff summarises binaries and caps patches', async () => {
  const repo = makeRepo()
  const a = await snapshots.snapshot(repo)
  fs.writeFileSync(path.join(repo, 'img.png'), Buffer.from([0, 1, 2, 3, 0, 255]))
  fs.writeFileSync(path.join(repo, 'long.txt'), Array.from({ length: 2000 }, (_, i) => `line ${i}`).join('\n') + '\n')
  fs.appendFileSync(path.join(repo, 'a.txt'), 'five\n')
  const b = await snapshots.snapshot(repo)
  const d = await snapshots.diff(repo, a.commit, b.commit, { maxFileBytes: 1000 })
  const by = Object.fromEntries(d.files.map(f => [f.path, f]))
  assert.equal(by['img.png'].binary, true)
  assert.equal(by['img.png'].patch, null)
  assert.equal(by['img.png'].newSize, 6)
  assert.equal(by['img.png'].oldSize, null)
  assert.equal(by['long.txt'].added, 2000)
  assert.equal(by['long.txt'].truncated, true)
  assert.ok(Buffer.byteLength(by['long.txt'].patch) <= 1000)
  assert.match(by['a.txt'].patch, /^@@ .*\n(.*\n)*\+five\n/)
  assert.equal(d.truncated, true)
  const small = await snapshots.diff(repo, a.commit, b.commit, { maxBytes: 50 })
  assert.ok(small.files.some(f => f.omitted))
})

// --- through a real daemon ----------------------------------------------------------

test('turns, diff, undo, per-file undo and redo through a real daemon', async () => {
  const c = companion()
  const repo = makeRepo()
  const sid = 'sess-1'
  try {
    c.hook('SessionStart', { session_id: sid, cwd: repo })
    const start = gitState(repo)
    const t = await turn(c, sid, repo, 'Fix the parser\nplease, and add tests', () => {
      fs.writeFileSync(path.join(repo, 'a.txt'), 'one\nTWO\nthree\nfour (unstaged)\n')
      fs.writeFileSync(path.join(repo, 'src', 'new.js'), 'new\n')
      fs.unlinkSync(path.join(repo, 'untracked.txt'))
      fs.writeFileSync(path.join(repo, 'debug.log'), 'more ignored')
    })
    const t1 = t.turns[0]
    assert.equal(t1.turn, 1)
    assert.equal(t1.prompt, 'Fix the parser')
    assert.equal(t1.running, false)
    assert.equal(t1.committed, false)
    assert.deepEqual(t1.files.map(f => [f.path, f.status]), [['a.txt', 'M'], ['src/new.js', 'A'], ['untracked.txt', 'D']])
    assert.equal(t1.before.ref, `refs/conductore/snapshots/${sid}/1/before`)
    assert.equal(t1.after.ref, `refs/conductore/snapshots/${sid}/1/after`)
    // Nothing of the user's git state moved but the files the "agent" edited.
    const after = gitState(repo)
    assert.equal(after.stash, start.stash)
    assert.equal(after.head, start.head)
    assert.equal(after.branch, start.branch)
    assert.equal(after.staged, start.staged)

    const d = await c.cli(['diff', sid, '1'])
    assert.equal(d.code, 0, JSON.stringify(d.json))
    assert.equal(d.json.live, false)
    assert.deepEqual(d.json.files.map(f => f.path), ['a.txt', 'src/new.js', 'untracked.txt'])
    assert.match(d.json.files[0].patch, /-two\n\+TWO\n/)
    assert.equal(d.json.files[0].added, 1)
    assert.equal(d.json.files[0].removed, 1)
    const one = await c.cli(['diff', sid, '1', '--file', 'src/new.js'])
    assert.deepEqual(one.json.files.map(f => f.path), ['src/new.js'])

    // Dry run: lists, changes nothing.
    const dry = await c.cli(['undo', sid, '1', '--dry-run'])
    assert.equal(dry.code, 0, JSON.stringify(dry.json))
    assert.deepEqual(dry.json.restored.map(r => [r.path, r.action]), [['a.txt', 'write'], ['src/new.js', 'delete'], ['untracked.txt', 'write']])
    assert.equal(fs.readFileSync(path.join(repo, 'a.txt'), 'utf8'), 'one\nTWO\nthree\nfour (unstaged)\n')

    // Per-file undo: only that file.
    const index = fs.readFileSync(path.join(repo, '.git', 'index'))
    const pf = await c.cli(['undo', sid, '1', '--file', 'a.txt'])
    assert.equal(pf.code, 0, JSON.stringify(pf.json))
    assert.deepEqual(pf.json.restored.map(r => r.path), ['a.txt'])
    assert.equal(fs.readFileSync(path.join(repo, 'a.txt'), 'utf8'), 'one\ntwo\nthree\nfour (unstaged)\n')
    assert.ok(fs.existsSync(path.join(repo, 'src', 'new.js')))
    assert.ok(fs.readFileSync(path.join(repo, '.git', 'index')).equals(index), 'index untouched by undo')
    let tv = await c.cli(['turns', sid])
    assert.equal(tv.json.turns[0].undone.kind, 'file')

    // Redo puts back just that file.
    const rd = await c.cli(['redo', sid, '1'])
    assert.equal(rd.code, 0, JSON.stringify(rd.json))
    assert.deepEqual(rd.json.restored.map(r => r.path), ['a.txt'])
    assert.equal(fs.readFileSync(path.join(repo, 'a.txt'), 'utf8'), 'one\nTWO\nthree\nfour (unstaged)\n')
    tv = await c.cli(['turns', sid])
    assert.equal(tv.json.turns[0].undone, null)
    assert.equal((await c.cli(['redo', sid, '1'])).code, 1)

    // Whole-turn undo: tracked and untracked back exactly, the created file gone
    // (and its empty dir), ignored files untouched.
    fs.writeFileSync(path.join(repo, 'src', 'new2.js'), 'x')
    const u = await c.cli(['undo', sid, '1'])
    assert.equal(u.code, 0, JSON.stringify(u.json))
    assert.ok(u.json.redo.ref.startsWith(`refs/conductore/snapshots/${sid}/1/undo-`))
    assert.equal(fs.readFileSync(path.join(repo, 'a.txt'), 'utf8'), 'one\ntwo\nthree\nfour (unstaged)\n')
    assert.equal(fs.readFileSync(path.join(repo, 'untracked.txt'), 'utf8'), 'untracked\n')
    assert.equal(fs.existsSync(path.join(repo, 'src', 'new.js')), false)
    assert.equal(fs.existsSync(path.join(repo, 'src', 'new2.js')), false)
    assert.equal(fs.readFileSync(path.join(repo, 'debug.log'), 'utf8'), 'more ignored')
    assert.ok(fs.existsSync(path.join(repo, 'build', 'out.bin')))
    assert.deepEqual(gitState(repo), start, 'back to the state before the turn')
    assert.ok(fs.readFileSync(path.join(repo, '.git', 'index')).equals(index), 'index untouched by undo')

    // Redo: the undone state comes back, including the file made after the turn.
    const r2 = await c.cli(['redo', sid, '1'])
    assert.equal(r2.code, 0, JSON.stringify(r2.json))
    assert.equal(fs.readFileSync(path.join(repo, 'src', 'new2.js'), 'utf8'), 'x')
    assert.equal(fs.readFileSync(path.join(repo, 'a.txt'), 'utf8'), 'one\nTWO\nthree\nfour (unstaged)\n')
    assert.equal(fs.existsSync(path.join(repo, 'untracked.txt')), false)
  } finally {
    await c.cli(['stop'])
  }
})

test('undo refuses while the agent works, and after it committed (unless --keep-commits)', async () => {
  const c = companion()
  const repo = makeRepo()
  const sid = 'sess-2'
  try {
    c.hook('SessionStart', { session_id: sid, cwd: repo })
    await turn(c, sid, repo, 'first', () => fs.writeFileSync(path.join(repo, 'b.txt'), 'changed\n'))
    // Turn 2 is running.
    c.hook('UserPromptSubmit', { session_id: sid, cwd: repo, prompt: 'second' })
    await waitFor(c, sid, t => t.turn === 2 && t.before)
    const busy = await c.cli(['undo', sid, '1'])
    assert.equal(busy.code, 1)
    assert.equal(busy.json.code, 'busy')
    assert.match(busy.json.error, /agent is working/)
    // While running, diff is against the work tree now.
    fs.writeFileSync(path.join(repo, 'c.txt'), 'c\n')
    const live = await c.cli(['diff', sid, '2'])
    assert.equal(live.json.live, true)
    assert.deepEqual(live.json.files.map(f => f.path), ['c.txt'])
    // The "agent" commits during turn 2.
    g(repo, ['add', 'c.txt'])
    g(repo, ['commit', '-qm', 'agent commit'])
    c.hook('Stop', { session_id: sid, cwd: repo })
    const t = await waitFor(c, sid, x => x.turn === 2 && x.after && x.files)
    assert.equal(t.turns[0].committed, true)
    const head = g(repo, ['rev-parse', 'HEAD'])
    const refused = await c.cli(['undo', sid, '2'])
    assert.equal(refused.code, 1)
    assert.equal(refused.json.code, 'head-moved')
    assert.match(refused.json.error, /committed during this turn.*1 commit/)
    // Turn 1 too: HEAD moved since it started.
    assert.match((await c.cli(['undo', sid, '1'])).json.error, /HEAD moved since this turn started/)
    const kept = await c.cli(['undo', sid, '2', '--keep-commits'])
    assert.equal(kept.code, 0, JSON.stringify(kept.json))
    assert.equal(kept.json.headMoved, true)
    assert.equal(g(repo, ['rev-parse', 'HEAD']), head, 'HEAD never moves')
    assert.equal(fs.existsSync(path.join(repo, 'c.txt')), false)
  } finally {
    await c.cli(['stop'])
  }
})

test('the hook stays async and fast while a slow snapshot runs', async () => {
  // A git that takes 1.5 s for `add`: the snapshot is slow, the hook is not,
  // and the daemon keeps applying events meanwhile.
  const bin = tempDir('cnd-slowgit-')
  const realGit = execFileSync('sh', ['-c', 'command -v git'], { encoding: 'utf8' }).trim()
  fs.writeFileSync(path.join(bin, 'git'), `#!/bin/sh\n[ "$1" = add ] && sleep 1.5\nexec ${realGit} "$@"\n`, { mode: 0o755 })
  const c = companion({ PATH: `${bin}:${baseEnv.PATH}` })
  const repo = makeRepo()
  const sid = 'sess-3'
  try {
    c.hook('SessionStart', { session_id: sid, cwd: repo })
    await c.cli(['status'])
    const times = []
    for (let i = 0; i < 3; i++) {
      const t0 = process.hrtime.bigint()
      c.hook('UserPromptSubmit', { session_id: sid, cwd: repo, prompt: `p${i}` })
      times.push(Number(process.hrtime.bigint() - t0) / 1e6)
      c.hook('Stop', { session_id: sid, cwd: repo })
    }
    times.sort((a, b) => a - b)
    const median = times[1]
    // The hook never waits for git (execFileSync adds its own spawn cost).
    assert.ok(median < 200, `hook median ${median.toFixed(1)} ms`)
    const t0 = Date.now()
    c.hook('UserPromptSubmit', { session_id: sid, cwd: repo, prompt: 'last' })
    let st
    for (let i = 0; i < 40; i++) {
      st = (await c.cli(['status'])).json
      if (st.agents[0] && st.agents[0].state === 'working') break
      await sleep(25)
    }
    assert.equal(st.agents[0].state, 'working')
    assert.ok(Date.now() - t0 < 1500, 'events are applied while snapshots queue')
    const tv = (await c.cli(['turns', sid])).json
    assert.ok(tv.pending > 0, 'snapshots still queued')
  } finally {
    await c.cli(['stop'])
  }
})

test('pruning: the last N turns per session, and stale refs in the repo', async () => {
  const c = companion({ CONDUCTORE_SNAPSHOT_KEEP_TURNS: '2' })
  const repo = makeRepo()
  const sid = 'sess-4'
  // A leftover from a lost record, 30 days old.
  const oldCommit = g(repo, ['commit-tree', 'HEAD^{tree}', '-m', 'old'], { env: { GIT_COMMITTER_DATE: `${Math.floor(Date.now() / 1000) - 30 * 86400} +0000` } }).trim()
  g(repo, ['update-ref', 'refs/conductore/snapshots/gone/1/before', oldCommit])
  try {
    c.hook('SessionStart', { session_id: sid, cwd: repo })
    for (let i = 1; i <= 3; i++) await turn(c, sid, repo, `turn ${i}`, () => fs.writeFileSync(path.join(repo, `f${i}.txt`), `${i}\n`))
    let refs = []
    for (let i = 0; i < 100; i++) {
      refs = g(repo, ['for-each-ref', '--format=%(refname)', 'refs/conductore']).trim().split('\n')
      if (!refs.some(r => r.includes(`/${sid}/1/`)) && !refs.some(r => r.includes('/gone/'))) break
      await sleep(50)
    }
    assert.deepEqual(refs.sort(), [2, 3].flatMap(n => [`refs/conductore/snapshots/${sid}/${n}/after`, `refs/conductore/snapshots/${sid}/${n}/before`]))
    const tv = (await c.cli(['turns', sid])).json
    assert.deepEqual(tv.turns.map(t => t.turn), [3, 2])
    assert.match((await c.cli(['undo', sid, '1'])).json.error, /unknown turn 1/)
  } finally {
    await c.cli(['stop'])
  }
})

test('large repos and non-git dirs are skipped silently; the turn is still listed', async () => {
  const c = companion({ CONDUCTORE_SNAPSHOT_MAX_INDEX_BYTES: '10' })
  const repo = makeRepo()
  const plain = realRepo(tempDir('cnd-plaincwd-'))
  try {
    c.hook('SessionStart', { session_id: 'big', cwd: repo })
    c.hook('UserPromptSubmit', { session_id: 'big', cwd: repo, prompt: 'go' })
    c.hook('Stop', { session_id: 'big', cwd: repo })
    const t = await waitFor(c, 'big', x => x.after)
    assert.equal(t.turns[0].before.skipped, 'repo too large')
    assert.equal(t.turns[0].after.skipped, 'repo too large')
    assert.match((await c.cli(['diff', 'big', '1'])).json.error, /no before snapshot for this turn \(repo too large\)/)
    assert.equal(g(repo, ['for-each-ref', 'refs/conductore']), '')
    c.hook('UserPromptSubmit', { session_id: 'plain', cwd: plain, prompt: 'go' })
    const p = await waitFor(c, 'plain', x => x.before)
    assert.equal(p.turns[0].before.skipped, 'not a git repo')
    // Logged only when it is not the plain "not a repo" case.
    const logText = fs.readFileSync(path.join(c.state, 'hostd.log'), 'utf8')
    assert.match(logText, /skipped before of big turn 1: repo too large/)
    assert.doesNotMatch(logText, /not a git repo/)
  } finally {
    await c.cli(['stop'])
  }
})

test('the capability is reported', async () => {
  const c = companion()
  const v = await c.cli(['version'])
  assert.ok(v.json.capabilities.includes('snapshots'))
})

// --- the turn store, with fake git ---------------------------------------------------

test('turn store: interrupted turns end at the next prompt, late edits are flagged, subagents ignored', async () => {
  const calls = []
  let n = 0
  const t = new Turns(null, {
    snapshot: async (cwd, { ref }) => { calls.push(ref); await sleep(5); return { ok: true, ref, commit: `c${++n}`, head: 'h', repo: '/r', untracked: 0, excluded: [], ms: 1 } },
    changes: async (repo, a, b) => [{ path: `${a}-${b}`, status: 'M', added: 1, removed: 0 }],
    listRefs: async () => [],
    deleteRefs: async () => 0
  })
  t.onEvent({ session_id: 's', hook_event_name: 'UserPromptSubmit', cwd: '/r', prompt: '  \n  hello   world \nmore' })
  t.onEvent({ session_id: 's', hook_event_name: 'PreToolUse', tool_name: 'Edit' })
  t.onEvent({ session_id: 's', hook_event_name: 'UserPromptSubmit', cwd: '/r', prompt: 'again', agent_id: 'sub' })
  t.onEvent({ session_id: 's', hook_event_name: 'Stop', agent_id: 'sub' })
  t.onEvent({ session_id: 's', hook_event_name: 'UserPromptSubmit', cwd: '/r', prompt: 'second' })
  t.onEvent({ session_id: 's', hook_event_name: 'Stop' })
  await t.idle('s')
  const v = t.view('s')
  assert.deepEqual(v.turns.map(x => x.turn), [2, 1])
  assert.equal(v.turns[1].prompt, 'hello world')
  assert.equal(v.turns[1].late, true)
  assert.equal(v.turns[1].after.fromNext, true)
  assert.equal(v.turns[1].after.commit, v.turns[0].before.commit)
  assert.deepEqual(v.turns[1].files.map(f => f.path), ['c1-c2'])
  assert.deepEqual(calls, ['refs/conductore/snapshots/s/1/before', 'refs/conductore/snapshots/s/2/before', 'refs/conductore/snapshots/s/2/after'])
  assert.equal(headline('x'.repeat(500)).length, 160)
  // Session ids that cannot be a ref are never snapshotted.
  t.onEvent({ session_id: '../evil', hook_event_name: 'UserPromptSubmit', cwd: '/r', prompt: 'x' })
  assert.equal(t.view('../evil'), null)
})

test('turn store: sessions quiet for 7 days go with their refs', async () => {
  const deleted = []
  const t = new Turns(null, {
    snapshot: async (cwd, { ref }) => ({ ok: true, ref, commit: 'c', head: 'h', repo: '/r', untracked: 0, excluded: [], ms: 1 }),
    changes: async () => [],
    listRefs: async (repo, prefix) => [{ ref: `${prefix}x`, at: 0 }],
    deleteRefs: async (repo, refs) => { deleted.push(...refs); return refs.length },
    collect: async () => ({ ok: true, skipped: 'test' })
  })
  const old = Date.now() - 8 * 24 * 3600 * 1000
  t.onEvent({ session_id: 'old', hook_event_name: 'UserPromptSubmit', cwd: '/r', prompt: 'x' }, old)
  t.onEvent({ session_id: 'old', hook_event_name: 'Stop' }, old)
  await t.idle('old')
  t.prune()
  await sleep(20)
  assert.equal(t.view('old'), null)
  assert.ok(deleted.includes('refs/conductore/snapshots/old/x'))
})

test('collect: old unreachable loose objects go, reachable ones are packed; HEAD, branches, index, stash and reflogs stay', async () => {
  const repo = makeRepo()
  const objectsOf = () => g(repo, ['count-objects', '-v']).match(/^count: (\d+)/m)[1] | 0
  // Reachable: a snapshot ref. Unreachable: blobs of deleted snapshots,
  // 30 days old, and one written just now (an operation in flight).
  const r = await snapshots.snapshot(repo, { ref: 'refs/conductore/snapshots/keep/1/before', meta: {} })
  assert.equal(r.ok, true, r.detail)
  const hash = text => execFileSync('git', ['hash-object', '-w', '--stdin'], { cwd: repo, input: text, encoding: 'utf8' }).trim()
  const old = []
  for (let i = 0; i < 20; i++) old.push(hash(`old ${i}\n`))
  const fresh = hash('fresh\n')
  const objFile = id => path.join(repo, '.git', 'objects', id.slice(0, 2), id.slice(2))
  const monthAgo = Date.now() / 1000 - 30 * 86400
  for (const id of old) fs.utimesSync(objFile(id), monthAgo, monthAgo)
  const before = gitState(repo)
  const index = fs.readFileSync(path.join(repo, '.git', 'index'))
  const reflog = g(repo, ['reflog', 'show', '--all'])
  const loose = objectsOf()

  // Few loose objects: nothing runs.
  const skipped = await snapshots.collect(repo, { expireMs: 7 * 86400000, minLoose: 100000 })
  assert.equal(skipped.skipped, 'few loose objects')
  assert.equal(objectsOf(), loose)

  const res = await snapshots.collect(repo, { expireMs: 7 * 86400000, minLoose: 1 })
  assert.equal(res.ok, true, res.skipped)
  for (const id of old) assert.equal(fs.existsSync(objFile(id)), false, `old unreachable ${id} pruned`)
  assert.doesNotThrow(() => g(repo, ['cat-file', '-e', fresh]), 'a fresh unreachable object stays (grace)')
  assert.doesNotThrow(() => g(repo, ['cat-file', '-e', `${r.commit}^{tree}`]), 'the snapshot is still readable')
  assert.ok(res.after < loose, `loose objects ${loose} -> ${res.after}`)
  assert.deepEqual(gitState(repo), before)
  assert.ok(fs.readFileSync(path.join(repo, '.git', 'index')).equals(index), 'index bytes unchanged')
  assert.equal(g(repo, ['reflog', 'show', '--all']), reflog, 'reflogs unchanged')
  assert.equal(fs.existsSync(path.join(repo, '.git', 'packed-refs')), false, 'refs not packed')

  // The owner turned automatic gc off: left alone.
  g(repo, ['config', 'gc.auto', '0'])
  assert.equal((await snapshots.collect(repo, { expireMs: 0, minLoose: 0 })).skipped, 'gc.auto is 0')
})

test('turn store: a prune that deleted refs queues one collect per repo, at most once a day', async () => {
  const collected = []
  const t = new Turns(null, {
    snapshot: async () => ({ ok: false, reason: 'no cwd' }),
    changes: async () => [],
    listRefs: async (repo, prefix) => [{ ref: `${prefix}x`, at: 0 }],
    deleteRefs: async (repo, refs) => refs.length,
    collect: async (repo, opts) => { collected.push([repo, opts.expireMs]); return { ok: true, before: 9, after: 1 } }
  })
  t.enqueue({ kind: 'prune', repo: '/r1', prefix: 'refs/conductore/snapshots/a/' })
  t.enqueue({ kind: 'prune', repo: '/r1', prefix: 'refs/conductore/snapshots/b/' })
  t.enqueue({ kind: 'prune', repo: '/r2', prefix: 'refs/conductore/snapshots/c/' })
  for (let i = 0; i < 50 && (t.running || t.queue.length); i++) await sleep(10)
  assert.deepEqual(collected.map(c => c[0]).sort(), ['/r1', '/r2'])
  assert.ok(collected.every(c => c[1] > 0), 'the keep time is passed on')
  assert.ok(t.toJSON().collected['/r1'], 'remembered in turns.json')
  // Restored from turns.json: still throttled.
  const again = new Turns(JSON.parse(JSON.stringify(t.toJSON())), { ...t.ops })
  again.ops.collect = async repo => { collected.push([repo]); return { ok: true } }
  again.enqueue({ kind: 'prune', repo: '/r1', prefix: 'refs/conductore/snapshots/d/' })
  for (let i = 0; i < 50 && (again.running || again.queue.length); i++) await sleep(10)
  assert.equal(collected.length, 2)
})
