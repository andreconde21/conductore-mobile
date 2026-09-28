'use strict'

// `conductore-hostd talkbawt <command>`: the Talkbawt client's CLI (JSON
// out, like the other commands). Secrets never go in argv: passphrases,
// keys and links the phone sends come on stdin (`-` reads one JSON object).
// The agent-facing commands (`deliver`, `draft`) type only fixed prompts;
// the content itself goes into 0600 files, fenced as untrusted.

const tb = require('./talkbawt')

const USAGE = `usage: conductore-hostd talkbawt <command>

  create --title "…" [--mode thread|handoff] [--from "…"] [--expires 1d]
         [--max-reads N] [--signing [required]] [--passphrase-from-stdin]
         [--server <url>] [--override-secret-scan]
                          text on stdin (after the passphrase line with
                          --passphrase-from-stdin); prints both links
  meta <link> | --id <id> the free check before a read (never counted)
  read <link> | --id <id> [--since N] [--wait S] [--passphrase-from-stdin]
  post <link> | --id <id> [--from "…"] [--passphrase-from-stdin]
                          text on stdin; signed when a key is known
  watch [--wait 50] [--id <id,id>]
                          new replies and readers on the threads you own
                          (one held POST /api/watch per server)
  revoke <owner link> | --id <id>
                          saves the access log, then revokes
  mine [--server <url>]   your threads on the server (creator key header)
  list | forget <id>      threads this machine holds (links redacted)
  config [--server <url> | --default] [--creator-key-from-stdin]
  deliver <sessionId> [--allow-unknown-mode] [--paired-with "…" --until "…"]
                          {title, mode, messages} on stdin: writes a fenced
                          file and types the fixed "untrusted data" prompt
  draft <sessionId> [--summary] [--timeout-ms 60000]
                          ask the agent for a handoff draft (or, with
                          --summary, Claude over its transcript, no tools)
  draft-status <draftId>  the agent's draft once it is written
  reply <sessionId> --after <ms>
                          the agent's last reply since then (paired mode)
  serve [--port 0] [--host 127.0.0.1] [--base-url <url>] [--detach]
  serve --status | --stop the bundled Talkbawt server (Node 22.5+)

  "-" in place of a link: one JSON object on stdin with link or id,
  passphrase, text, from, signingKey, since, wait.
`

function write (obj) {
  process.stdout.write(JSON.stringify(obj) + '\n')
}

function failWith (err) {
  const body = { error: err.message, code: err.code || 'failed' }
  for (const k of ['status', 'findings', 'retryAfter']) if (err[k] !== undefined) body[k] = err[k]
  write(body)
  return 1
}

const intFlag = (flags, name, fallback) => {
  if (flags[name] === undefined) return fallback
  const n = Number(flags[name])
  if (!Number.isFinite(n) || n < 0) throw new tb.TalkbawtError('bad-flag', `--${name} must be a non-negative number`)
  return Math.floor(n)
}

// stdin as JSON for "-", else { passphrase?, text? } per the flags.
async function input (h, flags, { json, wantText }) {
  if (json) {
    const raw = await h.readStdin()
    try {
      const v = JSON.parse(raw)
      if (v && typeof v === 'object') return v
    } catch {}
    throw new tb.TalkbawtError('bad-input', 'stdin must hold one JSON object')
  }
  if (!flags['passphrase-from-stdin'] && !wantText) return {}
  const raw = (await h.readStdin()).replace(/\r\n?/g, '\n')
  if (!flags['passphrase-from-stdin']) return { text: raw.replace(/\n$/, '') }
  const nl = raw.indexOf('\n')
  const passphrase = (nl === -1 ? raw : raw.slice(0, nl)).trim()
  const text = nl === -1 ? '' : raw.slice(nl + 1).replace(/\n$/, '')
  return { passphrase, text }
}

// The link or id a command works on: --id, a positional link, or "-".
function linkArgs (flags, positional, stdin) {
  const id = stdin.id || (typeof flags.id === 'string' ? flags.id : undefined)
  const link = stdin.link || (positional[0] && positional[0] !== '-' ? positional[0] : undefined)
  if (!id && !link) throw new tb.TalkbawtError('bad-input', 'give a link, --id <id>, or "-" with {"link"} on stdin')
  return { id, link }
}

