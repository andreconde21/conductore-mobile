#!/usr/bin/env node
'use strict'
// What the phone pays per companion command: wall time of one cold CLI run
// (what an SSH exec costs on the host) and the reply's bytes.
//
//   node host/bench-phone.js [runs]      (default 15 runs per command)
//
// Runs against a throwaway HOME / CONDUCTORE_HOME / CLAUDE_CONFIG_DIR (never
// your real ~/.conductore or its daemon): 20 agents with usage, a ~2,000-entry
// transcript and 60 synthetic usage transcripts. Env: AGENTS=N, USAGE_FILES=N,
// REAL_CLAUDE=<dir> (scan that Claude config dir's projects read-only for
// `usage`; the cache stays in the temp dir), IDLE=<s> (daemon idle CPU/RSS).
const fs = require('fs'), os = require('os'), path = require('path')
const { execFileSync, spawnSync, spawn } = require('child_process')
const HOST = __dirname; const RUNS = Number(process.argv[2] || 15)
const HOSTD = path.join(HOST, 'bin/conductore-hostd'), HOOK = path.join(HOST, 'bin/conductore-hook'), SL = path.join(HOST, 'bin/conductore-statusline')
const T = fs.mkdtempSync(path.join(os.tmpdir(), 'cnd-pb-'))
const env = { ...process.env, HOME: T, CONDUCTORE_HOME: path.join(T, 'c'), CONDUCTORE_SOCKET: path.join(T, 'c', 'hostd.sock'), CLAUDE_CONFIG_DIR: path.join(T, 'claude'), CODEX_HOME: path.join(T, 'codex'), TMUX_TMPDIR: T }
for (const k of Object.keys(env)) if (/^(HERDR_|TMUX$|TMUX_PANE)/.test(k)) delete env[k]
if (process.env.REAL_CLAUDE) env.CLAUDE_CONFIG_DIR = process.env.REAL_CLAUDE
const hook = (ev, obj) => spawnSync(HOOK, [ev], { input: JSON.stringify(obj) + '\n', env })
const cleanup = () => { try { execFileSync('node', [HOSTD, 'stop'], { env, stdio: 'ignore' }) } catch {} ; fs.rmSync(T, { recursive: true, force: true }) }
process.on('exit', cleanup)
// Synthetic transcript: ~2000 entries, several MB.
const proj = path.join(T, 'claude', 'projects', '-tmp-proj'); fs.mkdirSync(proj, { recursive: true })
function transcript (file, n, day0) {
  const lines = []
  for (let i = 0; i < n; i++) {
    const ts = new Date(day0 + i * 30000).toISOString()
    if (i % 4 === 0) lines.push({ type: 'user', uuid: 'u' + i, timestamp: ts, message: { role: 'user', content: 'please do step ' + i + ' ' + 'x'.repeat(200) } })
    else if (i % 4 === 1) lines.push({ type: 'assistant', uuid: 'a' + i, timestamp: ts, requestId: 'r' + i, message: { id: 'm' + i, role: 'assistant', model: 'claude-opus-4', usage: { input_tokens: 1000, output_tokens: 300, cache_read_input_tokens: 50000, cache_creation_input_tokens: 2000 }, content: [{ type: 'thinking', thinking: 't'.repeat(1500) }, { type: 'tool_use', id: 't' + i, name: 'Bash', input: { command: 'ls -la ' + 'y'.repeat(300) } }] } })
    else if (i % 4 === 2) lines.push({ type: 'user', uuid: 'r' + i, timestamp: ts, message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 't' + (i - 1), content: 'z'.repeat(3000) }] } })
    else lines.push({ type: 'assistant', uuid: 'b' + i, timestamp: ts, requestId: 'q' + i, message: { id: 'n' + i, role: 'assistant', model: 'claude-opus-4', usage: { input_tokens: 10, output_tokens: 500 }, content: [{ type: 'text', text: 'Done with step ' + i + '. ' + 'w'.repeat(800) }] } })
  }
  fs.writeFileSync(file, lines.map(l => JSON.stringify(l)).join('\n') + '\n')
}
const tfile = path.join(proj, 'sess-00.jsonl'); transcript(tfile, 2000, Date.now() - 2000 * 30000)
if (!process.env.REAL_CLAUDE) for (let d = 1; d <= Number(process.env.USAGE_FILES || 60); d++) transcript(path.join(proj, `old-${d}.jsonl`), 400, Date.now() - d * 86400000 / 2)
// 20 agents with usage and last messages.
const NA = Number(process.env.AGENTS || 20)
for (let i = 0; i < NA; i++) {
  const sid = 'sess-' + String(i).padStart(2, '0')
  const base = { session_id: sid, cwd: '/tmp/proj' + i, transcript_path: i === 0 ? tfile : path.join(proj, sid + '.jsonl') }
  hook('SessionStart', { ...base, hook_event_name: 'SessionStart' })
  hook('UserPromptSubmit', { ...base, hook_event_name: 'UserPromptSubmit', prompt: 'do the thing ' + i })
  hook('PreToolUse', { ...base, hook_event_name: 'PreToolUse', tool_name: 'Bash', tool_input: { command: 'npm test ' + 'a'.repeat(100) } })
  if (i % 2) hook('Stop', { ...base, hook_event_name: 'Stop', last_assistant_message: 'All done. '.repeat(60) })
  spawnSync(SL, [], { input: JSON.stringify({ session_id: sid, cwd: base.cwd, model: { display_name: 'Opus' }, context_window: { used_percentage: 42.5, total_input_tokens: 85000, context_window_size: 200000 }, rate_limits: { five_hour: { used_percentage: 23.5, resets_at: 1738425600 }, seven_day: { used_percentage: 50, resets_at: 1738425600 } } }), env })
}
const run = args => { const t = process.hrtime.bigint(); const r = spawnSync('node', [HOSTD, ...args], { env, maxBuffer: 64 << 20 }); return { ms: Number(process.hrtime.bigint() - t) / 1e6, bytes: r.stdout.length, out: r.stdout.toString(), code: r.status } }
const med = a => { const s = [...a].sort((x, y) => x - y); return s[Math.floor(s.length / 2)] }
function bench (label, args, runs = RUNS) {
  const r = []; let last
  for (let i = 0; i < runs; i++) { last = run(typeof args === 'function' ? args() : args); r.push(last.ms) }
  console.log(`${label.padEnd(34)} median ${med(r).toFixed(0).padStart(5)} ms  min ${Math.min(...r).toFixed(0).padStart(5)}  bytes ${String(last.bytes).padStart(8)}  exit ${last.code}`)
  return last
}
run(['status'])
bench('version', ['version'])
const st = bench('status', ['status'])
const seq = JSON.parse(st.out).seq
const etag = JSON.parse(st.out).etag
if (etag) bench('status --etag (unchanged)', ['status', '--etag', etag])
bench('status --gzip', ['status', '--gzip'])
bench('events --since seq (timeout 0)', ['events', '--since', String(seq), '--timeout', '0'], 5)
bench('events --since 0 (snapshot)', ['events', '--since', '0', '--timeout', '0'], 5)
const first = bench('transcript first (tail 256K)', ['transcript', 'sess-00', '--tail-bytes', String(256 * 1024)])
const off = JSON.parse(first.out).offset
bench('transcript first --gzip', ['transcript', 'sess-00', '--tail-bytes', String(256 * 1024), '--gzip'])
bench('transcript --since (no change)', ['transcript', 'sess-00', '--since', String(off)])
bench('transcript --before (older page)', ['transcript', 'sess-00', '--before', String(JSON.parse(first.out).start)])
bench('digest', ['digest'], 5)
bench('digest --gzip', ['digest', '--gzip'], 5)
// usage: cold = fresh cache each run
const cache = path.join(env.CONDUCTORE_HOME, 'usage-cache.json')
const cold = []
let u
for (let i = 0; i < 3; i++) { try { fs.rmSync(cache) } catch {} ; u = run(['usage', '--days', '31']); cold.push(u.ms) }
let uj = {}; try { uj = JSON.parse(u.out) } catch {}
console.log(`usage cold (1st call, no cache)       median ${med(cold).toFixed(0)} ms bytes ${u.bytes} partial=${uj.scan && uj.scan.partial} files=${uj.scan && JSON.stringify(uj.scan).slice(0,200)}`)
// calls until complete
try { fs.rmSync(cache) } catch {}
let calls = 0, total = 0
for (; calls < 400; ) { u = run(['usage', '--days', '31']); calls++; total += u.ms; uj = JSON.parse(u.out); if (!uj.scan || !uj.scan.partial) break }
console.log(`usage cold fill: ${calls} calls, ${total.toFixed(0)} ms total`)
bench('usage warm', ['usage', '--days', '31'], 7)
bench('usage warm --gzip', ['usage', '--days', '31', '--gzip'], 7)
bench('usage warm --hourly --sessions', ['usage', '--days', '31', '--hourly', '--sessions'], 5)
if (process.env.IDLE) {
  const pid = Number(fs.readFileSync(path.join(env.CONDUCTORE_HOME, 'hostd.pid'), 'utf8'))
  const cpu = () => { const f = fs.readFileSync(`/proc/${pid}/stat`, 'utf8').split(') ')[1].split(' '); return Number(f[11]) + Number(f[12]) }
  const rss = () => (/VmRSS:\s+(\d+)/.exec(fs.readFileSync(`/proc/${pid}/status`, 'utf8')) || [])[1]
  const c0 = cpu(); const t0 = Date.now()
  const end = Date.now() + Number(process.env.IDLE) * 1000; while (Date.now() < end) spawnSync('sleep', ['1'])
  console.log(`daemon idle ${((Date.now()-t0)/1000).toFixed(0)} s: ${cpu() - c0} CPU ticks, RSS ${rss()} kB`)
}
