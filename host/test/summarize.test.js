'use strict'

// `summarize` through the real CLI with a fake `claude` on PATH that records
// its argv, stdin and environment, plus the markdown, word cap and stdin
// helpers on their own.

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('fs')
const os = require('os')
const path = require('path')
const { Readable } = require('stream')
const { execFile } = require('child_process')
const sm = require('../lib/summarize')

const HOSTD = path.join(__dirname, '..', 'bin', 'conductore-hostd')
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'cnd-summarize-'))
const binDir = path.join(root, 'bin')
const emptyDir = path.join(root, 'empty')
const home = path.join(root, 'home')
const record = path.join(root, 'record.json')
const pidsFile = path.join(root, 'pids.json')
fs.mkdirSync(binDir)
fs.mkdirSync(emptyDir)
fs.mkdirSync(home)

// FAKE_MODE: ok (prints FAKE_RESULT after FAKE_DELAY_MS), hang (starts a
// grandchild, ignores SIGTERM, never answers), not-logged-in, crash.
fs.writeFileSync(path.join(binDir, 'claude'), `#!${process.execPath}
const fs = require('fs')
const { spawn } = require('child_process')
const stdin = fs.readFileSync(0, 'utf8')
fs.writeFileSync(${JSON.stringify(record)}, JSON.stringify({ args: process.argv.slice(2), stdin, thinking: process.env.MAX_THINKING_TOKENS, cwd: process.cwd() }))
const mode = process.env.FAKE_MODE || 'ok'
if (mode === 'hang') {
  const g = spawn('/bin/sleep', ['60'], { stdio: 'ignore' })
  fs.writeFileSync(${JSON.stringify(pidsFile)}, JSON.stringify([process.pid, g.pid]))
  process.on('SIGTERM', () => {})
  setInterval(() => {}, 1000)
} else if (mode === 'not-logged-in') {
  process.stdout.write(JSON.stringify({ type: 'result', subtype: 'success', is_error: true, result: 'Not logged in · Please run /login' }) + '\\n')
  process.exit(1)
} else if (mode === 'crash') {
  process.stderr.write('boom\\n')
  process.exit(3)
} else {
  setTimeout(() => {
    process.stdout.write(JSON.stringify({ type: 'result', subtype: 'success', is_error: false, result: process.env.FAKE_RESULT || 'A short summary.', modelUsage: { 'claude-haiku-4-5-20251001': {} } }) + '\\n')
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
    const child = execFile(process.execPath, [HOSTD, 'summarize', ...args], { env: { ...env, ...extraEnv }, timeout: 30000, maxBuffer: 1 << 20 }, (err, stdout) => {
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

// About 80 words: long enough to be summarised.
const LONG = [
  '## Build fix',
  '',
  'I looked into why the **nightly build** failed. The `package-lock.json` on `main` was regenerated with npm 11, while the CI agent still runs npm 9, so `npm ci` refuses to install.',
  '',
  '- Pinned npm to 11 in `azure-pipelines.yml`.',
  '- Added a check in [verify-lock.sh](tools/verify-lock.sh) that fails early.',
  '',
  '```sh',
  'npm ci --prefer-offline',
  '```',
  '',
  'The pipeline is green again on the branch. Do you want me to open a pull request, or keep npm 9 and regenerate the lockfile instead?'
].join('\n')

const alive = pid => { try { process.kill(pid, 0); return true } catch (err) { return err.code === 'EPERM' } }

test('short input is passed through with markdown stripped, without calling claude', async () => {
  reset()
  const r = await cli([], { input: '**Done.** The `tests` pass, see [the log](http://x/y).\n' })
  assert.equal(r.code, 0)
  assert.deepEqual(r.json, { schema: 1, summary: 'Done. The tests pass, see the log.', ms: 0, model: null, passthrough: true })
  assert.equal(fs.existsSync(record), false, 'claude was not run')
})

test('empty input fails without calling claude', async () => {
  reset()
  const r = await cli([], { input: '  \n' })
  assert.equal(r.code, 0)
  assert.equal(r.json.error, 'failed')
  assert.equal(fs.existsSync(record), false)
})

test('success: the result is parsed, one JSON line, the model claude used', async () => {
  reset()
  const r = await cli([], { input: LONG, extraEnv: { FAKE_RESULT: 'The build broke on an npm mismatch and is fixed. Open a pull request?' } })
  assert.equal(r.code, 0)
  assert.equal(r.lines.length, 0, 'exactly one line on stdout')
  assert.equal(r.json.schema, 1)
  assert.equal(r.json.summary, 'The build broke on an npm mismatch and is fixed. Open a pull request?')
  assert.equal(r.json.model, 'claude-haiku-4-5-20251001')
  assert.equal(typeof r.json.ms, 'number')
  assert.equal(r.json.passthrough, undefined)
})

