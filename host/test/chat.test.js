'use strict'

// `transcript`, `send` and `interrupt` through the real CLI. No daemon runs:
// the CLI falls back to state.json, which the test writes. Fake `tmux` and
// `herdr` binaries on PATH record their argv and stdin, so the tests see
// exactly what would reach the multiplexer (and that no shell is involved).
// They answer the relay's pane checks from PANES: tmux pane id -> pane pid,
// Herdr pane id -> Claude session id.

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('fs')
const path = require('path')
const { tempDir, cleanup } = require('./helpers/cleanup')
const { execFile } = require('child_process')

const HOSTD = path.join(__dirname, '..', 'bin', 'conductore-hostd')
const home = tempDir('cnd-chat-')
const binDir = path.join(home, 'bin')
const callLog = path.join(home, 'calls.jsonl')
fs.mkdirSync(binDir)

const SOCK = '/tmp/fake-tmux-0/default'
const PANES = { tmux: { '%3': 1003, '%4': 1004, '%9': 1009, '%6': 1006 }, herdr: { 'w1:p2': 'hd', 'w1:p7': 'someone-else' } }
// A second Herdr server (a named session): the same pane id holds another agent.
const HERDR_OTHER = path.join(home, 'herdr-other.sock')
const OTHER_PANES = { 'w1:p2': 'hs' }

// A fake multiplexer: logs {bin, args, stdin}; FAKE_<BIN>_FAIL makes it fail.
for (const bin of ['tmux', 'herdr']) {
  const f = path.join(binDir, bin)
  fs.writeFileSync(f, `#!${process.execPath}
const fs = require('fs')
const args = process.argv.slice(2)
let stdin = ''
try { if (args.includes('load-buffer')) stdin = fs.readFileSync(0, 'utf8') } catch {}
const socket = process.env.HERDR_SOCKET_PATH || null
fs.appendFileSync(${JSON.stringify(callLog)}, JSON.stringify({ bin: ${JSON.stringify(bin)}, args, stdin, socket }) + '\\n')
const fail = process.env.FAKE_${bin.toUpperCase()}_FAIL
const isCheck = args.includes('display-message') || args[1] === 'list'
if (fail && isCheck === !!process.env.FAKE_FAIL_CHECK) { process.stdout.write(fail + '\\n'); process.exit(1) }
const panes = ${JSON.stringify(bin)} === 'herdr' && socket === ${JSON.stringify(HERDR_OTHER)} ? ${JSON.stringify(OTHER_PANES)} : ${JSON.stringify(PANES)}.${bin}
if (args.includes('display-message')) {
  const pane = args[args.indexOf('-t') + 1]
  if (!(pane in panes)) { process.stderr.write("can't find pane: " + pane + '\\n'); process.exit(1) }
  process.stdout.write(panes[pane] + '\\n')
}
if (args[0] === 'pane' && args[1] === 'list') {
  process.stdout.write(JSON.stringify({ result: { panes: Object.entries(panes).map(([id, sid]) => ({ pane_id: id, workspace_id: 'w1', tab_id: 'w1:t1', agent_session: { agent: 'claude', kind: 'id', value: sid } })) } }))
}
`, { mode: 0o755 })
}

const env = {
  ...process.env,
  PATH: `${binDir}:${process.env.PATH}`,
  CONDUCTORE_HOME: home,
  CONDUCTORE_SOCKET: path.join(home, 'none.sock'),
  CONDUCTORE_SEND_ENTER_DELAY_MS: '0'
}
// Even a tmux call without -S (the fake on PATH aside) can only reach a
// private "default" server, never the real one.
env.TMUX_TMPDIR = tempDir('cnd-tmux-')
for (const k of Object.keys(env)) if (/^(TMUX$|TMUX_PANE$|HERDR_)/.test(k)) delete env[k]

function cli (args, { input, extraEnv } = {}) {
  return new Promise((resolve, reject) => {
    const child = execFile(process.execPath, [HOSTD, ...args], { env: { ...env, ...extraEnv }, timeout: 20000 }, (err, stdout) => {
      if (err && err.code === undefined) return reject(err)
      resolve({ code: err ? err.code : 0, json: JSON.parse(stdout.trim().split('\n').pop()) })
    })
    child.stdin.end(input === undefined ? '' : input)
  })
}

