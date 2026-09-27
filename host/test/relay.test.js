'use strict'

// Review M18 against real tmux: the relay types into the agent's own tmux
// server (the socket the hook reported), and refuses once the recorded pane
// id belongs to another process. Only private servers (tmux -L fix-<pid>
// under a private TMUX_TMPDIR) are used; the default server is never touched.

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('fs')
const path = require('path')
const { tempDir, cleanup } = require('./helpers/cleanup')
const { execFile, execFileSync } = require('child_process')

const HOSTD = path.join(__dirname, '..', 'bin', 'conductore-hostd')
let hasTmux = true
try { execFileSync('tmux', ['-V'], { stdio: 'ignore' }) } catch { hasTmux = false }

const home = tempDir('cnd-relay-')
const env = { ...process.env, CONDUCTORE_HOME: home, CONDUCTORE_SOCKET: path.join(home, 'none.sock'), CONDUCTORE_SEND_ENTER_DELAY_MS: '50' }
for (const k of Object.keys(env)) if (/^(TMUX|HERDR_)/.test(k)) delete env[k]
// Every server of this test, and the "default" one any unrouted tmux call
// would reach, live in a private dir: a relay without -S hits nothing real.
env.TMUX_TMPDIR = tempDir('cnd-tmux-')
const servers = [`fix-${process.pid}-a`, `fix-${process.pid}-b`]
const sockets = new Set()
const file = name => path.join(home, name)

const sleep = ms => new Promise(r => setTimeout(r, ms))
const tmux = (server, ...args) => execFileSync('tmux', ['-L', server, '-f', '/dev/null', ...args], { env, encoding: 'utf8' }).trim()

// A server whose only pane runs `cat > <out>`; returns its socket, pane id and pid.
function serve (server, out) {
  // Right after a kill-server, the dying server can still take the
  // connection ("server exited unexpectedly"): try again.
  for (let i = 0; ; i++) {
    try {
      tmux(server, 'new-session', '-d', '-s', 'agent', '-x', '80', '-y', '20', `cat > '${file(out)}'`)
      break
    } catch (err) {
      if (i >= 20) throw err
      execFileSync('sleep', ['0.1'])
    }
  }
  const [socket, paneId, panePid] = tmux(server, 'display-message', '-p', '-t', 'agent', '#{socket_path}\t#{pane_id}\t#{pane_pid}').split('\t')
  sockets.add(socket)
  return { socket, paneId, panePid: Number(panePid) }
}

function writeState (tmuxLoc) {
  const now = Date.now()
  fs.writeFileSync(file('state.json'), JSON.stringify({
    version: 1,
    seq: 1,
    agents: [{
      sessionId: 'r1', name: 'r1', cwd: home, transcriptPath: null, herdr: null, state: 'waiting_input',
      tmux: { session: 'agent', window: 0, windowName: 'cat', ...tmuxLoc },
      lastEvent: 'Stop', lastToolName: null, lastMessage: null, startedAt: now, updatedAt: now, endedAt: null, pending: []
    }]
  }))
}

function send (text) {
  return new Promise((resolve, reject) => {
    execFile(process.execPath, [HOSTD, 'send', 'r1', '--text', text], { env, timeout: 20000 }, (err, stdout) => {
      if (err && err.code === undefined) return reject(err)
      resolve(JSON.parse(stdout.trim().split('\n').pop()))
    })
  })
}

async function contents (name, expect) {
  for (let i = 0; i < 40; i++) {
    const text = fs.existsSync(file(name)) ? fs.readFileSync(file(name), 'utf8') : ''
    if (expect === undefined ? i === 10 : text === expect) return text
    await sleep(50)
  }
  return fs.existsSync(file(name)) ? fs.readFileSync(file(name), 'utf8') : ''
}

test('send reaches the agent on its own tmux server and refuses a reused pane id', { skip: !hasTmux }, async () => {
  const a = serve(servers[0], 'a.txt')
  // Another server with the same pane id: what `tmux` without -S would hit.
  const b = serve(servers[1], 'b.txt')
  assert.equal(a.paneId, b.paneId)
  writeState(a)
  const ok = await send('hello-for-a')
  assert.equal(ok.ok, true, JSON.stringify(ok))
  assert.equal(await contents('a.txt', 'hello-for-a\n'), 'hello-for-a\n')
  assert.equal(await contents('b.txt'), '')

  // The agent's server restarts: the pane id comes back, on another process.
  tmux(servers[0], 'kill-server')
  const again = serve(servers[0], 'c.txt')
  assert.equal(again.paneId, a.paneId)
  assert.notEqual(again.panePid, a.panePid)
  const refused = await send('meant-for-the-old-agent')
  assert.equal(refused.error, `tmux pane ${a.paneId} no longer holds this session (closed, or its id reused)`)
  assert.equal(await contents('c.txt'), '')
  assert.equal(await contents('b.txt'), '')
})

test.after(() => {
  for (const s of servers) { try { tmux(s, 'kill-server') } catch {} }
  for (const s of sockets) { try { fs.unlinkSync(s) } catch {} }
  return cleanup()
})
