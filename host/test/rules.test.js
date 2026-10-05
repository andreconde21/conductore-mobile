'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('fs')
const path = require('path')
const { tempDir, cleanup } = require('./helpers/cleanup')
const rules = require('../lib/rules')

const ROOT = '/home/andre/Projects/app'
const ctx = { cwd: ROOT, root: ROOT, home: '/home/andre' }
const NOW = 1_790_000_000_000

function rec (rule, extra = {}) {
  return { id: 'r' + Math.random(), rule, scope: { kind: 'any' }, expiresAt: null, endsWithSession: null, ...extra }
}

const bash = (rule, command, c = ctx) => !!rules.findMatch([rec(rule)], { session_id: 's1', tool_name: 'Bash', tool_input: { command } }, c, NOW)

test('parseRule mirrors Claude Code syntax', () => {
  assert.deepEqual(rules.parseRule('Bash'), { tool: 'Bash', content: null })
  assert.deepEqual(rules.parseRule('Bash(*)'), { tool: 'Bash', content: null })
  assert.deepEqual(rules.parseRule('Bash(npm test *)'), { tool: 'Bash', content: 'npm test *' })
  assert.deepEqual(rules.parseRule(' Edit(src/**) '), { tool: 'Edit', content: 'src/**' })
  assert.deepEqual(rules.parseRule('mcp__github__create_issue'), { tool: 'mcp__github__create_issue', content: null })
  assert.deepEqual(rules.parseRule('WebFetch(domain:docs.rs)'), { tool: 'WebFetch', content: 'domain:docs.rs' })
  for (const bad of ['', '   ', 'Bash(', '(x)', '1Bash', 'Bash x', null, 42, 'B'.repeat(600)]) assert.equal(rules.parseRule(bad), null, String(bad))
})

test('Bash glob, prefix and exact forms', () => {
  // [rule, command, matches]
  const table = [
    ['Bash', 'anything at all', true],
    ['Bash(*)', 'rm x', true],
    ['Bash(npm test)', 'npm test', true],
    ['Bash(npm test)', 'npm test -- --watch', false],
    ['Bash(npm test *)', 'npm test', true],
    ['Bash(npm test *)', 'npm test -- --grep foo', true],
    ['Bash(npm test *)', 'npm testing', false],
    ['Bash(npm test *)', 'npm  test   --ci', true],
    ['Bash(npm test*)', 'npm testing', true],
    ['Bash(npm test:*)', 'npm test', true],
    ['Bash(npm test:*)', 'npm test --ci', true],
    ['Bash(npm test:*)', 'npm tests', false],
    ['Bash(npm run test:*)', 'npm run test:unit', false],
    ['Bash(npm run test:* *)', 'npm run test:unit --ci', true],
    ['Bash(ls *)', 'ls -la', true],
    ['Bash(ls *)', 'lsof -i', false],
    ['Bash(git * main)', 'git merge main', true],
    ['Bash(git * main)', 'git merge dev', false],
    // Compound commands: every command must be covered.
    ['Bash(npm test *)', 'npm test && rm x', false],
    ['Bash(npm test *)', 'npm test; curl evil.example.com', false],
    ['Bash(npm test *)', 'npm test || echo failed', false],
    ['Bash(npm test *)', 'cd packages/web && npm test', true],
    ['Bash(npm test *)', 'npm test 2>&1 | tail -20', true],
    ['Bash(npm test *)', 'npm test | grep -v warn | head', true],
    ['Bash(npm test *)', 'npm test | sh', false],
    ['Bash(npm test *)', 'npm test | tee out.log', false],
    ['Bash(npm test *)', 'cd x', false],
    // A command the parser does not fully understand matches nothing.
    ['Bash(npm test *)', 'npm test $(cat args)', false],
    ['Bash(npm test *)', 'npm test `whoami`', false],
    ['Bash(npm test $(cat args))', 'npm test $(cat args)', false],
    ['Bash', 'npm test $(cat args)', false],
    ['Bash(echo *)', 'echo "unterminated', false],
    // Other tools never match a Bash rule.
    ['Read', 'cat x', false]
  ]
  const failures = table.filter(([rule, command, want]) => bash(rule, command) !== want)
    .map(([rule, command, want]) => `${rule} vs ${JSON.stringify(command)}: expected ${want}`)
  assert.deepEqual(failures, [])
})

