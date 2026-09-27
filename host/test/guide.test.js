'use strict'

// `guide` through the real CLI with a fake `claude` on PATH that records
// its argv and stdin: the argv shape (no request text in it), the stdin
// JSON, the structured answer, validation against the context, timeout
// and busy.

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('fs')
const os = require('os')
const path = require('path')
const { execFile } = require('child_process')
const gm = require('../lib/guide')

const HOSTD = path.join(__dirname, '..', 'bin', 'conductore-hostd')
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'cnd-guide-'))
const binDir = path.join(root, 'bin')
const home = path.join(root, 'home')
const record = path.join(root, 'record.json')
const pidsFile = path.join(root, 'pids.json')
fs.mkdirSync(binDir)
fs.mkdirSync(home)

// FAKE_MODE: ok (prints FAKE_ANSWER as structured_output after
// FAKE_DELAY_MS), result (the answer only in `result`), hang, not-logged-in,
// crash.
fs.writeFileSync(path.join(binDir, 'claude'), `#!${process.execPath}
const fs = require('fs')
const { spawn } = require('child_process')
const stdin = fs.readFileSync(0, 'utf8')
fs.writeFileSync(${JSON.stringify(record)}, JSON.stringify({ args: process.argv.slice(2), stdin, thinking: process.env.MAX_THINKING_TOKENS }))
const mode = process.env.FAKE_MODE || 'ok'
const answer = JSON.parse(process.env.FAKE_ANSWER || '{"action":"home","target":"","text":"","minutes":0,"speak":"Going home."}')
if (mode === 'hang') {
  const g = spawn('/bin/sleep', ['60'], { stdio: 'ignore' })
  fs.writeFileSync(${JSON.stringify(pidsFile)}, JSON.stringify([process.pid, g.pid]))
  process.on('SIGTERM', () => {})
  setInterval(() => {}, 1000)
} else if (mode === 'not-logged-in') {
  process.stdout.write(JSON.stringify({ type: 'result', is_error: true, result: 'Not logged in · Please run /login' }) + '\\n')
  process.exit(1)
} else if (mode === 'crash') {
  process.stderr.write('boom\\n')
  process.exit(3)
} else {
  setTimeout(() => {
    const res = { type: 'result', subtype: 'success', is_error: false, result: JSON.stringify(answer), modelUsage: { 'claude-haiku-4-5-20251001': {} } }
    if (mode === 'ok') res.structured_output = answer
    process.stdout.write(JSON.stringify(res) + '\\n')
  }, Number(process.env.FAKE_DELAY_MS || 0))
}
`, { mode: 0o755 })

const env = {
  ...process.env,
  PATH: binDir,
  HOME: home,
  CONDUCTORE_HOME: path.join(root, 'state'),
  CONDUCTORE_SOCKET: path.join(root, 'none.sock')
}
delete env.CLAUDECODE

function cli (args, { input, extraEnv } = {}) {
  return new Promise((resolve, reject) => {
    const child = execFile(process.execPath, [HOSTD, 'guide', ...args], { env: { ...env, ...extraEnv }, timeout: 30000, maxBuffer: 1 << 20 }, (err, stdout) => {
      if (err && err.code === undefined) return reject(err)
      const lines = stdout.trim().split('\n')
      resolve({ code: err ? err.code : 0, lines, json: JSON.parse(lines.pop()) })
    })
    child.stdin.on('error', () => {})
    child.stdin.end(input === undefined ? '' : input)
  })
}

const lastCall = () => JSON.parse(fs.readFileSync(record, 'utf8'))
const reset = () => { for (const f of [record, pidsFile]) try { fs.unlinkSync(f) } catch {} }
const alive = pid => { try { process.kill(pid, 0); return true } catch (err) { return err.code === 'EPERM' } }

const CONTEXT = {
  lang: 'en',
  screen: { view: 'home' },
  machines: [{ id: 'm1', name: 'VTM' }],
  projects: [{ id: 'p1', name: 'conductore-mobile' }],
  agents: [{ id: 'a1', machine: 'm1', name: 'api', project: 'p1', state: 'needs_permission', pending: [{ id: 'r1', tool: 'Bash', summary: 'npm test', risk: 'low' }] }]
}
const UTTERANCE = 'ask the api agent to run the secret-word-7731 tests'
const request = (extra = {}) => JSON.stringify({ utterance: UTTERANCE, context: CONTEXT, ...extra })
const answer = a => ({ FAKE_ANSWER: JSON.stringify({ target: '', text: '', minutes: 0, speak: 'OK.', ...a }) })

test('argv is locked down and never carries the request; stdin carries it as JSON', async () => {
  reset()
  const r = await cli([], { input: request(), extraEnv: answer({ action: 'send', target: 'a1', text: 'Run the tests.', speak: 'Sending to api.' }) })
  assert.equal(r.code, 0)
  assert.equal(r.lines.length, 0, 'exactly one line on stdout')
  const call = lastCall()
  const args = call.args
  for (const flag of ['-p', '--safe-mode', '--no-session-persistence']) assert.ok(args.includes(flag), flag)
  assert.equal(args[args.indexOf('--tools') + 1], '')
  assert.equal(args[args.indexOf('--output-format') + 1], 'json')
  assert.equal(args[args.indexOf('--model') + 1], 'haiku')
  assert.equal(args[args.indexOf('--system-prompt') + 1], gm.SYSTEM_PROMPT)
  assert.deepEqual(JSON.parse(args[args.indexOf('--json-schema') + 1]), gm.OUTPUT_SCHEMA)
  assert.ok(!args.join(' ').includes('secret-word-7731'), 'no utterance in argv')
  assert.ok(!args.join(' ').includes('npm test'), 'no context in argv')
  assert.equal(call.thinking, '0')
  // The request sits between random delimiters as one JSON line.
  const m = call.stdin.match(/<(REQUEST-[0-9a-f]{12})>\n(.*)\n<\/\1>/)
  assert.ok(m, 'delimited request')
  assert.deepEqual(JSON.parse(m[2]), { utterance: UTTERANCE, context: CONTEXT })
  assert.deepEqual(r.json.action, { action: 'send', target: 'a1', text: 'Run the tests.', minutes: 0, speak: 'Sending to api.' })
  assert.equal(r.json.schema, 1)
  assert.equal(r.json.model, 'claude-haiku-4-5-20251001')
  assert.equal(typeof r.json.ms, 'number')
})