function calls () {
  try {
    return fs.readFileSync(callLog, 'utf8').split('\n').filter(Boolean).map(l => JSON.parse(l))
  } catch { return [] }
}
function resetCalls () { try { fs.unlinkSync(callLog) } catch {} }
// The calls that type or focus, without the pane checks before them.
const isCheck = c => c.args.includes('display-message') || (c.args[0] === 'pane' && c.args[1] === 'list')
const typed = () => calls().filter(c => !isCheck(c))
const tmuxPane = (paneId, extra) => ({ session: 'main', window: 1, paneId, windowName: 'x', socket: SOCK, panePid: PANES.tmux[paneId], ...extra })

const transcriptFile = path.join(home, 'sess.jsonl')
const line = o => JSON.stringify(o) + '\n'
fs.writeFileSync(transcriptFile,
  line({ type: 'user', uuid: 'u1', parentUuid: null, isSidechain: false, timestamp: '2026-09-25T10:00:00Z', message: { role: 'user', content: 'fix the bug' } }) +
  line({ type: 'assistant', uuid: 'a1', parentUuid: 'u1', isSidechain: false, timestamp: '2026-09-25T10:00:01Z', message: { role: 'assistant', content: [{ type: 'text', text: 'On it.' }] } }) +
  '{"type":"assistant","uuid":"a2"')

// Big enough (over 4 KB of entries) for --gzip to compress.
const bigFile = path.join(home, 'big.jsonl')
fs.writeFileSync(bigFile, Array.from({ length: 40 }, (_, i) =>
  line({ type: 'assistant', uuid: `b${i}`, parentUuid: null, isSidechain: false, timestamp: '2026-09-25T10:00:01Z', message: { role: 'assistant', content: [{ type: 'text', text: `Step ${i} done. `.repeat(20) }] } })).join(''))

const agent = (sessionId, extra) => ({
  sessionId, name: sessionId, cwd: '/work', transcriptPath: null, tmux: null, herdr: null,
  state: 'waiting_input', lastEvent: 'Stop', lastToolName: null, lastMessage: null,
  startedAt: Date.now(), updatedAt: Date.now(), endedAt: null, pending: [], ...extra
})
fs.writeFileSync(path.join(home, 'state.json'), JSON.stringify({
  version: 1,
  seq: 7,
  writtenAt: Date.now(),
  agents: [
    agent('tm', { transcriptPath: transcriptFile, tmux: tmuxPane('%3') }),
    agent('hd', { herdr: { workspaceId: 'w1', tabId: 'w1:t1', paneId: 'w1:p2', name: null }, tmux: tmuxPane('%9', { window: 2 }) }),
    agent('bare', {}),
    agent('perm', { state: 'needs_permission', tmux: tmuxPane('%4', { window: 3 }) }),
    agent('gone', { state: 'ended', endedAt: Date.now(), tmux: tmuxPane('%5', { window: 4 }) }),
    agent('rel', { transcriptPath: 'relative.jsonl' }),
    // Pane checks: %3 now runs another process, %6 closed; w1:p7 runs another session.
    agent('reused', { tmux: tmuxPane('%3', { panePid: 4242 }) }),
    agent('closed', { tmux: { ...tmuxPane('%6'), paneId: '%8' } }),
    agent('old', { tmux: { session: 'main', window: 1, paneId: '%3', windowName: 'x' } }),
    agent('other', { herdr: { workspaceId: 'w1', tabId: 'w1:t1', paneId: 'w1:p7', name: null } }),
    agent('hs', { herdr: { workspaceId: 'w1', tabId: 'w1:t1', paneId: 'w1:p2', name: null, socket: HERDR_OTHER } }),
    // Recorded before the socket was: checked against the default server.
    agent('hs-old', { herdr: { workspaceId: 'w1', tabId: 'w1:t1', paneId: 'w1:p2', name: null } }),
    agent('exited', { tmux: tmuxPane('%3'), process: { pid: 2 ** 22 + 7, startTime: '1' } }),
    agent('big', { transcriptPath: bigFile })
  ]
}))