test('several statements are covered only by the exact command', () => {
  const list = [rec('Bash(npm run build *)'), rec('Bash(npm test *)')]
  const ev = command => ({ session_id: 's', tool_name: 'Bash', tool_input: { command } })
  assert.equal(rules.findMatch(list, ev('npm run build && npm test'), ctx, NOW), null)
  assert.equal(rules.findMatch(list, ev('npm run build && npm publish'), ctx, NOW), null)
  const exact = rec('Bash(npm run build && npm test)')
  assert.equal(rules.findMatch([exact], ev('npm run build && npm test'), ctx, NOW), exact)
  assert.equal(rules.findMatch([exact], ev('npm run build ; npm test'), ctx, NOW), null)
})

test('path rules for Edit and Read families', () => {
  const file = (tool, rule, p, extra = {}) => !!rules.findMatch([rec(rule, extra)], { session_id: 's', tool_name: tool, tool_input: { file_path: p } }, ctx, NOW)
  assert.equal(file('Edit', 'Edit(src/**)', `${ROOT}/src/a/b.ts`), true)
  assert.equal(file('Write', 'Edit(src/**)', `${ROOT}/src/new.ts`), true)
  assert.equal(file('MultiEdit', 'Edit(src/**)', 'src/x.ts'), true)
  assert.equal(file('Edit', 'Edit(src/**)', `${ROOT}/lib/a.ts`), false)
  assert.equal(file('Edit', 'Edit(src/*)', `${ROOT}/src/a/b.ts`), false)
  assert.equal(file('Edit', 'Edit(src/*)', `${ROOT}/src/b.ts`), true)
  assert.equal(file('Edit', 'Edit(*.md)', `${ROOT}/docs/deep/x.md`), true)
  assert.equal(file('Edit', 'Edit(/README.md)', `${ROOT}/README.md`), true)
  assert.equal(file('Edit', 'Edit(**)', `${ROOT}/anything/at/all.ts`), true)
  assert.equal(file('Edit', 'Edit(**)', '/etc/hosts'), false)
  assert.equal(file('Edit', 'Edit(src/**)', `${ROOT}/src/../../escape.ts`), false)
  assert.equal(file('Edit', 'Edit(//tmp/**)', '/tmp/x/y.txt'), true)
  assert.equal(file('Edit', 'Edit(~/notes/**)', '/home/andre/notes/a.md'), true)
  assert.equal(file('Edit', 'Edit', '/anywhere/x'), true)
  assert.equal(file('Read', 'Edit(src/**)', `${ROOT}/src/a.ts`), false)
  assert.equal(file('Read', 'Read(docs/**)', `${ROOT}/docs/a.md`), true)
  assert.equal(file('Grep', 'Read(docs/**)', `${ROOT}/docs`), true)
  // Repo-scoped rules resolve against their own path, not the agent's cwd.
  const scoped = { scope: { kind: 'repo', path: ROOT } }
  const deep = { cwd: `${ROOT}/packages/web`, root: ROOT, home: '/home/andre' }
  assert.ok(rules.findMatch([rec('Edit(src/**)', scoped)], { session_id: 's', tool_name: 'Edit', tool_input: { file_path: `${ROOT}/src/x.ts` } }, deep, NOW))
})

