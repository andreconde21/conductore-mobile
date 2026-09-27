'use strict'

// The spool: how the sh clients hand events to the daemon without Node.
//
// A client writes one file per event into <state dir>/tmp/, then hard-links
// it into <state dir>/spool/ (atomic, never overwrites; `mv` when the
// filesystem has no hard links), which the daemon watches. The daemon removes
// both names. File format: a small header of `key=value` lines, one empty
// line, then the payload exactly as Claude Code piped it (JSON):
//
//   conductore 1
//   kind=hook                 hook | usage
//   event=PreToolUse          argv[1] of conductore-hook
//   pid=12345
//   claude_pid=12340          Claude Code's pid (the hook's parent, or its
//                             grandparent through `sh -c`)
//   tmp=h.12345               the staging name in tmp/
//   tmux=/tmp/tmux-1000/default,123,0      only when set
//   tmux_pane=%5
//   herdr_workspace=w1 / herdr_tab / herdr_pane / herdr_name
//   fifo=<state dir>/tmp/p.12345          PermissionRequest only
//   timeout=120
//
//   {"session_id":"…", …}

const fs = require('fs')
const path = require('path')

const MAGIC = 'conductore 1'
const MAX_FILE_BYTES = 8 * 1024 * 1024

function parse (text) {
  const nl = text.indexOf('\n')
  if (nl === -1 || text.slice(0, nl) !== MAGIC) return null
  const end = text.indexOf('\n\n', nl - 1)
  if (end === -1) return null
  const header = {}
  for (const line of text.slice(nl + 1, end).split('\n')) {
    const eq = line.indexOf('=')
    if (eq > 0) header[line.slice(0, eq)] = line.slice(eq + 1)
  }
  let body = null
  try { body = JSON.parse(text.slice(end + 2) || 'null') } catch {}
  return { header, body }
}

// Entries of dir (optionally only names starting with `prefix`), oldest
// first (by mtime, then name). Dot files are ignored.
function list (dir, prefix = '') {
  let names
  try { names = fs.readdirSync(dir) } catch { return [] }
  const entries = []
  for (const name of names) {
    if (name.startsWith('.') || !name.startsWith(prefix)) continue
    const file = path.join(dir, name)
    try {
      const st = fs.statSync(file)
      if (st.isFile()) entries.push({ file, name, mtime: st.mtimeMs, size: st.size, ino: st.ino, dev: st.dev })
    } catch {}
  }
  return entries.sort((a, b) => a.mtime - b.mtime || (a.name < b.name ? -1 : a.name > b.name ? 1 : 0))
}

const TMP_NAME = /^[a-z]\.[0-9]+(\.n)*$/

// Reads and removes one entry and its staging twin in tmpDir (only when it
// still is the same file). Returns { header, body, mtime } or null.
function take (entry, tmpDir) {
  let text = null
  try {
    if (entry.size <= MAX_FILE_BYTES) text = fs.readFileSync(entry.file, 'utf8')
  } catch {}
  try { fs.unlinkSync(entry.file) } catch {}
  const item = text === null ? null : parse(text)
  if (item && tmpDir && TMP_NAME.test(item.header.tmp || '')) {
    const twin = path.join(tmpDir, item.header.tmp)
    try {
      const st = fs.lstatSync(twin)
      if (st.ino === entry.ino && st.dev === entry.dev) fs.unlinkSync(twin)
    } catch {}
  }
  if (item) item.mtime = entry.mtime
  return item
}

function isSpooled (dir) {
  try { return fs.readdirSync(dir).some(n => !n.startsWith('.')) } catch { return false }
}

module.exports = { parse, list, take, isSpooled, MAGIC }
