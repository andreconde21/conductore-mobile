'use strict'

// One neutral transcript page (lib/adapters/chat-items.js) covering every
// item type. host/test/adapters.test.js checks that
// test/fixtures/agent_adapters/neutral_chat_page.json (the app's fixture,
// parsed by NeutralChatItems in the Flutter tests) is exactly this page, so
// the two sides of the format cannot drift apart. Regenerate with
//   node host/test/fixtures/neutral-chat-page.js > test/fixtures/agent_adapters/neutral_chat_page.json

const c = require('../../lib/adapters/chat-items')

function page () {
  return c.page({
    items: [
      c.user('u1', 'Fix the failing test', { at: '2026-10-03T10:00:00Z' }),
      c.thinking('th1', { at: '2026-10-03T10:00:01Z' }),
      c.thinking('th2', { at: '2026-10-03T10:00:02Z' }),
      c.assistant('a1', 'Running the tests first.', { at: '2026-10-03T10:00:03Z' }),
      c.tool('t1', { tool: 'exec_command', toolKind: 'bash', input: { cmd: 'npm test' }, title: 'npm test', result: { ok: false, text: '1 failing' }, at: '2026-10-03T10:00:04Z' }),
      c.tool('t2', { tool: 'spawn_agent', toolKind: 'task', input: { prompt: 'look around' }, at: '2026-10-03T10:00:05Z' }),
      c.tool('t3', { tool: 'read_file', toolKind: 'read', input: { path: 'a.js' }, result: { ok: true, text: 'x' }, sidechain: true, parentId: 't2' }),
      c.tool('t4', { tool: 'mcp__github__issue', toolKind: 'mcp', input: {} }),
      c.todo('td1', [{ text: 'Fix test', status: 'in_progress' }, { text: 'Commit', status: 'pending' }, { text: 'Read', status: 'completed' }]),
      c.plan('p1', '1. Fix\n2. Test', { status: 'rejected', feedback: 'Too long' }),
      c.question('q1', [{ question: 'Which DB?', header: 'DB', multiSelect: false, options: [{ label: 'Postgres', description: 'SQL' }, { label: 'SQLite' }] }], { answer: 'Postgres' }),
      c.notice('n1', 'compacted', 'Conversation compacted'),
      c.notice('n2', 'error', 'Rate limited'),
      c.shell('s1', 'git status', { stdout: 'clean', stderr: '' }),
      { id: 'x1', type: 'future-type', at: null }
    ],
    cursor: 'c-2',
    startCursor: 'c-0',
    more: false
  })
}

module.exports = { page }

if (require.main === module) process.stdout.write(JSON.stringify(page(), null, 2) + '\n')
