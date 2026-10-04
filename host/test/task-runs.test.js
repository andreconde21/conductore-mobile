'use strict'

// Task runs (CON-037) on temp repositories: queueing under the cap, one
// worktree and branch per task and attempt, the launch line, Herdr through
// a fake socket server, tmux through a fake binary that only records, the
// link to the agent by cwd, finishing, and the next queued run starting.
// No real Herdr or tmux is touched.

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('fs')
const net = require('net')
const path = require('path')
const { execFile, execFileSync } = require('child_process')
const { tempDir, cleanup } = require('./helpers/cleanup')

const home = tempDir('cnd-runs-')
const binDir = path.join(home, 'bin')
const tmuxLog = path.join(home, 'tmux.jsonl')
fs.mkdirSync(binDir)
fs.writeFileSync(path.join(binDir, 'tmux'), `#!${process.execPath}
const fs = require('fs')
const args = process.argv.slice(2)
fs.appendFileSync(${JSON.stringify(tmuxLog)}, JSON.stringify(args) + '\\n')
if (args[0] === 'new-window') process.stdout.write('%42 @7 main\\n')
`, { mode: 0o755 })

process.env.CONDUCTORE_HOME = path.join(home, '.conductore')
process.env.PATH = `${binDir}:${process.env.PATH}`
process.env.GIT_CONFIG_GLOBAL = path.join(home, 'gitconfig')
fs.writeFileSync(process.env.GIT_CONFIG_GLOBAL, '[init]\n\tdefaultBranch = main\n[user]\n\tname = t\n\temail = t@example.com\n')
for (const k of Object.keys(process.env)) if (/^(TMUX$|TMUX_PANE$|HERDR_)/.test(k)) delete process.env[k]

const runs = require('../lib/task-runs')

test.after(cleanup)

const git = (cwd, ...args) => execFileSync('git', args, { cwd, encoding: 'utf8' }).trim()

function repo () {
  const dir = path.join(tempDir('cnd-runs-repo-'), 'app')
  fs.mkdirSync(dir)
  git(dir, 'init', '-q')
  fs.writeFileSync(path.join(dir, 'a.txt'), 'one\n')
  git(dir, 'add', '.')
  git(dir, 'commit', '-qm', 'one')
  return fs.realpathSync(dir)
}

function reset () {
  fs.rmSync(process.env.CONDUCTORE_HOME, { recursive: true, force: true })
  try { fs.unlinkSync(tmuxLog) } catch {}
}

const task = (key, prompt = `Do ${key}`) => ({ ref: `src/${key}`, key, title: `Title ${key}`, prompt })

