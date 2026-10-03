'use strict'

// Integration: risk labels, rules, time-boxed trust, "approve all safe" and
// the auto-approved log, through a real daemon and the real sh hook.

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('fs')
const path = require('path')
const { tempDir, cleanup } = require('./helpers/cleanup')
const { spawn, execFile } = require('child_process')

const HOSTD = path.join(__dirname, '..', 'bin', 'conductore-hostd')
const HOOK = path.join(__dirname, '..', 'bin', 'conductore-hook')

// Short paths: unix sockets are limited to ~100 bytes.
const home = tempDir('cnd-ap-')
const userHome = tempDir('cnd-aph-')
const repo = path.join(userHome, 'Projects', 'app')
const other = path.join(userHome, 'Projects', 'other')
fs.mkdirSync(path.join(repo, '.git'), { recursive: true })
fs.mkdirSync(path.join(repo, 'packages', 'web'), { recursive: true })
fs.mkdirSync(path.join(other, '.git'), { recursive: true })

const env = {
  ...process.env,
  HOME: userHome,
  CONDUCTORE_HOME: home,
  CONDUCTORE_SOCKET: path.join(home, 'hostd.sock'),
  CONDUCTORE_CLAUDE_SETTINGS: path.join(home, 'settings.json'),
  CONDUCTORE_PERMISSION_TIMEOUT: '20'
}
for (const k of ['TMUX', 'TMUX_PANE', 'HERDR_WORKSPACE_ID', 'HERDR_PANE_ID', 'HERDR_TAB_ID', 'HERDR_AGENT_NAME']) delete env[k]

const sleep = ms => new Promise(r => setTimeout(r, ms))

function cli (...args) {
  return new Promise((resolve, reject) => {
    execFile(process.execPath, [HOSTD, ...args], { env, timeout: 30000 }, (err, stdout) => {
      if (err && err.code === undefined) return reject(err)
      const lines = stdout.split('\n').filter(Boolean).map(l => JSON.parse(l))
      resolve({ code: err ? err.code : 0, json: lines[lines.length - 1] })
    })
  })
}

function hook (event) {
  return new Promise((resolve, reject) => {
    const t0 = process.hrtime.bigint()
    const child = spawn(HOOK, [event.hook_event_name], { env, stdio: ['pipe', 'pipe', 'ignore'] })
    let stdout = ''
    child.stdout.on('data', d => { stdout += d })
    child.on('error', reject)
    child.on('close', code => resolve({ code, stdout, ms: Number(process.hrtime.bigint() - t0) / 1e6 }))
    child.stdin.end(JSON.stringify(event))
  })
}

async function waitFor (pred, ms = 5000) {
  const deadline = Date.now() + ms
  while (Date.now() < deadline) {
    const v = await pred()
    if (v) return v
    await sleep(40)
  }
  throw new Error('timed out waiting')
}

const status = async () => (await cli('status')).json
const agent = async sid => (await status()).agents.find(a => a.sessionId === sid)
const pendingOf = async (sid, n = 1) => waitFor(async () => {
  const a = await agent(sid)
  return a && a.pending.length >= n && a.pending
})

const perm = (sid, tool, input, cwd = repo) => ({ session_id: sid, cwd, hook_event_name: 'PermissionRequest', tool_name: tool, tool_input: input })
const bash = (sid, command, cwd) => perm(sid, 'Bash', { command }, cwd)
const allowed = r => JSON.parse(r.stdout).hookSpecificOutput.decision.behavior === 'allow'
const median = xs => { const s = [...xs].sort((a, b) => a - b); return s[Math.floor(s.length / 2)] }

test('status reports the capability and a risk label on every pending request', async () => {
  await hook({ session_id: 'a1', cwd: repo, hook_event_name: 'SessionStart' })
  const st = await status()
  assert.deepEqual(st.capabilities, ['smart-approvals', 'digest', 'snapshots', 'live', 'herdr-agents', 'agent-messaging', 'herdr-sidebar', 'config', 'sheprd-sidebar', 'question-answers'])
  assert.deepEqual((await cli('version')).json.capabilities, ['smart-approvals', 'digest', 'snapshots', 'live', 'herdr-agents', 'agent-messaging', 'herdr-sidebar', 'config', 'sheprd-sidebar', 'question-answers'])
  const p = hook(bash('a1', 'rm -rf node_modules'))
  const [req] = await pendingOf('a1')
  assert.deepEqual(req.risk, { level: 'high', reason: 'Deletes recursively (rm -rf): node_modules' })
  assert.equal(req.batchable, false)
  assert.equal(req.repo, repo)
  assert.equal(req.suggestedRules[0], 'Bash(rm *)')
  await cli('decide', req.id, 'deny')
  assert.equal(JSON.parse((await p).stdout).hookSpecificOutput.decision.behavior, 'deny')
})

