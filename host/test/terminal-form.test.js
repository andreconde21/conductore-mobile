'use strict'

// Answering Claude Code's terminal dialogs (CON-096): the screens recorded
// from Claude Code 2.1.288 in Docker (fixtures/claude-forms), and a model
// of its form that behaves as the recording showed, driven key by key.

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('fs')
const path = require('path')
const form = require('../lib/terminal-form')

const fixture = name => fs.readFileSync(path.join(__dirname, 'fixtures', 'claude-forms', name), 'utf8')

const ASK = [
  { question: 'Which database should we use?', header: 'Database', multiSelect: false, options: [{ label: 'Postgres', description: 'Relational, the default' }, { label: 'SQLite', description: 'One file' }, { label: 'MySQL', description: 'Also relational' }] },
  { question: 'Which features do you want?', header: 'Features', multiSelect: true, options: [{ label: 'Auth', description: 'Logins' }, { label: 'Search', description: 'Full text' }, { label: 'Export', description: 'CSV export' }] }
]

test('reads the recorded question screens', () => {
  const q1 = form.formOf(fixture('ask-q1.txt'))
  assert.equal(q1.kind, 'question')
  assert.equal(q1.multi, false)
  assert.deepEqual(q1.tabs.map(t => [t.label, t.done]), [['Database', false], ['Features', false], ['Submit', false]])
  assert.match(q1.text, /Which database should we use\?/)
  assert.deepEqual(q1.options.map(o => [o.n, o.label, o.cursor]), [[1, 'Postgres', true], [2, 'SQLite', false], [3, 'MySQL', false], [4, 'Type something.', false]])

  const q2 = form.formOf(fixture('ask-q2.txt'))
  assert.equal(q2.multi, true)
  assert.deepEqual(q2.tabs.map(t => t.done), [true, false, false])
  assert.deepEqual(q2.options.map(o => [o.label, o.checked]), [['Auth', false], ['Search', false], ['Export', false], ['Type something', false]])
  assert.deepEqual(q2.submit, { cursor: false })

  const review = form.formOf(fixture('ask-review.txt'))
  assert.equal(review.kind, 'review')
  assert.match(review.text, /Which features do you want\? → Auth, Export/)

  const single = form.formOf(fixture('ask1-single.txt'))
  assert.equal(single.kind, 'question')
  assert.deepEqual(single.tabs.map(t => t.label), ['Database'])

  const typing = form.formOf(fixture('ask-other-typing.txt'))
  // Cut above the header (the screen scrolled): not a form to answer.
  assert.equal(typing, null)

  const bash = form.formOf(fixture('bash-prompt.txt'))
  assert.equal(bash.kind, 'permission')
  assert.match(bash.text, /touch \/tmp\/x4/)
  assert.deepEqual(bash.options.map(o => o.label.split(',')[0]), ['Yes', 'Yes', 'Yes', 'No'])
})

test('reads ticked boxes and a narrow pane (recorded, CON-096)', () => {
  const ticked = form.formOf(fixture('ask-q2-ticked.txt'))
  assert.deepEqual(ticked.options.map(o => [o.label, o.checked]), [['Auth', true], ['Search', false], ['Export', true], ['Type something', false]])
  assert.equal(ticked.options[0].cursor, true)
  // 46 columns: the footer wraps, the dialog still reads.
  const narrow = form.formOf(fixture('ask-q1-narrow.txt'))
  assert.equal(narrow.kind, 'question')
  assert.deepEqual(narrow.options.map(o => o.label), ['Postgres', 'SQLite', 'MySQL', 'Type something.'])
})

test('no dialog: the prompt box and transcript are not forms', () => {
  assert.equal(form.formOf('❯ ask me\n  ⎿  · Which database should we use? → SQLite\n\n❯ \n'), null)
  assert.equal(form.formOf(''), null)
})

// Claude Code's AskUserQuestion form as the Docker recording showed it.
class FakeForm {
  constructor (questions) {
    this.qs = questions
    this.at = 0 // question index, qs.length = review, -1 = submitted
    this.cursor = 1
    this.picks = questions.map(() => new Set())
    this.own = questions.map(() => '')
    this.answers = null
    this.keys = []
  }

  get q () { return this.qs[this.at] }
  get ownRow () { return this.q.options.length + 1 }

