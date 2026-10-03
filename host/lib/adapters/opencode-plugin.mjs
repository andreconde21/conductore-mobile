// Conductore Mobile: OpenCode plugin. Installed by `conductore-hostd install`
// into OpenCode's plugins directory and removed by `uninstall`; reinstalling
// overwrites this file, so do not edit it (add your own plugin beside it).
// CONDUCTORE_PLUGIN=opencode
// CONDUCTORE_PLUGIN_VERSION=1
//
// Hands OpenCode's session, prompt, tool, permission and question events to
// the Conductore companion through its hook client (conductore-hook --agent
// opencode <event>, the same spool as Claude Code's hooks), and answers a
// permission request or a question with the phone's decision when one comes
// back before the hook's timeout. Without an answer OpenCode's own prompt
// stays, as if this plugin were not here. The companion's adapter
// (lib/adapters/opencode.js) maps the events onto its vocabulary; this file
// only filters and forwards them. It never throws into OpenCode.

import { spawn } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'

const HOOK = '__CONDUCTORE_HOOK__'
const AGENT = 'opencode'
const TEXT_CAP = 4000
const OUTPUT_CAP = 2000

const cap = (s, max) => (typeof s === 'string' && s.length > max ? s.slice(0, max) : s)

// OpenCode's data directory and its OPENCODE_DB, so the companion finds the
// session's database (the file name depends on OpenCode's release channel).
function dataDir () {
  const base = process.env.XDG_DATA_HOME || path.join(os.homedir(), '.local', 'share')
  return path.join(base, 'opencode')
}