test('launch line: cd, the agent, the prompt from its file; quotes survive', () => {
  assert.equal(runs.launchLine('claude', "/w/it's", '/p/prompt.md'), "cd '/w/it'\\''s' && 'claude' \"$(cat '/p/prompt.md')\"")
  assert.match(runs.launchLine('opencode', '/w', '/p'), /'opencode' '--prompt' "\$\(cat/)
  assert.throws(() => runs.launchLine('nope', '/w', '/p'), /no launch command/)
})

test('a batch starts up to the cap; the rest wait; place none returns the command', async () => {
  reset()
  const dir = repo()
  const wtRoot = tempDir('cnd-runs-wt-')
  const res = await runs.start({
    repo: dir,
    agent: 'claude',
    place: 'none',
    cap: 2,
    location: `${wtRoot}/<branch>`,
    tasks: [task('CON-1', "it's \"quoted\" $(rm -rf /)"), task('CON-2'), task('CON-3')]
  })
  assert.equal(res.ok, true)
  assert.deepEqual(res.runs.map(r => r.status), ['running', 'running', 'queued'])
  const [one] = res.runs
  assert.equal(one.branch, 'task/con-1')
  assert.equal(one.worktree, path.join(wtRoot, 'task-con-1'))
  assert.equal(git(one.worktree, 'branch', '--show-current'), 'task/con-1')
  assert.equal(fs.readFileSync(one.promptFile, 'utf8'), "it's \"quoted\" $(rm -rf /)")
  assert.equal(fs.statSync(one.promptFile).mode & 0o777, 0o600)
  assert.ok(!one.command.includes('rm -rf'), 'the prompt is never in the command line')
  assert.match(one.command, /^cd '.*task-con-1' && 'claude' "\$\(cat '.*prompt\.md'\)"$/)
  // The prompt file's shell expansion reads it back unchanged.
  const echoed = execFileSync('bash', ['-c', `printf %s "$(cat '${one.promptFile}')"`], { encoding: 'utf8' })
  assert.equal(echoed, "it's \"quoted\" $(rm -rf /)")
  assert.equal(git(dir, 'branch', '--show-current'), 'main', 'main worktree untouched')
})

test('the agent in the worktree links; its first Stop finishes the run and the next starts', async () => {
  reset()
  const dir = repo()
  const wtRoot = tempDir('cnd-runs-wt-')
  const { runs: [a, b] } = await runs.start({ repo: dir, agent: 'codex', place: 'none', cap: 1, location: `${wtRoot}/<branch>`, tasks: [task('A-1'), task('A-2')] })
  assert.equal(a.status, 'running')
  assert.equal(b.status, 'queued')
  const agent = { sessionId: 's1', kind: 'codex', cwd: path.join(a.worktree, 'src'), state: 'waiting_input', lastEvent: 'SessionStart', startedAt: Date.now() }
  fs.mkdirSync(agent.cwd)
  const other = { sessionId: 's0', cwd: dir, state: 'working', startedAt: Date.now() }

  let listed = await runs.list([other, agent])
  let ra = listed.runs.find(r => r.id === a.id)
  assert.equal(ra.sessionId, 's1')
  assert.equal(ra.status, 'running', 'idle before any work is not done')

  agent.state = 'working'
  agent.lastEvent = 'UserPromptSubmit'
  await runs.list([other, agent])
  agent.state = 'waiting_input'
  agent.lastEvent = 'Stop'
  agent.lastMessage = 'All done.'
  listed = await runs.list([other, agent])
  ra = listed.runs.find(r => r.id === a.id)
  assert.equal(ra.status, 'finished')
  assert.equal(ra.outcome, 'done')
  assert.equal(ra.lastMessage, 'All done.')
  const rb = listed.runs.find(r => r.id === b.id)
  assert.equal(rb.status, 'running', 'the queued run took the free slot')
  assert.equal(rb.branch, 'task/a-2')
})

test('attempts get their own branch; a taken branch gets a suffix; a failure frees the slot', async () => {
  reset()
  const dir = repo()
  git(dir, 'branch', 'task/x-1-a1')
  const wtRoot = tempDir('cnd-runs-wt-')
  const res = await runs.start({ repo: dir, agent: 'claude', place: 'none', cap: 5, attempts: 2, location: `${wtRoot}/<branch>`, tasks: [task('X-1')] })
  assert.deepEqual(res.runs.map(r => r.branch), ['task/x-1-a1-2', 'task/x-1-a2'])
  assert.deepEqual(res.runs.map(r => r.attempt), [1, 2])

  reset()
  const bad = await runs.start({ repo: dir, agent: 'claude', place: 'none', cap: 1, base: 'no-such-ref', location: `${wtRoot}/<branch>`, tasks: [task('Y-1'), task('Y-2')] })
  assert.deepEqual(bad.runs.map(r => r.status), ['failed', 'failed'])
  assert.equal(bad.runs[0].errorCode, 'bad-base')
})

test('herdr: a tab in the worktree, the line typed, Enter', async () => {
  reset()
  const dir = repo()
  const sock = path.join(tempDir('cnd-runs-herdr-'), 'herdr.sock')
  const calls = []
  const server = net.createServer(c => {
    let buf = ''
    c.on('data', d => {
      buf += d
      let i
      while ((i = buf.indexOf('\n')) !== -1) {
        const msg = JSON.parse(buf.slice(0, i))
        buf = buf.slice(i + 1)
        calls.push(msg)
        const result = msg.method === 'tab.create'
          ? { type: 'tab_created', tab: { tab_id: 't9', workspace_id: msg.params.workspace_id }, root_pane: { pane_id: 'p9' } }
          : msg.method === 'workspace.create'
            ? { type: 'workspace_created', workspace: { workspace_id: 'w2' }, tab: { tab_id: 't1', workspace_id: 'w2' }, root_pane: { pane_id: 'p1' } }
            : { type: 'ok' }
        c.write(JSON.stringify({ id: msg.id, result }) + '\n')
      }
    })
  })
  await new Promise(resolve => server.listen(sock, resolve))
  process.env.CONDUCTORE_HERDR_SOCKETS = sock
  try {
    const wtRoot = tempDir('cnd-runs-wt-')
    const { runs: [r] } = await runs.start({ repo: dir, agent: 'claude', place: 'herdr', workspaceId: 'w1', location: `${wtRoot}/<branch>`, tasks: [task('H-1')] })
    assert.equal(r.status, 'running', r.error)
    assert.deepEqual(r.herdr, { server: 'herdr', socket: sock, workspaceId: 'w1', tabId: 't9', paneId: 'p9' })
    assert.deepEqual(calls.map(c => c.method), ['tab.create', 'pane.send_text', 'pane.send_keys'])
    assert.deepEqual(calls[0].params, { cwd: r.worktree, label: 'H-1', focus: false, workspace_id: 'w1' })
    assert.equal(calls[1].params.text, r.command)
    assert.deepEqual(calls[2].params, { pane_id: 'p9', keys: ['enter'] })

    // No workspace given: the batch's first run makes one, the next a tab.
    calls.length = 0
    const { runs: two } = await runs.start({ repo: dir, agent: 'claude', place: 'herdr', location: `${wtRoot}/<branch>`, tasks: [task('H-2'), task('H-3')] })
    assert.deepEqual(two.map(r => [r.status, r.herdr.workspaceId, r.herdr.paneId]), [['running', 'w2', 'p1'], ['running', 'w2', 'p9']])
    assert.deepEqual(calls.map(c => c.method), ['workspace.create', 'tab.rename', 'pane.send_text', 'pane.send_keys', 'tab.create', 'pane.send_text', 'pane.send_keys'])
    assert.equal(calls[0].params.focus, false)
    assert.deepEqual(calls[1].params, { tab_id: 't1', label: 'H-2' })
    assert.equal(calls[4].params.workspace_id, 'w2')
  } finally {
    delete process.env.CONDUCTORE_HERDR_SOCKETS
    server.close()
  }
})

test('tmux: a detached window, the line typed literally, Enter', async () => {
  reset()
  const dir = repo()
  const wtRoot = tempDir('cnd-runs-wt-')
  const { runs: [r] } = await runs.start({ repo: dir, agent: 'claude', place: 'tmux', location: `${wtRoot}/<branch>`, tasks: [task('T-1')] })
  assert.equal(r.status, 'running', r.error)
  assert.deepEqual(r.tmux, { session: 'main', windowId: '@7', paneId: '%42' })
  const calls = fs.readFileSync(tmuxLog, 'utf8').trim().split('\n').map(l => JSON.parse(l))
  assert.deepEqual(calls[0].slice(0, 2), ['new-window', '-d'])
  assert.ok(calls[0].includes(r.worktree))
  assert.deepEqual(calls[1], ['send-keys', '-t', '%42', '-l', '--', r.command])
  assert.deepEqual(calls[2], ['send-keys', '-t', '%42', 'Enter'])
  assert.ok(!calls.some(c => c.includes('select-window') || c.includes('kill-window')))
})

test('cancel, forget, cap and validation', async () => {
  reset()
  const dir = repo()
  const wtRoot = tempDir('cnd-runs-wt-')
  const { runs: [, q] } = await runs.start({ repo: dir, agent: 'claude', place: 'none', cap: 1, location: `${wtRoot}/<branch>`, tasks: [task('C-1'), task('C-2')] })
  assert.equal(q.status, 'queued')
  assert.equal((await runs.cancel(q.id)).run.status, 'cancelled')
  await runs.forget(q.id)
  assert.ok(!(await runs.list(null)).runs.some(r => r.id === q.id))
  await assert.rejects(runs.forget('nope'), /no finished run/)
  assert.equal((await runs.setCap(4)).cap, 4)
  for (const bad of [
    { repo: dir, agent: 'vim', tasks: [task('Z')] },
    { repo: dir, agent: 'claude', place: 'screen', tasks: [task('Z')] },
    { repo: dir, agent: 'claude', tasks: [] },
    { repo: dir, agent: 'claude', tasks: [{ key: 'Z', prompt: ' ' }] },
    { repo: dir, agent: 'claude', tasks: [task('Z')], attempts: 9 },
    { repo: dir, agent: 'claude', tasks: [task('Z')], branchPrefix: '-x' },
    { repo: dir, agent: 'claude', tasks: [task('Z')], branchPrefix: 'a..b' }
  ]) await assert.rejects(runs.start(bad), runs.RunError, JSON.stringify(bad))
})

test('CLI: task-start and task-runs through the real binary', async () => {
  reset()
  const dir = repo()
  const wtRoot = tempDir('cnd-runs-wt-')
  const HOSTD = path.join(__dirname, '..', 'bin', 'conductore-hostd')
  const env = { ...process.env, CONDUCTORE_SOCKET: path.join(home, 'none.sock') }
  const call = (args, input) => new Promise(resolve => {
    const child = execFile(process.execPath, [HOSTD, ...args], { env, timeout: 30000 }, (err, stdout) => resolve({ code: err ? err.code : 0, json: JSON.parse(stdout.trim().split('\n').pop()) }))
    child.stdin.end(input === undefined ? '' : JSON.stringify(input))
  })
  const started = await call(['task-start', '-'], { repo: dir, agent: 'claude', place: 'none', location: `${wtRoot}/<branch>`, tasks: [task('CLI-1')] })
  assert.equal(started.code, 0, JSON.stringify(started.json))
  assert.equal(started.json.runs[0].status, 'running')
  const listed = await call(['task-runs'])
  assert.equal(listed.json.runs[0].id, started.json.runs[0].id)
  assert.equal((await call(['task-runs', 'cap', '0'])).json.code, 'bad-cap')
})

test('the daemon hook finishes runs and starts the next, and reads nothing when idle', async () => {
  reset()
  const dir = repo()
  const wtRoot = tempDir('cnd-runs-wt-')
  const { runs: [a, b] } = await runs.start({ repo: dir, agent: 'claude', place: 'none', cap: 1, location: `${wtRoot}/<branch>`, tasks: [task('D-1'), task('D-2')] })
  const agents = { s1: { sessionId: 's1', cwd: a.worktree, state: 'ended', lastEvent: 'SessionEnd', startedAt: Date.now() } }
  runs.onAgents(agents, { debounceMs: 0 })
  for (let i = 0; i < 100; i++) {
    const data = JSON.parse(fs.readFileSync(runs.file(), 'utf8'))
    if (data.runs.find(r => r.id === b.id).status === 'running') break
    await new Promise(resolve => setTimeout(resolve, 20))
  }
  const data = JSON.parse(fs.readFileSync(runs.file(), 'utf8'))
  assert.equal(data.runs.find(r => r.id === a.id).status, 'finished')
  assert.equal(data.runs.find(r => r.id === a.id).outcome, 'error', 'ended without working')
  assert.equal(data.runs.find(r => r.id === b.id).status, 'running')
})

test('a linked agent that disappears ends its run', async () => {
  reset()
  const dir = repo()
  const wtRoot = tempDir('cnd-runs-wt-')
  const { runs: [a] } = await runs.start({ repo: dir, agent: 'claude', place: 'none', location: `${wtRoot}/<branch>`, tasks: [task('G-1')] })
  await runs.list([{ sessionId: 'g', cwd: a.worktree, state: 'working', startedAt: Date.now() }])
  const { runs: [after] } = await runs.list([])
  assert.equal(after.status, 'finished')
  assert.equal(after.outcome, 'gone')
})

test('worktree off: the run works in the repository, links only a fresh agent', async () => {
  reset()
  const dir = repo()
  const { runs: [r] } = await runs.start({ repo: dir, agent: 'claude', place: 'none', worktree: false, tasks: [task('N-1')] })
  assert.equal(r.status, 'running', r.error)
  assert.equal(r.worktree, dir)
  assert.equal(r.branch, null)
  assert.match(r.command, new RegExp(`^cd '${dir}' && 'claude'`))
  assert.deepEqual(git(dir, 'worktree', 'list').split('\n').length, 1, 'no worktree made')
  const old = { sessionId: 'old', cwd: dir, state: 'working', startedAt: r.startedAt - 60000 }
  let { runs: [after] } = await runs.list([old])
  assert.equal(after.sessionId, undefined, 'an agent already there is not the run')
  const fresh = { sessionId: 'new', cwd: dir, state: 'working', startedAt: Date.now() }
  ;({ runs: [after] } = await runs.list([old, fresh]))
  assert.equal(after.sessionId, 'new')
})
