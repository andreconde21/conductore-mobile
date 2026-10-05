'use strict'

// A small, strict reader for the shell commands coding agents ask to run
// (Bash tool input). It never executes anything; it only splits a command
// line the way bash would, to classify risk and match rules.
//
// It reads simple commands joined by ; & && || | |& and newlines, with
// quotes, escapes and redirections. Everything else bash can do (expansions,
// substitutions, subshells, compound commands, here-docs, line
// continuations, odd characters) is reported in `concerns`, and a caller
// treats a command with any concern as not understood: high risk, never
// matched by a rule. Where the parser and bash could read a command
// differently, it says so rather than guess.
//
// parse(command) -> {
//   segments: [{ words: [..], meta: [{ quoted, glob, brace }], assigns: N,
//                redirects: [{ op, target }], pipedFrom, sep, raw }],
//   substitutions: ['inner command', ..],   // $(..), `..`, <(..), >(..)
//   heredocs: N,
//   complete: bool,                          // false: unbalanced quotes etc.
//   concerns: ['substitution', ..],          // what it did not understand
//   understood: bool                         // complete and no concerns
// }
//
// `words` have their quotes removed; `meta[k]` says whether word k had any
// quoting, unquoted glob characters (* ? [..]) or a brace expansion.
// `assigns` counts the leading VAR=value words (bash's rule: an unquoted
// name before the `=`). `sep` is the operator before the segment (null for
// the first); `pipedFrom` is true when it is | or |&.
//
// One substitution is understood: "$(cat <<'EOF' … EOF)" with a quoted
// delimiter, which is literal text (the way agents write commit messages).