test('WebFetch domains and MCP servers', () => {
  const web = (rule, url) => !!rules.findMatch([rec(rule)], { session_id: 's', tool_name: 'WebFetch', tool_input: { url } }, ctx, NOW)
  assert.equal(web('WebFetch(domain:docs.rs)', 'https://docs.rs/serde'), true)
  assert.equal(web('WebFetch(domain:docs.rs)', 'https://api.docs.rs/x'), true)
  assert.equal(web('WebFetch(domain:docs.rs)', 'https://evildocs.rs/x'), false)
  assert.equal(web('WebFetch(domain:docs.rs)', 'https://docs.rs.evil.com/x'), false)
  assert.equal(web('WebFetch', 'https://anything.example/'), true)
  const mcp = (rule, tool) => !!rules.findMatch([rec(rule)], { session_id: 's', tool_name: tool, tool_input: {} }, ctx, NOW)
  assert.equal(mcp('mcp__github', 'mcp__github__create_issue'), true)
  assert.equal(mcp('mcp__github', 'mcp__githubx__list'), false)
  assert.equal(mcp('mcp__github__create_issue', 'mcp__github__create_issue'), true)
  assert.equal(mcp('mcp__github__create_issue', 'mcp__github__delete_repo'), false)
  assert.equal(mcp('ExitPlanMode(x)', 'ExitPlanMode'), false)
})

test('scopes: session, repo, any', () => {
  const ev = (sid, cwd) => [{ session_id: sid, tool_name: 'Bash', tool_input: { command: 'npm test' } }, { cwd, root: cwd, home: '/home/andre' }]
  const session = rec('Bash(npm test *)', { scope: { kind: 'session', sessionId: 's1' } })
  assert.ok(rules.findMatch([session], ...ev('s1', ROOT), NOW))
  assert.equal(rules.findMatch([session], ...ev('s2', ROOT), NOW), null)
  const repo = rec('Bash(npm test *)', { scope: { kind: 'repo', path: ROOT } })
  assert.ok(rules.findMatch([repo], ...ev('s9', ROOT), NOW))
  assert.ok(rules.findMatch([repo], ...ev('s9', `${ROOT}/packages/web`), NOW))
  assert.equal(rules.findMatch([repo], ...ev('s9', `${ROOT}-fork`), NOW), null)
  assert.equal(rules.findMatch([repo], ...ev('s9', '/home/andre/Projects/other'), NOW), null)
})

test('trust expiry: an expired rule never matches', () => {
  const soon = rec('Bash(npm test *)', { expiresAt: NOW + 1000 })
  const ev = { session_id: 's', tool_name: 'Bash', tool_input: { command: 'npm test' } }
  assert.ok(rules.findMatch([soon], ev, ctx, NOW))
  assert.ok(rules.findMatch([soon], ev, ctx, NOW + 999))
  assert.equal(rules.findMatch([soon], ev, ctx, NOW + 1000), null)
  assert.equal(rules.findMatch([soon], ev, ctx, NOW + 60000), null)
  const [kept, dropped] = rules.prune([soon, rec('Bash')], NOW + 5000)
  assert.equal(kept.length, 1)
  assert.equal(dropped[0], soon)
})

test('rules tied to a session are pruned when it ends', () => {
  const a = rec('Bash', { endsWithSession: 's1' })
  const b = rec('Bash', { endsWithSession: 's2' })
  const [kept, dropped] = rules.prune([a, b], NOW, 's1')
  assert.deepEqual(kept, [b])
  assert.deepEqual(dropped, [a])
})

test('makeRule validates and normalizes', () => {
  const r = rules.makeRule({ rule: ' Bash(npm test *) ', scope: { kind: 'repo', path: ROOT + '/' }, minutes: 15, source: 'trust' }, NOW)
  assert.equal(r.rule, 'Bash(npm test *)')
  assert.deepEqual(r.scope, { kind: 'repo', path: ROOT })
  assert.equal(r.expiresAt, NOW + 15 * 60000)
  assert.equal(r.endsWithSession, null)
  assert.equal(r.source, 'trust')
  assert.match(r.id, /^r[0-9a-f]{10}$/)
  const s = rules.makeRule({ rule: 'Edit', scope: { kind: 'session', sessionId: 's1' } }, NOW)
  assert.equal(s.endsWithSession, 's1')
  assert.equal(s.expiresAt, null)
  const u = rules.makeRule({ rule: 'Read', scope: { kind: 'any' }, untilSessionEnd: true, sessionId: 's3' }, NOW)
  assert.equal(u.endsWithSession, 's3')
  assert.equal(rules.makeRule({ rule: 'Bash(*)' }, NOW).rule, 'Bash')
  for (const bad of [
    { rule: 'nope nope' },
    { rule: 'Bash', scope: { kind: 'repo', path: 'relative' } },
    { rule: 'Bash', scope: { kind: 'repo', path: '/' } },
    { rule: 'Bash', scope: { kind: 'session' } },
    { rule: 'Bash', scope: { kind: 'galaxy' } },
    { rule: 'Bash', minutes: 0 },
    { rule: 'Bash', minutes: 99999 },
    { rule: 'Bash', untilSessionEnd: true }
  ]) assert.throws(() => rules.makeRule(bad, NOW), JSON.stringify(bad))
})

