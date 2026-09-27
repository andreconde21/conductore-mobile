'use strict'

// The transcript reader: offsets, whole lines only, capping, normalization.
// Fixtures are synthetic but mirror Claude Code's JSONL line shapes.

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('fs')
const os = require('os')
const path = require('path')
const { readTranscript, normalizeEntry } = require('../lib/transcript')

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'cnd-tr-'))
let n = 0
function file (lines, trailing = '') {
  const f = path.join(dir, `t${n++}.jsonl`)
  fs.writeFileSync(f, lines.map(l => JSON.stringify(l) + '\n').join('') + trailing)
  return f
}

const base = (type, uuid, extra = {}) => ({
  parentUuid: null, isSidechain: false, userType: 'external', cwd: '/work', sessionId: 's1',
  version: '2.1.0', gitBranch: 'main', type, uuid, timestamp: '2026-09-25T10:00:00.000Z', ...extra
})
const user = (uuid, content, extra) => base('user', uuid, { message: { role: 'user', content }, ...extra })
const assistant = (uuid, content, extra) => base('assistant', uuid, { message: { id: 'msg_1', type: 'message', role: 'assistant', model: 'claude-x', content }, requestId: 'req_1', ...extra })

test('reads whole lines, skips noise types, returns the next offset', () => {
  const f = file([
    { type: 'queue-operation', operation: 'enqueue', sessionId: 's1' },
    user('u1', 'hello'),
    assistant('a1', [{ type: 'thinking', thinking: 'secret plan', signature: 'sig' }, { type: 'text', text: 'hi there' }]),
    base('attachment', 'x1', { attachment: { type: 'hook' } }),
    { type: 'summary', summary: 'Greeting', leafUuid: 'a1' }
  ])
  const r = readTranscript(f)
  assert.equal(r.offset, fs.statSync(f).size)
  assert.equal(r.size, r.offset)
  assert.equal(r.start, 0)
  assert.deepEqual(r.entries.map(e => e.type), ['user', 'assistant', 'summary'])
  assert.equal(r.entries[0].message.content, 'hello')
  assert.deepEqual(r.entries[1].message.content[0], { type: 'thinking', hasText: true })
  assert.ok(!JSON.stringify(r).includes('secret plan'))
  assert.equal(r.entries[1].message.model, 'claude-x')
  assert.deepEqual(r.entries[2], { type: 'summary', summary: 'Greeting', leafUuid: 'a1' })
})

test('a partial last line is not returned and the offset stops before it', () => {
  const f = file([user('u1', 'one')], '{"type":"user","uuid":"u2","mess')
  const complete = Buffer.byteLength(JSON.stringify(user('u1', 'one')) + '\n')
  const r = readTranscript(f)
  assert.equal(r.entries.length, 1)
  assert.equal(r.offset, complete)
  // Once the line is finished, reading from the offset returns just it.
  fs.appendFileSync(f, 'age":{"role":"user","content":"two"}}\n')
  const r2 = readTranscript(f, { since: r.offset })
  assert.deepEqual(r2.entries.map(e => e.message.content), ['two'])
  assert.equal(r2.offset, fs.statSync(f).size)
  // Nothing new: same offset, no entries.
  const r3 = readTranscript(f, { since: r2.offset })
  assert.deepEqual(r3.entries, [])
  assert.equal(r3.offset, r2.offset)
})

test('tool_use / tool_result pairs are kept with ids, error flags and caps', () => {
  const big = 'x'.repeat(10000)
  const f = file([
    assistant('a1', [{ type: 'tool_use', id: 'toolu_1', name: 'Bash', input: { command: 'ls', description: 'List' }, caller: { type: 'direct' } }]),
    user('u1', [{ tool_use_id: 'toolu_1', type: 'tool_result', content: 'a\nb', is_error: false }], { toolUseResult: { stdout: 'a\nb' } }),
    assistant('a2', [{ type: 'tool_use', id: 'toolu_2', name: 'Write', input: { file_path: '/w/big.txt', content: big } }]),
    user('u2', [{ tool_use_id: 'toolu_2', type: 'tool_result', content: big, is_error: true }]),
    user('u3', [{ tool_use_id: 'toolu_3', type: 'tool_result', content: [{ type: 'text', text: 'shot' }, { type: 'image', source: { type: 'base64', media_type: 'image/png', data: 'AAAA' } }] }])
  ])
  const { entries } = readTranscript(f)
  assert.deepEqual(entries[0].message.content[0], { type: 'tool_use', id: 'toolu_1', name: 'Bash', input: { command: 'ls', description: 'List' } })
  assert.deepEqual(entries[1].message.content[0], { type: 'tool_result', tool_use_id: 'toolu_1', is_error: false, content: 'a\nb' })
  const write = entries[2].message.content[0]
  assert.equal(write.truncated, true)
  assert.equal(write.input.file_path, '/w/big.txt')
  assert.ok(JSON.stringify(write.input).length <= 4096)
  const err = entries[3].message.content[0]
  assert.equal(err.is_error, true)
  assert.equal(err.truncated, true)
  assert.ok(err.content.length <= 4096)
  const img = entries[4].message.content[0]
  assert.equal(img.content, 'shot')
  assert.equal(img.images, 1)
  assert.ok(!JSON.stringify(entries).includes('AAAA'))
})

