'use strict'

// sheprd's project sidebar (andreconde21/sheprd, a client-side Herdr fork):
// `<herdr config dir>/sidebar.toml`, read-only, as JSON for the phone, so
// the app groups workspaces into the same projects. Never written here.
//
//   compact = false            active_only = false     recent_hours = 24
//   hidden = ["gpu-box/w3:scratch"]   ungrouped = [...]
//   [[group]] name, pinned, collapsed, match = [...], members = [...], short
//
// Only those keys are passed on (sheprd's unread/dismissed/kept marks stay
// on the machine). Members and hidden entries are `machine/<id>:<label>` or
// `machine/<label>`; `local` is the machine that holds the file.

const fs = require('fs')
const os = require('os')
const path = require('path')
const toml = require('./toml-lite')

// Herdr's config_dir(): $XDG_CONFIG_HOME/herdr, else ~/.config/herdr.
function sidebarPath (env = process.env, home = os.homedir()) {
  const xdg = env.XDG_CONFIG_HOME
  const base = xdg && path.isAbsolute(xdg) ? xdg : path.join(home, '.config')
  return path.join(base, 'herdr', 'sidebar.toml')
}

const MAX_GROUPS = 200
const MAX_LIST = 2000
const MAX_TEXT = 512

const text = v => (typeof v === 'string' && v.length <= MAX_TEXT ? v : null)
const strings = v => Array.isArray(v) ? v.filter(s => text(s) !== null).slice(0, MAX_LIST) : []

// The keys the app uses, checked and capped.
function pick (raw) {
  const out = {}
  for (const k of ['compact', 'active_only', 'show_hidden', 'other_collapsed']) {
    if (typeof raw[k] === 'boolean') out[k] = raw[k]
  }
  if (Number.isSafeInteger(raw.recent_hours) && raw.recent_hours > 0 && raw.recent_hours <= 24 * 365) {
    out.recent_hours = raw.recent_hours
  }
  out.hidden = strings(raw.hidden)
  out.ungrouped = strings(raw.ungrouped)
  out.group = []
  for (const g of Array.isArray(raw.group) ? raw.group.slice(0, MAX_GROUPS) : []) {
    if (!g || typeof g !== 'object' || Array.isArray(g)) continue
    const name = text(g.name)
    if (!name || !name.trim()) continue
    const group = { name, members: strings(g.members), match: strings(g.match) }
    if (g.pinned === true) group.pinned = true
    if (g.collapsed === true) group.collapsed = true
    if (text(g.short) && g.short.trim()) group.short = g.short
    out.group.push(group)
  }
  return out
}

// { found: false } | { found: true, path, mtimeMs, layout } | { found: true, path, error }
function readLayout ({ file = sidebarPath() } = {}) {
  let st
  try { st = fs.statSync(file) } catch { return { found: false } }
  if (!st.isFile()) return { found: false }
  const shown = file.startsWith(os.homedir() + path.sep) ? '~' + file.slice(os.homedir().length) : file
  if (st.size > toml.MAX_BYTES) return { found: true, path: shown, error: 'sidebar.toml is too large' }
  try {
    const raw = toml.parse(fs.readFileSync(file, 'utf8'))
    return { found: true, path: shown, mtimeMs: Math.round(st.mtimeMs), layout: pick(raw) }
  } catch (err) {
    return { found: true, path: shown, error: `sidebar.toml: ${err.message}` }
  }
}

module.exports = { sidebarPath, readLayout, pick }
