'use strict'

// Regression (review H2): a few long permission prompts waiting while
// subagents keep emitting tool events. Every change record carries the
// agent's pending prompts, and 1000 of them outgrew the 16 MB old space: the
// daemon aborted (exit 134, no log line, stale hostd.pid). The daemon here
// runs with the old 16 MB limit on purpose, so the test proves the change
// buffer's size cap, not the higher limit.

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('fs')
const path = require('path')
const { tempDir, cleanup } = require('./helpers/cleanup')
const { spawn, execFile } = require('child_process')
const paths = require('../lib/paths')

const HOSTD = path.join(__dirname, '..', 'bin', 'conductore-hostd')
const HOOK = path.join(__dirname, '..', 'bin', 'conductore-hook')
const home = tempDir('cnd-mem-')
const env = {
  ...process.env,
  CONDUCTORE_HOME: home,
  CONDUCTORE_SOCKET: path.join(home, 'hostd.sock'),
  CONDUCTORE_PERMISSION_TIMEOUT: '120'
}
for (const k of Object.keys(env)) if (/^(TMUX|HERDR_)/.test(k)) delete env[k]
process.env.CONDUCTORE_HOME = env.CONDUCTORE_HOME
process.env.CONDUCTORE_SOCKET = env.CONDUCTORE_SOCKET
const client = require('../lib/client')

const sleep = ms => new Promise(r => setTimeout(r, ms))

function cli (...args) {
  return new Promise((resolve, reject) => {
    execFile(process.execPath, [HOSTD, ...args], { env, timeout: 30000, maxBuffer: 64 * 1024 * 1024 }, (err, stdout) => {
      if (err && err.code === undefined) return reject(err)
      resolve(stdout.split('\n').filter(Boolean).map(l => JSON.parse(l)))
    })
  })
}

// One hook event dropped straight into the spool (what the sh hook does,
// without a process per event).
let n = 0
function spoolEvent (event) {
  const name = `m.${process.pid}${String(n++).padStart(6, '0')}`
  const tmp = path.join(home, 'tmp', name)
  fs.writeFileSync(tmp, `conductore 1\nkind=hook\nevent=${event.hook_event_name}\n\n${JSON.stringify(event)}`)
  fs.renameSync(tmp, path.join(home, 'spool', name))
}

test('long pending prompts plus 1,500 subagent events do not exhaust a 16 MB heap', async () => {
  paths.ensureDirs()
  const flags = paths.DAEMON_NODE_FLAGS.map(f => f.startsWith('--max-old-space-size=') ? '--max-old-space-size=16' : f)
  const daemon = spawn(process.execPath, [...flags, HOSTD, 'daemon'], { env, stdio: ['ignore', 'ignore', 'pipe'] })
  let stderr = ''
  daemon.stderr.on('data', d => { stderr += d })
  let exit = null
  daemon.on('exit', (code, signal) => { exit = { code, signal } })
  let ping
  for (let i = 0; i < 100 && !ping; i++) {
    await sleep(50)
    try { [ping] = await client.request({ op: 'ping' }, { timeoutMs: 1000 }) } catch {}
  }
  assert.equal(ping.pid, daemon.pid)

  // Eight Bash prompts with ~4 KB commands wait for the phone.
  const hooks = []
  for (let i = 0; i < 8; i++) {
    const child = spawn(HOOK, ['PermissionRequest'], { env, stdio: ['pipe', 'ignore', 'ignore'] })
    child.stdin.end(JSON.stringify({
      session_id: 'lead', cwd: '/work', hook_event_name: 'PermissionRequest', tool_name: 'Bash',
      tool_input: { command: `echo ${i} ${'x'.repeat(4000)}` }
    }))
    hooks.push(child)
  }
  for (let i = 0; i < 100; i++) {
    const [st] = await cli('status')
    if ((st.agents.find(a => a.sessionId === 'lead') || { pending: [] }).pending.length === 8) break
    await sleep(100)
  }
  const [st0] = await cli('status')
  assert.equal(st0.agents.find(a => a.sessionId === 'lead').pending.length, 8)

  // Subagents keep working; a phone long-polls throughout.
  let polls = 0
  let polling = true
  const poller = (async () => {
    let since = st0.seq
    while (polling) {
      const lines = await cli('events', '--since', String(since), '--timeout', '1')
      polls++
      for (const l of lines) if (typeof l.seq === 'number') since = Math.max(since, l.seq)
    }
  })()
  for (let batch = 0; batch < 15; batch++) {
    for (let i = 0; i < 100; i++) {
      spoolEvent({
        session_id: 'lead', agent_id: `sub${i % 4}`, cwd: '/work', hook_event_name: i % 2 ? 'PostToolUse' : 'PreToolUse',
        tool_name: 'Read', tool_input: { file_path: `/work/f${batch}-${i}` }
      })
    }
    await cli('status') // waits until the batch is applied
  }
  polling = false
  await poller

  assert.equal(exit, null, `daemon exited ${JSON.stringify(exit)}: ${stderr.slice(0, 300)}`)
  const [after] = await client.request({ op: 'ping' })
  assert.equal(after.pid, daemon.pid)
  assert.ok(after.seq >= st0.seq + 1500, `seq ${after.seq}`)
  assert.ok(polls > 0)
  // The prompts are all still pending and answerable.
  const [st1] = await cli('status')
  assert.equal(st1.agents.find(a => a.sessionId === 'lead').pending.length, 8)
  // An old cursor falls out of the size-capped buffer and resyncs.
  const stale = await cli('events', '--since', String(st0.seq), '--timeout', '0')
  assert.equal(stale.length, 1)
  assert.equal(stale[0].type, 'snapshot')
  // A recent one is still served from it: the newest change of each session.
  const recent = await cli('events', '--since', String(after.seq - 5), '--timeout', '0')
  assert.ok(recent.length >= 1 && recent.every(l => l.type === 'change' && l.seq > after.seq - 5))
  assert.equal(recent[recent.length - 1].seq, after.seq)
  assert.equal(new Set(recent.map(l => l.sessionId)).size, recent.length)
  for (const h of hooks) h.kill('SIGKILL')
})

test.after(async () => {
  await cli('stop').catch(() => {})
  await cleanup()
})