test('argv: no tools, safe mode, no session persistence, haiku, and never the text', async () => {
  reset()
  await cli(['--max-words', '30'], { input: LONG })
  const call = lastCall()
  const a = call.args
  assert.equal(a[0], '-p')
  assert.equal(a[a.indexOf('--tools') + 1], '', '--tools ""')
  assert.ok(a.includes('--safe-mode'))
  assert.ok(a.includes('--no-session-persistence'))
  assert.equal(a[a.indexOf('--output-format') + 1], 'json')
  assert.equal(a[a.indexOf('--model') + 1], 'haiku')
  assert.match(a[a.indexOf('--system-prompt') + 1], /never more than 30\b/)
  for (const arg of a) {
    for (const needle of ['nightly build', 'npm', 'verify-lock', 'pull request']) assert.ok(!arg.includes(needle), `argv carries ${needle}`)
  }
  // The text goes on stdin, between random delimiters.
  assert.ok(call.stdin.includes('The `package-lock.json` on `main` was regenerated'))
  const tag = call.stdin.match(/<(REPLY-[0-9a-f]{12})>/)[1]
  assert.ok(call.stdin.trimEnd().endsWith(`</${tag}>`))
  assert.equal(call.thinking, '0')
  assert.equal(call.cwd, home)
})

test('markdown and quotes are stripped from the answer and the word cap keeps the closing question', async () => {
  reset()
  const answer = '**Summary:** "The `nightly build` failed because of an npm version mismatch between the lockfile and CI. ' +
    'I pinned npm to eleven in the pipeline and added an early check for it. ' +
    'The branch builds green again and the fix is ready for review. ' +
    'Should I open a pull request?"'
  const r = await cli(['--max-words', '36'], { input: LONG, extraEnv: { FAKE_RESULT: answer } })
  assert.equal(r.json.summary, 'The nightly build failed because of an npm version mismatch between the lockfile and CI. I pinned npm to eleven in the pipeline and added an early check for it. Should I open a pull request?')
  assert.ok(sm.words(r.json.summary) <= 36)
})

test('timeout: the error is returned and claude and what it started are killed', async () => {
  reset()
  const t0 = Date.now()
  const r = await cli(['--timeout-ms', '1000'], { input: LONG, extraEnv: { FAKE_MODE: 'hang' } })
  assert.equal(r.code, 0)
  assert.equal(r.json.error, 'timeout')
  assert.ok(Date.now() - t0 < 8000)
  const pids = JSON.parse(fs.readFileSync(pidsFile, 'utf8'))
  await new Promise(resolve => setTimeout(resolve, 200))
  for (const pid of pids) assert.equal(alive(pid), false, `pid ${pid} still alive`)
  assert.equal(fs.existsSync(path.join(env.CONDUCTORE_HOME, 'summarize.lock')), false, 'lock released')
})

test('claude-missing when claude is on neither PATH nor its install dirs', async () => {
  reset()
  const r = await cli([], { input: LONG, extraEnv: { PATH: emptyDir } })
  assert.equal(r.code, 0)
  assert.equal(r.json.error, 'claude-missing')
  assert.equal(typeof r.json.message, 'string')
})

test('claude in ~/.local/bin is found when PATH lacks it (SSH exec shells)', async () => {
  reset()
  const local = path.join(home, '.local', 'bin')
  fs.mkdirSync(local, { recursive: true })
  fs.copyFileSync(path.join(binDir, 'claude'), path.join(local, 'claude'))
  fs.chmodSync(path.join(local, 'claude'), 0o755)
  try {
    const r = await cli([], { input: LONG, extraEnv: { PATH: emptyDir } })
    assert.equal(r.json.summary, 'A short summary.')
  } finally {
    fs.rmSync(path.join(home, '.local'), { recursive: true, force: true })
  }
})

test('not-logged-in and other failures', async () => {
  reset()
  let r = await cli([], { input: LONG, extraEnv: { FAKE_MODE: 'not-logged-in' } })
  assert.equal(r.code, 0)
  assert.equal(r.json.error, 'not-logged-in')
  r = await cli([], { input: LONG, extraEnv: { FAKE_MODE: 'crash' } })
  assert.equal(r.code, 0)
  assert.equal(r.json.error, 'failed')
  assert.equal(r.json.schema, 1)
})

test('stdin beyond 64 KB is truncated', async () => {
  reset()
  const big = 'word '.repeat(20000) + 'TAIL-MARKER' // 100 KB
  const r = await cli([], { input: big })
  assert.equal(r.json.summary, 'A short summary.')
  const { stdin } = lastCall()
  assert.ok(!stdin.includes('TAIL-MARKER'))
  assert.ok(Buffer.byteLength(stdin) < sm.MAX_INPUT_BYTES + 1024)
  assert.ok(Buffer.byteLength(stdin) > sm.MAX_INPUT_BYTES - 1024)
})

