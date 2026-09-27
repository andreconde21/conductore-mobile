'use strict'

// Process identity checks. A bare pid is not enough: hostd.pid survives
// reboots and hard crashes, and its pid can belong to any process later.

const fs = require('fs')
const { execFileSync } = require('child_process')

// Also the daemon's process title (/proc/<pid>/comm keeps 15 characters:
// "conductore-host"), which the sh clients check.
const DAEMON_TITLE = 'conductore-hostd'

const hasProc = () => fs.existsSync('/proc/self/cmdline')

function pidAlive (pid) {
  try { process.kill(pid, 0); return true } catch (err) { return err.code === 'EPERM' }
}

// The command line of a live process ('' when it cannot be read), NULs as spaces.
function commandLine (pid) {
  if (hasProc()) {
    try { return fs.readFileSync(`/proc/${pid}/cmdline`, 'latin1').replace(/\0+/g, ' ').trim() } catch { return '' }
  }
  try {
    return execFileSync('ps', ['-p', String(pid), '-o', 'command='], { encoding: 'latin1', timeout: 2000, stdio: ['ignore', 'pipe', 'ignore'] }).trim()
  } catch { return '' }
}

// Whether pid is a running conductore-hostd (the current title, or the
// node command line of a daemon from before it set one).
function isDaemon (pid) {
  if (!Number.isInteger(pid) || pid <= 0 || !pidAlive(pid)) return false
  return commandLine(pid).includes(DAEMON_TITLE)
}

// /proc/<pid>/stat as { comm, ppid, startTime } (start in clock ticks since
// boot: with the pid, it names one process), or null.
function stat (pid) {
  let text
  try { text = fs.readFileSync(`/proc/${pid}/stat`, 'latin1') } catch { return null }
  const open = text.indexOf('(')
  const close = text.lastIndexOf(')')
  if (open === -1 || close === -1) return null
  const fields = text.slice(close + 2).split(' ')
  return { comm: text.slice(open + 1, close), ppid: Number(fields[1]), startTime: fields[19] }
}

// The Claude Code process a hook reported, as { pid, startTime }, or null
// when it cannot be identified (no /proc, gone, or not Claude Code: a
// short-lived wrapper must never be mistaken for the agent).
function identifyClaude (pid) {
  pid = Number(pid)
  if (!Number.isInteger(pid) || pid <= 1 || !hasProc()) return null
  const st = stat(pid)
  if (!st || !/claude/i.test(st.comm) || !st.startTime) return null
  return { pid, startTime: st.startTime }
}

// Whether a process recorded by identifyClaude is still running (the same
// one: a reused pid has another start time).
function sameProcess (p) {
  if (!p || !Number.isInteger(p.pid)) return false
  if (!hasProc()) return pidAlive(p.pid)
  const st = stat(p.pid)
  return !!st && st.startTime === p.startTime
}

module.exports = { DAEMON_TITLE, pidAlive, commandLine, isDaemon, hasProc, stat, identifyClaude, sameProcess }