test('sidechain, meta and compact-summary flags pass through; images are flagged', () => {
  const f = file([
    user('u1', [{ type: 'text', text: 'look' }, { type: 'image', source: { type: 'base64', media_type: 'image/jpeg', data: 'ZZZZ' } }]),
    assistant('a1', [{ type: 'text', text: 'sub' }], { isSidechain: true }),
    user('u2', 'Base directory for this skill', { isMeta: true }),
    user('u3', 'This session is being continued', { isCompactSummary: true }),
    base('system', 's1', { subtype: 'compact_boundary', content: 'Conversation compacted', level: 'info' })
  ])
  const { entries } = readTranscript(f)
  assert.deepEqual(entries[0].message.content[1], { type: 'image', omitted: true, mediaType: 'image/jpeg' })
  assert.equal(entries[1].isSidechain, true)
  assert.equal(entries[2].isMeta, true)
  assert.equal(entries[3].isCompactSummary, true)
  assert.equal(entries[4].subtype, 'compact_boundary')
  assert.equal(entries[4].content, 'Conversation compacted')
})

test('tail reads start on a line boundary and --before pages backwards', () => {
  const lines = []
  for (let i = 0; i < 50; i++) lines.push(user(`u${i}`, `message ${i} ${'y'.repeat(60)}`))
  const f = file(lines)
  const size = fs.statSync(f).size
  const tail = readTranscript(f, { tailBytes: 1000 })
  assert.ok(tail.start > 0 && tail.start < size)
  assert.equal(tail.offset, size)
  assert.equal(tail.entries[tail.entries.length - 1].uuid, 'u49')
  // The first entry is complete (parsed), not a fragment.
  assert.match(tail.entries[0].message.content, /^message \d+/)
  const older = readTranscript(f, { before: tail.start, maxBytes: 1024 })
  assert.equal(older.offset, tail.start)
  const lastOlder = older.entries[older.entries.length - 1].uuid
  assert.equal(Number(lastOlder.slice(1)) + 1, Number(tail.entries[0].uuid.slice(1)))
  // Page to the very beginning.
  let cursor = older.start
  let first = older.entries[0].uuid
  while (cursor > 0) {
    const page = readTranscript(f, { before: cursor, maxBytes: 1024 })
    cursor = page.start
    first = page.entries[0].uuid
  }
  assert.equal(first, 'u0')
})

test('a tail that starts exactly on a line boundary keeps that line', () => {
  const f = file([user('u0', 'a'), user('u1', 'b')])
  const firstLen = Buffer.byteLength(JSON.stringify(user('u0', 'a')) + '\n')
  const size = fs.statSync(f).size
  const r = readTranscript(f, { tailBytes: size - firstLen })
  assert.deepEqual(r.entries.map(e => e.uuid), ['u1'])
  assert.equal(r.start, firstLen)
})

test('maxBytes caps one read; the next read continues', () => {
  const lines = []
  for (let i = 0; i < 40; i++) lines.push(user(`u${i}`, 'z'.repeat(100)))
  const f = file(lines)
  const seen = []
  let offset = 0
  for (let guard = 0; guard < 100; guard++) {
    const r = readTranscript(f, { since: offset, maxBytes: 1024 })
    seen.push(...r.entries.map(e => e.uuid))
    if (r.offset === offset) break
    offset = r.offset
  }
  assert.equal(seen.length, 40)
  assert.equal(seen[39], 'u39')
})

test('a single line longer than maxBytes is read on its own instead of stalling', () => {
  const f = file([user('u0', 'q'.repeat(5000)), user('u1', 'after')])
  const r = readTranscript(f, { since: 0, maxBytes: 1024 })
  assert.equal(r.oversized, true)
  assert.deepEqual(r.entries.map(e => e.uuid), ['u0'])
  assert.equal(r.entries[0].message.content, 'q'.repeat(5000))
  assert.equal(r.offset, Buffer.byteLength(JSON.stringify(user('u0', 'q'.repeat(5000))) + '\n'))
  const r2 = readTranscript(f, { since: r.offset, maxBytes: 1024 })
  assert.deepEqual(r2.entries.map(e => e.uuid), ['u1'])
})

