'use strict'

// The Herdr bridge against a fake Herdr server (test/helpers/fake-herdr.js)
// with Herdr 0.9.1's subscription quirks, and the recorded fixtures.

for (const k of Object.keys(process.env)) if (k.startsWith('HERDR_') || k.startsWith('TMUX')) delete process.env[k]

const test = require('node:test')
const assert = require('node:assert')
const fs = require('fs')
const path = require('path')
const { tempDir, cleanup } = require('./helpers/cleanup')
const { FakeHerdr } = require('./helpers/fake-herdr')
const { HerdrWatch, entitiesFrom } = require('../lib/herdr-live')
const { LiveStore } = require('../lib/live')
const api = require('../lib/herdr-api')

test.after(() => cleanup())

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms))
async function until (fn, ms = 3000) {
  for (let t = 0; t < ms; t += 20) {
    if (fn()) return true
    await sleep(20)
  }
  return fn()
}

function setup () {
  const dir = tempDir('hl-herdr-')
  const fake = new FakeHerdr(path.join(dir, 's.sock'))
  const changes = []
  const store = new LiveStore(ch => changes.push(ch))
  return { dir, fake, store, changes }
}

test('the recorded snapshot becomes workspace, tab and pane entities', () => {
  const doc = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures', 'herdr-snapshot-0.9.1.json'), 'utf8'))
  const { entities, paneIds } = entitiesFrom('herdr', api.snapshotOf(doc.result))
  assert.deepEqual(paneIds, ['w1:p1'])
  assert.deepEqual(entities.get('ws:herdr:w1'), { kind: 'workspace', server: 'herdr', id: 'w1', label: 'beta', number: 1, focused: true, agentStatus: 'idle', activeTabId: 'w1:t1', tabCount: 1 })
  assert.deepEqual(entities.get('tab:herdr:w1:t1'), { kind: 'tab', server: 'herdr', id: 'w1:t1', workspaceId: 'w1', label: '1', number: 1, focused: true, agentStatus: 'idle', paneCount: 1 })
  const pane = entities.get('pane:herdr:w1:p1')
  assert.equal(pane.agent, 'codex')
  assert.equal(pane.agentStatus, 'idle')
  assert.equal(pane.seq, 1)
  assert.equal(pane.cwd, '/h')
})

test('the recorded events are the shapes the bridge reacts to', () => {
  const lines = fs.readFileSync(path.join(__dirname, 'fixtures', 'herdr-events-0.9.1.jsonl'), 'utf8').split('\n').filter(Boolean).map(l => JSON.parse(l))
  const events = new Set(lines.filter(l => l.event).map(l => l.event))
  for (const e of ['workspace_created', 'tab_created', 'pane_created', 'pane_agent_detected', 'pane.agent_status_changed']) assert.ok(events.has(e), e)
})

test('snapshot, lifecycle events and per-pane status subscriptions', async () => {
  const { fake, store } = setup()
  await fake.start()
  const watch = new HerdrWatch({ id: 'herdr', socket: fake.socket, session: '', isDefault: true }, store)
  watch.start()
  assert.ok(await until(() => store.get('srv:herdr') && store.get('srv:herdr').state === 'up'))
  assert.equal(store.get('srv:herdr').version, '0.9.1')
  assert.equal(store.get('pane:herdr:w1:p1').agentStatus, 'idle')
  assert.ok(await until(() => fake.statusSubscriptions().length === 1))
  assert.deepEqual(fake.statusSubscriptions(), [['w1:p1']])

  // A status change (no pane or workspace event) arrives through C.
  fake.setStatus('w1:p1', 'working')
  assert.ok(await until(() => store.get('pane:herdr:w1:p1').agentStatus === 'working'))

  // A new pane: re-snapshot, and a new status subscription C' replaces C.
  fake.addPane({ pane_id: 'w1:p2', workspace_id: 'w1', tab_id: 'w1:t1', focused: false, cwd: '/x', agent_status: 'unknown' })
  assert.ok(await until(() => !!store.get('pane:herdr:w1:p2')))
  assert.ok(await until(() => JSON.stringify(fake.statusSubscriptions()) === JSON.stringify([['w1:p1', 'w1:p2']])))

  // Nothing but subscribe, ping and snapshot was ever sent.
  const methods = new Set(fake.requests.map(r => r.method))
  assert.deepEqual([...methods].sort(), ['events.subscribe', 'ping', 'session.snapshot'])
  assert.equal(fake.writes.length, 0)
  watch.stop()
  await fake.stop()
})

