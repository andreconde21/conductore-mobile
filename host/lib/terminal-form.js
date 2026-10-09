'use strict'

// Answering Claude Code's own terminal dialogs from the phone (CON-096):
// once a prompt's hook wait is over (or the companion never had the
// request), the only way left is the dialog in the agent's pane. This
// module reads the pane's screen, checks it shows exactly the question or
// prompt the phone answers, and types the keys Claude Code's form takes,
// reading the screen again after every key. Anything unexpected stops it
// before the next key; nothing is ever typed blind.
//
// Claude Code 2.1.288's forms (recorded in test/fixtures/claude-forms/):
//
//   AskUserQuestion   a header row of tabs (`←  ☐ DB  ☒ CI  ✔ Submit  →`,
//                     one question: ` ☐ DB`), the question, numbered
//                     options, `n+1. Type something.`, then a rule and
//                     `n+2. Chat about this`; footer `Enter to select`.
//     single-select   the option's digit picks it and moves on (one
//                     question: submits). Own text: the digit of "Type
//                     something", the text, Enter.
//     multiSelect     `k. [ ] label` rows; a digit toggles its row and the
//                     cursor stays. Own text: Down to "Type something",
//                     the text, Tab (to Submit). A `Submit` row after the
//                     options: Enter on it moves on.
//     review          after the last of several questions: `Review your
//                     answers` and `1. Submit answers`; 1 sends them.
//   permission        `Do you want to …?`, `❯ 1. Yes` … `Esc to cancel`;
//                     1 allows, Esc refuses (and interrupts the turn).
//
// io: { read() -> screen text, text(s), key('enter'|'tab'|'down'|'escape'),
//       sleep(ms) }, plus timeoutMs / pollMs for tests.

const HEADER = /^\s*(?:←\s*)?[☐☒]\s*\S/u
const OPTION = /^\s*(❯)?\s*(\d+)\.\s+(?:\[(.)\]\s+)?(.*?)\s*$/u
const RULE = /^\s*[─━]{8,}\s*$/u
const SUBMIT_ROW = /^\s*(❯)?\s*Submit\s*$/u

const norm = s => String(s || '').replace(/\s+/g, ' ').trim()
const KEY_PREFIX = 12
const sameLabel = (want, shown) => {
  const a = norm(want).slice(0, KEY_PREFIX)
  const b = norm(shown).slice(0, KEY_PREFIX)
  return a.length > 0 && (b === a || b.startsWith(a) || (b.endsWith('…') && a.startsWith(b.slice(0, -1))))
}

// The options of a region: numbered rows up to the rule before "Chat about
// this", the Submit row, and where the cursor is.
function optionsOf (region) {
  const options = []
  let submit = null
  for (const line of region) {
    if (RULE.test(line) && options.length) break
    const s = SUBMIT_ROW.exec(line)
    if (s) { submit = { cursor: !!s[1] }; continue }
    const m = OPTION.exec(line)
    if (m) options.push({ n: Number(m[2]), label: m[4], checked: m[3] === undefined ? null : m[3] !== ' ', cursor: !!m[1] })
  }
  return { options, submit }
}

// What Claude Code's dialog at the bottom of `screen` is, or null:
// { kind: 'question' | 'review', tabs, text, options, submit, multi } or
// { kind: 'permission', text, options }. `text`: the dialog's text on one
// line (wrapped lines joined).
function formOf (screen) {
  const lines = String(screen || '').replace(/\r/g, '').split('\n').map(l => l.replace(/\s+$/, ''))
  let header = -1
  for (let i = lines.length - 1; i >= 0; i--) if (HEADER.test(lines[i])) { header = i; break }
  if (header !== -1) {
    const region = lines.slice(header)
    const text = norm(region.join(' '))
    const tabs = []
    for (const m of lines[header].matchAll(/([☐☒✔])\s*(.+?)(?=\s*[☐☒✔→]|\s*$)/gu)) tabs.push({ label: norm(m[2]), done: m[1] === '☒', submit: m[1] === '✔' })
    if (/Review your answers/.test(text) && /\b1\.\s+Submit answers\b/.test(text)) {
      return { kind: 'review', tabs, text, ...optionsOf(region), multi: false }
    }
    if (/Enter to select/.test(text)) {
      const { options, submit } = optionsOf(region.slice(1))
      return { kind: 'question', tabs, text, options, submit, multi: options.some(o => o.checked !== null) }
    }
  }
  // A permission prompt: `1. Yes` and `Esc to cancel` in the last box.
  let rule = -1
  for (let i = lines.length - 1; i >= 0; i--) if (RULE.test(lines[i])) { rule = i; break }
  const region = lines.slice(rule + 1)
  const text = norm(region.join(' '))
  const { options } = optionsOf(region)
  if (options.length >= 2 && options[0].n === 1 && norm(options[0].label) === 'Yes' && /Esc to cancel/.test(text)) {
    return { kind: 'permission', text, options }
  }
  return null
}

