'use strict'

// Fresh git worktrees for tasks (CON-037): `conductore-hostd worktree`.
//
// `create` adds a linked worktree on a new branch with `git worktree add -b`
// and nothing else: the main worktree's HEAD, index and files are never
// touched (no checkout, no stash, no reset there). Inputs are checked
// first: the repository must be an existing git work tree, the branch a
// valid new branch name (`git check-ref-format --branch`, no leading dash),
// the base a commit, the target a path that does not exist yet. Every git
// call is an argv (never a shell string) with `--` before paths.
//
// Where the worktree goes follows the `worktree-location` setting
// (config.js): next to the repository (`<parent>/<repo>-wt/<branch>`, the
// default), Herdr's place (`~/.herdr/worktrees/<repo>/<branch>`), or a
// template with <repo> and <branch>. A branch's slashes become dashes in
// the directory name.

const fs = require('fs')
const os = require('os')
const path = require('path')
const { execFile } = require('child_process')

class WorktreeError extends Error {
  constructor (code, message) {
    super(message)
    this.code = code
  }
}

function git (args, { cwd, timeout = 30000 } = {}) {
  return new Promise(resolve => {
    execFile('git', args, { cwd, timeout, maxBuffer: 4 * 1024 * 1024, env: { ...process.env, GIT_TERMINAL_PROMPT: '0', GIT_OPTIONAL_LOCKS: '0' } }, (err, stdout, stderr) => {
      resolve({ ok: !err, code: err ? (typeof err.code === 'number' ? err.code : 1) : 0, stdout: String(stdout), stderr: String(stderr).trim() })
    })
  })
}

const expandHome = p => p === '~' || p.startsWith('~/') ? path.join(os.homedir(), p.slice(1)) : p

// The repository's top level, as a real path.
async function repoRoot (raw) {
  if (typeof raw !== 'string' || !raw.trim() || /[\0\n\r]/.test(raw)) throw new WorktreeError('bad-repo', 'repo must be a path')
  const p = expandHome(raw.trim())
  if (!path.isAbsolute(p)) throw new WorktreeError('bad-repo', 'repo must be an absolute path (or start with ~/)')
  let real
  try { real = fs.realpathSync(p) } catch { throw new WorktreeError('no-repo', `no such folder: ${raw}`) }
  if (!fs.statSync(real).isDirectory()) throw new WorktreeError('bad-repo', `not a folder: ${raw}`)
  const r = await git(['rev-parse', '--show-toplevel'], { cwd: real })
  if (!r.ok || !r.stdout.trim()) throw new WorktreeError('not-a-repo', `not a git work tree: ${raw}`)
  return fs.realpathSync(r.stdout.trim())
}

async function checkBranch (root, branch) {
  if (typeof branch !== 'string' || !branch || branch.length > 120 || branch.startsWith('-') || /\s/.test(branch)) {
    throw new WorktreeError('bad-branch', 'branch must be a short name without spaces or a leading dash')
  }
  const r = await git(['check-ref-format', '--branch', branch], { cwd: root })
  if (!r.ok) throw new WorktreeError('bad-branch', `not a valid branch name: ${branch}`)
  const exists = await git(['show-ref', '--verify', '--quiet', `refs/heads/${branch}`], { cwd: root })
  if (exists.ok) throw new WorktreeError('branch-exists', `branch ${branch} already exists`)
}

async function checkBase (root, base) {
  if (typeof base !== 'string' || !base || base.length > 200 || base.startsWith('-') || /[\s\0]/.test(base)) {
    throw new WorktreeError('bad-base', 'base must be a branch, tag or commit')
  }
  const r = await git(['rev-parse', '--verify', '--quiet', '--end-of-options', `${base}^{commit}`], { cwd: root })
  if (!r.ok) throw new WorktreeError('bad-base', `no such commit: ${base}`)
  return r.stdout.trim()
}

