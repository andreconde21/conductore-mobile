'use strict'

// `conductore-hostd worktree …` on temp repositories: a new branch in a new
// worktree where worktree-location says, inputs validated, the main
// worktree's HEAD, index and files untouched.

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('fs')
const path = require('path')
const { execFile, execFileSync } = require('child_process')
const { tempDir, cleanup } = require('./helpers/cleanup')

const HOSTD = path.join(__dirname, '..', 'bin', 'conductore-hostd')
const home = tempDir('cnd-wt-')
const env = {
  ...process.env,
  HOME: home,
  CONDUCTORE_HOME: path.join(home, '.conductore'),
  GIT_CONFIG_GLOBAL: path.join(home, 'gitconfig'),
  GIT_AUTHOR_NAME: 't',
  GIT_AUTHOR_EMAIL: 't@example.com',
  GIT_COMMITTER_NAME: 't',
  GIT_COMMITTER_EMAIL: 't@example.com'
}
for (const k of Object.keys(env)) if (/^(TMUX$|TMUX_PANE$|HERDR_)/.test(k)) delete env[k]
fs.writeFileSync(env.GIT_CONFIG_GLOBAL, '[init]\n\tdefaultBranch = main\n')

test.after(cleanup)

const git = (cwd, ...args) => execFileSync('git', args, { cwd, env, encoding: 'utf8' }).trim()

function repo (name = 'app') {
  const dir = path.join(tempDir('cnd-wt-repo-'), name)
  fs.mkdirSync(dir)
  git(dir, 'init', '-q')
  fs.writeFileSync(path.join(dir, 'a.txt'), 'one\n')
  git(dir, 'add', '.')
  git(dir, 'commit', '-qm', 'one')
  return fs.realpathSync(dir)
}

function hostd (args, input) {
  return new Promise(resolve => {
    const child = execFile(process.execPath, [HOSTD, ...args], { env, timeout: 30000 }, (err, stdout) => {
      resolve({ code: err ? err.code : 0, json: JSON.parse(stdout.trim().split('\n').pop()) })
    })
    child.stdin.end(JSON.stringify(input))
  })
}

test('create: next to the repository by default; the main worktree is untouched', async () => {
  const dir = repo()
  // A dirty main worktree: staged and unstaged changes, on its own branch.
  git(dir, 'checkout', '-qb', 'feature')
  fs.writeFileSync(path.join(dir, 'a.txt'), 'staged\n')
  git(dir, 'add', 'a.txt')
  fs.writeFileSync(path.join(dir, 'a.txt'), 'unstaged\n')
  const before = { head: git(dir, 'rev-parse', 'HEAD'), branch: git(dir, 'branch', '--show-current'), status: git(dir, 'status', '--porcelain'), index: git(dir, 'diff', '--cached') }

  const { code, json } = await hostd(['worktree', 'create', '-'], { repo: dir, branch: 'task/con-1' })
  assert.equal(code, 0, JSON.stringify(json))
  const expected = path.join(path.dirname(dir), 'app-wt', 'task-con-1')
  assert.equal(json.path, expected)
  assert.equal(json.branch, 'task/con-1')
  assert.equal(git(expected, 'branch', '--show-current'), 'task/con-1')
  assert.equal(fs.readFileSync(path.join(expected, 'a.txt'), 'utf8'), 'one\n', 'from the base commit')

  assert.deepEqual({ head: git(dir, 'rev-parse', 'HEAD'), branch: git(dir, 'branch', '--show-current'), status: git(dir, 'status', '--porcelain'), index: git(dir, 'diff', '--cached') }, before)
  assert.equal(fs.readFileSync(path.join(dir, 'a.txt'), 'utf8'), 'unstaged\n')

  const listed = await hostd(['worktree', 'list', '-'], { repo: dir })
  assert.deepEqual(listed.json.worktrees.map(w => [w.branch, w.main]), [['feature', true], ['task/con-1', false]])
})

test('create: a template location and a base', async () => {
  const dir = repo('svc')
  const first = git(dir, 'rev-parse', 'HEAD')
  fs.writeFileSync(path.join(dir, 'b.txt'), 'two\n')
  git(dir, 'add', '.')
  git(dir, 'commit', '-qm', 'two')
  const root = tempDir('cnd-wt-tpl-')
  const { json } = await hostd(['worktree', 'create', '-'], { repo: dir, branch: 'fix/x', base: first, location: `${root}/<repo>/<branch>` })
  assert.equal(json.path, path.join(root, 'svc', 'fix-x'))
  assert.equal(json.head, first)
  assert.ok(!fs.existsSync(path.join(json.path, 'b.txt')))
})

test('create: the worktree-location setting is the default', async () => {
  const dir = repo('cfg')
  const root = tempDir('cnd-wt-cfg-')
  const set = await new Promise(resolve => execFile(process.execPath, [HOSTD, 'config', 'set', 'worktree-location', `${root}/<branch>`], { env }, (err, stdout) => resolve({ err, stdout })))
  assert.ifError(set.err)
  const { json } = await hostd(['worktree', 'create', '-'], { repo: dir, branch: 'b1' })
  assert.equal(json.path, path.join(root, 'b1'))
})

test('bad input is refused before git runs', async () => {
  const dir = repo('bad')
  const notRepo = tempDir('cnd-wt-plain-')
  const cases = [
    [{ repo: 'relative', branch: 'x' }, 'bad-repo'],
    [{ repo: notRepo, branch: 'x' }, 'not-a-repo'],
    [{ repo: dir, branch: '-f' }, 'bad-branch'],
    [{ repo: dir, branch: 'a b' }, 'bad-branch'],
    [{ repo: dir, branch: 'a..b' }, 'bad-branch'],
    [{ repo: dir, branch: 'main' }, 'branch-exists'],
    [{ repo: dir, branch: 'ok', base: '--exec=x' }, 'bad-base'],
    [{ repo: dir, branch: 'ok', base: 'nope' }, 'bad-base'],
    [{ repo: dir, branch: 'ok', location: 'nowhere' }, 'bad-location'],
    [{ repo: dir, branch: 'ok', location: `${dir}/inside/<branch>` }, 'bad-location']
  ]
  for (const [input, code] of cases) {
    const { json } = await hostd(['worktree', 'create', '-'], input)
    assert.equal(json.code, code, JSON.stringify(input))
  }
  const taken = tempDir('cnd-wt-taken-')
  fs.mkdirSync(path.join(taken, 'ok'))
  const { json } = await hostd(['worktree', 'create', '-'], { repo: dir, branch: 'ok', location: `${taken}/<branch>` })
  assert.equal(json.code, 'path-exists')
  assert.equal(git(dir, 'branch', '--list', 'ok'), '', 'no branch left behind')
})

test('remove: a clean linked worktree only, never the main one', async () => {
  const dir = repo('rm')
  const { json: made } = await hostd(['worktree', 'create', '-'], { repo: dir, branch: 'gone' })
  assert.equal((await hostd(['worktree', 'remove', '-'], { repo: dir, path: dir })).json.code, 'main-worktree')
  fs.writeFileSync(path.join(made.path, 'a.txt'), 'dirty\n')
  assert.equal((await hostd(['worktree', 'remove', '-'], { repo: dir, path: made.path })).json.code, 'git-failed')
  git(made.path, 'checkout', '--', 'a.txt')
  const { json } = await hostd(['worktree', 'remove', '-'], { repo: dir, path: made.path })
  assert.equal(json.ok, true)
  assert.ok(!fs.existsSync(made.path))
  assert.equal(git(dir, 'branch', '--list', 'gone'), 'gone', 'the branch stays')
})
