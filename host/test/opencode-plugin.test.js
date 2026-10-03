'use strict'

// The OpenCode plugin (lib/adapters/opencode-plugin.mjs) as install()
// writes it, loaded like OpenCode loads it, with a recording hook client
// and a fake OpenCode client: what it forwards, in which order, and how it
// replies to permissions and questions.

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('fs')
const path = require('path')
const { pathToFileURL } = require('url')
const { tempDir, cleanup } = require('./helpers/cleanup')

const root = tempDir('conductore-ocplugin-')
const opencode = require('../lib/adapters/opencode')

test.after(() => cleanup())

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms))
const log = path.join(root, 'hook.log')
const answerFile = path.join(root, 'answer')
const hook = path.join(root, 'conductore-hook')
// Records argv and stdin; a PermissionRequest prints the answer file (after
// $REC_SLEEP seconds when set).
fs.writeFileSync(hook, `#!/bin/sh
body=$(cat)
printf '%s\\t%s\\n' "$*" "$body" >> "${log}"
case "$*" in *PermissionRequest*)
  [ -n "$REC_SLEEP" ] && sleep "$REC_SLEEP"
  cat "${answerFile}" 2>/dev/null ;;
esac
exit 0
`, { mode: 0o755 })

let n = 0
// A fresh copy of the installed plugin (a new module instance each time).
async function load (hookPath = hook) {
  const file = path.join(root, `conductore-${++n}.mjs`)
  fs.writeFileSync(file, opencode.renderPlugin(hookPath))
  return (await import(pathToFileURL(file).href)).default
}

function fakeCtx () {
  const posts = []
  const legacy = []
  return {
    posts,
    legacy,
    ctx: {
      directory: '/home/u/proj',
      client: {
        _client: { post: async opts => { posts.push(opts); return { data: true } } },
        postSessionIdPermissionsPermissionId: async opts => { legacy.push(opts) }
      }
    }
  }
}

const calls = () => {
  let text = ''
  try { text = fs.readFileSync(log, 'utf8') } catch {}
  return text.split('\n').filter(Boolean).map(l => { const [argv, body] = l.split('\t'); return { argv: argv.split(' '), body: JSON.parse(body) } })
}

async function until (fn, ms = 5000) {
  const end = Date.now() + ms
  while (Date.now() < end) { if (fn()) return true; await sleep(20) }
  return false
}

test.beforeEach(() => {
  try { fs.unlinkSync(log) } catch {}
  try { fs.unlinkSync(answerFile) } catch {}
  delete process.env.REC_SLEEP
  delete process.env.CONDUCTORE_BRAIN
})

test('exports both loader shapes and nothing else', async () => {
  const file = path.join(root, 'shape.mjs')
  fs.writeFileSync(file, opencode.renderPlugin(hook))
  const mod = await import(pathToFileURL(file).href)
  assert.deepEqual(Object.keys(mod), ['default'])
  assert.equal(mod.default.id, 'conductore')
  assert.equal(typeof mod.default.server, 'function')
  assert.equal(typeof mod.default.setup, 'function')
})

