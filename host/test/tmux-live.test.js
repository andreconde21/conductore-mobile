'use strict'

// tmux control mode: the parser, the read-only guard, where the client
// attaches, and a watch over a fake control client (no tmux runs here; a
// real isolated server is exercised only inside the test container, see
// docs/herdr-live.md).

for (const k of Object.keys(process.env)) if (k.startsWith('HERDR_') || k.startsWith('TMUX')) delete process.env[k]

const test = require('node:test')
const assert = require('node:assert')
const fs = require('fs')
const path = require('path')
const { EventEmitter } = require('events')
const { PassThrough } = require('stream')
const { tempDir, cleanup } = require('./helpers/cleanup')
const tl = require('../lib/tmux-live')
const { LiveStore } = require('../lib/live')

test.after(() => cleanup())

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms))
async function until (fn, ms = 3000) {
  for (let t = 0; t < ms; t += 20) {
    if (fn()) return true
    await sleep(20)
  }
  return fn()
}

test('only list-sessions, list-windows and list-clients may go to the control client', () => {
  for (const ok of ["list-sessions -F 'x'", 'list-windows -a -F x', 'list-clients']) assert.equal(tl.assertReadOnly(ok), ok)
  for (const bad of ['new-window -t main', 'kill-server', 'list-sessions ; kill-server', 'list-sessions \; kill-server', 'refresh-client -C 80x24', 'list-sessions\nkill-server', 'send-keys -t %1 x']) {
    assert.throws(() => tl.assertReadOnly(bad), /refusing/, bad)
  }
})

test('the parser hands our replies (flag 1) back in order and reports notifications', () => {
  const replies = []
  const notes = []
  const p = new tl.ControlParser({ onReply: r => replies.push(r), onNotification: (n) => notes.push(n) })
  p.push('%begin 1 274 0\n%end 1 274 0\n%session-changed $0 main\n%begin 1 279 1\n$0|1|0|10|5|main\n$1|2|1|12|6|we|ird\n')
  p.push('%end 1 279 1\n%window-add @3\n%begin 1 280 1\nbad\n%error 1 280 1\n%exit\n')
  assert.deepEqual(replies, [{ ok: true, lines: ['$0|1|0|10|5|main', '$1|2|1|12|6|we|ird'] }, { ok: false, lines: ['bad'] }])
  assert.deepEqual(notes, ['%session-changed', '%window-add', '%exit'])
  assert.deepEqual(tl.parseSessions(replies[0].lines)[1], { id: '$1', windows: 2, attached: 1, activity: 12, created: 6, name: 'we|ird' })
})

test('our own control client is not counted as attached', () => {
  const sessions = tl.parseSessions(['$0|2|2|100|1|main', '$1|1|0|90|1|other'])
  const windows = tl.parseWindows(['$0|@1|0|1|2|100|0|0|editor', '$0|@2|1|0|1|99|1|0|logs|x', '$1|@3|0|1|1|90|0|1|bash'])
  const clients = tl.parseClients(['4242|$0|1', '777|$0|0'])
  const e = tl.entitiesFrom('tmux', sessions, windows, clients, 4242)
  assert.equal(e.get('tses:tmux:$0').attached, 1)
  assert.equal(e.get('tses:tmux:$1').attached, 0)
  assert.deepEqual(e.get('twin:tmux:$0:@2'), { kind: 'tmuxWindow', server: 'tmux', id: '@2', sessionId: '$0', session: 'main', index: 1, name: 'logs|x', active: false, panes: 1, activity: 99, activityFlag: true, bellFlag: false })
  assert.equal(e.get('twin:tmux:$1:@3').bellFlag, true)
})

test('the client sits where a person already is, else in the least recently active session', () => {
  const sessions = tl.parseSessions(['$0|1|0|300|1|recent', '$1|1|1|100|1|old', '$2|1|0|50|1|oldest'])
  assert.equal(tl.pickSession(sessions, tl.parseClients(['10|$1|0']), -1), '$1')
  assert.equal(tl.pickSession(sessions, [], -1), '$2')
  // Our own client is no person.
  assert.equal(tl.pickSession(sessions, tl.parseClients(['99|$0|1']), 99), '$2')
  assert.equal(tl.pickSession([], [], -1), null)
})

