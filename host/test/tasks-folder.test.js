'use strict'

// `conductore-hostd tasks …`: the markdown tasks folder, through the real
// CLI on temp folders only. Reads parse the frontmatter and comments;
// writes touch only the status line (and an existing updated_at) or append
// a comment, keep CRLF files CRLF, and never leave the folder.

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('fs')
const path = require('path')
const { execFile } = require('child_process')
const { tempDir, cleanup } = require('./helpers/cleanup')

const HOSTD = path.join(__dirname, '..', 'bin', 'conductore-hostd')
const home = tempDir('cnd-tasks-')
const env = { ...process.env, CONDUCTORE_HOME: path.join(home, '.conductore'), TMUX_TMPDIR: home }
for (const k of Object.keys(env)) if (/^(TMUX$|TMUX_PANE$|HERDR_)/.test(k)) delete env[k]

test.after(cleanup)

function tasks (op, input) {
  return new Promise(resolve => {
    const child = execFile(process.execPath, [HOSTD, 'tasks', op, '-'], { env, timeout: 15000 }, (err, stdout) => {
      resolve({ code: err ? err.code : 0, json: JSON.parse(stdout.trim().split('\n').pop()) })
    })
    child.stdin.end(typeof input === 'string' ? input : JSON.stringify(input))
  })
}

const CARD = `---
id: CON-001
title: "Start tasks, not sessions"
status: backlog
priority: medium
assignee: andre
labels: [mobile, tasks]
created_at: "2026-09-25T13:09:19Z"
updated_at: "2026-09-25T13:09:19Z"
---

## Description

From the phone, describe a task.
`

function folderWith (files) {
  const dir = tempDir('cnd-tasks-folder-')
  for (const [name, text] of Object.entries(files)) fs.writeFileSync(path.join(dir, name), text)
  return dir
}

test('list reads frontmatter and skips files without it', async () => {
  const dir = folderWith({
    'CON-001.md': CARD,
    'README.md': '# Not a task\n',
    'CON-002.md': '---\nid: CON-002\ntitle: Two\nstatus: verify\nassignees:\n  - ana\n  - bo\n---\nbody\n'
  })
  const { code, json } = await tasks('list', { folder: dir })
  assert.equal(code, 0)
  assert.equal(json.tasks.length, 2)
  const [one, two] = json.tasks
  assert.equal(one.id, 'CON-001')
  assert.equal(one.title, 'Start tasks, not sessions')
  assert.equal(one.status, 'backlog')
  assert.deepEqual(one.assignees, ['andre'])
  assert.deepEqual(one.labels, ['mobile', 'tasks'])
  assert.equal(one.body, undefined)
  assert.deepEqual(two.assignees, ['ana', 'bo'])
  assert.ok(json.statuses.includes('verify'), 'statuses seen in files are offered')
  assert.ok(json.statuses.includes('done'))
})

test('read returns the body and the comments', async () => {
  const dir = folderWith({ 'CON-001.md': CARD + '\n## Comments\n\n- ana (2026-10-01T10:00:00Z): first\n  second line\n' })
  const { json } = await tasks('read', { folder: dir, id: 'CON-001' })
  assert.match(json.task.body, /From the phone/)
  assert.deepEqual(json.task.comments, [{ author: 'ana', createdAt: '2026-10-01T10:00:00Z', body: 'first\nsecond line' }])
})

test('status rewrites only the status and updated_at lines', async () => {
  const dir = folderWith({ 'CON-001.md': CARD })
  const { code, json } = await tasks('status', { folder: dir, id: 'CON-001', status: 'in-progress' })
  assert.equal(code, 0)
  assert.equal(json.task.status, 'in-progress')
  const after = fs.readFileSync(path.join(dir, 'CON-001.md'), 'utf8')
  const changed = CARD.split('\n').filter((l, i) => after.split('\n')[i] !== l)
  assert.deepEqual(changed, ['status: backlog', 'updated_at: "2026-09-25T13:09:19Z"'])
  assert.match(after, /^status: in-progress$/m)
  assert.deepEqual(fs.readdirSync(dir), ['CON-001.md'], 'no temp file left')
})

