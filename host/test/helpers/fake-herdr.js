'use strict'

// A fake Herdr server on a unix socket, speaking the socket API the way
// Herdr 0.9.1 does (shapes recorded on an isolated server, see
// test/fixtures/herdr-*.json), including its subscription quirks:
//   - any second request on a subscribed connection resets it;
//   - an unknown pane id fails the whole subscribe with pane_not_found;
//   - status changes are pushed only to `pane.agent_status_changed`
//     subscribers of that pane.
// Tests change `state` and call emit()/setStatus().

const net = require('net')
const fs = require('fs')

class FakeHerdr {
  constructor (socket) {
    this.socket = socket
    this.state = {
      workspaces: [{ workspace_id: 'w1', number: 1, label: 'alpha', focused: true, pane_count: 1, tab_count: 1, active_tab_id: 'w1:t1', agent_status: 'idle' }],
      tabs: [{ tab_id: 'w1:t1', workspace_id: 'w1', number: 1, label: '1', focused: true, pane_count: 1, agent_status: 'idle' }],
      panes: [{ pane_id: 'w1:p1', workspace_id: 'w1', tab_id: 'w1:t1', focused: true, cwd: '/work', foreground_cwd: '/work', agent: 'codex', agent_status: 'idle', revision: 0 }],
      agents: [{ agent: 'codex', agent_status: 'idle', workspace_id: 'w1', tab_id: 'w1:t1', pane_id: 'w1:p1', focused: true, state_change_seq: 1, cwd: '/work', foreground_cwd: '/work' }]
    }
    this.requests = []
    this.subscribers = new Set() // { conn, subs }
    this.handlers = {} // method -> (params, conn) => result | throws {code,message}
    this.writes = [] // write methods seen
    this.server = null
  }

  start () {
    try { fs.unlinkSync(this.socket) } catch {}
    this.server = net.createServer(conn => this.onConn(conn))
    return new Promise(resolve => this.server.listen(this.socket, resolve))
  }

  stop () {
    for (const s of this.subscribers) s.conn.destroy()
    this.subscribers.clear()
    return new Promise(resolve => this.server ? this.server.close(() => resolve()) : resolve())
  }

  onConn (conn) {
    let buf = ''
    let sub = null
    conn.setEncoding('utf8')
    conn.on('error', () => {})
    conn.on('close', () => { if (sub) this.subscribers.delete(sub) })
    conn.on('data', chunk => {
      buf += chunk
      let i
      while ((i = buf.indexOf('\n')) !== -1) {
        const line = buf.slice(0, i)
        buf = buf.slice(i + 1)
        let msg
        try { msg = JSON.parse(line) } catch { continue }
        this.requests.push(msg)
        if (sub) { conn.destroy(); return } // one subscribe per connection
        if (msg.method === 'events.subscribe') {
          const list = (msg.params && msg.params.subscriptions) || []
          const missing = list.find(s => s.pane_id && !this.state.panes.some(p => p.pane_id === s.pane_id))
          if (missing) {
            conn.write(JSON.stringify({ id: `${msg.id}:sub:0:probe`, error: { code: 'pane_not_found', message: `pane ${missing.pane_id} not found` } }) + '\n')
            continue
          }
          sub = { conn, subs: list }
          this.subscribers.add(sub)
          conn.write(JSON.stringify({ id: msg.id, result: { type: 'subscription_started' } }) + '\n')
          continue
        }
        this.answer(conn, msg)
      }
    })
  }

  answer (conn, msg) {
    const reply = obj => conn.write(JSON.stringify({ id: msg.id, ...obj }) + '\n')
    try {
      const custom = this.handlers[msg.method]
      if (custom) return reply({ result: custom(msg.params || {}, conn) })
      switch (msg.method) {
        case 'ping': return reply({ result: { type: 'pong', version: '0.9.1', protocol: 22, capabilities: {} } })
        case 'session.snapshot': return reply({ result: { type: 'session_snapshot', snapshot: { version: '0.9.1', protocol: 22, ...JSON.parse(JSON.stringify(this.state)) } } })
        case 'pane.report_metadata':
        case 'agent.prompt':
          this.writes.push(msg)
          return reply({ result: { type: 'ok' } })
        default:
          return reply({ error: { code: 'invalid_request', message: `invalid request: unknown variant \`${msg.method}\`` } })
      }
    } catch (err) {
      reply({ error: { code: err.code || 'error', message: err.message || String(err) } })
    }
  }

  // Pushes a lifecycle event to the subscribers of its type.
  emit (type, data) {
    const event = type.replace('.', '_')
    for (const s of this.subscribers) {
      if (s.subs.some(x => x.type === type)) s.conn.write(JSON.stringify({ event, data: { type: event, ...data } }) + '\n')
    }
  }

  setStatus (paneId, status) {
    for (const p of this.state.panes) if (p.pane_id === paneId) p.agent_status = status
    for (const a of this.state.agents) if (a.pane_id === paneId) { a.agent_status = status; a.state_change_seq = (a.state_change_seq || 0) + 1 }
    const pane = this.state.panes.find(p => p.pane_id === paneId)
    for (const s of this.subscribers) {
      if (s.subs.some(x => x.type === 'pane.agent_status_changed' && x.pane_id === paneId)) {
        s.conn.write(JSON.stringify({ event: 'pane.agent_status_changed', data: { agent: pane && pane.agent, agent_status: status, pane_id: paneId, workspace_id: pane && pane.workspace_id } }) + '\n')
      }
    }
  }

  addPane (pane, agent) {
    this.state.panes.push(pane)
    if (agent) this.state.agents.push(agent)
    this.emit('pane.created', { pane })
  }

  statusSubscriptions () {
    return [...this.subscribers].filter(s => s.subs.some(x => x.type === 'pane.agent_status_changed')).map(s => s.subs.map(x => x.pane_id).sort())
  }
}

module.exports = { FakeHerdr }
