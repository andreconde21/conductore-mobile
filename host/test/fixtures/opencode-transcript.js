'use strict'

// The `transcript` replies the app gets for the two OpenCode sessions
// recorded in fixtures/opencode/1.18.34.json, as the OpenCode adapter reads
// them. host/test/opencode-adapter.test.js checks that
// test/fixtures/agent_adapters/opencode_transcript.json (the app's fixture,
// replayed by the Flutter chat tests) is exactly this, so the app is tested
// on what the companion really sends. Regenerate with
//   node host/test/fixtures/opencode-transcript.js > test/fixtures/agent_adapters/opencode_transcript.json

const fs = require('fs')
const os = require('os')
const path = require('path')
const opencode = require('../../lib/adapters/opencode')

const FIXTURE = JSON.parse(fs.readFileSync(path.join(__dirname, 'opencode', '1.18.34.json'), 'utf8'))

// The fixture rows as an OpenCode database in dir.
function writeDb (dir) {
  const { DatabaseSync } = opencode.sqlite()
  const file = path.join(dir, 'opencode.db')
  try { fs.unlinkSync(file) } catch {}
  const db = new DatabaseSync(file)
  db.exec(`CREATE TABLE session (id text PRIMARY KEY, parent_id text, directory text NOT NULL, title text, version text, time_created integer, time_updated integer);
    CREATE TABLE message (id text PRIMARY KEY, session_id text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL);
    CREATE TABLE part (id text PRIMARY KEY, message_id text NOT NULL, session_id text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL);`)
  const s = db.prepare('INSERT INTO session VALUES (?, ?, ?, ?, ?, ?, ?)')
  for (const r of FIXTURE.db.session) s.run(r.id, r.parent_id, r.directory, r.title, r.version, r.time_created, r.time_updated)
  const m = db.prepare('INSERT INTO message VALUES (?, ?, ?, ?, ?)')
  for (const r of FIXTURE.db.message) m.run(r.id, r.session_id, r.time_created, r.time_updated, r.data)
  const p = db.prepare('INSERT INTO part VALUES (?, ?, ?, ?, ?, ?)')
  for (const r of FIXTURE.db.part) p.run(r.id, r.message_id, r.session_id, r.time_created, r.time_updated, r.data)
  db.close()
  return file
}

function replies (dir) {
  const file = writeDb(dir)
  const out = {}
  for (const [key, session] of [['bash', FIXTURE.db.session[0]], ['question', FIXTURE.db.session[1]]]) {
    const page = opencode.readTranscript({ sessionId: session.id, transcriptPath: `opencode:${file}` }, {})
    out[key] = {
      sessionId: session.id,
      agent: { name: 'proj', state: 'waiting_input', lastEvent: 'Stop', lastToolName: key === 'bash' ? 'Bash' : 'AskUserQuestion', lastMessage: 'All done.', startedAt: session.time_created, updatedAt: session.time_updated, endedAt: null, pending: [] },
      ...page
    }
  }
  return out
}

module.exports = { replies, writeDb }

if (require.main === module) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'oc-fixture-'))
  try { process.stdout.write(JSON.stringify(replies(dir), null, 2) + '\n') } finally { fs.rmSync(dir, { recursive: true, force: true }) }
}
