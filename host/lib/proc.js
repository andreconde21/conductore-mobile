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

module.exports = { DAEMON_TITLE, pidAlive, commandLine, isDaemon, hasProc }
