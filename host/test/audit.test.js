'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('fs')
const path = require('path')
const { tempDir, cleanup } = require('./helpers/cleanup')
const { Approvals, AUDIT_MAX_BYTES } = require('../lib/approvals')

test('the auto-approved log is bounded by bytes, holds no tool input, and survives a restart', () => {
  const dir = tempDir('cnd-audit-')
  const opts = { rules: path.join(dir, 'rules.json'), audit: path.join(dir, 'auto-approved.json'), home: dir }
  const a = new Approvals(opts)
  const rule = a.add({ rule: 'Bash', scope: { kind: 'any' } })
  const big = 'x'.repeat(4000)
  const now = Date.now()
  for (let i = 0; i < 400; i++) {
    a.record(rule, { request_id: `q${i}`, session_id: 's', cwd: dir, tool_name: 'Bash', tool_input: { command: `echo ${big}`, description: big }, risk: { level: 'medium', reason: 'x' } }, { name: 'a' }, now + i)
  }
  const entries = a.auditEntries(now + 400)
  assert.ok(JSON.stringify(entries).length <= AUDIT_MAX_BYTES + 1000, `${JSON.stringify(entries).length} bytes`)
  assert.equal(entries[0].requestId, 'q399')
  assert.ok(entries.every(e => !('toolInput' in e) && e.summary.length <= 200))
  assert.ok(fs.statSync(opts.audit).size <= AUDIT_MAX_BYTES + 1000)
  assert.equal(fs.statSync(opts.audit).mode & 0o777, 0o600)
  assert.equal(new Approvals(opts).auditEntries(now + 400).length, entries.length)
  // Older than 24 h: gone.
  assert.equal(new Approvals(opts).auditEntries(now + 25 * 3600000).length, 0)
  fs.rmSync(dir, { recursive: true })
})

test.after(() => cleanup())