test('suggestions: exactly this call first, then broader', () => {
  const s = (tool, input, c = ctx) => rules.suggest(tool, input, c)
  assert.deepEqual(s('Bash', { command: 'npm test -- --grep foo' }), ['Bash(npm test -- --grep foo)', 'Bash(npm test *)', 'Bash(npm *)', 'Bash'])
  assert.deepEqual(s('Bash', { command: 'npm run test:unit' }).slice(0, 3), ['Bash(npm run test:unit)', 'Bash(npm run test:unit *)', 'Bash(npm *)'])
  assert.equal(s('Bash', { command: 'git status' })[1], 'Bash(git status *)')
  assert.equal(s('Bash', { command: 'git -C ../x log -5' })[1], 'Bash(git -C ../x log *)')
  assert.equal(s('Bash', { command: 'ls -la src' })[1], 'Bash(ls *)')
  assert.equal(s('Bash', { command: 'python -m pytest -x' })[1], 'Bash(python -m pytest *)')
  assert.deepEqual(s('Bash', { command: 'cd web && npm test 2>&1 | tail -5' }).slice(0, 2), ['Bash(cd web && npm test 2>&1 | tail -5)', 'Bash(npm test *)'])
  assert.deepEqual(s('Bash', { command: 'npm run build && npm test' }), ['Bash(npm run build && npm test)'])
  assert.deepEqual(s('Bash', { command: 'git commit -m "fix (x)"' }).slice(0, 2), ['Bash(git commit -m "fix (x)")', 'Bash(git commit *)'])
  // Nothing for what no rule may answer.
  assert.deepEqual(s('Bash', { command: 'npm test $(cat args)' }), [])
  assert.deepEqual(s('AskUserQuestion', { questions: [] }), [])
  assert.deepEqual(s('ExitPlanMode', { plan: 'x' }), [])
  assert.deepEqual(s('Edit', { file_path: `${ROOT}/src/components/Button.tsx` }), ['Edit(src/components/Button.tsx)', 'Edit(src/components/**)', 'Edit(src/**)', 'Edit(**)'])
  assert.deepEqual(s('Write', { file_path: `${ROOT}/README.md` }), ['Edit(/README.md)', 'Edit(**)'])
  assert.deepEqual(s('Read', { file_path: '/etc/nginx/nginx.conf' }), ['Read(//etc/nginx/nginx.conf)', 'Read(//etc/nginx/**)'])
  assert.deepEqual(s('WebFetch', { url: 'https://docs.rs/serde' }), ['WebFetch(domain:docs.rs)', 'WebFetch'])
  assert.deepEqual(s('mcp__github__create_issue', {}), ['mcp__github__create_issue', 'mcp__github'])
  assert.deepEqual(s('Task', {}), ['Task'])
  // Every suggestion matches the request it came from.
  for (const [tool, input] of [['Bash', { command: 'npm test -- --grep foo' }], ['Bash', { command: 'cd web && npm test 2>&1 | tail -5' }], ['Bash', { command: 'npm run build && npm test' }], ['Bash', { command: 'git commit -m "fix (x)"' }], ['Edit', { file_path: `${ROOT}/src/components/Button.tsx` }], ['Read', { file_path: '/etc/nginx/nginx.conf' }], ['WebFetch', { url: 'https://docs.rs/serde' }]]) {
    for (const rule of s(tool, input)) {
      assert.ok(rules.findMatch([rec(rule)], { session_id: 's', tool_name: tool, tool_input: input }, ctx, NOW), `${rule} should match its own request`)
    }
  }
})