// A fake `tmux -C` process: answers the three list commands from `model`.
function fakeTmux (model) {
  const spawned = []
  const written = []
  const spawnFn = (bin, args) => {
    const child = new EventEmitter()
    child.pid = 4242
    child.stdout = new PassThrough()
    child.stdin = new PassThrough()
    let n = 300
    child.stdin.on('data', d => {
      for (const line of String(d).split('\n').filter(Boolean)) {
        written.push(line)
        n += 1
        const out = line.startsWith('list-sessions') ? model.sessions : line.startsWith('list-windows') ? model.windows : model.clients
        child.stdout.write(`%begin 1 ${n} 1\n${out.join('\n')}${out.length ? '\n' : ''}%end 1 ${n} 1\n`)
      }
    })
    child.kill = () => child.emit('exit', 0)
    spawned.push({ bin, args, child })
    setImmediate(() => child.stdout.write('%begin 1 1 0\n%end 1 1 0\n%session-changed $0 main\n'))
    return child
  }
  const execFileFn = (bin, args, opts, cb) => {
    if (args[0] === '-V') return cb(null, 'tmux 3.4\n')
    const cmd = args[2]
    const out = cmd === 'list-sessions' ? model.sessions : cmd === 'list-clients' ? model.clients.filter(l => !l.startsWith('4242|')) : []
    cb(null, out.join('\n') + '\n')
  }
  return { spawnFn, execFileFn, spawned, written }
}

test('a watch lists over the control client, refreshes on notifications and never writes anything else', async () => {
  const dir = tempDir('hl-tmux-')
  const socket = path.join(dir, 'default')
  fs.writeFileSync(socket, '')
  const model = { sessions: ['$0|1|1|100|1|main'], windows: ['$0|@1|0|1|1|100|0|0|bash'], clients: ['4242|$0|1'] }
  const fake = fakeTmux(model)
  const store = new LiveStore()
  const watch = new tl.TmuxWatch(store, { socket, spawnFn: fake.spawnFn, execFileFn: fake.execFileFn })
  watch.start()
  assert.ok(await until(() => store.get('srv:tmux') && store.get('srv:tmux').state === 'up'))
  assert.deepEqual(fake.spawned[0].args, ['-S', socket, '-C', 'attach-session', '-t', '$0', '-f', 'read-only,ignore-size,no-output'])
  assert.equal(store.get('srv:tmux').version, '3.4')
  assert.equal(store.get('tses:tmux:$0').attached, 0)
  // A window appears: tmux says so, the watch lists again.
  model.windows.push('$0|@2|1|0|1|101|0|0|logs')
  fake.spawned[0].child.stdout.write('%window-add @2\n')
  assert.ok(await until(() => !!store.get('twin:tmux:$0:@2')))
  for (const line of fake.written) assert.match(line, /^list-(sessions|windows|clients) /)
  watch.stop()
})

test('no tmux server: state none, and the socket directory is watched', async () => {
  const dir = tempDir('hl-tmux-')
  const socket = path.join(dir, 'default')
  const model = { sessions: ['$0|1|0|100|1|main'], windows: [], clients: [] }
  const fake = fakeTmux(model)
  const store = new LiveStore()
  const watch = new tl.TmuxWatch(store, { socket, spawnFn: fake.spawnFn, execFileFn: fake.execFileFn })
  watch.start()
  assert.ok(await until(() => store.get('srv:tmux') && store.get('srv:tmux').state === 'none'))
  assert.equal(fake.spawned.length, 0)
  // The server starts: its socket appears.
  fs.writeFileSync(socket, '')
  assert.ok(await until(() => store.get('srv:tmux').state === 'up', 5000))
  watch.stop()
})

test('tmux not installed: state none with the reason', async () => {
  const store = new LiveStore()
  const watch = new tl.TmuxWatch(store, { socket: '/nonexistent/x', execFileFn: (b, a, o, cb) => cb(Object.assign(new Error('nope'), { code: 'ENOENT' })) })
  watch.start()
  assert.equal(store.get('srv:tmux').state, 'none')
  watch.stop()
})