test('forwards sessions, prompts, tools and the turn end in order, children folded into the root', async () => {
  const plugin = await load()
  const { ctx } = fakeCtx()
  const hooks = await plugin.server(ctx)
  const ev = (type, properties) => hooks.event({ event: { type, properties } })
  await ev('session.created', { sessionID: 'ses_r', info: { id: 'ses_r', directory: '/home/u/proj', title: 't' } })
  await hooks['chat.message']({ sessionID: 'ses_r' }, { message: { id: 'msg_1' }, parts: [{ type: 'text', text: 'fix it' }, { type: 'text', text: 'injected', synthetic: true }] })
  await ev('message.part.delta', { sessionID: 'ses_r', delta: 'x' })
  await ev('session.status', { sessionID: 'ses_r', status: { type: 'busy' } })
  await hooks['tool.execute.before']({ tool: 'bash', sessionID: 'ses_r', callID: 'c1' }, { args: { command: 'ls' } })
  await hooks['tool.execute.after']({ tool: 'bash', sessionID: 'ses_r', callID: 'c1', args: { command: 'ls' } }, { title: 'ls', output: 'a\n', metadata: { exit: 0 } })
  await ev('session.created', { sessionID: 'ses_c', info: { id: 'ses_c', parentID: 'ses_r' } })
  await hooks['tool.execute.before']({ tool: 'read', sessionID: 'ses_c', callID: 'c2' }, { args: { filePath: '/a' } })
  await ev('session.idle', { sessionID: 'ses_c' })
  await ev('message.updated', { sessionID: 'ses_r', info: { id: 'msg_2', role: 'assistant' } })
  await ev('message.part.updated', { sessionID: 'ses_r', part: { type: 'text', messageID: 'msg_2', sessionID: 'ses_r', text: 'Done.' } })
  await ev('session.idle', { sessionID: 'ses_r' })
  const got = calls()
  assert.deepEqual(got.map(c => c.argv.join(' ')), [
    '--agent opencode session.created',
    '--agent opencode chat.message',
    '--agent opencode tool.execute.before',
    '--agent opencode tool.execute.after',
    '--agent opencode tool.execute.before',
    '--agent opencode session.idle',
    '--agent opencode session.idle'
  ])
  for (const c of got) assert.equal(c.body.session_id, 'ses_r')
  assert.equal(got[1].body.properties.text, 'fix it')
  assert.equal(got[3].body.properties.exit, 0)
  assert.equal(got[4].body.child, 'ses_c')
  assert.equal(got[5].body.child, 'ses_c')
  assert.equal(got[6].body.child, null)
  assert.equal(got[6].body.last_text, 'Done.')
  assert.equal(got[0].body.cwd, '/home/u/proj')
  assert.ok(path.isAbsolute(got[0].body.store.data))
  // Every forwarded body maps onto an event the daemon knows.
  for (const c of got) assert.ok(opencode.normalize(c.body, { event: c.argv[2] }), c.argv[2])
})

test('a permission waits for the hook and replies once / always / reject through the client', async () => {
  for (const [line, reply] of [['{"reply":"once"}', { reply: 'once' }], ['{"reply":"always"}', { reply: 'always' }], ['{"reply":"reject","message":"no"}', { reply: 'reject', message: 'no' }]]) {
    fs.writeFileSync(answerFile, line + '\n')
    const plugin = await load()
    const { ctx, posts } = fakeCtx()
    const hooks = await plugin.server(ctx)
    await hooks['tool.execute.before']({ tool: 'bash', sessionID: 'ses_r', callID: 'c1' }, { args: { command: 'rm -rf x' } })
    await hooks.event({ event: { type: 'permission.asked', properties: { id: 'per_1', sessionID: 'ses_r', permission: 'bash', patterns: ['rm -rf x'], metadata: { command: 'rm -rf x' }, always: ['rm *'] } } })
    assert.ok(await until(() => posts.length === 1), 'replied')
    assert.equal(posts[0].url, '/permission/{requestID}/reply')
    assert.deepEqual(posts[0].path, { requestID: 'per_1' })
    assert.deepEqual(posts[0].body, reply)
    const got = calls()
    // After the tool event, as a PermissionRequest.
    assert.deepEqual(got.map(c => c.argv[2]), ['tool.execute.before', 'PermissionRequest'])
    assert.equal(opencode.normalize(got[1].body, {}).hook_event_name, 'PermissionRequest')
    fs.unlinkSync(log)
  }
})

test('without an answer (timeout, no daemon) OpenCode keeps its own prompt', async () => {
  const plugin = await load()
  const { ctx, posts, legacy } = fakeCtx()
  const hooks = await plugin.server(ctx)
  await hooks.event({ event: { type: 'permission.asked', properties: { id: 'per_1', sessionID: 'ses_r', permission: 'bash', patterns: ['ls'] } } })
  assert.ok(await until(() => calls().length === 1))
  await sleep(200)
  assert.equal(posts.length, 0)
  assert.equal(legacy.length, 0)
})

