'use strict'

// Loaded by every host test file (through cleanup.js, or directly): the
// process gets a temp CONDUCTORE_HOME of its own, so whatever a module
// loaded in the test process writes (hostd.log, rules.json, …) lands there
// and never in the user's ~/.conductore. A test that sets CONDUCTORE_HOME
// itself keeps its own; child processes inherit the test's.
//
// It also marks the run (CONDUCTORE_TEST_RUN, which log.js stamps on every
// line) and fails the file when the real ~/.conductore changed: rules.json
// or auto-approved.json by content, or hostd.log by lines carrying this
// run's mark. The live daemon's own logging never carries it.

const crypto = require('crypto')
const fs = require('fs')
const os = require('os')
const path = require('path')
const { after } = require('node:test')

const REAL_HOME = path.join(os.homedir(), '.conductore')

if (!process.env.CONDUCTORE_TEST_RUN) {
  process.env.CONDUCTORE_TEST_RUN = `${process.pid}-${crypto.randomBytes(4).toString('hex')}`
}
const MARK = process.env.CONDUCTORE_TEST_RUN

// Inherited from a parent test process: that one's home, not ours.
if (!process.env.CONDUCTORE_HOME || process.env.CONDUCTORE_HOME === process.env.CONDUCTORE_TEST_AUTO_HOME) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'conductore-test-home-'))
  process.env.CONDUCTORE_HOME = dir
  process.env.CONDUCTORE_TEST_AUTO_HOME = dir
  process.on('exit', () => { try { fs.rmSync(dir, { recursive: true, force: true }) } catch {} })
}

const sha = file => {
  try { return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex').slice(0, 16) } catch { return '-' }
}
const size = file => { try { return fs.statSync(file).size } catch { return 0 } }
const WATCHED = ['rules.json', 'auto-approved.json']
const LOG = path.join(REAL_HOME, 'hostd.log')

const before = { hashes: WATCHED.map(f => sha(path.join(REAL_HOME, f))), logSize: size(LOG) }

// What this run appended to the real hostd.log (across one rotation).
function appendedLog () {
  const read = (file, from) => {
    try {
      const buf = fs.readFileSync(file)
      return buf.length >= from ? buf.subarray(from).toString('utf8') : ''
    } catch { return '' }
  }
  const now = size(LOG)
  return now >= before.logSize ? read(LOG, before.logSize) : read(`${LOG}.1`, before.logSize) + read(LOG, 0)
}

// Throws when this run wrote to the real ~/.conductore.
function checkRealHome () {
  const changed = WATCHED.filter((f, i) => sha(path.join(REAL_HOME, f)) !== before.hashes[i])
  const lines = appendedLog().split('\n').filter(l => l.includes(`{test ${MARK}}`))
  if (changed.length || lines.length) {
    throw new Error(`a test wrote to the real ${REAL_HOME}: ${[...changed, ...(lines.length ? [`hostd.log (${lines.length} lines, e.g. ${lines[0].slice(0, 160)})`] : [])].join(', ')}`)
  }
}

after(checkRealHome)

module.exports = { checkRealHome, REAL_HOME, MARK }