  screen () {
    const out = ['❯ ask me', '─'.repeat(60)]
    if (this.at === -1) return ['❯ ask me', '  ⎿  · ' + this.qs.map(q => `${q.question} → ${this.answerOf(this.qs.indexOf(q))}`).join(' · '), '', '❯ '].join('\n')
    const tabs = this.qs.map((q, i) => `${this.answerOf(i) ? '☒' : '☐'} ${q.header}`).join('  ')
    out.push(this.qs.length > 1 ? `←  ${tabs}  ✔ Submit  →` : ` ${tabs}`)
    out.push('')
    if (this.at === this.qs.length) {
      out.push('Review your answers', '')
      for (let i = 0; i < this.qs.length; i++) out.push(` ● ${this.qs[i].question}`, `   → ${this.answerOf(i)}`)
      out.push('', 'Ready to submit your answers?', '', `${this.cursor === 1 ? '❯' : ' '} 1. Submit answers`, '  2. Cancel')
      return out.join('\n')
    }
    out.push(this.q.question, '')
    const multi = this.q.multiSelect
    this.q.options.forEach((o, i) => {
      const box = multi ? `[${this.picks[this.at].has(i) ? '✔' : ' '}] ` : ''
      out.push(`${this.cursor === i + 1 ? '❯' : ' '} ${i + 1}. ${box}${o.label}`, `     ${o.description || ''}`)
    })
    const own = this.own[this.at]
    out.push(`${this.cursor === this.ownRow ? '❯' : ' '} ${this.ownRow}. ${multi ? `[${own ? '✔' : ' '}] ` : ''}${own || (multi ? 'Type something' : 'Type something.')}`)
    if (multi) out.push(`${this.cursor === this.ownRow + 1 ? '❯' : ' '}    Submit`)
    out.push('─'.repeat(60), `  ${this.ownRow + 1}. Chat about this`, '', 'Enter to select · Tab/Arrow keys to navigate · Esc to cancel')
    return out.join('\n')
  }

  answerOf (i) {
    const q = this.qs[i]
    const parts = q.options.filter((o, k) => this.picks[i].has(k)).map(o => o.label)
    if (this.own[i]) parts.push(this.own[i])
    return parts.join(', ')
  }

  next () {
    this.cursor = 1
    if (this.qs.length === 1) return this.submit()
    this.at += 1
  }

  submit () {
    this.answers = Object.fromEntries(this.qs.map((q, i) => [q.question, this.answerOf(i)]))
    this.at = -1
  }

  text (s) {
    this.keys.push(s)
    if (this.at === -1) return
    if (this.at === this.qs.length) { if (s === '1') this.submit(); return }
    if (this.cursor === this.ownRow && !/^\d$/.test(s)) { this.own[this.at] += s; return }
    if (this.cursor === this.ownRow && /^\d$/.test(s) && this.own[this.at]) { this.own[this.at] += s; return }
    const n = Number(s)
    if (!(n >= 1 && n <= this.ownRow)) return
    if (n === this.ownRow) { this.cursor = n; return }
    if (this.q.multiSelect) {
      const p = this.picks[this.at]
      if (!p.delete(n - 1)) p.add(n - 1)
      return
    }
    this.picks[this.at] = new Set([n - 1])
    this.next()
  }

  key (k) {
    this.keys.push(`<${k}>`)
    if (this.at === -1 || this.at === this.qs.length) { if (k === 'enter' && this.at === this.qs.length) this.submit(); return }
    const last = this.q.multiSelect ? this.ownRow + 1 : this.ownRow
    if (k === 'down') this.cursor = Math.min(this.cursor + 1, last)
    else if (k === 'tab') this.cursor = this.q.multiSelect && this.cursor === this.ownRow ? this.ownRow + 1 : this.cursor
    else if (k === 'enter') {
      if (this.q.multiSelect) { if (this.cursor === this.ownRow + 1) this.next() } else if (this.cursor === this.ownRow && this.own[this.at]) {
        this.picks[this.at] = new Set()
        this.next()
      }
    }
  }

  io () {
    return { read: async () => this.screen(), text: async s => this.text(s), key: async k => this.key(k), sleep: async () => {}, timeoutMs: 200, pollMs: 1 }
  }
}

test('answers a two-question form: a pick, several ticks, the review (CON-096)', async () => {
  const f = new FakeForm(ASK)
  const r = await form.answerQuestions(f.io(), ASK, { 'Which database should we use?': 'SQLite', 'Which features do you want?': ['Auth', 'Export'] })
  assert.equal(r.error, undefined)
  assert.deepEqual(f.answers, { 'Which database should we use?': 'SQLite', 'Which features do you want?': 'Auth, Export' })
  assert.deepEqual(f.keys, ['2', '1', '3', '<down>', '<down>', '<down>', '<down>', '<enter>', '1'])
})