test('the answer is read from result when there is no structured_output', async () => {
  reset()
  const r = await cli([], { input: request(), extraEnv: { FAKE_MODE: 'result', ...answer({ action: 'approve', target: 'r1', speak: 'Approve npm test?' }) } })
  assert.equal(r.json.action.action, 'approve')
  assert.equal(r.json.action.target, 'r1')
})

test('ids the context does not name are rejected as a say', async () => {
  reset()
  const r = await cli([], { input: request(), extraEnv: answer({ action: 'open', target: 'a9', speak: 'Opening.' }) })
  assert.equal(r.json.action.action, 'say')
  assert.equal(r.json.action.target, '')
  assert.equal(r.json.rejected, 'unknown-target')
})

test('incomplete actions are rejected: send without text, trust without minutes', async () => {
  reset()
  let r = await cli([], { input: request(), extraEnv: answer({ action: 'send', target: 'a1', text: ' ' }) })
  assert.equal(r.json.rejected, 'incomplete')
  r = await cli([], { input: request(), extraEnv: answer({ action: 'trust', target: 'a1', minutes: 0 }) })
  assert.equal(r.json.rejected, 'incomplete')
  r = await cli([], { input: request(), extraEnv: answer({ action: 'trust', target: 'a1', minutes: 15 }) })
  assert.equal(r.json.action.minutes, 15)
})

test('bad stdin fails without calling claude', async () => {
  for (const input of ['', 'not json', '[]', JSON.stringify({ context: CONTEXT }), JSON.stringify({ utterance: 'x'.repeat(501) })]) {
    reset()
    const r = await cli([], { input })
    assert.equal(r.code, 0)
    assert.equal(r.json.error, 'failed', input.slice(0, 30))
    assert.equal(fs.existsSync(record), false)
  }
  reset()
  const big = await cli([], { input: JSON.stringify({ utterance: 'hi', context: { pad: 'x'.repeat(40000) } }) })
  assert.equal(big.json.error, 'failed')
  assert.match(big.json.message, /larger than/)
})

test('claude missing, not logged in, crash', async () => {
  reset()
  let r = await cli([], { input: request(), extraEnv: { PATH: path.join(root, 'nowhere') } })
  assert.equal(r.json.error, 'claude-missing')
  r = await cli([], { input: request(), extraEnv: { FAKE_MODE: 'not-logged-in' } })
  assert.equal(r.json.error, 'not-logged-in')
  r = await cli([], { input: request(), extraEnv: { FAKE_MODE: 'crash' } })
  assert.equal(r.json.error, 'failed')
})

test('timeout kills claude and everything it started', async () => {
  reset()
  // Long enough for the fake to start on a loaded machine.
  const r = await cli(['--timeout-ms', '3000'], { input: request(), extraEnv: { FAKE_MODE: 'hang' } })
  assert.equal(r.json.error, 'timeout')
  const pids = JSON.parse(fs.readFileSync(pidsFile, 'utf8'))
  await new Promise(resolve => setTimeout(resolve, 1500))
  for (const pid of pids) assert.equal(alive(pid), false, `pid ${pid} is gone`)
  assert.equal(fs.existsSync(path.join(root, 'state', 'guide.lock')), false, 'lock released')
})

test('a second request while one runs is busy', async () => {
  reset()
  const slow = cli([], { input: request(), extraEnv: { FAKE_DELAY_MS: '4000' } })
  await new Promise(resolve => setTimeout(resolve, 600))
  const second = await cli([], { input: request() })
  assert.equal(second.json.error, 'busy')
  assert.equal((await slow).json.action.action, 'home')
})

test('bad --timeout-ms fails', async () => {
  const r = await cli(['--timeout-ms', '5'], { input: request() })
  assert.equal(r.json.error, 'failed')
})

test('normalizeAction on its own', () => {
  assert.equal(gm.normalizeAction({ action: 'rm -rf', speak: 'x' }, CONTEXT).rejected, 'unknown-action')
  assert.equal(gm.normalizeAction(null, CONTEXT).rejected, 'unknown-action')
  assert.equal(gm.normalizeAction({ action: 'open', target: '', speak: '' }, CONTEXT).rejected, 'incomplete')
  assert.deepEqual(gm.normalizeAction({ action: 'say', target: '', text: 'ignored', minutes: 3, speak: '' }, CONTEXT).action,
    { action: 'say', target: '', text: '', minutes: 0, speak: 'Sorry, I did not understand.' })
  assert.deepEqual([...gm.contextIds(CONTEXT)].sort(), ['a1', 'm1', 'p1', 'r1'])
})

test.after(() => fs.rmSync(root, { recursive: true, force: true }))