test('a pane closed between snapshot and subscribe (pane_not_found) is retried with a fresh list', async () => {
  const { fake, store } = setup()
  await fake.start()
  // The first snapshot lists a pane Herdr no longer has.
  let first = true
  fake.handlers['session.snapshot'] = () => {
    const state = JSON.parse(JSON.stringify(fake.state))
    if (first) { first = false; state.panes.push({ pane_id: 'w1:p9', workspace_id: 'w1', tab_id: 'w1:t1', agent_status: 'idle' }) }
    return { type: 'session_snapshot', snapshot: state }
  }
  const watch = new HerdrWatch({ id: 'herdr', socket: fake.socket, isDefault: true }, store)
  watch.start()
  assert.ok(await until(() => JSON.stringify(fake.statusSubscriptions()) === JSON.stringify([['w1:p1']])))
  assert.equal(store.get('pane:herdr:w1:p9'), null)
  assert.ok(fake.requests.filter(r => r.method === 'session.snapshot').length >= 2)
  watch.stop()
  await fake.stop()
})

test('Herdr going away marks the server down and drops its entities; it comes back by itself', async () => {
  const { fake, store } = setup()
  await fake.start()
  const watch = new HerdrWatch({ id: 'herdr', socket: fake.socket, isDefault: true }, store)
  watch.start()
  assert.ok(await until(() => store.get('srv:herdr') && store.get('srv:herdr').state === 'up'))
  await fake.stop()
  assert.ok(await until(() => store.get('srv:herdr').state !== 'up'))
  assert.equal(store.get('ws:herdr:w1'), null)
  await fake.start()
  assert.ok(await until(() => store.get('srv:herdr').state === 'up', 5000))
  assert.ok(store.get('ws:herdr:w1'))
  watch.stop()
  await fake.stop()
})

test('no Herdr at all: state none, nothing else', async () => {
  const { dir, store } = setup()
  const watch = new HerdrWatch({ id: 'herdr', socket: path.join(dir, 'missing.sock'), isDefault: true }, store)
  watch.start()
  assert.ok(await until(() => !!store.get('srv:herdr')))
  assert.equal(store.get('srv:herdr').state, 'none')
  assert.deepEqual(Object.keys(store.all()), ['srv:herdr'])
  watch.stop()
})

test('a Herdr without events.subscribe is read by snapshot', async () => {
  const { fake, store } = setup()
  fake.onConn = (orig => function (conn) {
    // Answers subscribe as an unknown method.
    let buf = ''
    conn.setEncoding('utf8')
    conn.on('error', () => {})
    conn.on('data', chunk => {
      buf += chunk
      let i
      while ((i = buf.indexOf('\n')) !== -1) {
        const msg = JSON.parse(buf.slice(0, i))
        buf = buf.slice(i + 1)
        this.requests.push(msg)
        if (msg.method === 'events.subscribe') conn.write(JSON.stringify({ id: msg.id, error: { code: 'invalid_request', message: 'invalid request: unknown variant `events.subscribe`' } }) + '\n')
        else this.answer(conn, msg)
      }
    })
  })(fake.onConn)
  await fake.start()
  const watch = new HerdrWatch({ id: 'herdr', socket: fake.socket, isDefault: true }, store)
  watch.start()
  assert.ok(await until(() => store.get('srv:herdr') && store.get('srv:herdr').state === 'up'))
  assert.equal(store.get('srv:herdr').mode, 'snapshot')
  assert.ok(store.get('pane:herdr:w1:p1'))
  watch.stop()
  await fake.stop()
})