async function run (args, h) {
  const [sub, ...rest] = args
  const { flags, positional } = h.parseFlags(rest)
  const json = positional[0] === '-'
  switch (sub) {
    case 'create': {
      const s = await input(h, flags, { json, wantText: true })
      return tb.create({
        server: s.server || (typeof flags.server === 'string' ? flags.server : undefined),
        title: s.title ?? flags.title,
        mode: s.mode ?? (typeof flags.mode === 'string' ? flags.mode : undefined),
        from: s.from ?? flags.from,
        text: s.text,
        expires: s.expires ?? (typeof flags.expires === 'string' ? flags.expires : undefined),
        passphrase: s.passphrase,
        maxReads: s.maxReads ?? (flags['max-reads'] !== undefined ? Number(flags['max-reads']) : undefined),
        signing: s.signing ?? (flags.signing === 'required' ? 'required' : flags.signing ? true : undefined),
        overrideSecretScan: !!(s.overrideSecretScan ?? flags['override-secret-scan'])
      })
    }
    case 'meta': {
      const s = await input(h, flags, { json })
      return tb.meta({ ...linkArgs(flags, positional, s), passphrase: s.passphrase })
    }
    case 'read': {
      const s = await input(h, flags, { json })
      return tb.read({ ...linkArgs(flags, positional, s), passphrase: s.passphrase, since: s.since ?? intFlag(flags, 'since', 0), wait: s.wait ?? intFlag(flags, 'wait', 0) })
    }
    case 'post': {
      const s = await input(h, flags, { json, wantText: true })
      return tb.post({ ...linkArgs(flags, positional, s), passphrase: s.passphrase, text: s.text, from: s.from ?? flags.from, signingKey: s.signingKey, overrideSecretScan: !!(s.overrideSecretScan ?? flags['override-secret-scan']) })
    }
    case 'watch':
      return tb.watch({ wait: intFlag(flags, 'wait', 50), ids: typeof flags.id === 'string' ? flags.id.split(',') : undefined })
    case 'revoke': {
      const s = await input(h, flags, { json })
      return tb.revoke(linkArgs(flags, positional, s))
    }
    case 'mine':
      return tb.mine({ server: typeof flags.server === 'string' ? flags.server : undefined })
    case 'list': case 'ls':
      return tb.list()
    case 'forget':
      return tb.forget({ id: positional[0] })
    case 'config': {
      let creatorKey
      if (flags['creator-key-from-stdin']) creatorKey = (await h.readStdin()).trim()
      const server = flags.default ? '' : typeof flags.server === 'string' ? flags.server : undefined
      return tb.config({ server, creatorKey })
    }
    case 'deliver': return deliver(positional[0], flags, h)
    case 'draft': return draft(positional[0], flags, h)
    case 'draft-status': {
      const id = positional[0]
      const r = tb.draftStatus(id, null)
      const found = await h.findAgent(r.sessionId)
      return tb.draftStatus(id, found.agent ? found.agent.state : 'ended')
    }
    case 'reply': return reply(positional[0], flags, h)
    case 'serve': return serve(rest, flags, h)
    case 'help': case '--help': case '-h': case undefined:
      process.stdout.write(USAGE)
      return { __exit: sub === undefined ? 1 : 0 }
    default:
      throw new tb.TalkbawtError('unknown-command', `unknown talkbawt command ${sub}\n${USAGE}`)
  }
}

// Writes the preview the user saw to a fenced 0600 file and types the fixed
// frame. Refused for agents that run tools without asking, and (unless the
// user confirmed it on the phone) when the mode is unknown.
async function deliver (sessionId, flags, h) {
  if (!sessionId) throw new tb.TalkbawtError('bad-input', 'usage: talkbawt deliver <sessionId> ({title, mode, messages} on stdin)')
  let content
  try { content = JSON.parse(await h.readStdin()) } catch {}
  if (!content || typeof content !== 'object' || !Array.isArray(content.messages) || !content.messages.length) {
    throw new tb.TalkbawtError('bad-input', 'stdin must hold {"title", "mode", "messages": [{seq, from, at, verified, text}]}')
  }
  const found = await h.inputAgent(sessionId)
  if (found.error) throw new tb.TalkbawtError('agent', found.error)
  const mode = found.agent.permissionMode || null
  if (mode && tb.UNSAFE_PERMISSION_MODES.has(mode)) {
    throw new tb.TalkbawtError('unsafe-permission-mode', `the agent runs in ${mode} mode, where it acts without asking; switch it to default or plan mode first`)
  }
  if (!mode && !flags['allow-unknown-mode']) {
    throw new tb.TalkbawtError('permission-mode-unknown', 'this agent has not reported its permission mode yet; confirm it is not in an auto-approve mode')
  }
  const { id, file } = tb.writeInbox(content)
  const paired = typeof flags['paired-with'] === 'string'
  const prompt = paired
    ? tb.pairedPrompt(file, flags['paired-with'], typeof flags.until === 'string' ? flags.until : 'the pairing ends')
    : tb.inboxPrompt(file, content.mode)
  const r = await h.sendText(found.agent, prompt)
  if (r.error) throw new tb.TalkbawtError('send', r.error)
  tb.tlog(`delivered ${content.messages.length} message(s) to ${sessionId} as ${file}${paired ? ' (paired)' : ''}`)
  return { ok: true, id, file, sessionId, permissionMode: mode, chars: prompt.length, via: r.via }
}