test('transcript returns whole lines and the offset of the partial one', async () => {
  const r = await cli(['transcript', 'tm'])
  assert.equal(r.code, 0)
  assert.equal(r.json.sessionId, 'tm')
  assert.equal(r.json.agent.state, 'waiting_input')
  // The phone tells a finished turn from a question by the last event.
  assert.equal(r.json.agent.lastEvent, 'Stop')
  assert.deepEqual(r.json.agent.pending, [])
  assert.deepEqual(r.json.entries.map(e => e.uuid), ['u1', 'a1'])
  const whole = fs.readFileSync(transcriptFile, 'utf8').lastIndexOf('\n') + 1
  assert.equal(r.json.offset, whole)
  assert.equal(r.json.size, fs.statSync(transcriptFile).size)
  const again = await cli(['transcript', 'tm', '--since', String(r.json.offset)])
  assert.deepEqual(again.json.entries, [])
  assert.equal(again.json.offset, whole)
})

test('transcript --tail-bytes and --before', async () => {
  const tail = await cli(['transcript', 'tm', '--tail-bytes', '20'])
  assert.equal(tail.code, 0)
  assert.ok(tail.json.start > 0)
  const older = await cli(['transcript', 'tm', '--before', String(tail.json.start)])
  assert.equal(older.code, 0)
  assert.equal(older.json.start, 0)
  assert.equal(older.json.entries[0].uuid, 'u1')
})

test('transcript errors: unknown session, no transcript, bad flags, bad path', async () => {
  assert.deepEqual(await cli(['transcript', 'nope']), { code: 1, json: { error: 'unknown session nope' } })
  const none = await cli(['transcript', 'bare'])
  assert.equal(none.code, 1)
  assert.match(none.json.error, /no transcript recorded/)
  // Before the first turn: the phone shows an empty chat (CON-071).
  assert.equal(none.json.notYet, true)
  assert.equal((await cli(['transcript', 'rel'])).json.notYet, undefined)
  assert.equal((await cli(['transcript', 'tm', '--since', 'abc'])).json.error, '--since must be a non-negative number')
  assert.match((await cli(['transcript', 'tm', '--since', '1', '--before', '2'])).json.error, /not both/)
  assert.match((await cli(['transcript', 'rel'])).json.error, /absolute \.jsonl/)
  assert.match((await cli(['transcript'])).json.error, /^usage/)
})

test('--gzip: a big reply is the base64 of the gzipped JSON; small replies and errors stay plain', async () => {
  const zlib = require('zlib')
  const unzip = j => {
    assert.deepEqual(Object.keys(j), ['encoding', 'data'])
    assert.equal(j.encoding, 'gzip')
    return JSON.parse(zlib.gunzipSync(Buffer.from(j.data, 'base64')).toString('utf8'))
  }
  const plain = await cli(['transcript', 'big'])
  const packed = await cli(['transcript', 'big', '--gzip'])
  assert.equal(packed.code, 0)
  assert.deepEqual(unzip(packed.json), plain.json)
  assert.ok(JSON.stringify(packed.json).length < JSON.stringify(plain.json).length / 3)
  // The flag may come anywhere after the command, like any other.
  assert.deepEqual(unzip((await cli(['transcript', '--gzip', 'big', '--since', '0'])).json), (await cli(['transcript', 'big', '--since', '0'])).json)
  const st = await cli(['status', '--gzip'])
  assert.deepEqual(unzip(st.json).agents, (await cli(['status'])).json.agents)
  // Under 4 KB: as it was.
  assert.deepEqual((await cli(['transcript', 'tm', '--gzip'])).json.entries.map(e => e.uuid), ['u1', 'a1'])
  assert.deepEqual(await cli(['transcript', 'nope', '--gzip']), { code: 1, json: { error: 'unknown session nope' } })
})

test('send types single-line text literally into the tmux pane, then Enter', async () => {
  resetCalls()
  const nasty = `$(touch ${home}/pwned); echo 'x' "y" \`id\` -t %0`
  const r = await cli(['send', 'tm', '--text', nasty])
  assert.equal(r.code, 0)
  assert.deepEqual(r.json, { ok: true, sessionId: 'tm', via: 'tmux', paneId: '%3', chars: nasty.length, enter: true })
  assert.deepEqual(calls().map(c => c.args), [
    ['-S', SOCK, 'display-message', '-p', '-t', '%3', '#{pane_pid}'],
    ['-S', SOCK, 'send-keys', '-t', '%3', '-l', '--', nasty],
    ['-S', SOCK, 'send-keys', '-t', '%3', 'Enter']
  ])
  assert.equal(fs.existsSync(path.join(home, 'pwned')), false)
})

