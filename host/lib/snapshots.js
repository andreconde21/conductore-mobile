'use strict'

// Git snapshots of an agent's work tree, for `turns`, `diff` and `undo`.
//
// A snapshot is an ordinary commit object (tree = the work tree's tracked
// and untracked, non-ignored files; parent = HEAD) kept alive by a ref
// under refs/conductore/snapshots/<session>/<turn>/<kind>. It is made with
// plumbing only and a TEMPORARY index file (GIT_INDEX_FILE), so the user's
// branch, index, stash, work tree and HEAD are never touched:
//
//   cp .git/index <tmp>                  (stat data: only changed files are hashed)
//   GIT_INDEX_FILE=<tmp> git add -u      (tracked files as they are on disk)
//   git ls-files -o --exclude-standard   (untracked, not ignored)
//   GIT_INDEX_FILE=<tmp> git update-index --add --remove -z --stdin
//   GIT_INDEX_FILE=<tmp> git write-tree
//   git commit-tree <tree> -p HEAD       (identity: Conductore; no hooks run)
//   git update-ref <ref> <commit>        (no reflog outside refs/heads)
//
// Every git runs with GIT_OPTIONAL_LOCKS=0 (a read never refreshes the real
// index), inherited GIT_* variables removed, at nice 10 (Linux derives
// the I/O priority from it: best-effort 6, unless set otherwise), in its
// own process group, killed at the deadline. Anything that fails makes the snapshot a skip with a reason;
// nothing here throws at the daemon.
//
// Restoring (`undo`) reads a snapshot into another temporary index and
// writes the files with `checkout-index`; files the snapshot does not hold
// are deleted. HEAD, branches, the index and the stash stay as they are.

const fs = require('fs')
const os = require('os')
const path = require('path')
const crypto = require('crypto')
const { spawn } = require('child_process')
const paths = require('./paths')

const REF_ROOT = 'refs/conductore/snapshots'
const SESSION_RE = /^[A-Za-z0-9_-]{1,128}$/
const DEFAULT_TIMEOUT_MS = 20000
const MAX_EXCLUDED = 200
const ARG_BUDGET = 256 * 1024
const MIN_PIECE = 256
// git gc's default gc.pruneExpire (2.weeks.ago).
const PRUNE_EXPIRE_MIN_S = 14 * 24 * 60 * 60
const IDENTITY = { name: 'Conductore', email: 'conductore@localhost' }

const envInt = (name, fallback) => {
  const v = Number(process.env[name])
  return Number.isFinite(v) && v >= 0 ? v : fallback
}

// Repos over these are skipped (checked before any hashing): the index's
// size tracks the number of tracked files (~100 bytes each), and the
// untracked files are counted and sized before they are added.
function limits () {
  return {
    maxIndexBytes: envInt('CONDUCTORE_SNAPSHOT_MAX_INDEX_BYTES', 16 * 1024 * 1024),
    maxUntrackedFiles: envInt('CONDUCTORE_SNAPSHOT_MAX_UNTRACKED', 20000),
    maxUntrackedBytes: envInt('CONDUCTORE_SNAPSHOT_MAX_UNTRACKED_BYTES', 256 * 1024 * 1024),
    // One untracked file above this is left out (listed in `excluded`).
    maxFileBytes: envInt('CONDUCTORE_SNAPSHOT_MAX_FILE_BYTES', 32 * 1024 * 1024),
    timeoutMs: envInt('CONDUCTORE_SNAPSHOT_TIMEOUT_MS', DEFAULT_TIMEOUT_MS)
  }
}

// The environment every git runs with: nothing inherited that could point
// it at another index, directory or repo, never a prompt or an editor.
function gitEnv (extra = {}) {
  const env = {}
  for (const [k, v] of Object.entries(process.env)) if (!/^GIT_/.test(k)) env[k] = v
  return {
    ...env,
    GIT_OPTIONAL_LOCKS: '0',
    GIT_TERMINAL_PROMPT: '0',
    GIT_LITERAL_PATHSPECS: '1',
    GIT_AUTHOR_NAME: IDENTITY.name,
    GIT_AUTHOR_EMAIL: IDENTITY.email,
    GIT_COMMITTER_NAME: IDENTITY.name,
    GIT_COMMITTER_EMAIL: IDENTITY.email,
    LC_ALL: 'C',
    ...extra
  }
}

// Running gits, so a stopping daemon can end them (killAll).
const live = new Set()

function killAll () {
  for (const child of live) try { process.kill(-child.pid, 'SIGKILL') } catch {}
  live.clear()
}