test('trust: allows the request, saves a 0600 rule, and the hook answers the next one itself', async () => {
  const p = hook(bash('a1', 'npm test -- --grep auth'))
  const [req] = await pendingOf('a1')
  assert.equal(req.risk.level, 'low')
  const t = await cli('trust', req.id, '--minutes', '15', '--rule', 'Bash(npm test *)')
  assert.equal(t.code, 0, JSON.stringify(t.json))
  assert.equal(t.json.rule.rule, 'Bash(npm test *)')
  assert.deepEqual(t.json.rule.scope, { kind: 'repo', path: repo })
  assert.ok(Math.abs(t.json.rule.expiresAt - (Date.now() + 15 * 60000)) < 5000)
  assert.deepEqual(t.json.approved, [req.id])
  assert.ok(allowed(await p))
  const file = path.join(home, 'rules.json')
  assert.equal(fs.statSync(file).mode & 0o777, 0o600)
  assert.equal(JSON.parse(fs.readFileSync(file, 'utf8')).rules[0].rule, 'Bash(npm test *)')

  // Covered: answered by the hook itself, never pending, logged.
  const seq = (await status()).seq
  const r = await hook(bash('a1', 'cd packages/web && npm test 2>&1 | tail -20', path.join(repo, 'packages', 'web')))
  assert.ok(allowed(r))
  const a = await agent('a1')
  assert.equal(a.pending.length, 0)
  assert.equal(a.state, 'working')
  assert.ok(a.lastAutoApprovedAt > 0)
  const ev = await cli('events', '--since', String(seq), '--timeout', '0')
  assert.ok(ev.code === 0)
  const log = (await cli('approvals')).json
  assert.equal(log.autoApproved.length, 1)
  assert.equal(log.autoApproved[0].rule, 'Bash(npm test *)')
  assert.equal(log.autoApproved[0].summary, 'cd packages/web && npm test 2>&1 | tail -20')
  assert.equal(log.autoApproved[0].risk.level, 'low')
  assert.equal(log.autoApproved[0].agent, 'web')
  assert.equal(log.rules[0].hits, 1)

  // Not covered: another repo, or another command, still asks.
  const q = hook(bash('a2', 'npm test', other))
  const [req2] = await pendingOf('a2')
  await cli('decide', req2.id, 'allow')
  await q
})

test('trust without a rule covers only that exact call', async () => {
  const p = hook(bash('n1', 'npm run lint -- --fix=false'))
  const [req] = await pendingOf('n1')
  const t = await cli('trust', req.id, '--minutes', '5')
  assert.equal(t.json.rule.rule, 'Bash(npm run lint -- --fix=false)')
  await p
  assert.ok(allowed(await hook(bash('n1', 'npm run lint -- --fix=false'))))
  const q = hook(bash('n1', 'npm run lint'))
  const [other] = await pendingOf('n1')
  await cli('decide', other.id, 'allow')
  await q
  await cli('rules', 'remove', t.json.rule.id)
})

test('high risk is never auto-approved, whatever the rules say', async () => {
  const add = await cli('rules', 'add', 'Bash', '--scope', 'any')
  assert.equal(add.code, 0)
  const p = hook(bash('h1', 'git push --force origin main'))
  const [req] = await pendingOf('h1')
  assert.equal(req.risk.level, 'high')
  // Trust is refused too.
  const t = await cli('trust', req.id, '--minutes', '60')
  assert.equal(t.code, 1)
  assert.match(t.json.error, /high-risk requests always ask/)
  // "Always" on high is answered as a one-time allow, no rule for Claude Code.
  const d = await cli('decide', req.id, 'always')
  assert.equal(d.json.decision, 'allow')
  assert.match(d.json.note, /high-risk/)
  const out = JSON.parse((await p).stdout).hookSpecificOutput.decision
  assert.deepEqual(out, { behavior: 'allow' })
  // Medium is covered by the catch-all Bash rule.
  assert.ok(allowed(await hook(bash('h1', 'npm install left-pad'))))
  await cli('rules', 'remove', add.json.rule.id)
})