test('send --text-b64 and stdin; multiline goes through a bracketed paste buffer', async () => {
  resetCalls()
  const text = 'line one\nline "two" $HOME\n'
  const r = await cli(['send', 'tm', '--text-b64', Buffer.from(text).toString('base64')])
  assert.equal(r.code, 0)
  const [load, paste, enter] = typed()
  assert.deepEqual(load.args.slice(0, 3), ['-S', SOCK, 'load-buffer'])
  assert.equal(load.args[5], '-')
  assert.equal(load.stdin, text)
  const buffer = load.args[4]
  assert.match(buffer, /^conductore-[0-9a-f]{8}$/)
  assert.deepEqual(paste.args, ['-S', SOCK, 'paste-buffer', '-p', '-d', '-b', buffer, '-t', '%3'])
  assert.deepEqual(enter.args, ['-S', SOCK, 'send-keys', '-t', '%3', 'Enter'])

  resetCalls()
  const s = await cli(['send', 'tm'], { input: 'from stdin\n' })
  assert.equal(s.code, 0)
  assert.equal(s.json.chars, 'from stdin'.length)
  assert.deepEqual(typed()[0].args, ['-S', SOCK, 'send-keys', '-t', '%3', '-l', '--', 'from stdin'])
})

test('send --no-enter types without submitting', async () => {
  resetCalls()
  const r = await cli(['send', 'tm', '--text', '2', '--no-enter'])
  assert.equal(r.json.enter, false)
  assert.deepEqual(typed().map(c => c.args), [['-S', SOCK, 'send-keys', '-t', '%3', '-l', '--', '2']])
})

test('send prefers Herdr (agent prompt) and falls back to tmux when it fails', async () => {
  resetCalls()
  const r = await cli(['send', 'hd', '--text', 'hello\nworld'])
  assert.equal(r.json.via, 'herdr')
  assert.deepEqual(typed().map(c => [c.bin, ...c.args]), [['herdr', 'agent', 'prompt', 'w1:p2', 'hello\nworld']])

  resetCalls()
  const f = await cli(['send', 'hd', '--text', 'hi'], { extraEnv: { FAKE_HERDR_FAIL: '{"error":{"code":"agent_not_found"}}' } })
  assert.equal(f.code, 0)
  assert.equal(f.json.via, 'tmux')
  assert.equal(f.json.paneId, '%9')

  resetCalls()
  const blocked = await cli(['send', 'hd', '--text', 'hi'], { extraEnv: { FAKE_HERDR_FAIL: '{"error":{"code":"agent_blocked"}}' } })
  assert.equal(blocked.code, 1)
  assert.match(blocked.json.error, /agent_blocked/)
  assert.deepEqual(typed().map(c => c.bin), ['herdr'])
})

test("every herdr command goes to the agent's own Herdr server", async () => {
  resetCalls()
  const r = await cli(['send', 'hs', '--text', 'hi', '--no-enter'])
  assert.equal(r.json.via, 'herdr')
  const k = await cli(['interrupt', 'hs'])
  assert.equal(k.json.via, 'herdr')
  const f = await cli(['focus', 'hs'])
  assert.equal(f.json.via, 'herdr')
  const p = await cli(['send', 'hs', '--text', 'go'])
  assert.equal(p.json.via, 'herdr')
  const all = calls()
  assert.deepEqual(all.filter(c => !isCheck(c)).map(c => c.args), [
    ['pane', 'send-text', 'w1:p2', 'hi'],
    ['pane', 'send-keys', 'w1:p2', 'esc'],
    ['agent', 'focus', 'w1:p2'],
    ['agent', 'prompt', 'w1:p2', 'go']
  ])
  assert.ok(all.filter(isCheck).length >= 4, 'each one checked the pane first')
  assert.deepEqual([...new Set(all.map(c => c.socket))], [HERDR_OTHER])

  // Without the socket, the default server's w1:p2 holds another session:
  // the pane check refuses and nothing is typed.
  resetCalls()
  const old = await cli(['send', 'hs-old', '--text', 'hi'])
  assert.equal(old.code, 1)
  assert.match(old.json.error, /no longer holds this session/)
  assert.deepEqual(typed(), [])
})