test('status keeps CRLF files CRLF and adds a missing status line', async () => {
  const crlf = '---\r\nid: X-1\r\ntitle: Windows\r\n---\r\nbody\r\n'
  const dir = folderWith({ 'X-1.md': crlf })
  await tasks('status', { folder: dir, id: 'X-1', status: 'In Review' })
  const after = fs.readFileSync(path.join(dir, 'X-1.md'), 'utf8')
  assert.equal(after, '---\r\nid: X-1\r\ntitle: Windows\r\nstatus: "In Review"\r\n---\r\nbody\r\n')
})

test('comment appends under a Comments heading', async () => {
  const dir = folderWith({ 'CON-001.md': CARD })
  const { json } = await tasks('comment', { folder: dir, id: 'CON-001', text: 'Started\nby the phone', author: 'André' })
  const after = fs.readFileSync(path.join(dir, 'CON-001.md'), 'utf8')
  assert.ok(after.startsWith(CARD), 'existing text untouched')
  assert.match(after, /\n## Comments\n\n- André \(\d{4}-\d\d-\d\dT[\d:]+Z\): Started\n {2}by the phone\n$/)
  assert.equal(json.task.comments.length, 1)
  assert.equal(json.task.comments[0].body, 'Started\nby the phone')
  await tasks('comment', { folder: dir, id: 'CON-001', text: 'again' })
  assert.equal(fs.readFileSync(path.join(dir, 'CON-001.md'), 'utf8').match(/## Comments/g).length, 1)
})

test('ids and folders that escape are refused', async () => {
  const dir = folderWith({ 'CON-001.md': CARD })
  const outside = folderWith({ 'secret.md': CARD })
  fs.symlinkSync(path.join(outside, 'secret.md'), path.join(dir, 'link.md'))
  for (const id of ['../CON-001', '..', 'a/b', '/etc/passwd', '.hidden', 'link', 'missing']) {
    const { code, json } = await tasks('status', { folder: dir, id, status: 'done' })
    assert.equal(code, 1, id)
    assert.ok(json.error, id)
  }
  assert.equal(fs.readFileSync(path.join(outside, 'secret.md'), 'utf8'), CARD, 'symlink target untouched')
  const listed = await tasks('list', { folder: dir })
  assert.deepEqual(listed.json.tasks.map(t => t.id), ['CON-001'], 'symlinks are not listed')
  for (const folder of ['relative/dir', '/', path.join(dir, 'nope'), path.join(dir, 'CON-001.md'), 7]) {
    const { code, json } = await tasks('list', { folder })
    assert.equal(code, 1, String(folder))
    assert.ok(['bad-folder', 'no-folder'].includes(json.code), String(folder))
  }
  for (const status of ['', 'x\ny', 'a'.repeat(60), '-lead']) {
    const { code } = await tasks('status', { folder: dir, id: 'CON-001', status })
    assert.equal(code, 1, JSON.stringify(status))
  }
  assert.equal(fs.readFileSync(path.join(dir, 'CON-001.md'), 'utf8'), CARD)
})

test('bad input gives usage errors', async () => {
  assert.equal((await tasks('list', 'not json')).code, 1)
  assert.equal((await tasks('nope', {})).json.code, 'usage')
})

// A folder shaped like /data/projectstasks (CON-084): one folder per
// project, `_` folders and stray files at the top, and a symlinked folder.
function projectsTree () {
  const root = tempDir('cnd-tasks-tree-')
  const write = (rel, text) => {
    fs.mkdirSync(path.dirname(path.join(root, rel)), { recursive: true })
    fs.writeFileSync(path.join(root, rel), text)
  }
  write('README.md', '# ProjectsTasks\n')
  write('docker-compose.yml', 'services: {}\n')
  write('body.html', '<p></p>\n')
  write('conductore-mobile/CON-001.md', CARD)
  write('conductore-mobile/CON-002.md', '---\nid: CON-002\ntitle: Two\nstatus: done\n---\n')
  write('conductore-mobile/README.md', '# not a task\n')
  write('amedia/AM-1.md', '---\nid: AM-1\ntitle: Amedia one\nstatus: todo\n---\n')
  write('amedia/deep/AM-9.md', '---\nid: AM-9\ntitle: Too deep\n---\n')
  write('_registry/REG-1.md', '---\nid: REG-1\ntitle: Registry\n---\n')
  write('_config/agents.md', '---\ntitle: config\n---\n')
  write('.git/HEAD.md', '---\ntitle: git\n---\n')
  write('web/package.json', '{}\n')
  const outside = tempDir('cnd-tasks-outside-')
  fs.writeFileSync(path.join(outside, 'OUT-1.md'), '---\nid: OUT-1\ntitle: Outside\n---\n')
  fs.symlinkSync(outside, path.join(root, 'linked'))
  return { root, outside }
}

test('a folder of project folders lists each project\'s tasks as project/id', async () => {
  const { root } = projectsTree()
  const { code, json } = await tasks('list', { folder: root })
  assert.equal(code, 0)
  assert.deepEqual(json.tasks.map(t => t.id), ['amedia/AM-1', 'conductore-mobile/CON-001', 'conductore-mobile/CON-002'])
  assert.deepEqual(json.tasks.map(t => t.project), ['amedia', 'conductore-mobile', 'conductore-mobile'])
  assert.deepEqual(json.tasks.map(t => t.key), ['AM-1', 'CON-001', 'CON-002'])
  assert.deepEqual(json.projects, ['amedia', 'conductore-mobile', 'web'], '_ and . folders and symlinks are not projects')
  assert.equal(json.truncated, false)
})

test('a folder with task files of its own stays flat', async () => {
  const { root } = projectsTree()
  fs.writeFileSync(path.join(root, 'TOP-1.md'), '---\nid: TOP-1\ntitle: Top\n---\n')
  const { json } = await tasks('list', { folder: root })
  assert.deepEqual(json.tasks.map(t => t.id), ['TOP-1'])
  assert.equal(json.tasks[0].project, undefined)
  assert.equal(json.projects, undefined)
})

test('read, status and comment take project/id', async () => {
  const { root } = projectsTree()
  const id = 'conductore-mobile/CON-001'
  const read = await tasks('read', { folder: root, id })
  assert.equal(read.code, 0)
  assert.equal(read.json.task.id, id)
  assert.equal(read.json.task.project, 'conductore-mobile')
  assert.match(read.json.task.body, /From the phone/)
  const moved = await tasks('status', { folder: root, id, status: 'review' })
  assert.equal(moved.code, 0)
  assert.equal(moved.json.task.status, 'review')
  const commented = await tasks('comment', { folder: root, id, text: 'from the tree' })
  assert.equal(commented.code, 0)
  assert.equal(commented.json.task.comments[0].body, 'from the tree')
  const after = fs.readFileSync(path.join(root, 'conductore-mobile', 'CON-001.md'), 'utf8')
  assert.match(after, /^status: review$/m)
  assert.deepEqual(fs.readdirSync(path.join(root, 'conductore-mobile')).sort(), ['CON-001.md', 'CON-002.md', 'README.md'], 'no temp file left')
})

test('project ids that escape or skip the rules are refused', async () => {
  const { root, outside } = projectsTree()
  const ids = [
    'linked/OUT-1', // a symlinked folder
    '_registry/REG-1', // an underscore folder
    '.git/HEAD',
    'amedia/deep/AM-9', // two levels
    'amedia/../conductore-mobile/CON-001',
    '../amedia/AM-1',
    'amedia/',
    '/amedia/AM-1',
    'amedia//AM-1',
    'amedia\\AM-1',
    'nope/AM-1',
    'README/x' // a file, not a folder
  ]
  for (const id of ids) {
    for (const [op, extra] of [['read', {}], ['status', { status: 'done' }], ['comment', { text: 'x' }]]) {
      const { code, json } = await tasks(op, { folder: root, id, ...extra })
      assert.equal(code, 1, `${op} ${id}`)
      assert.ok(json.error, `${op} ${id}`)
    }
  }
  assert.equal(fs.readFileSync(path.join(outside, 'OUT-1.md'), 'utf8'), '---\nid: OUT-1\ntitle: Outside\n---\n', 'symlink target untouched')
  assert.equal(fs.readFileSync(path.join(root, '_registry', 'REG-1.md'), 'utf8'), '---\nid: REG-1\ntitle: Registry\n---\n')
})

test('a tree list stops at the task cap and the scan time cap', () => {
  const { listTasks } = require('../lib/tasks-folder')
  const { root } = projectsTree()
  const capped = listTasks({ folder: root }, { maxTasks: 2 })
  assert.deepEqual(capped.tasks.map(t => t.id), ['amedia/AM-1', 'conductore-mobile/CON-001'])
  assert.equal(capped.truncated, true)
  const late = listTasks({ folder: root }, { maxScanMs: -1 })
  assert.deepEqual(late.tasks, [])
  assert.equal(late.truncated, true)
  assert.equal(listTasks({ folder: root }).truncated, false)
})