test('a question is never answered by a rule, nor trusted (CON-062)', async () => {
  // An allow without answers would run AskUserQuestion with no answers (or
  // be ignored, leaving the dialog in the terminal): the user answers it.
  const add = await cli('rules', 'add', 'AskUserQuestion', '--scope', 'any')
  assert.equal(add.code, 0)
  const input = { questions: [{ question: 'Ship it?', header: 'Ship', multiSelect: false, options: [{ label: 'Yes' }, { label: 'No' }] }] }
  const p = hook(perm('qa', 'AskUserQuestion', input))
  const [req] = await pendingOf('qa')
  assert.equal(req.toolName, 'AskUserQuestion')
  const t = await cli('trust', req.id, '--minutes', '60')
  assert.equal(t.code, 1)
  assert.match(t.json.error, /question takes an answer/)
  const d = await cli('decide', req.id, 'answer', '--answers', JSON.stringify({ 'Ship it?': 'Yes' }))
  assert.equal(d.code, 0)
  assert.deepEqual(JSON.parse((await p).stdout).hookSpecificOutput.decision.updatedInput.answers, { 'Ship it?': 'Yes' })
  await cli('rules', 'remove', add.json.rule.id)
})

test('adding a rule answers waiting requests it covers; remove revokes it', async () => {
  const p1 = hook(perm('w1', 'Edit', { file_path: path.join(repo, 'src', 'a.ts'), old_string: 'a', new_string: 'b' }))
  const p2 = hook(perm('w1', 'Edit', { file_path: path.join(repo, 'docs', 'b.md'), old_string: 'a', new_string: 'b' }))
  const pending = await pendingOf('w1', 2)
  const src = pending.find(p => p.summary.endsWith('a.ts'))
  assert.equal(src.risk.level, 'medium')
  assert.deepEqual(src.suggestedRules, ['Edit(src/**)', 'Edit(**)'])
  const add = await cli('rules', 'add', 'Edit(src/**)', '--scope', 'repo', '--path', repo)
  assert.deepEqual(add.json.approved, [src.id])
  assert.ok(allowed(await p1))
  const left = (await agent('w1')).pending
  assert.equal(left.length, 1)
  const rm = await cli('rules', 'remove', add.json.rule.id)
  assert.equal(rm.json.removed.id, add.json.rule.id)
  assert.equal((await cli('rules', 'remove', add.json.rule.id)).code, 1)
  await cli('decide', left[0].id, 'deny')
  await p2
  // Revoked: the same edit asks again.
  const p3 = hook(perm('w1', 'Edit', { file_path: path.join(repo, 'src', 'c.ts'), old_string: 'a', new_string: 'b' }))
  const [again] = await pendingOf('w1')
  await cli('decide', again.id, 'allow')
  await p3
})

test('trust expiry: a rule past its time asks again', async () => {
  // Written by hand (the daemon re-reads the file when it changes).
  const file = path.join(home, 'rules.json')
  const soon = { id: 'rsoon000001', rule: 'Bash(make lint *)', scope: { kind: 'any' }, expiresAt: Date.now() + 1500, endsWithSession: null, source: 'trust', createdAt: Date.now(), hits: 0, lastUsedAt: null }
  const data = JSON.parse(fs.readFileSync(file, 'utf8'))
  data.rules.push(soon)
  fs.writeFileSync(file, JSON.stringify(data))
  assert.ok(allowed(await hook(bash('e1', 'make lint'))))
  await sleep(1700)
  const p = hook(bash('e1', 'make lint'))
  const [req] = await pendingOf('e1')
  assert.equal(req.toolName, 'Bash')
  assert.ok(!(await cli('rules')).json.rules.some(r => r.id === 'rsoon000001'))
  await cli('decide', req.id, 'allow')
  await p
})