test('store: load, save (0600), junk tolerant', () => {
  const dir = tempDir('cnd-rules-')
  const file = path.join(dir, 'rules.json')
  assert.deepEqual(rules.load(file), [])
  const r = rules.makeRule({ rule: 'Bash(npm test *)' }, NOW)
  rules.save(file, [r])
  assert.equal(fs.statSync(file).mode & 0o777, 0o600)
  assert.deepEqual(rules.load(file), [r])
  fs.writeFileSync(file, '{"version":1,"rules":[{"id":"x","rule":"(bad"},{"id":"y","rule":"Read"}, 5]}')
  assert.deepEqual(rules.load(file).map(x => x.id), ['y'])
  fs.writeFileSync(file, 'not json')
  assert.deepEqual(rules.load(file), [])
  fs.rmSync(dir, { recursive: true })
})

test('repoRoot finds the git work tree, never above home', () => {
  const home = tempDir('cnd-home-')
  const repo = path.join(home, 'Projects', 'app')
  fs.mkdirSync(path.join(repo, 'packages', 'web'), { recursive: true })
  fs.mkdirSync(path.join(repo, '.git'))
  assert.equal(rules.repoRoot(path.join(repo, 'packages', 'web'), home), repo)
  assert.equal(rules.repoRoot(repo, home), repo)
  const loose = path.join(home, 'scratch')
  fs.mkdirSync(loose)
  assert.equal(rules.repoRoot(loose, home), loose)
  assert.equal(rules.repoRoot('relative', home), null)
  fs.rmSync(home, { recursive: true })
})

test('narrowest: exactly this call, never a glob', () => {
  assert.equal(rules.narrowest('Bash', { command: 'npm  test -- --grep x' }, ctx), 'Bash(npm  test -- --grep x)')
  assert.equal(rules.narrowest('Bash', { command: 'rm *.log' }, ctx), null)
  assert.equal(rules.narrowest('Bash', { command: 'echo $(id)' }, ctx), null)
  assert.equal(rules.narrowest('ExitPlanMode', { plan: 'x' }, ctx), null)
  assert.equal(rules.narrowest('AskUserQuestion', { questions: [] }, ctx), null)
  assert.equal(rules.narrowest('Edit', { file_path: `${ROOT}/a.ts`, files: [`${ROOT}/a.ts`, `${ROOT}/b.ts`] }, ctx), null)
  assert.equal(rules.narrowest('Bash', { _truncated: true }, ctx), null)
  assert.equal(rules.narrowest('Edit', { file_path: `${ROOT}/src/a.ts` }, ctx), 'Edit(src/a.ts)')
  assert.equal(rules.narrowest('Write', { file_path: `${ROOT}/README.md` }, ctx), 'Edit(/README.md)')
  assert.equal(rules.narrowest('Read', { file_path: '/etc/hosts' }, ctx), 'Read(//etc/hosts)')
  assert.equal(rules.narrowest('WebFetch', { url: 'https://docs.rs/x' }, ctx), 'WebFetch(domain:docs.rs)')
  assert.equal(rules.narrowest('Task', {}, ctx), 'Task')
  for (const [tool, input, other] of [
    ['Bash', { command: 'npm test -- --grep x' }, { command: 'npm test' }],
    ['Edit', { file_path: `${ROOT}/src/a.ts` }, { file_path: `${ROOT}/src/b.ts` }],
    ['Write', { file_path: `${ROOT}/README.md` }, { file_path: `${ROOT}/docs/README.md` }],
    ['Read', { file_path: '/etc/hosts' }, { file_path: '/etc/passwd' }]
  ]) {
    const r = rec(rules.narrowest(tool, input, ctx))
    assert.ok(rules.findMatch([r], { session_id: 's', tool_name: tool, tool_input: input }, ctx, NOW), `${r.rule} covers its call`)
    assert.equal(rules.findMatch([r], { session_id: 's', tool_name: tool, tool_input: other }, ctx, NOW), null, `${r.rule} covers nothing else`)
  }
})

test.after(() => cleanup())
