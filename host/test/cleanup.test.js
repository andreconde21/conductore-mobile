'use strict'

// The guard behind every test file's test.after: a daemon left running in
// a test's temp dir is found (by its lock, or by /proc when the lock is
// gone), stopped, reported as a failure, and the dirs are removed.

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('fs')
const path = require('path')
const { spawn } = require('child_process')
const proc = require('../lib/proc')
const { tempDir, cleanup, daemonsIn } = require('./helpers/cleanup')

const HOSTD = path.join(__dirname, '..', 'bin', 'conductore-hostd')
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms))

function startDaemon (home) {
  const env = { ...process.env, CONDUCTORE_HOME: home, CONDUCTORE_SOCKET: path.join(home, 'hostd.sock') }
  for (const k of Object.keys(env)) if (/^(TMUX|HERDR_)/.test(k)) delete env[k]
  const d = spawn(process.execPath, [HOSTD, 'daemon'], { env, stdio: 'ignore' })
  d.exited = new Promise(resolve => d.on('exit', resolve))
  return d
}

async function until (check, what) {
  for (let i = 0; i < 200; i++) {
    if (check()) return
    await sleep(25)
  }
  assert.fail(`timed out waiting for ${what}`)
}

test('cleanup stops a daemon the tests left running, fails, and removes the dirs', async () => {
  const withLock = tempDir('cnd-guard-')
  const lockLost = tempDir('cnd-guard-')
  const a = startDaemon(withLock)
  const b = startDaemon(lockLost)
  try {
    await until(() => fs.existsSync(path.join(withLock, 'hostd.sock')) && fs.existsSync(path.join(lockLost, 'hostd.sock')), 'the daemons')
    // One daemon without its lock: only the /proc scan finds it.
    fs.rmSync(path.join(lockLost, 'hostd.pid'))
    if (proc.hasProc()) await until(() => proc.commandLine(b.pid).includes(proc.DAEMON_TITLE), 'the title')
    assert.deepEqual(daemonsIn([withLock, lockLost]).sort(), (proc.hasProc() ? [a.pid, b.pid] : [a.pid]).sort())

    await assert.rejects(cleanup(), /left \d daemon\(s\) running/)
    await a.exited
    if (proc.hasProc()) await b.exited
    assert.equal(fs.existsSync(withLock), false)
    assert.equal(fs.existsSync(lockLost), false)
  } finally {
    a.kill('SIGKILL')
    b.kill('SIGKILL')
  }
})

test('cleanup passes when the tests stopped their daemons', async () => {
  const home = tempDir('cnd-guard-')
  const d = startDaemon(home)
  await until(() => fs.existsSync(path.join(home, 'hostd.sock')), 'the daemon')
  d.kill('SIGTERM')
  await d.exited
  await cleanup()
  assert.equal(fs.existsSync(home), false)
})

test.after(() => cleanup())