class Refused extends Error {}

const DEFAULTS = { timeoutMs: 4000, pollMs: 150 }

// Reads the screen until `pred(form)` holds; throws Refused(`what`) after
// io.timeoutMs.
async function until (io, pred, what) {
  const deadline = Date.now() + (io.timeoutMs || DEFAULTS.timeoutMs)
  for (;;) {
    let form = null
    try { form = formOf(await io.read()) } catch (err) { throw new Refused(`cannot read the terminal: ${err.message}`) }
    if (pred(form)) return form
    if (Date.now() >= deadline) throw new Refused(what)
    await io.sleep(io.pollMs || DEFAULTS.pollMs)
  }
}

// Checks the phone's questions and answers: [{ question, options, multi,
// picks: [option index], other }] or throws Refused.
function plan (questions, answers) {
  if (!Array.isArray(questions) || !questions.length || questions.length > 12) throw new Refused('no questions')
  if (!answers || typeof answers !== 'object' || Array.isArray(answers)) throw new Refused('answers must be an object: question -> answer')
  return questions.map((q, i) => {
    if (!q || typeof q.question !== 'string' || !q.question.trim()) throw new Refused(`question ${i + 1} has no text`)
    const options = (Array.isArray(q.options) ? q.options : []).map(o => (typeof o === 'string' ? o : o && o.label)).filter(l => typeof l === 'string' && l)
    if (!options.length || options.length > 8) throw new Refused(`question ${i + 1} has no options to pick from in the terminal`)
    const raw = answers[q.question]
    const given = (Array.isArray(raw) ? raw : [raw]).filter(v => typeof v === 'string').map(v => v.trim()).filter(Boolean)
    if (!given.length) throw new Refused(`no answer for question ${i + 1}; the terminal form takes every question in turn`)
    const multi = q.multiSelect === true
    const picks = []
    const own = []
    for (const v of multi ? given : given.slice(0, 1)) {
      const k = options.indexOf(v)
      if (k === -1) own.push(v)
      else if (!picks.includes(k)) picks.push(k)
    }
    const other = own.join(', ')
    if (/[\n\r\t\x00-\x1f\x7f]/.test(other)) throw new Refused('an own answer must be one line of text')
    if (other.length > 500) throw new Refused('own answer too long')
    return { question: q.question, options, multi, picks, other: other || null }
  })
}

// The form shows this question, its options in this order, and the row for
// one's own text after them.
function showsQuestion (form, q) {
  if (!form || form.kind !== 'question' || form.multi !== q.multi) return false
  if (!form.text.includes(norm(q.question))) return false
  if (form.options.length < q.options.length + 1) return false
  return q.options.every((label, i) => form.options[i].n === i + 1 && sameLabel(label, form.options[i].label))
}

const cursorRow = form => (form && form.options.find(o => o.cursor) || {}).n || null