const OPERATORS = ['&&', '||', '|&', ';;', '|', ';', '&', '\n']
const CHAIN = new Set(['&&', '||', '|', '|&'])
const REDIRECT = /^([0-9]*|&)(>>|>&|>\||>|<<<|<<-|<<|<>|<&|<)$/
const KEYWORDS = new Set(['if', 'then', 'else', 'elif', 'fi', 'for', 'while', 'until', 'do', 'done', 'case', 'esac', 'select', 'function', 'coproc', '[[', ']]', '!', '{', '}'])
// Characters bash or a terminal could read differently from what is shown:
// control characters (other than tab and newline), and Unicode spaces,
// invisible and direction marks.
const ODD_CHARS = /[\u0000-\u0008\u000b-\u001f\u007f-\u009f\u00a0\u00ad\u1680\u180e\u2000-\u200f\u2028-\u202f\u205f-\u2064\u2066-\u206f\u3000\ufeff\ufff9-\ufffb]/
// What follows a `$` that bash expands: a name, a positional or special
// parameter, ${…}, $(…), $((…)) or $[…].
const EXPANDS = /[A-Za-z_0-9{(@*#?$!\-[]/
const ASSIGNMENT = /^[A-Za-z_][A-Za-z0-9_]*\+?=/

function parse (command) {
  const text = typeof command === 'string' ? command : ''
  const segments = []
  const substitutions = []
  const concerns = new Set()
  let heredocs = 0
  let complete = true
  let words = [] // { text, raw, quoted, glob, brace, redir }
  let raw = ''
  let word = null // the word being built, null between words
  let sep = null
  const pendingHeredocs = [] // delimiters waiting for the next newline

  if (ODD_CHARS.test(text)) concerns.add('control')

  const startWord = () => {
    if (word === null) word = { text: '', raw: '', quoted: false, glob: false, brace: false, open: 0 }
    return word
  }
  const endWord = () => {
    if (word !== null) { words.push(word); word = null }
  }
  const endSegment = (op) => {
    endWord()
    if (words.length) {
      segments.push(shape(words, raw.trim(), segments.length ? sep : null, concerns))
      sep = op
    } else if (op === null) {
      // `ls &&` at the end: bash wants more.
      if (CHAIN.has(sep)) concerns.add('syntax')
    } else if (op === '\n') {
      // A newline after && or | continues the chain; else it separates.
      if (!CHAIN.has(sep)) sep = op
    } else {
      // `&& ls`, `ls ; ; ls`: an operator with no command before it.
      concerns.add('syntax')
      sep = op
    }
    words = []
    raw = ''
  }

  let i = 0
  while (i < text.length) {
    const c = text[i]
    if (c === '\n' && pendingHeredocs.length) {
      endSegment('\n')
      i = skipHeredocs(text, i + 1, pendingHeredocs)
      heredocs += pendingHeredocs.length
      pendingHeredocs.length = 0
      continue
    }
    // Operators and separators (outside quotes: we are at top level here).
    const op = OPERATORS.find(o => text.startsWith(o, i))
    if (op && !(op === '&' && (text[i + 1] === '>' || text[i - 1] === '>' || text[i - 1] === '<'))) {
      if (op === ';;' || (op === ';' && text[i + 1] === '&')) concerns.add('compound')
      if (op === '&') concerns.add('background')
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
      if (text[i + 1] === '\n') { concerns.add('continuation'); i += 2; continue }
      if (i + 1 >= text.length) { complete = false; i++; continue }
      const w = startWord()
      w.text += text[i + 1]
      w.quoted = true
      w.raw += text.slice(i, i + 2)
      raw += text.slice(i, i + 2)
      i += 2
      continue
    }
    if (c === "'") {
      const w = startWord()
      w.quoted = true
      const end = text.indexOf("'", i + 1)
      if (end === -1) { complete = false; w.text += text.slice(i + 1); raw += text.slice(i); i = text.length; continue }
      w.text += text.slice(i + 1, end)
      w.raw += text.slice(i, end + 1)
      raw += text.slice(i, end + 1)
      i = end + 1
      continue
    }
    if (c === '"') {
      const w = startWord()
      w.quoted = true
      let j = i + 1
      let value = ''
      while (j < text.length && text[j] !== '"') {
        const d = text[j]
        if (d === '\\' && j + 1 < text.length) {
          // In double quotes a backslash escapes only $ ` " \ and newline.
          const n = text[j + 1]
          if (n === '\n') { concerns.add('continuation'); j += 2; continue }
          value += '$`"\\'.includes(n) ? n : d + n
          j += 2
          continue
        }
        if (d === '`' || (d === '$' && text[j + 1] === '(')) {
          const sub = readSubstitution(text, j)
          if (!sub) { complete = false; concerns.add('substitution'); j = text.length; break }
          substitutions.push(sub.inner)
          if (d === '`' || !literalHeredoc(sub.inner)) concerns.add('substitution')
          value += '$(…)'
          j = sub.end
          continue
        }
        if (d === '$' && EXPANDS.test(text[j + 1] || '')) concerns.add('expansion')
        value += d
        j++
      }
      if (j >= text.length) complete = false
      w.text += value
      w.raw += text.slice(i, j + 1)
      raw += text.slice(i, j + 1)
      i = j + 1
      continue
    }
    if (c === '$' && (text[i + 1] === "'" || text[i + 1] === '"')) {
      // $'…' (ANSI-C escapes) and $"…" (translated): not read here.
      concerns.add('expansion')
      const w = startWord()
      w.quoted = true
      w.raw += c
      raw += c
      i++
      continue
    }
    if (c === '`' || (c === '$' && text[i + 1] === '(') || ((c === '<' || c === '>') && text[i + 1] === '(')) {
      const sub = readSubstitution(text, i)
      if (!sub) { complete = false; concerns.add('substitution'); raw += text.slice(i); i = text.length; continue }
      substitutions.push(sub.inner)
      if (c !== '$' || !literalHeredoc(sub.inner)) concerns.add('substitution')
      const w = startWord()
      w.text += '$(…)'
      w.quoted = true
      w.raw += text.slice(i, sub.end)
      raw += text.slice(i, sub.end)
      i = sub.end
      continue
    }
    if (c === '$' && EXPANDS.test(text[i + 1] || '')) {
      concerns.add('expansion')
      const w = startWord()
      w.text += c
      w.raw += c
      raw += c
      i++
      continue
    }
    if (c === '(' || c === ')') {
      // Subshells, function definitions, arrays, extended globs.
      concerns.add('subshell')
      endWord()
      raw += c
      i++
      continue
    }
    // Redirection operators start their own word.
    if (c === '>' || c === '<') {
      const m = /^(>>|>&|>\||>|<<<|<<-|<<|<>|<&|<)/.exec(text.slice(i))
      const prefix = word !== null && !word.quoted && /^([0-9]+|&)$/.test(word.text) ? word.text : ''
      if (prefix) word = null
      endWord()
      words.push({ text: prefix + m[0], raw: prefix + m[0], quoted: false, glob: false, brace: false, redir: true })
      raw += m[0]
      i += m[0].length
      if (m[1] === '<<<') concerns.add('heredoc')
      if (m[1] === '<<' || m[1] === '<<-') {
        concerns.add('heredoc')
        // The delimiter is the next word.
        let j = i
        while (text[j] === ' ' || text[j] === '\t') j++
        const dm = /^(['"]?)([^\s'";&|<>()]+)\1/.exec(text.slice(j))
        if (dm) {
          pendingHeredocs.push({ delim: dm[2], strip: m[1] === '<<-' })
          words.push({ text: dm[2], raw: dm[0], quoted: !!dm[1], glob: false, brace: false })
          raw += text.slice(i, j + dm[0].length)
          i = j + dm[0].length
        }
      }
      continue
    }
    const w = startWord()
    // `~user`, `~+`, `~-`: expansions resolvePath does not read.
    if (c === '~' && w.text === '' && !w.quoted && i + 1 < text.length && !/[\s/;&|<>()]/.test(text[i + 1])) concerns.add('expansion')
    if (c === '*' || c === '?') w.glob = true
    if (c === '[' && /^[^\s/]*\]/.test(text.slice(i + 1))) w.glob = true
    if (c === '{') w.open += 1
    if (c === '}' && w.open && /\{[^{}]*(,|\.\.)[^{}]*$/.test(w.text)) w.brace = true
    w.text += c
    w.raw += c
    raw += c
    i++
  }
  if (pendingHeredocs.length) { heredocs += pendingHeredocs.length; complete = false }
  endSegment(null)
  const list = [...concerns]
  return { segments, substitutions, heredocs, complete, concerns: list, understood: complete && !list.length }
}

// "$(cat <<'EOF'\n…\nEOF\n)": a quoted delimiter keeps the body literal, so
// the substitution is plain text. Anything more is not this form.
function literalHeredoc (inner) {
  const m = /^[ \t]*cat[ \t]+<<(-?)[ \t]*(['"])([A-Za-z0-9_]+)\2[ \t]*\n/.exec(inner)
  if (!m) return false
  const strip = m[1] === '-'
  const lines = inner.slice(m[0].length).split('\n')
  for (let k = 0; k < lines.length; k++) {
    if ((strip ? lines[k].replace(/^\t+/, '') : lines[k]) === m[3]) {
      return lines.slice(k + 1).every(l => /^[ \t]*$/.test(l))
    }
  }
  return false
}

// Returns { inner, end } for $( … ), ` … `, <( … ) or >( … ) starting at i.
function readSubstitution (text, i) {
  if (text[i] === '`') {
    for (let j = i + 1; j < text.length; j++) {
      if (text[j] === '\\') { j++; continue }
      if (text[j] === '`') return { inner: text.slice(i + 1, j), end: j + 1 }
    }
    return null
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
function shape (all, raw, sep, concerns) {
  const words = []
  const objs = []
  const redirects = []
  for (let k = 0; k < all.length; k++) {
    const w = all[k]
    const m = w.redir ? REDIRECT.exec(w.text) : null
    if (m) {
      const op = m[2]
      const target = all[k + 1]
      if (!target || target.redir) { concerns.add('syntax'); continue }
      if (target.glob || target.brace) concerns.add('glob-redirect')
      // 2>&1, >&2, >&-: a file descriptor, not a file.
      if (!((op === '>&' || op === '<&') && /^([0-9]+|-)$/.test(target.text))) redirects.push({ op, target: target.text })
      k++
      continue
    }
    words.push(w.text)
    objs.push(w)
  }
  // Leading VAR=value words; bash needs the name and `=` unquoted.
  let assigns = 0
  while (assigns < objs.length && ASSIGNMENT.test(objs[assigns].raw)) assigns++
  const first = objs[assigns]
  if (first && !first.quoted && KEYWORDS.has(first.text)) concerns.add('compound')
  if (first && (first.glob || first.brace)) concerns.add('glob-command')
  // {a,b} and {1..3} turn one word into several.
  if (objs.some(w => w.brace)) concerns.add('brace')
  const meta = objs.map(w => ({ quoted: w.quoted, glob: w.glob, brace: w.brace }))
  return { words, meta, assigns, redirects, pipedFrom: sep === '|' || sep === '|&', sep, raw }
}

// Leading VAR=value assignments are not the command. With a parsed
// segment's own count (quoting aware), else the same name rule on words.
function stripAssignments (words, assigns) {
  if (typeof assigns === 'number') return words.slice(assigns)
  let k = 0
  while (k < words.length && ASSIGNMENT.test(words[k])) k++
  return words.slice(k)
}

module.exports = { parse, stripAssignments, literalHeredoc }