async function draft (sessionId, flags, h) {
  if (!sessionId) throw new tb.TalkbawtError('bad-input', 'usage: talkbawt draft <sessionId> [--summary]')
  if (flags.summary) {
    const found = await h.findAgent(sessionId)
    if (found.error) throw new tb.TalkbawtError('agent', found.error)
    const file = found.agent.transcriptPath
    if (!file) throw new tb.TalkbawtError('no-transcript', 'no transcript recorded for this session yet')
    let entries
    try { entries = h.readTranscript(file, { tailBytes: 512 * 1024 }).entries } catch (err) {
      throw new tb.TalkbawtError('no-transcript', `cannot read the transcript: ${err.message}`)
    }
    return tb.summaryDraft({ entries, timeoutMs: intFlag(flags, 'timeout-ms', 60000), lockFile: h.lockFile('talkbawt-draft.lock') })
  }
  // The agent drafts only when it is free to: a busy one would get the
  // request queued behind its turn, so the phone falls back to --summary.
  const found = await h.inputAgent(sessionId)
  if (found.error) throw new tb.TalkbawtError('agent', found.error)
  if (found.agent.state !== 'waiting_input') {
    throw new tb.TalkbawtError('busy', 'the agent is working; use the summary instead, or wait until its turn ends')
  }
  const d = tb.startDraft(sessionId)
  const r = await h.sendText(found.agent, d.prompt)
  if (r.error) throw new tb.TalkbawtError('send', r.error)
  return { ok: true, via: 'agent', id: d.id, file: d.file }
}

async function reply (sessionId, flags, h) {
  if (!sessionId) throw new tb.TalkbawtError('bad-input', 'usage: talkbawt reply <sessionId> --after <ms>')
  const after = intFlag(flags, 'after', 0)
  const found = await h.findAgent(sessionId)
  if (found.error) throw new tb.TalkbawtError('agent', found.error)
  const a = found.agent
  if (!a.transcriptPath) return { ok: true, ready: false, state: a.state }
  let entries = []
  try { entries = h.readTranscript(a.transcriptPath, { tailBytes: 512 * 1024 }).entries } catch {}
  const text = tb.lastReplyAfter(entries, after)
  const idle = a.state === 'waiting_input' || a.state === 'ended'
  return { ok: true, ready: idle && !!text, state: a.state, permissionMode: a.permissionMode || null, ...(idle && text ? { text } : {}) }
}

async function serve (rest, flags, h) {
  const sv = require('./talkbawt-serve')
  if (flags.status) return sv.status()
  if (flags.stop) return sv.stop()
  const opts = {
    port: flags.port !== undefined ? sv.checkPort(flags.port) : 0,
    host: typeof flags.host === 'string' ? flags.host : '127.0.0.1',
    baseUrl: typeof flags['base-url'] === 'string' ? flags['base-url'] : undefined
  }
  if (flags.detach) {
    // Checked here too, so an old Node fails with the reason, not a timeout.
    const node = sv.checkNode()
    if (!node.ok) throw new tb.TalkbawtError('node-too-old', node.reason)
    sv.checkHost(opts.host)
    const r = await sv.detach(rest)
    return r.error ? { __exit: 1, ...r } : r
  }
  const s = await sv.start(opts)
  write({ ok: true, pid: s.pid, url: s.url, localUrl: s.localUrl, host: s.host, port: s.port, db: s.db })
  process.stdout.on('error', () => {})
  for (const sig of ['SIGTERM', 'SIGINT', 'SIGHUP']) {
    process.once(sig, () => { s.close().then(() => process.exit(0)) })
  }
  return { __keepRunning: true }
}

// Resolves the exit code (null keeps the process running: `serve`).
async function main (args, h) {
  let res
  try {
    res = await run(args, h)
  } catch (err) {
    if (err instanceof tb.TalkbawtError) return failWith(err)
    return failWith(Object.assign(new Error(err.message), { code: 'failed' }))
  }
  if (res && res.__keepRunning) return null
  if (res && res.__exit !== undefined) {
    const { __exit, ...rest } = res
    if (Object.keys(rest).length) write(rest)
    return __exit
  }
  write(res)
  return 0
}

module.exports = { main, USAGE }