test('own answers: "Type something" for one pick and for several (CON-096)', async () => {
  const f = new FakeForm(ASK)
  const r = await form.answerQuestions(f.io(), ASK, { 'Which database should we use?': 'CockroachDB please', 'Which features do you want?': ['Search', 'Webhooks 3'] })
  assert.equal(r.error, undefined)
  assert.deepEqual(f.answers, { 'Which database should we use?': 'CockroachDB please', 'Which features do you want?': 'Search, Webhooks 3' })
  assert.deepEqual(f.keys, ['4', 'CockroachDB please', '<enter>', '2', '<down>', '<down>', '<down>', 'Webhooks 3', '<tab>', '<enter>', '1'])
})

test('one single-select question: the digit submits it (CON-096)', async () => {
  const one = [ASK[0]]
  const f = new FakeForm(one)
  const r = await form.answerQuestions(f.io(), one, { 'Which database should we use?': 'MySQL' })
  assert.equal(r.error, undefined)
  assert.deepEqual(f.answers, { 'Which database should we use?': 'MySQL' })
  assert.deepEqual(f.keys, ['3'])
})

test('types nothing when the terminal shows another question or no form (CON-096)', async () => {
  const f = new FakeForm(ASK)
  const other = [{ ...ASK[0], question: 'Which cache should we use?' }]
  const r = await form.answerQuestions(f.io(), other, { 'Which cache should we use?': 'SQLite' })
  assert.match(r.error, /does not show this question/)
  assert.deepEqual(f.keys, [])

  const moved = [{ ...ASK[0], options: [{ label: 'SQLite' }, { label: 'Postgres' }, { label: 'MySQL' }] }]
  assert.match((await form.answerQuestions(f.io(), moved, { 'Which database should we use?': 'SQLite' })).error, /does not show this question/)

  const done = new FakeForm([ASK[0]])
  done.submit()
  assert.match((await form.answerQuestions(done.io(), [ASK[0]], { 'Which database should we use?': 'SQLite' })).error, /does not show/)
  assert.deepEqual(done.keys, [])

  // Every question needs an answer; nothing typed when one lacks it.
  const partial = await form.answerQuestions(f.io(), ASK, { 'Which database should we use?': 'SQLite' })
  assert.match(partial.error, /no answer for question 2/)
  assert.match((await form.answerQuestions(f.io(), ASK, { 'Which database should we use?': 'a\nb', 'Which features do you want?': 'Auth' })).error, /one line/)
  assert.deepEqual(f.keys, [])
})

test('stops at the step the terminal did not take (CON-096)', async () => {
  const f = new FakeForm(ASK)
  // The digit lands nowhere (a slow or frozen terminal).
  f.text = function (s) { this.keys.push(s) }
  const r = await form.answerQuestions(f.io(), ASK, { 'Which database should we use?': 'SQLite', 'Which features do you want?': ['Auth'] })
  assert.match(r.error, /did not move on to question 2/)
  assert.deepEqual(f.keys, ['2'])
  assert.deepEqual(r.steps, ['question 1: pick 2'])
})

test('a permission prompt: 1 allows, Esc refuses, only for its own command (CON-096)', async () => {
  let screen = fixture('bash-prompt.txt')
  const keys = []
  const io = { read: async () => screen, text: async s => { keys.push(s); screen = '❯ touch it\n  ⎿  done\n' }, key: async k => { keys.push(`<${k}>`); screen = '❯ ' }, sleep: async () => {}, timeoutMs: 100, pollMs: 1 }
  const request = { toolName: 'Bash', toolInput: { command: 'touch /tmp/x4' }, summary: 'touch /tmp/x4' }
  assert.deepEqual(await form.answerPermission(io, request, 'allow'), { ok: true, steps: ['yes'] })
  assert.deepEqual(keys, ['1'])

  screen = fixture('bash-prompt.txt')
  assert.deepEqual(await form.answerPermission(io, request, 'deny'), { ok: true, steps: ['escape'] })
  assert.deepEqual(keys, ['1', '<escape>'])

  screen = fixture('bash-prompt.txt')
  const other = await form.answerPermission(io, { toolName: 'Bash', toolInput: { command: 'rm -rf build' } }, 'allow')
  assert.match(other.error, /does not show this permission prompt/)
  assert.match((await form.answerPermission(io, { toolName: 'Task', toolInput: {} }, 'allow')).error, /cannot tell this prompt apart/)
  assert.deepEqual(keys, ['1', '<escape>'])
})