// Runs git. Resolves { code, stdout (Buffer), stderr (string) }; code is
// null when it was killed (deadline) and 'ENOENT' when git is missing.
function git (args, { cwd, env, input, deadline, maxBytes = 64 * 1024 * 1024, index } = {}) {
  return new Promise(resolve => {
    const remaining = deadline ? deadline - Date.now() : DEFAULT_TIMEOUT_MS
    if (remaining <= 0) return resolve({ code: null, stdout: Buffer.alloc(0), stderr: 'timeout' })
    const extra = index ? { GIT_INDEX_FILE: index } : {}
    let child
    try {
      child = spawn('git', args, { cwd, env: env || gitEnv(extra), detached: true, stdio: ['pipe', 'pipe', 'pipe'] })
    } catch (err) {
      return resolve({ code: 'ENOENT', stdout: Buffer.alloc(0), stderr: err.message })
    }
    try { os.setPriority(child.pid, 10) } catch {}
    live.add(child)
    const out = []
    let outBytes = 0
    let err = ''
    let killed = false
    const kill = why => {
      if (killed) return
      killed = why
      try { process.kill(-child.pid, 'SIGKILL') } catch { try { child.kill('SIGKILL') } catch {} }
    }
    const timer = setTimeout(() => kill('timeout'), remaining)
    child.stdout.on('data', d => {
      outBytes += d.length
      if (outBytes > maxBytes) return kill('too much output')
      out.push(d)
    })
    child.stderr.on('data', d => { if (err.length < 8192) err += d })
    child.on('error', e => {
      live.delete(child)
      clearTimeout(timer)
      resolve({ code: e.code === 'ENOENT' ? 'ENOENT' : null, stdout: Buffer.alloc(0), stderr: e.message })
    })
    child.on('close', code => {
      live.delete(child)
      clearTimeout(timer)
      resolve({ code: killed ? null : code, stdout: Buffer.concat(out), stderr: killed || err })
    })
    child.stdin.on('error', () => {})
    if (input !== undefined) child.stdin.end(input)
    else child.stdin.end()
  })
}

class SnapshotError extends Error {
  constructor (reason, detail) {
    super(detail ? `${reason}: ${detail}` : reason)
    this.reason = reason
  }
}

async function gitOk (args, opts, what) {
  const r = await git(args, opts)
  if (r.code === 'ENOENT') throw new SnapshotError('git missing')
  if (r.code === null) throw new SnapshotError('timeout', `${what || args[0]}`)
  if (r.code !== 0) throw new SnapshotError('git failed', `${what || args[0]}: ${String(r.stderr).trim().split('\n')[0]}`)
  return r.stdout
}

const lines0 = buf => buf.toString('utf8').split('\0').filter(Boolean)

// The work tree of cwd: { repo, gitDir, index, head } or throws a skip.
async function locate (cwd, deadline) {
  if (!cwd || typeof cwd !== 'string' || !path.isAbsolute(cwd)) throw new SnapshotError('no cwd')
  try { if (!fs.statSync(cwd).isDirectory()) throw new Error() } catch { throw new SnapshotError('no cwd') }
  // One git for all four; on an unborn branch HEAD fails, so ask again without it.
  const base = ['rev-parse', '--is-inside-work-tree', '--show-toplevel', '--absolute-git-dir']
  let r = await git([...base, 'HEAD^{commit}', '--'], { cwd, deadline })
  if (r.code === 'ENOENT') throw new SnapshotError('git missing')
  let head = null
  if (r.code === 0) head = r.stdout.toString('utf8').trim().split('\n')[3] || null
  else r = await git(base, { cwd, deadline })
  if (r.code !== 0) throw new SnapshotError('not a git repo')
  const [inside, repo, gitDir] = r.stdout.toString('utf8').trim().split('\n')
  if (inside !== 'true' || !repo || !gitDir) throw new SnapshotError('not a git repo')
  return { repo, gitDir, index: path.join(gitDir, 'index'), head }
}

function tmpIndexPath () {
  paths.ensureDirs()
  return path.join(paths.tmpDir(), `snap-${process.pid}-${crypto.randomBytes(6).toString('hex')}.index`)
}

function dropIndex (file) {
  for (const f of [file, `${file}.lock`]) try { fs.unlinkSync(f) } catch {}
}

