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
