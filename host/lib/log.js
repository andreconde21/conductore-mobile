'use strict'

// Append-only log with a single rotation at 1 MB (hostd.log -> hostd.log.1).
// Never throws. Per-event lines are written only with CONDUCTORE_LOG=debug.

const fs = require('fs')
const paths = require('./paths')

const MAX_BYTES = 1024 * 1024

function log (tag, msg, extra) {
  try {
    paths.ensureDirs()
    const file = paths.logPath()
    try {
      if (fs.statSync(file).size > MAX_BYTES) fs.renameSync(file, file + '.1')
    } catch {}
    let line = `${new Date().toISOString()} [${tag}] ${msg}`
    // Host test runs stamp their lines, so a test that reaches the real
    // log is caught (test/helpers/isolate.js).
    if (process.env.CONDUCTORE_TEST_RUN) line += ` {test ${process.env.CONDUCTORE_TEST_RUN}}`
    if (extra !== undefined) line += ' ' + safeJson(extra)
    fs.appendFileSync(file, line + '\n', { mode: 0o600 })
  } catch {}
}

const debugEnabled = () => process.env.CONDUCTORE_LOG === 'debug'

function debug (tag, msg, extra) {
  if (debugEnabled()) log(tag, msg, extra)
}

function safeJson (v) {
  try { return JSON.stringify(v) } catch { return String(v) }
}

module.exports = { log, debug }