// The work tree as a tree object, through a temporary index. Resolves
// { repo, head, tree, untracked, excluded, ms } or throws a SnapshotError.
async function captureTree (cwd, opts = {}) {
  const lim = { ...limits(), ...opts }
  const started = Date.now()
  const deadline = opts.deadline || started + lim.timeoutMs
  const loc = opts.location || await locate(cwd, deadline)
  let indexSize = 0
  try { indexSize = fs.statSync(loc.index).size } catch {}
  if (indexSize > lim.maxIndexBytes) throw new SnapshotError('repo too large', `index ${indexSize} bytes`)
  const tmp = tmpIndexPath()
  try {
    // A copy of the real index, read once (git replaces it by rename, so a
    // read is never torn): its stat data spares hashing unchanged files.
    if (indexSize) fs.copyFileSync(loc.index, tmp)
    const o = { cwd: loc.repo, deadline, index: tmp }
    await gitOk(['add', '-u'], o, 'add -u')
    const untracked = lines0(await gitOk(['ls-files', '-z', '-o', '--exclude-standard'], { ...o, maxBytes: 32 * 1024 * 1024 }, 'ls-files'))
    if (untracked.length > lim.maxUntrackedFiles) throw new SnapshotError('too many untracked files', String(untracked.length))
    const add = []
    const excluded = []
    let bytes = 0
    for (const rel of untracked) {
      // A nested repository shows as "dir/": left alone, like git add -A would.
      if (rel.endsWith('/')) { excluded.push({ path: rel, reason: 'nested repository' }); continue }
      let st
      try { st = fs.lstatSync(path.join(loc.repo, rel)) } catch { continue }
      if (st.isFile() && st.size > lim.maxFileBytes) { excluded.push({ path: rel, reason: 'too large', size: st.size }); continue }
      bytes += st.isFile() ? st.size : 0
      add.push(rel)
    }
    if (bytes > lim.maxUntrackedBytes) throw new SnapshotError('untracked files too large', `${bytes} bytes`)
    if (add.length) await gitOk(['update-index', '--add', '--remove', '-z', '--stdin'], { ...o, input: add.join('\0') + '\0' }, 'update-index')
    const tree = (await gitOk(['write-tree'], o, 'write-tree')).toString('utf8').trim()
    return { repo: loc.repo, head: loc.head, tree, untracked: add.length, excluded: excluded.slice(0, MAX_EXCLUDED), ms: Date.now() - started }
  } finally {
    dropIndex(tmp)
  }
}

// commit-tree + update-ref. meta goes into the message as JSON (a snapshot
// describes itself: `diff` and `redo` read it back).
async function commitTree (repo, cap, meta, ref, deadline) {
  const message = `conductore snapshot\n\n${JSON.stringify({ ...meta, excluded: cap.excluded })}\n`
  const args = ['commit-tree', cap.tree]
  if (cap.head) args.push('-p', cap.head)
  const commit = (await gitOk(args, { cwd: repo, deadline, input: message }, 'commit-tree')).toString('utf8').trim()
  if (ref) await gitOk(['update-ref', ref, commit], { cwd: repo, deadline }, 'update-ref')
  return commit
}

function refFor (sessionId, turn, kind) {
  if (!SESSION_RE.test(String(sessionId)) || !Number.isInteger(turn) || turn < 1 || !/^[a-z0-9-]{1,40}$/.test(kind)) return null
  return `${REF_ROOT}/${sessionId}/${turn}/${kind}`
}

// Takes one snapshot. Resolves { ok: true, ref, commit, tree, head, repo,
// untracked, excluded, ms } or { ok: false, reason, detail, ms }. Never rejects.
async function snapshot (cwd, { ref = null, meta = {}, ...opts } = {}) {
  const started = Date.now()
  const deadline = opts.deadline || started + limits().timeoutMs
  try {
    const cap = await captureTree(cwd, { ...opts, deadline })
    const commit = await commitTree(cap.repo, cap, meta, ref, deadline)
    return { ok: true, ref, commit, tree: cap.tree, head: cap.head, repo: cap.repo, untracked: cap.untracked, excluded: cap.excluded, ms: Date.now() - started }
  } catch (err) {
    return { ok: false, reason: err.reason || 'failed', detail: err.message, ms: Date.now() - started }
  }
}

// --- reading snapshots --------------------------------------------------------