function createPlugin ({ hook = HOOK, spawnFn = spawn, env = process.env } = {}) {
  return async (ctx = {}) => {
    // Our own brain calls (`opencode run` with CONDUCTORE_BRAIN=1) are never
    // agents; nor is anything when the companion is gone.
    if (env.CONDUCTORE_BRAIN === '1') return {}
    try { fs.accessSync(hook, fs.constants.X_OK) } catch { return {} }

    const store = { data: dataDir(), db: env.OPENCODE_DB || null }
    const parents = new Map() // child session -> parent session
    const lastText = new Map() // session -> last assistant text
    const roles = new Map() // message id -> role
    const waiting = new Map() // permission/question id -> hook child
    let queue = Promise.resolve()

    const rootOf = id => {
      const seen = new Set()
      while (parents.has(id) && !seen.has(id)) { seen.add(id); id = parents.get(id) }
      return id
    }

    // Runs the hook once; resolves its stdout ('' on any failure).
    function run (event, body, track) {
      return new Promise(resolve => {
        let out = ''
        let child
        try {
          child = spawnFn(hook, ['--agent', AGENT, event], { stdio: ['pipe', 'pipe', 'ignore'], env, detached: !!track })
        } catch { return resolve('') }
        if (track) waiting.set(track, child)
        child.stdout.on('data', d => { out += d })
        child.on('error', () => resolve(''))
        child.on('close', () => { if (track) waiting.delete(track); resolve(out) })
        child.stdin.on('error', () => {})
        child.stdin.end(JSON.stringify(body))
      })
    }

    function body (type, properties, sessionID) {
      const root = rootOf(sessionID)
      return { type, properties, session_id: root, child: root !== sessionID ? sessionID : null, cwd: ctx.directory || null, store }
    }

    // Events go out one at a time, in order.
    function forward (type, properties, sessionID, extra) {
      if (typeof sessionID !== 'string' || !sessionID) return queue
      const b = { ...body(type, properties, sessionID), ...extra }
      queue = queue.then(() => run(type, b)).catch(() => {})
      return queue
    }

    // A permission or question waits for the phone (in parallel: it blocks
    // up to the hook's timeout), after every event before it went out.
    async function ask (type, properties) {
      const sessionID = properties.sessionID
      const id = properties.id
      if (typeof sessionID !== 'string' || typeof id !== 'string') return
      const b = body(type, properties, sessionID)
      await queue
      const line = (await run('PermissionRequest', b, id)).trim()
      if (!line) return
      let answer
      try { answer = JSON.parse(line) } catch { return }
      await reply(type, id, sessionID, answer)
    }

    async function post (url, pathParams, payload) {
      const raw = ctx.client && ctx.client._client
      if (raw && typeof raw.post === 'function') {
        const r = await raw.post({ url, path: pathParams, body: payload, headers: { 'Content-Type': 'application/json' } })
        return !(r && r.error)
      }
      return false
    }

    async function reply (type, id, sessionID, answer) {
      try {
        if (type === 'question.asked') {
          if (Array.isArray(answer.answers)) await post('/question/{requestID}/reply', { requestID: id }, { answers: answer.answers })
          else if (answer.reject) await post('/question/{requestID}/reject', { requestID: id }, {})
          return
        }
        if (!['once', 'always', 'reject'].includes(answer.reply)) return
        const payload = { reply: answer.reply }
        if (typeof answer.message === 'string' && answer.message) payload.message = answer.message
        if (await post('/permission/{requestID}/reply', { requestID: id }, payload)) return
        // Older servers: the legacy route.
        const legacy = ctx.client && ctx.client.postSessionIdPermissionsPermissionId
        if (typeof legacy === 'function') {
          await legacy.call(ctx.client, { path: { id: sessionID, permissionID: id }, body: { response: answer.reply } })
        }
      } catch {}
    }

    // Answered in the terminal (or by us): the waiting hook is let go, so
    // the phone drops the request.
    function settled (id) {
      const child = waiting.get(id)
      if (!child) return
      waiting.delete(id)
      // The whole group: the hook's watchdog holds the FIFO open too.
      try { process.kill(-child.pid, 'SIGTERM') } catch { try { child.kill('SIGTERM') } catch {} }
    }

    return {
      event: async ({ event } = {}) => {
        try {
          const type = event && event.type
          const p = (event && event.properties) || {}
          switch (type) {
            case 'session.created':
            case 'session.updated': {
              const info = p.info || {}
              if (info.id && info.parentID) parents.set(info.id, info.parentID)
              if (type === 'session.created' && info.id && !info.parentID) await forward(type, { info: { id: info.id, directory: info.directory, title: info.title } }, info.id)
              return
            }
            case 'session.deleted': {
              const info = p.info || {}
              if (info.id && !parents.has(info.id)) await forward(type, {}, info.id)
              return
            }
            case 'message.updated':
              if (p.info && p.info.id) roles.set(p.info.id, p.info.role)
              if (roles.size > 500) roles.delete(roles.keys().next().value)
              return
            case 'message.part.updated': {
              const part = p.part || {}
              if (part.type === 'text' && !part.synthetic && roles.get(part.messageID) === 'assistant' && typeof part.text === 'string' && part.text.trim()) {
                lastText.set(part.sessionID, cap(part.text, TEXT_CAP))
              }
              return
            }
            case 'session.idle': {
              const text = lastText.get(p.sessionID) || null
              lastText.delete(p.sessionID)
              await forward(type, { sessionID: p.sessionID }, p.sessionID, { last_text: text })
              return
            }
            case 'session.status':
              if (p.status && p.status.type === 'retry') await forward(type, { sessionID: p.sessionID, status: { type: 'retry', attempt: p.status.attempt, message: cap(p.status.message, 300) } }, p.sessionID)
              return
            case 'session.error': {
              const e = p.error || {}
              const data = e.data || {}
              await forward(type, { sessionID: p.sessionID, error: { name: e.name, data: { message: cap(data.message, 300), statusCode: data.statusCode } } }, p.sessionID, { last_text: lastText.get(p.sessionID) || null })
              return
            }
            case 'permission.asked':
            case 'question.asked':
              ask(type, p).catch(() => {})
              return
            case 'permission.replied':
              settled(p.requestID)
              if (p.reply === 'reject') await forward(type, { sessionID: p.sessionID, requestID: p.requestID, reply: p.reply }, p.sessionID)
              return
            case 'question.replied':
            case 'question.rejected':
              settled(p.requestID)
              return
            default:
          }
        } catch {}
      },
      'chat.message': async (input = {}, output = {}) => {
        try {
          const parts = Array.isArray(output.parts) ? output.parts : []
          const text = parts.filter(x => x && x.type === 'text' && !x.synthetic && typeof x.text === 'string').map(x => x.text).join('\n')
          const images = parts.filter(x => x && x.type === 'file' && /^image\//.test(x.mime || '')).length
          await forward('chat.message', { sessionID: input.sessionID, messageID: input.messageID || (output.message && output.message.id) || null, text: cap(text, TEXT_CAP), images }, input.sessionID)
        } catch {}
      },
      'tool.execute.before': async (input = {}, output = {}) => {
        try {
          await forward('tool.execute.before', { tool: input.tool, sessionID: input.sessionID, callID: input.callID, args: output.args }, input.sessionID)
        } catch {}
      },
      'tool.execute.after': async (input = {}, output = {}) => {
        try {
          const md = (output && output.metadata) || {}
          await forward('tool.execute.after', { tool: input.tool, sessionID: input.sessionID, callID: input.callID, args: input.args, title: cap(output.title, 300), output: cap(output.output, OUTPUT_CAP), exit: typeof md.exit === 'number' ? md.exit : null }, input.sessionID)
        } catch {}
      }
    }
  }
}

const server = createPlugin()

// Both loader shapes (OpenCode changed its plugin loader in 1.18.29): the
// default export with `server` and a no-op `setup`. Nothing else is
// exported: older loaders call every exported function as a plugin.
export default { id: 'conductore', server, setup () {} }