test('until the session ends: session rules go with SessionEnd', async () => {
  const p = hook(perm('s9', 'Read', { file_path: path.join(repo, 'README.md') }))
  const [req] = await pendingOf('s9')
  const t = await cli('trust', req.id, '--scope', 'session', '--until-session-end')
  assert.equal(t.json.rule.scope.kind, 'session')
  assert.equal(t.json.rule.endsWithSession, 's9')
  assert.equal(t.json.rule.expiresAt, null)
  await p
  // Another session is not covered.
  const q = hook(perm('s8', 'Read', { file_path: path.join(repo, 'README.md') }))
  const [other] = await pendingOf('s8')
  await cli('decide', other.id, 'allow')
  await q
  assert.ok(allowed(await hook(perm('s9', 'Read', { file_path: path.join(repo, 'README.md') }))))
  await hook({ session_id: 's9', cwd: repo, hook_event_name: 'SessionEnd' })
  await waitFor(async () => !(await cli('rules')).json.rules.some(r => r.id === t.json.rule.id))
})

test('approve-low approves only low-risk requests, across agents', async () => {
  const hooks = [
    hook(bash('b1', 'git status')),
    hook(bash('b2', 'ls -la')),
    hook(bash('b2', 'npm install')),
    hook(bash('b3', 'rm -rf dist'))
  ]
  await pendingOf('b1')
  await pendingOf('b2', 2)
  const [high] = await pendingOf('b3')
  const all = (await status()).agents.flatMap(a => a.pending)
  const low = all.filter(p => p.batchable).map(p => p.id)
  assert.equal(low.length, 2)
  // --ids: the list the phone showed; a high one slipped in is skipped.
  const r = await cli('approve-low', '--ids', [...low, high.id, 'nope'].join(','))
  assert.equal(r.code, 0)
  assert.deepEqual(r.json.approved.map(a => a.id).sort(), [...low].sort())
  assert.deepEqual(r.json.skipped.map(s => s.id).sort(), [high.id, 'nope'].sort())
  assert.match(r.json.skipped.find(s => s.id === high.id).reason, /high risk/)
  assert.ok(allowed(await hooks[0]))
  assert.ok(allowed(await hooks[1]))
  // Without --ids: everything low that waits (none left), medium and high untouched.
  const again = await cli('approve-low')
  assert.deepEqual(again.json.approved, [])
  assert.equal(again.json.skipped.length, 2)
  for (const p of (await status()).agents.flatMap(a => a.pending)) await cli('decide', p.id, 'deny')
  await Promise.all(hooks)
})

test('rules edit changes pattern and duration, keeps id and counters', async () => {
  const add = await cli('rules', 'add', 'Bash(cargo check *)', '--minutes', '10')
  const id = add.json.rule.id
  const e = await cli('rules', 'edit', id, '--rule', 'Bash(cargo *)', '--forever')
  assert.equal(e.json.rule.id, id)
  assert.equal(e.json.rule.rule, 'Bash(cargo *)')
  assert.equal(e.json.rule.expiresAt, null)
  const bad = await cli('rules', 'add', 'not a rule!')
  assert.equal(bad.code, 1)
  assert.match(bad.json.error, /not a rule/)
  await cli('rules', 'remove', id)
})

test('hook auto-answer latency stays low', async (t) => {
  const add = await cli('rules', 'add', 'Bash(git status *)', '--scope', 'repo', '--path', repo)
  // Warm up.
  for (let i = 0; i < 3; i++) await hook(bash('l1', 'git status'))
  const auto = []
  const plain = []
  for (let i = 0; i < 20; i++) {
    const r = await hook(bash('l1', 'git status --short'))
    assert.ok(allowed(r))
    auto.push(r.ms)
    plain.push((await hook({ session_id: 'l1', cwd: repo, hook_event_name: 'PostToolUse', tool_name: 'Bash' })).ms)
  }
  const m = median(auto)
  t.diagnostic(`auto-approve: median ${m.toFixed(1)} ms, max ${Math.max(...auto).toFixed(1)} ms; plain event: median ${median(plain).toFixed(1)} ms (20 runs)`)
  assert.ok(m < 250, `median ${m} ms`)
  await cli('rules', 'remove', add.json.rule.id)
})

test.after(async () => {
  await cli('stop').catch(() => {})
  await cleanup()
})