// { tree, parent, meta } of a snapshot commit.
async function readCommit (repo, commit, deadline) {
  const text = (await gitOk(['cat-file', 'commit', commit], { cwd: repo, deadline }, 'cat-file')).toString('utf8')
  const blank = text.indexOf('\n\n')
  const header = text.slice(0, blank)
  const body = text.slice(blank + 2)
  const tree = (header.match(/^tree ([0-9a-f]+)$/m) || [])[1] || null
  const parent = (header.match(/^parent ([0-9a-f]+)$/m) || [])[1] || null
  let meta = {}
  const json = body.split('\n').find(l => l.startsWith('{'))
  try { meta = JSON.parse(json) } catch {}
  return { tree, parent, meta: meta && typeof meta === 'object' ? meta : {} }
}

async function resolveRef (repo, ref, deadline) {
  const r = await git(['rev-parse', '-q', '--verify', `${ref}^{commit}`], { cwd: repo, deadline })
  return r.code === 0 ? r.stdout.toString('utf8').trim() : null
}

// refs under a prefix: [{ ref, commit, at }] (at = committer time, ms).
async function listRefs (repo, prefix, deadline) {
  const r = await git(['for-each-ref', '--format=%(refname)%00%(objectname)%00%(committerdate:unix)', prefix], { cwd: repo, deadline })
  if (r.code !== 0) return []
  return r.stdout.toString('utf8').split('\n').filter(Boolean).map(l => {
    const [ref, commit, at] = l.split('\0')
    return { ref, commit, at: Number(at) * 1000 }
  })
}

async function deleteRefs (repo, refs, deadline) {
  if (!refs.length) return 0
  const input = refs.map(r => `delete ${r}\n`).join('')
  const r = await git(['update-ref', '--stdin'], { cwd: repo, deadline, input })
  return r.code === 0 ? refs.length : 0
}

// Clears out what deleted snapshot refs left in a repo, without git gc
// (which would also expire reflogs and pack refs): unreachable loose
// objects older than expireMs, and never younger than git gc's own default
// of two weeks, go (`git prune --expire`: the grace git gc relies on, so
// objects an operation is writing now and a user's dangling objects stay
// as long as git itself would keep them), and the
// reachable loose ones go into one incremental pack (`git repack -d`,
// never -a or -A). Branches, HEAD, the index, reflogs and the stash are
// never written; prune treats all of them (and every worktree's) as
// reachable. Like every git here: nice 10, its own group, a deadline.
// Skipped when the repo has few loose objects or its owner turned
// automatic gc off (gc.auto = 0). Resolves { ok, skipped?, before, after }
// (loose object counts).
async function collect (repo, { expireMs, deadline = Date.now() + 120000, minLoose = envInt('CONDUCTORE_SNAPSHOT_GC_MIN_LOOSE', 500) } = {}) {
  const count = async () => {
    const r = await git(['count-objects', '-v'], { cwd: repo, deadline })
    if (r.code !== 0) return null
    const m = /^count: (\d+)/m.exec(r.stdout.toString('utf8'))
    return m ? Number(m[1]) : null
  }
  const before = await count()
  if (before === null) return { ok: false, skipped: 'count-objects failed' }
  if (before < minLoose) return { ok: true, skipped: 'few loose objects', before, after: before }
  const auto = await git(['config', '--get', 'gc.auto'], { cwd: repo, deadline })
  if (auto.code === 0 && auto.stdout.toString('utf8').trim() === '0') return { ok: true, skipped: 'gc.auto is 0', before, after: before }
  const secs = Math.max(PRUNE_EXPIRE_MIN_S, Math.ceil((expireMs || 0) / 1000))
  const pruned = await git(['prune', `--expire=${secs}.seconds.ago`], { cwd: repo, deadline })
  if (pruned.code !== 0) return { ok: false, skipped: `prune: ${String(pruned.stderr).trim().slice(0, 200)}`, before }
  const packed = await git(['repack', '-d', '-q'], { cwd: repo, deadline })
  if (packed.code !== 0) return { ok: false, skipped: `repack: ${String(packed.stderr).trim().slice(0, 200)}`, before }
  return { ok: true, before, after: await count() }
}