test('readInput cuts at a whole UTF-8 character', async () => {
  const buf = Buffer.from('a' + 'é'.repeat(40000)) // 80,001 bytes: byte 65,536 is inside an é
  const r = await sm.readInput(Readable.from([buf.subarray(0, 30000), buf.subarray(30000)]), 5000)
  assert.equal(r.truncated, true)
  assert.ok(!r.text.includes('�'))
  assert.equal(Buffer.byteLength(r.text), 65535)
  const small = await sm.readInput(Readable.from([Buffer.from('hello')]), 5000)
  assert.deepEqual(small, { text: 'hello', truncated: false })
})

test('a second concurrent call waits, then answers busy; a stale lock is taken over', async () => {
  reset()
  const lockFile = path.join(env.CONDUCTORE_HOME, 'summarize.lock')
  const first = cli([], { input: LONG, extraEnv: { FAKE_DELAY_MS: '4000' } })
  const deadline = Date.now() + 5000
  while (!fs.existsSync(lockFile) && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 20))
  assert.ok(fs.existsSync(lockFile), 'first call holds the lock')
  const t0 = Date.now()
  const second = await cli([], { input: LONG })
  const waited = Date.now() - t0
  assert.equal(second.code, 0)
  assert.equal(second.json.error, 'busy')
  assert.ok(waited >= 1900, `waited ${waited} ms`)
  assert.equal((await first).json.summary, 'A short summary.')

  // A lock left by a process that is gone does not block.
  fs.writeFileSync(lockFile, '2147483646')
  const r = await cli([], { input: LONG })
  assert.equal(r.json.summary, 'A short summary.')
})

test('bad flags answer failed on one line with exit 0', async () => {
  const r = await cli(['--max-words', 'lots'], { input: LONG })
  assert.equal(r.code, 0)
  assert.equal(r.json.error, 'failed')
})

test('the text is never logged', () => {
  let logText = ''
  try { logText = fs.readFileSync(path.join(env.CONDUCTORE_HOME, 'hostd.log'), 'utf8') } catch {}
  assert.ok(!logText.includes('nightly'))
  const files = fs.readdirSync(env.CONDUCTORE_HOME)
  assert.ok(!files.some(f => f.includes('summar') && f !== 'summarize.lock'), files.join(','))
})

test('stripMarkdown, cleanSummary and capWords', () => {
  assert.equal(sm.stripMarkdown('# Title\n\nSome *emphasis* and __bold__ and ~~gone~~.\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n> quoted\n\n1. first\n2. second'),
    'Title. Some emphasis and bold and gone. a b. 1 2. quoted. 1. first. 2. second')
  assert.equal(sm.stripMarkdown('Run this:\n\n```js\nconst x = 1\n```\n\nThen done.'), 'Run this: Then done.')
  assert.equal(sm.stripMarkdown('Keep snake_case_names and 2 * 3 * 4.'), 'Keep snake_case_names and 2 * 3 * 4.')
  assert.equal(sm.stripMarkdown('<b>Bold</b> ![alt text](a.png)'), 'Bold alt text')
  assert.equal(sm.cleanSummary('Summary: “It works.”'), 'It works.')
  assert.equal(sm.capWords('One two three. Four five six. Seven eight nine.', 6), 'One two three. Four five six.')
  assert.equal(sm.capWords('One two three. Four five six. Seven eight nine. Ready?', 7), 'One two three. Four five six. Ready?')
  assert.equal(sm.capWords('One two three four five six seven, eight.', 4), 'One two three four…')
  assert.equal(sm.capWords('Short.', 45), 'Short.')
})

test('callers racing to clear a stale lock never both get it', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'cnd-lock-'))
  const lockFile = path.join(dir, 'summarize.lock')
  for (let round = 0; round < 5; round++) {
    fs.writeFileSync(lockFile, '2147483646') // a pid that is not running
    const start = Date.now() + 300
    const racer = `
      const sm = require(${JSON.stringify(require.resolve('../lib/summarize'))})
      setTimeout(async () => {
        const release = await sm.acquireLock(${JSON.stringify(lockFile)}, 0)
        if (!release) return process.stdout.write('busy')
        const from = Date.now()
        setTimeout(() => { process.stdout.write(\`won \${from} \${Date.now()}\`); release() }, 400)
      }, ${start} - Date.now())`
    const results = await Promise.all(Array.from({ length: 8 }, () => new Promise((resolve, reject) => {
      execFile(process.execPath, ['-e', racer], { timeout: 10000 }, (err, stdout) => err ? reject(err) : resolve(stdout))
    })))
    // Holders never overlap (a racer delayed past the release may win later).
    const held = results.filter(r => r.startsWith('won')).map(r => r.split(' ').slice(1).map(Number)).sort((a, b) => a[0] - b[0])
    assert.ok(held.length >= 1, results.join(','))
    for (let i = 1; i < held.length; i++) assert.ok(held[i][0] >= held[i - 1][1], results.join(','))
    assert.equal(fs.existsSync(lockFile), false, 'released')
    assert.deepEqual(fs.readdirSync(dir), [])
  }
  fs.rmSync(dir, { recursive: true, force: true })
})