test('an older server without the raw client gets the legacy permission route', async () => {
  fs.writeFileSync(answerFile, '{"reply":"once"}\n')
  const plugin = await load()
  const legacy = []
  const hooks = await plugin.server({ directory: '/p', client: { postSessionIdPermissionsPermissionId: async o => { legacy.push(o) } } })
  await hooks.event({ event: { type: 'permission.asked', properties: { id: 'per_9', sessionID: 'ses_r', permission: 'bash', patterns: ['ls'] } } })
  assert.ok(await until(() => legacy.length === 1))
  assert.deepEqual(legacy[0], { path: { id: 'ses_r', permissionID: 'per_9' }, body: { response: 'once' } })
})

test('a question is answered with the labels per question, or rejected', async () => {
  fs.writeFileSync(answerFile, '{"answers":[["Blue"]]}\n')
  let plugin = await load()
  let f = fakeCtx()
  let hooks = await plugin.server(f.ctx)
  await hooks.event({ event: { type: 'question.asked', properties: { id: 'que_1', sessionID: 'ses_r', questions: [{ question: 'Which colour?', options: [{ label: 'Blue' }] }] } } })
  assert.ok(await until(() => f.posts.length === 1))
  assert.equal(f.posts[0].url, '/question/{requestID}/reply')
  assert.deepEqual(f.posts[0].body, { answers: [['Blue']] })
  assert.equal(opencode.normalize(calls()[0].body, {}).tool_name, 'AskUserQuestion')

  fs.writeFileSync(answerFile, '{"reject":true}\n')
  plugin = await load()
  f = fakeCtx()
  hooks = await plugin.server(f.ctx)
  await hooks.event({ event: { type: 'question.asked', properties: { id: 'que_2', sessionID: 'ses_r', questions: [] } } })
  assert.ok(await until(() => f.posts.length === 1))
  assert.equal(f.posts[0].url, '/question/{requestID}/reject')
})

test('answered in the terminal: the waiting hook is let go at once and nothing is replied', async () => {
  // The hook would print the answer after 1 s: killed first, it prints nothing.
  process.env.REC_SLEEP = '1'
  fs.writeFileSync(answerFile, '{"reply":"once"}\n')
  const plugin = await load()
  const { ctx, posts } = fakeCtx()
  const hooks = await plugin.server(ctx)
  await hooks.event({ event: { type: 'permission.asked', properties: { id: 'per_1', sessionID: 'ses_r', permission: 'bash', patterns: ['ls'] } } })
  assert.ok(await until(() => calls().length === 1))
  await hooks.event({ event: { type: 'permission.replied', properties: { sessionID: 'ses_r', requestID: 'per_1', reply: 'reject' } } })
  // The reject is reported (the tool will not run).
  assert.ok(await until(() => calls().length === 2))
  assert.equal(calls()[1].argv[2], 'permission.replied')
  await sleep(1500)
  assert.equal(posts.length, 0)
})

test('inert for our own brain calls and when the companion is gone', async () => {
  process.env.CONDUCTORE_BRAIN = '1'
  let plugin = await load()
  assert.deepEqual(await plugin.server(fakeCtx().ctx), {})
  delete process.env.CONDUCTORE_BRAIN
  plugin = await load(path.join(root, 'missing-hook'))
  assert.deepEqual(await plugin.server(fakeCtx().ctx), {})
  // Junk never throws into OpenCode.
  plugin = await load()
  const hooks = await plugin.server({})
  await hooks.event({})
  await hooks.event({ event: { type: 'session.idle', properties: {} } })
  await hooks['chat.message']()
  await hooks['tool.execute.before']()
  await hooks['tool.execute.after']()
  assert.equal(calls().length, 0)
})
