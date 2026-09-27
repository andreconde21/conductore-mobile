'use strict'

// A small, conservative reader for the shell commands Claude Code asks to
// run (Bash tool input). It never executes anything; it only splits a command
// line the way sh would, well enough to classify risk and match rules.
//
// parse(command) -> {
//   segments: [{ words: [..], redirects: [{ op, target }], pipedFrom, raw }],
//   substitutions: ['inner command', ..],   // $(..), `..`, <(..), >(..)
//   heredocs: N,
//   complete: bool                           // false: unbalanced quotes etc.
// }
//
// Segments are split on ; & && || | |& and newlines outside quotes;
// `pipedFrom` is true when the previous segment pipes into this one. Words
// have their quotes removed. Heredoc bodies are skipped (they are data).
// Substitutions are returned as text so callers can read them as commands
// too; the word that held one keeps a `$(…)` placeholder.

const OPERATORS = ['&&', '||', '|&', ';;', '|', ';', '&', '\n']
const REDIRECT = /^([0-9]*|&)(>>|>&|>\||>|<<<|<<-|<<|<>|<&|<)$/

function parse (command) {
  const text = typeof command === 'string' ? command : ''
  const segments = []
  const substitutions = []
  let heredocs = 0
  let complete = true
  let words = []
  let raw = ''
  let word = null // current word being built, null between words
  let pipedFrom = false
  const pendingHeredocs = [] // delimiters waiting for the next newline

  const endWord = () => {
    if (word !== null) { words.push(word); word = null }
  }
  const endSegment = (op) => {
    endWord()
    if (words.length) segments.push(shape(words, raw.trim(), pipedFrom))
    words = []
    raw = ''
    pipedFrom = op === '|' || op === '|&'
  }

  let i = 0
  while (i < text.length) {
    const c = text[i]
    // Operators and separators (outside quotes, as we are at top level here).
    if (c === '\n' && pendingHeredocs.length) {
      endSegment('\n')
      i = skipHeredocs(text, i + 1, pendingHeredocs)
      heredocs += pendingHeredocs.length
      pendingHeredocs.length = 0
      continue
    }
    const op = OPERATORS.find(o => text.startsWith(o, i))
    if (op && !(op === '&' && (text[i + 1] === '>' || text[i - 1] === '>' || text[i - 1] === '<'))) {
      endSegment(op)
      i += op.length
      continue
    }
    if (c === ' ' || c === '\t') { endWord(); raw += c; i++; continue }
    if (c === '#' && word === null) {
      // Comment to end of line.
      while (i < text.length && text[i] !== '\n') i++
      continue
    }
    if (c === '\\') {
      if (text[i + 1] === '\n') { i += 2; continue }
      word = (word || '') + (text[i + 1] || '')
      raw += text.slice(i, i + 2)
      i += 2
      continue
    }
    if (c === "'") {
      const end = text.indexOf("'", i + 1)
      if (end === -1) { complete = false; word = (word || '') + text.slice(i + 1); raw += text.slice(i); i = text.length; continue }
      word = (word || '') + text.slice(i + 1, end)
      raw += text.slice(i, end + 1)
      i = end + 1
      continue
    }
    if (c === '"') {
      let j = i + 1
      let value = ''
      while (j < text.length && text[j] !== '"') {
        if (text[j] === '\\' && j + 1 < text.length) { value += text[j + 1]; j += 2; continue }
        if (text[j] === '`' || (text[j] === '$' && text[j + 1] === '(')) {
          const sub = readSubstitution(text, j)
          if (!sub) { complete = false; j = text.length; break }
          substitutions.push(sub.inner)
          value += '$(…)'
          j = sub.end
          continue
        }
        value += text[j]
        j++
      }
      if (j >= text.length) complete = false
      word = (word || '') + value
      raw += text.slice(i, j + 1)
      i = j + 1
      continue
    }
    if (c === '`' || (c === '$' && text[i + 1] === '(') || ((c === '<' || c === '>') && text[i + 1] === '(')) {
      const sub = readSubstitution(text, i)
      if (!sub) { complete = false; raw += text.slice(i); i = text.length; continue }
      substitutions.push(sub.inner)
      word = (word || '') + '$(…)'
      raw += text.slice(i, sub.end)
      i = sub.end
      continue
    }
    // Redirection operators start their own word.
    if (c === '>' || c === '<') {
      const m = /^([0-9]*|&)?(>>|>&|>\||>|<<<|<<-|<<|<>|<&|<)/.exec(text.slice(i))
      const prefix = word !== null && /^([0-9]+|&)$/.test(word) ? word : ''
      if (prefix) word = null
      endWord()
      words.push(prefix + m[0])
      raw += m[0]
      i += m[0].length
      if (m[2] === '<<' || m[2] === '<<-') {
        // The delimiter is the next word.
        let j = i
        while (text[j] === ' ' || text[j] === '\t') j++
        const dm = /^(['"]?)([^\s'";&|<>]+)\1/.exec(text.slice(j))
        if (dm) {
          pendingHeredocs.push({ delim: dm[2], strip: m[2] === '<<-' })
          words.push(dm[2])
          raw += text.slice(i, j + dm[0].length)
          i = j + dm[0].length
        }
      }
      continue
    }
    word = (word || '') + c
    raw += c
    i++
  }
  if (pendingHeredocs.length) { heredocs += pendingHeredocs.length; complete = false }
  endSegment(null)
  return { segments, substitutions, heredocs, complete }
}

// Returns { inner, end } for $( … ), ` … `, <( … ) or >( … ) starting at i.
function readSubstitution (text, i) {
  if (text[i] === '`') {
    const end = text.indexOf('`', i + 1)
    if (end === -1) return null
    return { inner: text.slice(i + 1, end), end: end + 1 }
  }
  let depth = 0
  let j = i + 1 // at "("
  let quote = null
  const heredocs = []
  for (; j < text.length; j++) {
    const ch = text[j]
    if (quote) {
      if (ch === '\\' && quote === '"') { j++; continue }
      if (ch === quote) quote = null
      continue
    }
    // A heredoc body (a commit message, say) may hold quotes and parens.
    if (ch === '<' && text[j + 1] === '<' && text[j + 2] !== '<') {
      const dm = /^<<-?[ \t]*(['"]?)([^\s'";&|<>()]+)\1/.exec(text.slice(j))
      if (dm) {
        heredocs.push({ delim: dm[2], strip: dm[0].startsWith('<<-') })
        j += dm[0].length - 1
        continue
      }
    }
    if (ch === '\n' && heredocs.length) {
      j = skipHeredocs(text, j + 1, heredocs) - 1
      heredocs.length = 0
      continue
    }
    if (ch === "'" || ch === '"') { quote = ch; continue }
    if (ch === '\\') { j++; continue }
    if (ch === '(') depth++
    else if (ch === ')') {
      depth--
      if (depth === 0) return { inner: text.slice(i + 2, j), end: j + 1 }
    }
  }
  return null
}

function skipHeredocs (text, i, pending) {
  for (const { delim, strip } of pending) {
    while (i < text.length) {
      const nl = text.indexOf('\n', i)
      const line = text.slice(i, nl === -1 ? text.length : nl)
      i = nl === -1 ? text.length : nl + 1
      if ((strip ? line.replace(/^\t+/, '') : line) === delim) break
    }
  }
  return i
}

// Splits a segment's words into the command words and its redirections.
function shape (all, raw, pipedFrom) {
  const words = []
  const redirects = []
  for (let k = 0; k < all.length; k++) {
    const m = REDIRECT.exec(all[k])
    if (m) {
      const op = m[2]
      const target = all[k + 1]
      // 2>&1, >&2: a file descriptor, not a file.
      if (target !== undefined && !((op === '>&' || op === '<&') && /^[0-9-]+$/.test(target))) redirects.push({ op, target })
      k++
      continue
    }
    words.push(all[k])
  }
  return { words, redirects, pipedFrom, raw }
}

// Leading VAR=value assignments are not the command.
function stripAssignments (words) {
  let k = 0
  while (k < words.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(words[k])) k++
  return words.slice(k)
}

module.exports = { parse, stripAssignments }