// Answers an AskUserQuestion form in the terminal. Resolves { ok: true,
// steps } or { error, steps } (nothing typed after the step that failed).
async function answerQuestions (io, questions, answers) {
  const steps = []
  const type = async (what, s) => { steps.push(what); await io.text(s) }
  const press = async (what, k) => { steps.push(what); await io.key(k) }
  try {
    const qs = plan(questions, answers)
    for (let i = 0; i < qs.length; i++) {
      const q = qs[i]
      const label = qs.length > 1 ? `question ${i + 1}` : 'the question'
      let form = await until(io, f => showsQuestion(f, q), i === 0
        ? 'the terminal does not show this question (answered already, or another dialog is open)'
        : `the terminal did not move on to ${label}`)
      const own = q.options.length + 1
      if (!q.multi) {
        if (q.other === null) {
          await type(`${label}: pick ${q.picks[0] + 1}`, String(q.picks[0] + 1))
          continue
        }
        await type(`${label}: own answer`, String(own))
        await until(io, f => showsQuestion(f, q) && cursorRow(f) === own, `${label}: the terminal did not open the own-answer row`)
        await type(`${label}: type the answer`, q.other)
        await until(io, f => f && f.kind === 'question' && f.options.some(o => o.n === own && norm(o.label).includes(norm(q.other).slice(0, 20))), `${label}: the answer did not appear`)
        await press(`${label}: enter`, 'enter')
        continue
      }
      for (let k = 0; k < q.options.length; k++) {
        const want = q.picks.includes(k)
        if (form.options[k].checked === want) continue
        await type(`${label}: ${want ? 'tick' : 'untick'} ${k + 1}`, String(k + 1))
        form = await until(io, f => showsQuestion(f, q) && f.options[k].checked === want, `${label}: option ${k + 1} did not ${want ? 'tick' : 'untick'}`)
      }
      if (q.other !== null) {
        for (let n = 0; cursorRow(form) !== own; n++) {
          const at = cursorRow(form)
          if (at === null || at > own || n > own) throw new Refused(`${label}: cannot reach the own-answer row`)
          await press(`${label}: down`, 'down')
          form = await until(io, f => f && f.kind === 'question' && f.text.includes(norm(q.question)) && cursorRow(f) !== at, `${label}: the cursor did not move`)
        }
        await type(`${label}: type the answer`, q.other)
        form = await until(io, f => f && f.kind === 'question' && f.options.some(o => o.n === own && norm(o.label).includes(norm(q.other).slice(0, 20))), `${label}: the answer did not appear`)
        await press(`${label}: tab`, 'tab')
        form = await until(io, f => f && f.kind === 'question' && f.submit && f.submit.cursor, `${label}: the cursor did not reach Submit`)
      } else {
        for (let n = 0; !(form.submit && form.submit.cursor); n++) {
          if (n > own + 2) throw new Refused(`${label}: cannot reach Submit`)
          const at = cursorRow(form)
          await press(`${label}: down`, 'down')
          form = await until(io, f => f && f.kind === 'question' && f.text.includes(norm(q.question)) && (cursorRow(f) !== at || (f.submit && f.submit.cursor)), `${label}: the cursor did not move`)
        }
      }
      await press(`${label}: submit`, 'enter')
    }
    const last = norm(qs[qs.length - 1].question)
    const after = await until(io, f => !f || f.kind === 'review' || (f.kind === 'question' && !f.text.includes(last)), 'the terminal did not take the answers')
    if (after && after.kind === 'review') {
      if (!qs.every(q => after.text.includes(norm(q.question)))) throw new Refused('the review shows other questions')
      await type('submit answers', '1')
      await until(io, f => !f || f.kind !== 'review', 'the terminal did not submit the answers')
    } else if (after) {
      throw new Refused('the terminal shows another dialog now; check it there')
    }
    return { ok: true, steps }
  } catch (err) {
    if (err instanceof Refused) return { error: err.message, steps }
    throw err
  }
}

// What a permission prompt for `request` (a pending request: toolName,
// toolInput, summary) must show: its command or file name.
function promptMark (request) {
  const input = request && request.toolInput && typeof request.toolInput === 'object' && !request.toolInput._truncated ? request.toolInput : {}
  if (typeof input.command === 'string' && input.command.trim()) return norm(input.command.split('\n')[0]).slice(0, 40)
  const file = input.file_path || input.notebook_path
  if (typeof file === 'string' && file) return file.split('/').filter(Boolean).pop() || null
  return null
}

// Allows (1) or refuses (Esc) the permission prompt for `request` in the
// terminal. Resolves { ok: true, steps } or { error, steps }.
async function answerPermission (io, request, decision) {
  const steps = []
  try {
    if (decision !== 'allow' && decision !== 'deny') throw new Refused('decision must be allow or deny')
    const mark = promptMark(request)
    if (!mark) throw new Refused('cannot tell this prompt apart in the terminal; answer it there')
    await until(io, f => f && f.kind === 'permission' && f.text.includes(mark),
      'the terminal does not show this permission prompt (answered already, or another dialog is open)')
    steps.push(decision === 'allow' ? 'yes' : 'escape')
    if (decision === 'allow') await io.text('1')
    else await io.key('escape')
    await until(io, f => !f || f.kind !== 'permission' || !f.text.includes(mark), 'the terminal did not take the answer')
    return { ok: true, steps }
  } catch (err) {
    if (err instanceof Refused) return { error: err.message, steps }
    throw err
  }
}

module.exports = { formOf, plan, answerQuestions, answerPermission, promptMark, Refused }