// Changed paths between two trees: [{ path, status, added, removed, binary,
// oldMode, newMode }], sorted by path. status: A M D T (no rename detection:
// every card is one path, and so is every per-file undo).
async function changes (repo, from, to, { deadline, paths: only } = {}) {
  const spec = only && only.length ? ['--', ...only] : []
  const raw = lines0(await gitOk(['diff-tree', '-r', '-z', '--no-renames', '--raw', from, to, ...spec], { cwd: repo, deadline }, 'diff-tree'))
  const out = new Map()
  for (let i = 0; i + 1 < raw.length; i += 2) {
    const [oldMode, newMode, , , status] = raw[i].replace(/^:/, '').split(' ')
    out.set(raw[i + 1], { path: raw[i + 1], status: status[0], added: 0, removed: 0, binary: false, oldMode, newMode })
  }
  if (out.size) {
    const num = lines0(await gitOk(['diff-tree', '-r', '-z', '--no-renames', '--numstat', from, to, ...spec], { cwd: repo, deadline }, 'numstat'))
    for (const entry of num) {
      const [a, d, p] = entry.split('\t')
      const e = out.get(p)
      if (!e) continue
      if (a === '-') e.binary = true
      else { e.added = Number(a) || 0; e.removed = Number(d) || 0 }
    }
  }
  return [...out.values()].sort((x, y) => (x.path < y.path ? -1 : x.path > y.path ? 1 : 0))
}

// Unified diff per path between two trees, capped. Resolves the changes
// list with `patch` (string), `truncated`, `omitted` and, for binaries,
// `oldSize` / `newSize`.
async function diff (repo, from, to, { deadline, paths: only, maxBytes = 1024 * 1024, maxFileBytes = 64 * 1024, context = 3 } = {}) {
  const files = await changes(repo, from, to, { deadline, paths: only })
  if (!files.length) return { files, truncated: false }
  // Paths go on the command line: at most ARG_BUDGET bytes of them.
  let argBytes = 0
  const text = files.filter(f => !f.binary && f.oldMode !== '160000' && f.newMode !== '160000')
    .filter(f => (argBytes += Buffer.byteLength(f.path) + 1) <= ARG_BUDGET)
  let total = 0
  let truncated = false
  for (const f of files) if (!f.binary && f.oldMode !== '160000' && f.newMode !== '160000' && !text.includes(f)) { f.patch = null; f.omitted = true; truncated = true }
  // One `git diff` for all text files; its sections come in path order.
  if (text.length) {
    const r = await git(['diff', '--no-color', '--no-ext-diff', '--no-textconv', '--no-renames', `-U${context}`, from, to, '--', ...text.map(f => f.path)], { cwd: repo, deadline, maxBytes: Math.max(maxBytes * 4, 4 * 1024 * 1024) })
    const out = r.stdout.toString('utf8')
    const sections = out.split(/^(?=diff --git )/m).filter(s => s.startsWith('diff --git '))
    if (r.code !== 0) truncated = true
    text.forEach((f, i) => {
      const s = sections[i]
      if (s === undefined) { f.patch = null; f.omitted = true; truncated = true; return }
      // Keep the hunks only (the path is in the entry).
      const at = s.search(/^@@ /m)
      let patch = at === -1 ? '' : s.slice(at)
      const cap = Math.min(maxFileBytes, maxBytes - total)
      const omit = () => { f.patch = null; f.omitted = true; truncated = true }
      // Too little budget left for a readable piece: none at all.
      if (total > 0 && cap < MIN_PIECE && Buffer.byteLength(patch) > cap) return omit()
      if (Buffer.byteLength(patch) > cap) {
        patch = Buffer.from(patch).subarray(0, cap).toString('utf8').replace(/\n[^\n]*$/, '\n')
        if (!patch.trim()) return omit()
        f.truncated = true
        truncated = true
      }
      total += Buffer.byteLength(patch)
      f.patch = patch
    })
  }
  let blobBytes = 0
  const blobs = files.filter(f => f.binary || f.oldMode === '160000' || f.newMode === '160000')
    .filter(f => (blobBytes += Buffer.byteLength(f.path) + 1) <= ARG_BUDGET)
  if (blobs.length) {
    const sizes = async tree => {
      const r = await git(['ls-tree', '-z', '-l', '-r', tree, '--', ...blobs.map(f => f.path)], { cwd: repo, deadline })
      const m = new Map()
      for (const e of lines0(r.stdout)) {
        const tab = e.indexOf('\t')
        const size = e.slice(0, tab).trim().split(/\s+/)[3]
        m.set(e.slice(tab + 1), size === '-' ? null : Number(size))
      }
      return m
    }
    const [a, b] = await Promise.all([sizes(from), sizes(to)])
    for (const f of blobs) {
      f.patch = null
      if (f.oldMode === '160000' || f.newMode === '160000') f.submodule = true
      f.oldSize = a.has(f.path) ? a.get(f.path) : null
      f.newSize = b.has(f.path) ? b.get(f.path) : null
    }
  }
  return { files, truncated }
}

// --- restoring ------------------------------------------------------------------

