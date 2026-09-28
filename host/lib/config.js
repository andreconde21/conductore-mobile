'use strict'

// Small per-machine settings the phone sets (`conductore-hostd config`),
// in ~/.conductore/config.json (0600). The daemon reads them once and again
// on its `config` op, which `config set` sends.
//
//   herdr-sidebar      on | off (default on): publish pending approvals and
//                      today's cost as Herdr sidebar tokens
//   worktree-location  next-to-repo (default) | herdr | a path template
//                      with <repo> and <branch> (e.g. ~/wt/<repo>/<branch>);
//                      where a later task start (CON-037) puts worktrees

const fs = require('fs')
const path = require('path')
const paths = require('./paths')

const KEYS = {
  'herdr-sidebar': { default: 'on', valid: v => v === 'on' || v === 'off' },
  'worktree-location': {
    default: 'next-to-repo',
    valid: v => v === 'next-to-repo' || v === 'herdr' || (v.includes('<branch>') && v.length <= 400 && !/[\n\r\0]/.test(v))
  }
}

const file = () => path.join(paths.homeDir(), 'config.json')

let cache = null

function read () {
  let raw = {}
  try { raw = JSON.parse(fs.readFileSync(file(), 'utf8')) } catch {}
  const out = {}
  for (const [key, spec] of Object.entries(KEYS)) {
    const v = raw && typeof raw[key] === 'string' && spec.valid(raw[key]) ? raw[key] : spec.default
    out[key] = v
  }
  return out
}

function reload () {
  cache = read()
  return { ...cache }
}

function get (key) {
  if (!cache) cache = read()
  return key === undefined ? { ...cache } : cache[key]
}

// Validates and saves one key; returns the whole config.
function set (key, value) {
  const spec = KEYS[key]
  if (!spec) throw new Error(`unknown key ${key} (${Object.keys(KEYS).join(', ')})`)
  if (typeof value !== 'string' || !spec.valid(value)) throw new Error(`invalid value for ${key}`)
  const current = read()
  current[key] = value
  paths.ensureDirs()
  const tmp = `${file()}.${process.pid}.tmp`
  fs.writeFileSync(tmp, JSON.stringify(current, null, 2) + '\n', { mode: 0o600 })
  fs.renameSync(tmp, file())
  cache = current
  return { ...current }
}

module.exports = { KEYS, get, set, reload, file }
