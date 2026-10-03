'use strict'

// A small, strict TOML subset: enough for hand-edited config files like
// sheprd's sidebar.toml, nothing more. Supported:
//   # comments, blank lines
//   key = "basic string" | 'literal string' | 123 | -4 | true | false
//   key = [ values... ]   (one level, may span lines, trailing comma ok)
//   [table] and [[array.of.tables]] with bare or dotted bare keys
// Not supported (a parse error, never a guess): inline tables, multi-line
// strings, floats, dates, quoted keys. Values land in objects without a
// prototype so a key like __proto__ is just a key; the result is plain
// JSON-able data.

const MAX_BYTES = 256 * 1024
const BARE_KEY = /^[A-Za-z0-9_-]+$/

class TomlError extends Error {
  constructor (message, line) {
    super(`line ${line}: ${message}`)
    this.line = line
  }
}

function parse (text) {
  if (typeof text !== 'string') throw new TomlError('not text', 0)
  if (Buffer.byteLength(text) > MAX_BYTES) throw new TomlError('file too large', 0)
  const root = Object.create(null)
  let current = root
  const src = text.replace(/^﻿/, '')
  let i = 0
  let line = 1

  const peek = () => src[i]
  const atEnd = () => i >= src.length

  function skipSpaces () {
    while (!atEnd() && (src[i] === ' ' || src[i] === '\t')) i++
  }

  function skipComment () {
    if (src[i] === '#') while (!atEnd() && src[i] !== '\n') i++
  }

  // Spaces, comments and newlines (inside arrays).
  function skipBlank () {
    for (;;) {
      skipSpaces()
      skipComment()
      if (src[i] === '\r' && src[i + 1] === '\n') i++
      if (src[i] === '\n') { i++; line++; continue }
      return
    }
  }

  function endOfLine () {
    skipSpaces()
    skipComment()
    if (src[i] === '\r') i++
    if (atEnd()) return
    if (src[i] !== '\n') throw new TomlError(`unexpected ${JSON.stringify(src[i])}`, line)
    i++
    line++
  }

  function key () {
    const start = i
    while (!atEnd() && /[A-Za-z0-9_.\- \t]/.test(src[i]) && src[i] !== '=' && src[i] !== ']') i++
    const parts = src.slice(start, i).split('.').map(part => part.trim())
    if (!parts.length || parts.some(part => !BARE_KEY.test(part))) {
      throw new TomlError('expected a bare key', line)
    }
    return parts
  }

  function basicString () {
    i++ // "
    let out = ''
    for (;;) {
      if (atEnd() || src[i] === '\n') throw new TomlError('unterminated string', line)
      const c = src[i++]
      if (c === '"') return out
      if (c !== '\\') { out += c; continue }
      const e = src[i++]
      switch (e) {
        case 'n': out += '\n'; break
        case 't': out += '\t'; break
        case 'r': out += '\r'; break
        case 'b': out += '\b'; break
        case 'f': out += '\f'; break
        case '"': out += '"'; break
        case '\\': out += '\\'; break
        case 'u': case 'U': {
          const len = e === 'u' ? 4 : 8
          const hex = src.slice(i, i + len)
          if (!/^[0-9A-Fa-f]+$/.test(hex) || hex.length !== len) throw new TomlError('bad unicode escape', line)
          const code = parseInt(hex, 16)
          if (code > 0x10FFFF || (code >= 0xD800 && code <= 0xDFFF)) throw new TomlError('bad unicode escape', line)
          out += String.fromCodePoint(code)
          i += len
          break
        }
        default: throw new TomlError('bad escape', line)
      }
    }
  }

  function literalString () {
    i++ // '
    const start = i
    while (!atEnd() && src[i] !== "'" && src[i] !== '\n') i++
    if (src[i] !== "'") throw new TomlError('unterminated string', line)
    return src.slice(start, i++)
  }

  function scalar () {
    const c = peek()
    if (c === '"') {
      if (src.startsWith('"""', i)) throw new TomlError('multi-line strings are not supported', line)
      return basicString()
    }
    if (c === "'") {
      if (src.startsWith("'''", i)) throw new TomlError('multi-line strings are not supported', line)
      return literalString()
    }
    const start = i
    while (!atEnd() && /[A-Za-z0-9_+\-.:]/.test(src[i])) i++
    const word = src.slice(start, i)
    if (word === 'true') return true
    if (word === 'false') return false
    if (/^[+-]?(0|[1-9](_?[0-9])*)$/.test(word)) {
      const n = Number(word.replace(/_/g, ''))
      if (!Number.isSafeInteger(n)) throw new TomlError('integer out of range', line)
      return n
    }
    throw new TomlError(word ? `unsupported value ${JSON.stringify(word)}` : 'expected a value', line)
  }

  function value () {
    if (peek() === '{') throw new TomlError('inline tables are not supported', line)
    if (peek() !== '[') return scalar()
    i++ // [
    const items = []
    for (;;) {
      skipBlank()
      if (peek() === ']') { i++; return items }
      if (peek() === '[') throw new TomlError('nested arrays are not supported', line)
      items.push(scalar())
      skipBlank()
      if (peek() === ',') { i++; continue }
      if (peek() === ']') { i++; return items }
      throw new TomlError('expected , or ] in array', line)
    }
  }

  function descend (table, parts, at) {
    let t = table
    for (const part of parts) {
      const next = t[part]
      if (next === undefined) {
        t = t[part] = Object.create(null)
      } else if (Array.isArray(next) && next.length && typeof next[next.length - 1] === 'object') {
        t = next[next.length - 1]
      } else if (next && typeof next === 'object' && !Array.isArray(next)) {
        t = next
      } else {
        throw new TomlError(`${part} is not a table`, at)
      }
    }
    return t
  }

  while (!atEnd()) {
    skipSpaces()
    if (atEnd()) break
    const c = peek()
    if (c === '#' || c === '\n' || c === '\r') { endOfLine(); continue }
    if (c === '[') {
      const array = src[i + 1] === '['
      i += array ? 2 : 1
      skipSpaces()
      const parts = key()
      skipSpaces()
      if (!src.startsWith(array ? ']]' : ']', i)) throw new TomlError('expected ]', line)
      i += array ? 2 : 1
      const parent = descend(root, parts.slice(0, -1), line)
      const last = parts[parts.length - 1]
      if (array) {
        if (parent[last] === undefined) parent[last] = []
        if (!Array.isArray(parent[last])) throw new TomlError(`${last} is not an array of tables`, line)
        const table = Object.create(null)
        parent[last].push(table)
        current = table
      } else {
        if (parent[last] !== undefined) throw new TomlError(`duplicate table ${parts.join('.')}`, line)
        current = parent[last] = Object.create(null)
      }
      endOfLine()
      continue
    }
    const parts = key()
    skipSpaces()
    if (peek() !== '=') throw new TomlError('expected =', line)
    i++
    skipSpaces()
    const at = line
    const v = value()
    const table = descend(current, parts.slice(0, -1), at)
    const last = parts[parts.length - 1]
    if (last in table) throw new TomlError(`duplicate key ${parts.join('.')}`, at)
    table[last] = v
    endOfLine()
  }
  return toPlain(root)
}

// Prototype-less objects to ordinary ones, keys like __proto__ defined as
// own properties (never assigned through the setter).
function toPlain (v) {
  if (Array.isArray(v)) return v.map(toPlain)
  if (v && typeof v === 'object') {
    const out = {}
    for (const k of Object.keys(v)) {
      Object.defineProperty(out, k, { value: toPlain(v[k]), enumerable: true, writable: true, configurable: true })
    }
    return out
  }
  return v
}

module.exports = { parse, TomlError, MAX_BYTES }