// Where the worktree for branch of the repository at root goes.
function targetPath (root, branch, location = 'next-to-repo') {
  const repo = path.basename(root)
  const dir = branch.replace(/\//g, '-')
  let p
  if (location === 'next-to-repo') p = path.join(path.dirname(root), `${repo}-wt`, dir)
  else if (location === 'herdr') p = path.join(os.homedir(), '.herdr', 'worktrees', repo, dir)
  else if (typeof location === 'string' && location.includes('<branch>')) p = expandHome(location.replace(/<repo>/g, repo).replace(/<branch>/g, dir))
  else throw new WorktreeError('bad-location', 'location is next-to-repo, herdr, or a template with <branch>')
  if (!path.isAbsolute(p)) throw new WorktreeError('bad-location', `the worktree path must be absolute: ${p}`)
  p = path.normalize(p)
  if (p === root || p.startsWith(root + path.sep)) throw new WorktreeError('bad-location', 'the worktree cannot be inside the repository')
  return p
}

// {ok, repo, path, branch, base, head}
async function create ({ repo, branch, base = 'HEAD', location } = {}) {
  const root = await repoRoot(repo)
  await checkBranch(root, branch)
  const head = await checkBase(root, base)
  const loc = location === undefined ? require('./config').get('worktree-location') : location
  const target = targetPath(root, branch, loc)
  if (fs.existsSync(target)) throw new WorktreeError('path-exists', `${target} already exists`)
  fs.mkdirSync(path.dirname(target), { recursive: true })
  const r = await git(['worktree', 'add', '-b', branch, '--', target, head], { cwd: root })
  if (!r.ok) throw new WorktreeError('git-failed', `git worktree add failed: ${r.stderr || r.code}`)
  return { ok: true, repo: root, path: target, branch, base, head }
}

// The repository's worktrees: [{path, branch, head, main}]
async function list ({ repo } = {}) {
  const root = await repoRoot(repo)
  const r = await git(['worktree', 'list', '--porcelain'], { cwd: root })
  if (!r.ok) throw new WorktreeError('git-failed', r.stderr)
  const out = []
  let cur = null
  for (const line of r.stdout.split('\n')) {
    if (line.startsWith('worktree ')) {
      cur = { path: line.slice(9), branch: null, head: null, main: out.length === 0 }
      out.push(cur)
    } else if (cur && line.startsWith('HEAD ')) cur.head = line.slice(5)
    else if (cur && line.startsWith('branch ')) cur.branch = line.slice(7).replace(/^refs\/heads\//, '')
  }
  return { ok: true, repo: root, worktrees: out }
}

// Removes a linked worktree (never the main one, never with --force: git
// refuses one with changes). The branch stays.
async function remove ({ repo, path: wt } = {}) {
  const { repo: root, worktrees } = await list({ repo })
  let real
  try { real = fs.realpathSync(expandHome(String(wt || ''))) } catch { throw new WorktreeError('not-found', `no such worktree: ${wt}`) }
  const entry = worktrees.find(w => { try { return fs.realpathSync(w.path) === real } catch { return false } })
  if (!entry) throw new WorktreeError('not-found', `${wt} is not a worktree of ${root}`)
  if (entry.main) throw new WorktreeError('main-worktree', 'refusing to remove the main worktree')
  const r = await git(['worktree', 'remove', '--', entry.path], { cwd: root })
  if (!r.ok) throw new WorktreeError('git-failed', `git worktree remove failed: ${r.stderr}`)
  return { ok: true, repo: root, removed: entry.path, branch: entry.branch }
}

const OPS = { create, list, remove }

const USAGE = `usage: conductore-hostd worktree <create|list|remove> -

  One JSON object on stdin:
    create  {repo, branch, base?, location?}   a new branch in a new worktree
                                              (location: next-to-repo, herdr
                                              or a <repo>/<branch> template;
                                              default: the worktree-location
                                              setting)
    list    {repo}
    remove  {repo, path}                       a clean linked worktree only
`

async function cli (args, { readStdin }) {
  const [op] = args
  const write = obj => { process.stdout.write(JSON.stringify(obj) + '\n'); return obj.error ? 1 : 0 }
  if (!OPS[op]) return write({ error: USAGE.trim(), code: 'usage' })
  let input
  try { input = JSON.parse(await readStdin()) } catch { return write({ error: 'worktree: expected one JSON object on stdin', code: 'usage' }) }
  if (!input || typeof input !== 'object') return write({ error: 'worktree: expected one JSON object on stdin', code: 'usage' })
  try {
    return write(await OPS[op](input))
  } catch (err) {
    return write({ error: err.message, code: err.code || 'failed' })
  }
}

module.exports = { cli, create, list, remove, targetPath, repoRoot, WorktreeError, git }