test('a prompt with images past maxBytes still arrives, images dropped', () => {
  // Pasted screenshots make the line megabytes long; the prompt was lost.
  const data = 'A'.repeat(400 * 1024)
  const f = file([
    user('u0', [
      { type: 'text', text: '[Image #1] why is this red?' },
      { type: 'image', source: { type: 'base64', media_type: 'image/png', data } }
    ]),
    user('u1', 'after')
  ])
  const r = readTranscript(f, { since: 0 })
  assert.equal(r.oversized, true)
  assert.deepEqual(r.entries.map(e => e.uuid), ['u0'])
  assert.deepEqual(r.entries[0].message.content, [
    { type: 'text', text: '[Image #1] why is this red?' },
    { type: 'image', omitted: true, mediaType: 'image/png' }
  ])
  assert.ok(!JSON.stringify(r).includes('AAAA'))
  const r2 = readTranscript(f, { since: r.offset })
  assert.deepEqual(r2.entries.map(e => e.uuid), ['u1'])
})

test('a prompt typed while the agent worked (queued_command) becomes a user entry', () => {
  // Claude Code absorbs it into the running turn and records it only as an
  // attachment; the chat view never showed it.
  const queued = (uuid, attachment, extra) => base('attachment', uuid, { attachment: { type: 'queued_command', timestamp: '2026-09-25T10:00:01.000Z', ...attachment }, ...extra })
  const f = file([
    queued('q1', { prompt: 'also check the logs', commandMode: 'prompt', origin: { kind: 'human' }, humanTurn: true, source_uuid: 's' }),
    { type: 'queue-operation', operation: 'remove', content: 'also check the logs', reason: 'absorbed_mid_turn' },
    // Older Claude Code: no origin.
    queued('q2', { prompt: 'and the tests', commandMode: 'prompt' }),
    // With a pasted image.
    queued('q3', { prompt: [{ type: 'text', text: '[Image #2] this one' }, { type: 'image', source: { type: 'base64', media_type: 'image/png', data: 'iVBOR' } }], commandMode: 'prompt', origin: { kind: 'human' }, imagePasteIds: [2] }),
    // Not typed by the user: dropped as before.
    queued('q4', { prompt: '<task-notification><summary>done</summary></task-notification>', commandMode: 'task-notification' }),
    queued('q5', { prompt: '<agent-message from="x">hi</agent-message>', commandMode: 'prompt', origin: { kind: 'peer' }, isMeta: true }),
    queued('q6', { prompt: 'coordinator note', origin: { kind: 'coordinator' }, isMeta: true }, { isSidechain: true }),
    base('attachment', 'x1', { attachment: { type: 'edited_text_file', filename: '/a' } })
  ])
  const r = readTranscript(f)
  assert.deepEqual(r.entries.map(e => e.uuid), ['q1', 'q2', 'q3'])
  assert.deepEqual(r.entries[0], {
    type: 'user',
    uuid: 'q1',
    parentUuid: null,
    timestamp: '2026-09-25T10:00:00.000Z',
    isSidechain: false,
    queued: true,
    message: { role: 'user', content: 'also check the logs' }
  })
  assert.equal(r.entries[1].message.content, 'and the tests')
  assert.deepEqual(r.entries[2].message.content, [
    { type: 'text', text: '[Image #2] this one' },
    { type: 'image', omitted: true, mediaType: 'image/png' }
  ])
  assert.ok(!JSON.stringify(r).includes('iVBOR'))
})

test('a long queued prompt is capped like a user line', () => {
  const long = 'w'.repeat(40 * 1024)
  const e = normalizeEntry(base('attachment', 'q1', { attachment: { type: 'queued_command', prompt: long, commandMode: 'prompt', origin: { kind: 'human' } } }))
  assert.equal(e.message.truncated, true)
  assert.equal(e.message.content.length, 32 * 1024)
})

test('an offset past the end (file replaced) resets to the tail', () => {
  const f = file([user('u0', 'a')])
  const r = readTranscript(f, { since: 999999 })
  assert.equal(r.reset, true)
  assert.deepEqual(r.entries.map(e => e.uuid), ['u0'])
})

test('malformed lines are counted and skipped', () => {
  const f = path.join(dir, 'bad.jsonl')
  fs.writeFileSync(f, 'not json\n' + JSON.stringify(user('u0', 'ok')) + '\n')
  const r = readTranscript(f)
  assert.equal(r.skipped, 1)
  assert.equal(r.entries.length, 1)
})

test('normalizeEntry drops unknown line types', () => {
  assert.equal(normalizeEntry({ type: 'file-history-snapshot' }), null)
  assert.equal(normalizeEntry(null), null)
})