test('send refuses unknown, ended, permission-blocked and paneless sessions', async () => {
  resetCalls()
  assert.deepEqual((await cli(['send', 'nope', '--text', 'x'])).json, { error: 'unknown session nope' })
  assert.deepEqual((await cli(['send', 'gone', '--text', 'x'])).json, { error: 'session has ended' })
  assert.match((await cli(['send', 'perm', '--text', 'x'])).json.error, /permission decision/)
  assert.deepEqual((await cli(['send', 'bare', '--text', 'x'])).json, { error: 'session not in tmux or Herdr' })
  assert.match((await cli(['send'])).json.error, /^usage/)
  assert.deepEqual(calls(), [])
})

test('send reports a tmux failure', async () => {
  const r = await cli(['send', 'tm', '--text', 'x'], { extraEnv: { FAKE_TMUX_FAIL: 'server exited unexpectedly' } })
  assert.equal(r.code, 1)
  assert.match(r.json.error, /tmux send-keys failed: server exited unexpectedly/)
})

test('interrupt sends Escape, also while a permission prompt is up', async () => {
  resetCalls()
  assert.deepEqual((await cli(['interrupt', 'perm'])).json, { ok: true, sessionId: 'perm', via: 'tmux', paneId: '%4', key: 'Escape' })
  const h = await cli(['interrupt', 'hd'])
  assert.equal(h.json.via, 'herdr')
  assert.deepEqual(typed().map(c => [c.bin, ...c.args]), [
    ['tmux', '-S', SOCK, 'send-keys', '-t', '%4', 'Escape'],
    ['herdr', 'pane', 'send-keys', 'w1:p2', 'esc']
  ])
  assert.deepEqual((await cli(['interrupt', 'nope'])).json, { error: 'unknown session nope' })
  assert.deepEqual((await cli(['interrupt', 'gone'])).json, { error: 'session has ended' })
})

test('send refuses a pane that no longer holds the session, and types nothing', async () => {
  resetCalls()
  const reused = await cli(['send', 'reused', '--text', 'meant-for-reused'])
  assert.equal(reused.code, 1)
  assert.equal(reused.json.error, 'tmux pane %3 no longer holds this session (closed, or its id reused)')
  const closed = await cli(['send', 'closed', '--text', 'x'])
  assert.match(closed.json.error, /^tmux pane %8 is gone: can't find pane: %8/)
  const old = await cli(['send', 'old', '--text', 'x'])
  assert.match(old.json.error, /^cannot verify tmux pane %3 \(recorded by an older companion\)/)
  const other = await cli(['send', 'other', '--text', 'x'])
  assert.equal(other.json.error, 'Herdr pane w1:p7 no longer holds this session')
  const exited = await cli(['send', 'exited', '--text', 'x'])
  assert.match(exited.json.error, /Claude Code process has exited/)
  assert.deepEqual(typed(), [])
  // Nothing about the old record is ever sent to the default tmux server.
  assert.ok(calls().every(c => c.bin !== 'tmux' || c.args[0] === '-S'))

  resetCalls()
  assert.equal((await cli(['interrupt', 'reused'])).code, 1)
  assert.equal((await cli(['focus', 'reused'])).code, 1)
  assert.deepEqual(typed(), [])
})

test('a Herdr pane that fails its check falls back to the verified tmux pane', async () => {
  resetCalls()
  const r = await cli(['send', 'hd', '--text', 'hi'], { extraEnv: { FAKE_HERDR_FAIL: 'no server', FAKE_FAIL_CHECK: '1' } })
  assert.equal(r.code, 0)
  assert.equal(r.json.via, 'tmux')
  assert.deepEqual(typed().map(c => c.bin), ['tmux', 'tmux'])
})

test('focus checks the pane and selects it on the agent\'s own tmux server', async () => {
  resetCalls()
  const r = await cli(['focus', 'tm'])
  assert.deepEqual(r.json, { ok: true, via: 'tmux', target: 'main:1', paneId: '%3' })
  assert.deepEqual(typed().map(c => c.args), [
    ['-S', SOCK, 'select-window', '-t', '%3'],
    ['-S', SOCK, 'select-pane', '-t', '%3']
  ])
})

test.after(() => cleanup())