function inside (repo, rel) {
  const abs = path.resolve(repo, rel)
  return abs.startsWith(repo + path.sep) ? abs : null
}

// Removes a file the target does not hold, then its parent dirs while empty.
function removeFile (repo, rel) {
  const abs = inside(repo, rel)
  if (!abs) return false
  let st
  try { st = fs.lstatSync(abs) } catch { return true }
  if (st.isDirectory()) return false
  fs.unlinkSync(abs)
  let dir = path.dirname(abs)
  while (dir.startsWith(repo + path.sep)) {
    try { fs.rmdirSync(dir) } catch { break }
    dir = path.dirname(dir)
  }
  return true
}

// Makes the work tree match `target` (a snapshot commit) for the paths
// where the current state differs (or only `only`). First snapshots the
// current state into `redoRef` (its message lists the paths restored, so
// `redo` restores just those). Never touches HEAD, branches, the index or
// the stash: files are written from a temporary index with checkout-index.
//
// Resolves { ok, dryRun, repo, restored: [{path, action: 'write'|'delete'}],
// skipped: [{path, reason}], redo: {ref, commit} } or throws a SnapshotError.
async function restore (repo, target, { only = null, dryRun = false, redoRef = null, redoMeta = {}, protect = [], deadline } = {}) {
  deadline = deadline || Date.now() + limits().timeoutMs * 2
  const loc = await locate(repo, deadline)
  if (loc.repo !== repo) throw new SnapshotError('repo moved', loc.repo)
  const cap = await captureTree(repo, { deadline, location: loc })
  const protectedPaths = new Set([...protect, ...cap.excluded.map(e => e.path)])
  const diffs = await changes(repo, cap.tree, target, { deadline, paths: only })
  const restored = []
  const skipped = []
  for (const d of diffs) {
    if (protectedPaths.has(d.path) || [...protectedPaths].some(p => p.endsWith('/') && d.path.startsWith(p))) {
      skipped.push({ path: d.path, reason: 'not in the snapshot (too large or a nested repository)' })
    } else if (d.oldMode === '160000' || d.newMode === '160000') {
      skipped.push({ path: d.path, reason: 'submodule' })
    } else if (!inside(repo, d.path)) {
      skipped.push({ path: d.path, reason: 'outside the repository' })
    } else {
      // status is from the current state to the target: D = the target
      // does not have it (the turn created it).
      restored.push({ path: d.path, action: d.status === 'D' ? 'delete' : 'write', added: d.added, removed: d.removed, binary: d.binary })
    }
  }
  if (dryRun) return { ok: true, dryRun: true, repo, head: loc.head, restored, skipped, redo: null }
  let redo = null
  if (restored.length) {
    const commit = await commitTree(repo, cap, { ...redoMeta, kind: redoMeta.kind || 'undo', target, paths: restored.map(r => r.path).slice(0, 5000), at: Date.now() }, redoRef, deadline)
    redo = { ref: redoRef, commit }
  }
  const writes = restored.filter(r => r.action === 'write').map(r => r.path)
  for (const r of restored) {
    if (r.action !== 'delete') continue
    try { removeFile(repo, r.path) } catch (err) { r.error = err.message }
  }
  if (writes.length) {
    const tmp = tmpIndexPath()
    try {
      const o = { cwd: repo, deadline, index: tmp }
      await gitOk(['read-tree', target], o, 'read-tree')
      // A file where the target has a directory (or the reverse) was
      // handled by the deletes above; -f overwrites the rest.
      await gitOk(['checkout-index', '-f', '-z', '--stdin'], { ...o, input: writes.join('\0') + '\0' }, 'checkout-index')
    } finally {
      dropIndex(tmp)
    }
  }
  return { ok: true, dryRun: false, repo, head: loc.head, restored, skipped, redo }
}

// Paths staged in the user's real index (read-only; optional locks off),
// so `undo` can say which restored files still differ in the index.
async function stagedPaths (repo, deadline) {
  const r = await git(['diff', '--cached', '--name-only', '-z', '--no-renames'], { cwd: repo, deadline, maxBytes: 4 * 1024 * 1024 })
  return r.code === 0 ? lines0(r.stdout) : []
}

module.exports = {
  REF_ROOT,
  collect,
  SESSION_RE,
  SnapshotError,
  limits,
  git,
  gitEnv,
  killAll,
  locate,
  captureTree,
  commitTree,
  snapshot,
  refFor,
  readCommit,
  resolveRef,
  listRefs,
  deleteRefs,
  changes,
  diff,
  restore,
  stagedPaths
}
