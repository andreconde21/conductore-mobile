# Conductore host companion

A small daemon plus two tiny sh clients (a Claude Code hook and a statusline)
that run on the machine where your agents run. It turns Claude Code hook
events into a live, machine-readable view of every agent (working, waiting for
input, waiting for permission, ended) and lets a phone answer permission
prompts. The phone talks to it over plain SSH exec commands: no ports, no
relay, nothing listening on the network.

    Claude Code ──hooks──────▶ conductore-hook (sh) ─────┐ spool dir
    Claude Code ──statusLine─▶ conductore-statusline (sh)┘ (one file per event)
                                                          ▼
                                                   conductore-hostd (Node daemon)
                                                          ▲ unix socket
    phone ──ssh user@host "conductore-hostd status|events|decide|transcript|send|ports|usage|summarize|guide"

Built to cost nothing while agents work: a hook event is one `cat` and one
`ln` (about 2.5 ms and 2 MB, no Node start), and the daemon sleeps until a
file appears. See Footprint.

Requirements: Node.js 18 or newer for the daemon and CLI (Claude Code already
needs it), Linux or macOS. The hook and statusline need only POSIX `sh`,
`cat`, `ln`, `mkfifo`, `date` and `rm`. No npm dependencies. Optional: tmux
and/or Herdr for "focus".

## Install

```sh
host/install.sh          # copies host/ to ~/.local/share/conductore, links
                         # ~/.local/bin/conductore-{hostd,hook,statusline},
                         # registers hooks and the statusline
host/install.sh --link   # dev: link ~/.local/bin straight at this checkout
host/install.sh --uninstall
```

`install.sh` ends by running `conductore-hostd install`, which merges nine
hook handlers into `~/.claude/settings.json` (backup in `settings.json.bak`),
wires the statusline (see Usage below) and records the path of `node` for
the sh clients (`~/.conductore/node`: hooks may run with a PATH without node).
Existing hooks are left untouched; running it again changes nothing and does
not rewrite the file. Upgrading from 0.3 is the same command: the Node hook
entries (same file name) are replaced in place and a
`conductore-hostd statusline [--chain '…']` line becomes
`conductore-statusline [--chain '…']`, keeping the command it wraps. Check with:

```sh
conductore-hostd doctor
```

The daemon is not a service. The first hook event after install (or after the
daemon exits) starts it detached (at most one attempt per 10 s); it exits by
itself after 6 h without any event or request. Events that arrive while it is
down wait in the spool and are applied, in order, when it starts; `status`
starts it when the spool is not empty. `conductore-hostd stop` stops it;
`uninstall` removes the hooks and stops it. Files (all in 0700 directories):

| Path | Purpose |
| --- | --- |
| `$XDG_RUNTIME_DIR/conductore/hostd.sock` (else `~/.conductore/hostd.sock`) | socket, mode 0600 |
| `~/.conductore/spool/` | events and statusline reports waiting for the daemon |
| `~/.conductore/tmp/` | staging files of the sh clients, FIFOs of waiting permission prompts |
| `~/.conductore/usage/` | statusline holds and parked reports (see Usage) |
| `~/.conductore/hostd.pid` | lock and pid of the running daemon |
| `~/.conductore/node` | node binary the sh clients start the daemon with |
| `~/.conductore/spawn.at` | time of the last start attempt |
| `~/.conductore/state.json` | atomic snapshot of the state, read by `status` when the daemon is down |
| `~/.conductore/ports.json` | listening ports and the seq each first appeared at (`ports`) |
| `~/.conductore/usage-cache.json` | `usage`: per-transcript offsets and daily token sums, last 31 days (about 1.3 MB for 1,100 transcripts) |
| `~/.conductore/summarize.lock` | pid of the running `summarize` (one at a time; never the text) |
| `~/.conductore/guide.lock` | pid of the running `guide` (one at a time; never the request) |
| `~/.conductore/hostd.log` | log, rotated once at 1 MB to `hostd.log.1` |
| `~/.conductore/always-rules.json` | record of every rule added through an "always" decision |

Environment: `CONDUCTORE_PERMISSION_TIMEOUT` (seconds the hook waits for the
phone, default 120, read by the hook), `CONDUCTORE_IDLE_EXIT_S` (daemon idle
exit, default 21600 = 6 h, 0 = never), `CONDUCTORE_USAGE_THROTTLE_MS`
(default 10000, see Usage), `CONDUCTORE_LOG=debug` (log every state change),
`CONDUCTORE_HOME`, `CONDUCTORE_SOCKET`, `CONDUCTORE_CLAUDE_SETTINGS`
(overrides, mainly for tests; with `CONDUCTORE_HOME` set the socket defaults
to `<home>/hostd.sock`). The daemon reads its environment when it starts, from
whichever client started it.

### PATH for the phone's SSH shell

SSH exec channels get a non-login shell whose PATH often lacks `~/.local/bin`.
The phone should run commands as
`sh -c 'PATH="$HOME/.local/bin:$PATH" exec conductore-hostd status'`
(same trick the app already uses for Herdr) or call the binary by absolute path.

## How it works

`conductore-hostd install` registers `conductore-hook <Event>` for
SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, PermissionRequest,
Notification, Stop, SubagentStop and SessionEnd, all with an empty matcher.
Every handler except PermissionRequest is `async: true`, so it can never stall
Claude Code; SessionEnd gets a 5 s timeout because Claude Code only waits
briefly on exit.

The hook (`bin/conductore-hook`, POSIX sh) never parses the JSON. It writes a
few `key=value` header lines (event name, pid, `$TMUX`, `$TMUX_PANE`,
`$HERDR_WORKSPACE_ID`, `$HERDR_TAB_ID`, `$HERDR_PANE_ID`, `$HERDR_AGENT_NAME`)
and then Claude Code's stdin untouched into `~/.conductore/tmp/`, hard-links
the finished file into `~/.conductore/spool/` (atomic, never overwrites; `mv`
on filesystems without hard links) and exits 0 without output. If the pid
file shows no live daemon it starts one in the background first. The format
is documented in `lib/spool.js`.

The daemon watches the spool (`fs.watch`: inotify on Linux, FSEvents on
macOS; it also scans it at start and before answering `status` / `events`),
takes entries oldest first, removes them, and adds the location: `herdr`
straight from the header when Herdr's variables were set (Herdr exports
`HERDR_WORKSPACE_ID`, `HERDR_TAB_ID`, `HERDR_PANE_ID`), else completed or
found from one `herdr pane list` (matched by pane id, or by the Claude
session id Herdr records per pane; cached 10 s, not retried for 5 min when
herdr is missing, never used for agents in tmux or already known not to be
in Herdr); the cwd is never used as a location. `tmux` by asking the pane's tmux server
(`tmux -S <socket from $TMUX> display-message -p -t <pane>`: session, window
index, pane id, window name), cached 5 s per pane so bursts of tool events
cost one `tmux`. It reduces events into one record per `session_id`, bumps a
`seq` counter on every change, keeps the last 1000 change records for
long-polling, and writes `state.json` (debounced 1 s, atomic rename). Agents
whose session ended more than an hour ago are pruned.

### Agent states

| state | set by |
| --- | --- |
| `working` | UserPromptSubmit, PreToolUse, PostToolUse, a permission decision |
| `waiting_input` | SessionStart, Stop, Notification `idle_prompt` / `agent_needs_input`, PreToolUse of AskUserQuestion or ExitPlanMode |
| `needs_permission` | PermissionRequest (until decided), Notification `permission_prompt`, a PermissionRequest that timed out (the prompt is now in the terminal) |
| `ended` | SessionEnd |

Events carrying `agent_id` (subagents) never move the parent to a waiting state.

## CLI and JSON contract

Every command prints one JSON document on stdout and exits 0, or prints
`{"error":"..."}` and exits 1. `events` prints one JSON object per line.

### `conductore-hostd status`

```json
{
  "version": 1,
  "seq": 42,
  "source": "daemon",
  "agents": [
    {
      "sessionId": "0f2c…",
      "name": "reviewer",
      "cwd": "/home/andre/Projects/Foo",
      "transcriptPath": "/home/andre/.claude/projects/-home-andre-Projects-Foo/0f2c….jsonl",
      "tmux": { "session": "main", "window": 2, "paneId": "%5", "windowName": "reviewer" },
      "herdr": { "workspaceId": "w1", "tabId": "w1:t1", "paneId": "w1:p1", "name": null },
      "state": "needs_permission",
      "lastEvent": "PermissionRequest",
      "lastToolName": "Bash",
      "lastMessage": null,
      "startedAt": 1790286139217,
      "updatedAt": 1790286139530,
      "endedAt": null,
      "usage": { "contextUsedPct": 42.5, "contextTokens": 85000, "windowLabel": "200k",
                 "limits": [ { "label": "5h", "usedPct": 23.5, "resetsAt": 1738425600000 } ] },
      "pending": [
        {
          "id": "3671d8715ac1",
          "toolName": "Bash",
          "summary": "rm -rf node_modules",
          "toolInput": { "command": "rm -rf node_modules", "description": "Remove node_modules" },
          "createdAt": 1790286139530
        }
      ]
    }
  ]
}
```

* `name`: Herdr agent name, else the tmux window name (unless it is a generic
  process name like `node` or `claude`), else the basename of `cwd`. Leading
  status glyphs from Claude Code's terminal title (`⚠`, `✳`, `●`, emoji,
  spinner dots) are stripped first.
* `tmux` / `herdr` are `null` when unknown. `transcriptPath` is the
  `transcript_path` of the latest hook event (null until one carried it).
* `lastMessage`: last assistant text (Stop), notification text, or the
  question of an AskUserQuestion; capped at 500 chars.
* `pending[].summary`: one line (command, file path, URL, …) capped at 200
  chars. `toolInput` is the raw input; above 4 KB it is replaced by
  `{"_truncated":true,"preview":"…"}`.
* `usage` is present only once the statusline reported something for the
  session (see Usage).
* `source` is `daemon`, `snapshot` (daemon down, read from `state.json`, with
  `writtenAt`) or `none` (never ran). Timestamps are Unix milliseconds.
* Agents are sorted by `updatedAt`, newest first.

### `conductore-hostd events --since <seq> [--timeout 55]`

Long-poll. Holds the SSH exec channel open until something changes, then
prints every change since `seq` (one per line) and exits. If changes newer
than `seq` already exist, it prints them and exits at once. Lines:

```json
{"seq":43,"type":"change","sessionId":"0f2c…","reason":"Stop","agent":{ …full agent as in status… }}
{"seq":44,"type":"remove","sessionId":"0f2c…","reason":"prune","agent":null}
{"type":"timeout","seq":43}
{"type":"snapshot","version":1,"seq":43,"agents":[ … ]}
```

* `change` carries the complete agent; replace the phone's copy by `sessionId`.
* `timeout`: nothing happened within `--timeout` seconds (default 55, max 600).
  Poll again from the printed `seq`.
* `snapshot`: the cursor is not covered by the daemon's buffer (it restarted
  or the phone was away for more than 1000 changes). Replace everything and
  continue from its `seq`.
* `reason` is the hook event name, `decision:<allow|deny|always|timeout|gone>`,
  `usage` (only the `usage` field changed) or `prune`.

Suggested loop on the phone: `status` once, then `events --since <seq>` in a
loop, reconnecting on SSH errors.

### `conductore-hostd decide <requestId> allow|deny|always [--message "..."]`

```json
{"ok":true,"requestId":"3671d8715ac1","decision":"allow","sessionId":"0f2c…"}
```

Unblocks the waiting hook. Errors (exit 1): `unknown request <id>` (already
decided, timed out, or never existed) and `request expired; answer it in the
terminal` (the hook process is gone). `--message` is passed to Claude on deny.

### `conductore-hostd focus <sessionId>`

Runs `herdr agent focus <paneId>` when the agent has a Herdr pane, else
`tmux select-window -t <session>:<window>` and `tmux select-pane -t <paneId>`.
Prints `{"ok":true,"via":"tmux","target":"main:2","paneId":"%5"}`.

### `conductore-hostd transcript <sessionId> [--since <offset> | --before <offset>] [--tail-bytes N] [--max-bytes 262144]`

Reads the session's Claude Code transcript (JSONL) for the phone's chat view.

```json
{"sessionId":"0f2c…","offset":183422,"size":183422,"start":0,"skipped":0,
 "agent":{"name":"Foo","state":"working","lastMessage":null,"startedAt":1790286139217,"updatedAt":1790286139530,"endedAt":null,"pending":[]},
 "entries":[
  {"type":"user","uuid":"u1","parentUuid":null,"timestamp":"2026-09-25T10:00:00.000Z","isSidechain":false,
   "message":{"role":"user","content":"fix the failing test"}},
  {"type":"assistant","uuid":"a1","parentUuid":"u1","timestamp":"…","isSidechain":false,
   "message":{"role":"assistant","model":"claude-…","content":[
     {"type":"thinking","hasText":true},
     {"type":"text","text":"Running the suite first."},
     {"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"npm test"}}]}},
  {"type":"user","uuid":"u2","parentUuid":"a1","timestamp":"…","isSidechain":false,
   "message":{"role":"user","content":[
     {"type":"tool_result","tool_use_id":"toolu_1","is_error":true,"content":"Exit code 1\n…","truncated":true}]}},
  {"type":"summary","summary":"Fix failing test","leafUuid":"a1"}
]}
```

* `agent` is the session's live status (fields as in `status`, `pending`
  included), so one poll refreshes both the thread and the header.
* Without `--since` it returns the last `--tail-bytes` (default: `--max-bytes`)
  of the file; `start` is the byte offset of the first line returned, so
  `--before <start>` pages backwards (it returns the whole lines in the
  `--max-bytes` window that ends there, with a new `start`; `start` 0 means
  the beginning of the file).
* `--since <offset>` continues from a previous `offset`. Only whole lines are
  returned: a line still being written stays for the next call, and `offset`
  points at its first byte. At most `--max-bytes` (default 256 KB, max 4 MB)
  are read per call; poll again until `offset` equals `size`.
* `reset: true`: `--since` was past the end (the file was replaced), so this
  is a fresh tail read. `oversized: true`: one line was longer than
  `--max-bytes` and was skipped.
* Kept line types: `user`, `assistant`, `system` (`subtype`, `content`
  capped at 500 chars, `level`) and `summary`. Attachments, queue
  operations, file-history snapshots, cost state and other bookkeeping lines
  are dropped. `isMeta`, `isCompactSummary` and `isApiErrorMessage` are
  passed through when set.
* Content blocks: `text` (capped at 32 KB, `truncated` when cut), `thinking`
  (text never sent, only `hasText`), `tool_use` (`id`, `name`, `input`; long
  string fields cut to 1 KB once the input exceeds 4 KB, else
  `{"_truncated":true,"preview":"…"}`), `tool_result` (`tool_use_id`,
  `is_error`, text `content` capped at 4 KB, `images` = number of images
  dropped), `image` (`{"omitted":true,"mediaType":…}`).
* Errors: `unknown session <id>`, `no transcript recorded for this session
  yet …`, `transcript not found: <path>`.

### `conductore-hostd send <sessionId> [--text "..." | --text-b64 <base64>] [--no-enter]`

Types a prompt into the agent's live pane and presses Enter, so the running
Claude Code session receives it exactly as if typed in the terminal. The
text comes from `--text`, `--text-b64` (what the phone uses: no quoting
issues) or stdin; at most 100 000 characters.

```json
{"ok":true,"sessionId":"0f2c…","via":"tmux","paneId":"%5","chars":24,"enter":true}
```

* Herdr pane first: `herdr agent prompt <paneId> <text>` (Herdr's own
  submit, multiline-safe; it refuses an agent that is blocked on a prompt).
  With `--no-enter`: `herdr pane send-text`. If Herdr fails for another
  reason and the agent also has a tmux pane, tmux is tried.
* tmux: single line `tmux send-keys -t <pane> -l -- <text>`; multiline
  `tmux load-buffer -b conductore-<rand> -` (text on stdin) then
  `tmux paste-buffer -p -d -b … -t <pane>` (bracketed paste, so newlines do
  not submit). Enter follows as a separate `send-keys … Enter` after 150 ms
  (`CONDUCTORE_SEND_ENTER_DELAY_MS`): Claude Code treats text and CR in one
  read as a paste and would insert a newline instead of submitting.
* Everything goes through `execFile`/`spawn` with an argument array; the
  text never passes through a shell.
* Errors: `unknown session <id>`, `session has ended`, `agent is waiting for
  a permission decision; answer it first` (typing would answer the prompt),
  `session not in tmux or Herdr`, and the multiplexer's own error.

### `conductore-hostd interrupt <sessionId>`

Presses Escape in the agent's pane (`herdr pane send-keys <pane> esc`, else
`tmux send-keys -t <pane> Escape`), which interrupts Claude Code's current
turn. Allowed while a permission prompt is up (Escape dismisses it).
Prints `{"ok":true,"sessionId":"…","via":"tmux","paneId":"%5","key":"Escape"}`.

### `conductore-hostd ports [--since <seq>]`

The TCP ports the user's own processes listen on, for the phone's "Preview
ready" chip (Live preview). Nothing watches in the background: the list is
computed when asked, from `ss -ltnpH` (else `lsof -nP -iTCP -sTCP:LISTEN`,
else `/proc/net/tcp`), and a result younger than 2 s is reused. The table
lives in `~/.conductore/ports.json` so each port keeps the `seq` at which
it first appeared; a port that closes is dropped, and when it opens again
(a restarted dev server, a new pid) it gets a new `seq`.

```json
{"seq":7,"source":"ss","cached":false,"ports":[
  {"port":5173,"address":"127.0.0.1","pid":4242,"process":"node","label":"vite",
   "cwd":"/home/andre/app","seq":7,"firstSeenAt":1790340104253,"url":"http://localhost:5173/"}]}
```

* Without `--since`: every current port. With it: only ports whose `seq` is
  greater (the phone polls with the last `seq` it saw).
* `label`: the dev server read from the command line (`vite`, `next`,
  `create-react-app`, `webpack`, `astro`, `nuxt`, `django`, `flask`,
  `uvicorn`, `python http.server`, `rails`, …), else the process name.
* Left out: SSH, mail, DNS, portmapper, CUPS and LLMNR ports (22, 25, 53,
  111, 631, 5355), 80/443 owned by root or `docker-proxy`, system daemons
  (`sshd`, `docker-proxy`, `mosh-server`, `tailscaled`, …), other users'
  sockets (unless running as root), and ports from 32768 up (debuggers,
  language servers) unless the command line is a known dev server.
* `source`: `ss`, `lsof`, `proc` (no process details) or `none`.

### `conductore-hostd usage [--days 7] [--since <iso>] [--max-bytes N] [--max-ms N]`

Usage at a glance, computed on this machine from local files (no network,
no Anthropic or OpenAI API): the account's rate limits, each live
session's context, and tokens with an estimated cost per local day,
project and model.

```json
{"version":"0.7.0","schema":1,"machine":"devbox","generatedAt":1790340104253,
 "timeZone":"Europe/Lisbon","today":"2026-09-25","from":"2026-09-19",
 "claude":{"present":true,
   "limits":[{"label":"5h","usedPct":42,"resetsAt":1790348400000,"expired":false},
             {"label":"7d","usedPct":18,"resetsAt":1790697600000,"expired":false}],
   "sessions":[{"sessionId":"…","name":"api","project":"api","state":"working",
                "contextUsedPct":41,"contextTokens":82000,"windowLabel":"200k"}],
   "today":{"input":1200,"output":98000,"cacheWrite":350000,"cacheRead":9100000,
            "tokens":9549200,"messages":212,"costUsd":8.93},
   "range":{…same fields, from `from` to `today`…},
   "rows":[{"date":"2026-09-25","project":"api","model":"claude-opus-5",
            "input":1200,"output":98000,"cacheWrite":350000,"cacheRead":9100000,
            "messages":212,"costUsd":8.93}]},
 "codex":{"present":false},
 "pricing":{"estimate":true,"asOf":"2026-09-25","note":"Estimate at public API list prices. …",
            "sources":{"claude":"…","codex":"…"},"unpriced":[]},
 "scan":{"ms":61,"files":1137,"filesRead":0,"bytesRead":0,"partial":false,
         "pendingFiles":0,"busy":false,"cacheBytes":1311180}}
```

* `claude.limits`: the 5-hour and 7-day windows (and `spend` when set)
  from the newest statusline reports (see Usage below), remembered in the
  cache after the sessions end. `expired: true` once `resetsAt` has passed:
  the window reset and its use is unknown until the next report (show 0).
* `claude.sessions`: context use of the sessions the daemon knows (read
  from the daemon when it runs, else its snapshot; the daemon is never
  started for this).
* Tokens come from the transcripts under `~/.claude/projects/**/*.jsonl`
  (`$CLAUDE_CONFIG_DIR/projects`), subagents included: each assistant
  entry's `message.usage` and `message.model`. `input` excludes cache
  reads and writes; `tokens` is the sum of the four. A message is counted
  once per message id and request id (streaming writes one line per
  content block, a resumed session copies earlier entries); the largest
  `output_tokens` wins. `<synthetic>` entries are skipped. `speed: "fast"`
  rows are fast mode.
* `project`: the repository the entry's cwd is in (the main checkout's
  name for a linked worktree), `~` for the home directory, else the cwd's
  name. `rows` hold one line per day, project, model and speed; the phone
  groups them by machine, project, model or day.
* `costUsd`: an **estimate** at public API list prices from
  `lib/pricing.js` (one dated table, applied when answering, so an update
  also reprices history). On a subscription plan it is the API-equivalent
  cost, not a bill. A model missing from the table has `costUsd: null` and
  is listed in `pricing.unpriced`.
* `codex`: `{"present":false}` without `~/.codex/sessions` (`$CODEX_HOME`).
  Otherwise the same shape, from the `token_count` events of the Codex CLI
  session logs (running totals turned into per-day deltas, `input` without
  the cached part, `cacheRead` = cached input) and `limits` from the newest
  event's `rate_limits` (primary 5h, secondary 7d). Read only.
* `--days` (1–31, default 7) or `--since <iso>` (day granularity) set
  `from`. Only the last 31 days are kept.
* Cost: incremental. The cache holds, per file, the byte offset read so
  far; only files whose size or mtime changed are opened, from there, and
  only lines containing `"usage"` and `"assistant"` (Codex: `token_count`,
  `turn_context`, `session_meta`) are parsed. One call reads at most
  `--max-bytes` (256 MB) or `--max-ms` (2500 ms), newest files first, then
  answers with `scan.partial: true`; the next call goes on (the phone
  polls again sooner). A first scan of 2 GB of transcripts takes about five
  calls; afterwards a call takes ~60 ms. It runs at nice 10, never touches
  the daemon's event path, and a second concurrent call answers from the
  cache with `scan.busy: true` instead of scanning too.

### `conductore-hostd summarize [--max-words 45] [--timeout-ms 20000]`

A spoken version of an assistant reply for the phone's "Claude summary"
read-aloud mode: one or two sentences, plain words, at most `--max-words`
(5–200) words. The reply comes on stdin (UTF-8; beyond 64 KB it is
truncated), never as an argument. Exactly one JSON line on stdout and exit
0 in every case:

```json
{"schema":1,"summary":"The nightly build failed because the lockfile was made with npm 11 but CI runs npm 9. I pinned npm to 11. Should I open a pull request?","ms":2830,"model":"claude-haiku-4-5-20251001"}
{"schema":1,"summary":"Done. The tests pass.","ms":0,"model":null,"passthrough":true}
{"schema":1,"error":"timeout","message":"claude did not answer within 20000 ms"}
```

* A reply under 40 words (or no longer than `--max-words`), markdown
  stripped, comes back as it is with `passthrough: true`; claude is not
  called.
* `error`: `claude-missing` (not on PATH, `~/.local/bin` or
  `~/.claude/local`), `not-logged-in`, `timeout`, `busy` (another
  `summarize` still ran after 2 s), `failed` (anything else, including
  empty input and bad flags).
* It runs `claude -p --tools "" --safe-mode --no-session-persistence
  --output-format json --model haiku --system-prompt <fixed instruction>`
  with the reply on stdin between random delimiters and marked as content,
  never instructions. No tools; `--safe-mode` skips hooks (the companion's
  own included, so the call never shows up as an agent), skills, plugins,
  MCP servers and CLAUDE.md; nothing is written under `~/.claude/projects`.
  `MAX_THINKING_TOKENS=0`: with extended thinking Haiku took 5–55 s here,
  without it about 3 s (2.8 s median on development-central).
* The answer is stripped of markdown, a "Summary:" label and quotes, and cut
  to the word cap at a sentence boundary, keeping a closing question.
* A CLI one-shot like `usage`: no daemon, no cost at idle. It runs at nice
  10, claude in its own process group (killed on timeout, SIGHUP, SIGINT or
  SIGTERM), one call per user at a time (`~/.conductore/summarize.lock`
  holds only a pid). The text is never logged or written to disk.
* Claude Code itself still does its start-up bookkeeping for the call: a
  `~/.claude/sessions/<pid>.json` entry removed at exit, `~/.claude.json`
  counters, and plugin marketplace refreshes.

### `conductore-hostd guide [--timeout-ms 15000]`

The phone's voice guide ("Talk to the fleet"). The phone matches common
spoken commands itself; anything else comes here as one JSON object on
stdin (32 KB max), never as an argument:

```json
{"utterance":"ask the api agent how far it is","context":{"lang":"en","screen":{"view":"home"},"machines":[{"id":"m1","name":"VTM"}],"projects":[{"id":"p1","name":"conductore-mobile"}],"agents":[{"id":"a1","machine":"m1","name":"api","project":"p1","state":"working","pending":[]}]}}
```

The context holds short ids (`m1`, `a1`, `r1`, …, made up by the phone for
this one request) and labels: machines, projects, agents with their state
and pending permission requests (tool, one-line summary, risk), and the
screen. Never a transcript. Exactly one JSON line on stdout and exit 0 in
every case:

```json
{"schema":1,"action":{"action":"send","target":"a1","text":"How far are you?","minutes":0,"speak":"Asking api how far it is."},"ms":2900,"model":"claude-haiku-4-5-20251001"}
{"schema":1,"action":{"action":"say","target":"","text":"","minutes":0,"speak":"I could not find that."},"rejected":"unknown-target","ms":2500,"model":"claude-haiku-4-5-20251001"}
{"schema":1,"error":"busy","message":"another guide request is running"}
```

* `action` is one of `open`, `chat`, `terminal`, `approve`, `deny`,
  `approveAllSafe`, `trust`, `send`, `read`, `usage`, `home`, `say`;
  `target` is an id from the context or empty, `text` the prompt for
  `send`, `minutes` (1–480) for `trust`, `speak` one short sentence to say.
* The answer is checked here too: an action outside the list, an id the
  context does not name, a `send` without text or target, an `open` or
  `read` without target, or a `trust` without minutes comes back as a
  `say` with `rejected` (`unknown-action`, `unknown-target`, `incomplete`).
  The phone checks the action against its own state again before doing
  anything, and asks for a spoken confirmation before approving, denying,
  sending or trusting.
* `error`: `claude-missing`, `not-logged-in`, `timeout`, `busy` (another
  `guide` still ran after 2 s), `failed` (anything else, including bad
  input and flags).
* It runs `claude -p --tools "" --safe-mode --no-session-persistence
  --output-format json --model haiku --system-prompt <fixed instruction>
  --json-schema <fixed schema>` with the request on stdin between random
  delimiters, `MAX_THINKING_TOKENS=0`: the same lock-down as `summarize`
  (no tools, no hooks, no transcript), at nice 10, claude in its own
  process group killed on timeout or a signal, one call per user at a time
  (`~/.conductore/guide.lock`). The request is never logged or written to
  disk. A CLI one-shot: nothing at idle.
* Older companions answer `unknown command guide`: the phone then asks the
  next machine, or says the guide's brain needs an update.

### `conductore-hostd statusline [--chain '<cmd>']`

Not for the phone: the Node statusline of 0.3, kept so a not yet migrated
`statusLine` keeps working. `install` registers `conductore-statusline`
instead. See Usage.

### Others

* `install` / `uninstall`: `{"ok":true,"settings":"…/settings.json","hook":"…/conductore-hook","statusline":"…/conductore-statusline","events":[…],"statusLine":"set|wrapped|updated|unchanged"}` / `{"ok":true,"removed":[…],"statusLineRestored":true,"daemonStopped":true}`
* `doctor`: `{"ok":true,"user":"andre","checks":[{"name":"hooks registered","ok":true,"detail":"9 events"},{"name":"statusline (usage)","ok":true,"detail":"wired, wrapping: ~/bin/my-line"},{"name":"hook latency","ok":true,"detail":"3.1 ms per event (median of 5, no-op event)"},{"name":"daemon memory","ok":true,"detail":"45.9 MB RSS, 180 ms CPU in 3600 s, version 0.7.0"}, …]}`
  (a missing statusline, daemon or latency does not make `ok` false; the
  latency is measured around the spawn from Node, so it includes a little
  process start-up; with no daemon running, it starts one)
* `stop`: `{"ok":true,"running":true,"stopped":true}` or `{"ok":true,"running":false}`
* `version`: `{"version":"0.7.0","protocol":1,"node":"22.23.1"}`
* `daemon [--detach]`: runs the daemon (what the clients start;
  `--detach` starts it in its own session with the flags from Footprint).

## Usage (context and rate limits)

Hooks carry no usage data; Claude Code's statusline does. `install` sets
`statusLine.command` to `conductore-statusline` (sh) when none is set. If
you already have one, it becomes
`conductore-statusline --chain '<your command>'` (other `statusLine`
fields such as `padding` are kept): your command runs through `sh -c` with
the same JSON on stdin (trailing newlines normalised to one) and its output
is printed unchanged. `uninstall` puts your command back.

Each run spools the statusline JSON; the daemon maps it into the session's
`usage`:

| `usage` field | from |
| --- | --- |
| `contextUsedPct` | `context_window.used_percentage` (clamped 0 to 100) |
| `contextTokens` | `context_window.total_input_tokens` |
| `windowLabel` | `context_window.context_window_size` as `200k` / `1M` |
| `limits[]` | `rate_limits.five_hour` → `5h`, `seven_day` → `7d`, `spend_limit` → `spend`: `{label, usedPct, resetsAt}` with `resetsAt` in epoch ms |

Null fields and absent windows are omitted; `usage` itself is omitted until
something is known. Rate limits appear only for Pro/Max accounts, after the
first API response.

A usage report never changes `state` or `updatedAt`. The daemon publishes at
most one `reason: "usage"` change per session every 10 s
(`CONDUCTORE_USAGE_THROTTLE_MS`), always carrying the latest value; an
unchanged report publishes nothing. A report for a session the daemon has
not seen yet is held until its first hook event.

The statusline runs after every assistant message, so it is throttled before
it reaches the daemon too: when the daemon takes a report from the spool it
creates `usage/<session>.hold` for the same 10 s. While that file exists the
statusline parks its report as `usage/<session>.<pid>` (one `[ -e ]` test, no
clock read, no daemon wake-up), and when the hold ends the daemon applies the
newest parked report and deletes the rest. So the daemon wakes at most once
per 10 s per session and the last value of a burst is never lost.

Without `--chain` the command prints `Opus · api · 43% ctx · 5h 24%`, the
same line as `lib/statusline.js` builds, computed with shell parameter
expansion only (no jq, no Node); on JSON it cannot read it prints
`conductore`. It never fails visibly: bad input, a stopped daemon (started
for the next report) or a failing chained command still exit 0. The chained
command has no time limit of its own any more; Claude Code cancels a slow
statusline itself.

## Permission decisions

`conductore-hook PermissionRequest` creates a FIFO (`tmp/p.<pid>`), opens
it read-write, spools the request with the FIFO's path and blocks reading it
until `decide` is called or `CONDUCTORE_PERMISSION_TIMEOUT` (120 s) passes.
The daemon writes the decision line into the FIFO with a non-blocking open,
which fails (ENXIO) once nobody reads it: that is how it notices a hook that
Claude Code killed (checked once a second, only while a prompt is pending),
and why `decide` on a dead hook fails. A watchdog subshell (one `sleep 1` per
second, only while the prompt waits) ends the wait at the timeout, after 5 s
if no daemon picked the request up (none running and none could start), or
as soon as the daemon that took it dies. Its stdout is exactly what Claude
Code's PermissionRequest decision control expects (`hookSpecificOutput.hookEventName = "PermissionRequest"`,
`decision.behavior` allow or deny, optional `message`, `updatedInput`,
`updatedPermissions`), as documented at
https://code.claude.com/docs/en/hooks#permissionrequest-decision-control.

allow:

```json
{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}
```

deny (message defaults to "Denied from Conductore Mobile"):

```json
{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"not on prod"}}}
```

always: allow plus `updatedPermissions`. The docs say a hook may echo one of
the `permission_suggestions` it received, so the first suggested
`addRules`/`allow` entry (which carries Claude Code's own rule, e.g.
`git *`, and its destination) is used. When Claude Code suggested nothing, a
rule scoped to the exact command (`Bash`) or file path (file tools), else the
whole tool, is written to `localSettings`. Every rule is also appended to
`~/.conductore/always-rules.json`.

```json
{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow",
  "updatedPermissions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"git *"}],"behavior":"allow","destination":"localSettings"}]}}}
```

timeout, daemon unreachable, or the phone never answered: the hook prints
nothing and exits 0, so Claude Code shows its normal terminal prompt. The
agent is then reported as `needs_permission` with an empty `pending` list and
`lastMessage` "Permission prompt is waiting in the terminal" until the next
event. A `decide` for that request fails with `unknown request`.

Note that a hook `allow` does not override a matching deny rule, and Claude
Code still evaluates ask rules against `updatedInput` (not used here).

## Threat model

* Everything runs as the user who runs Claude Code. The socket is 0600 inside
  a 0700 directory, and both ends refuse a socket owned by another uid.
  Whoever can execute commands as that user can already do anything the
  agent can; the daemon adds no new capability.
* The phone must have SSH access as that same user (key-based, over the
  tailnet in the intended setup). There is no other authentication layer, so
  protect the SSH key as you would the host.
* The daemon never executes tool input. It stores and reports it; `focus`,
  `send`, `interrupt` and the location lookup run only `tmux`, `herdr` and
  `node` through `execFile`/`spawn`, with arguments passed as an array (no
  shell). The sh clients never evaluate their input: the JSON is copied with
  `cat` or held in a variable and only matched with parameter expansion.
* The spool, tmp and usage directories are 0700 under a 0700 state dir, so
  only the user can drop events in (the same user can already run the CLI).
  The daemon only opens FIFOs that are directly inside its own `tmp/`, and
  opens them write-only and non-blocking.
* `send` types into the agent's pane, which is what the SSH user could do by
  attaching to tmux/Herdr anyway. It refuses while a permission prompt is
  waiting so a prompt cannot answer it by accident.
* `transcript` only reads the `transcript_path` Claude Code reported for a
  known session (absolute, `.jsonl`), and drops thinking text and images.
* An `always` decision persists an allow rule in the project's
  `.claude/settings.local.json` (or wherever Claude Code suggested), exactly
  as choosing "always" in the terminal would. Review
  `~/.conductore/always-rules.json` if in doubt.
* Tool inputs (commands, file contents up to 4 KB) and last messages are held
  in memory and in `state.json` (0600). They are visible to anyone with the
  user's shell, which is also true of the transcripts.
* The hook client trusts its stdin (it comes from Claude Code) and the daemon
  trusts its socket peers (owner-only) and spool files (owner-only
  directory). Request bodies are capped at 1 MB, spool files at 8 MB.

## Footprint

Measured on development-central (Ubuntu 24.04, dash as `/bin/sh`, Node 22,
12 cores) with `host/bench.sh 200` and `/proc` over 60 s windows:

| | 0.3.0 (Node hook) | 0.4.0 (sh clients) |
| --- | --- | --- |
| hook event, wall | 34 ms | 2.4 ms |
| hook event, peak RSS | 46 MB (a Node process) | 1.9 MB (`sh`, `cat`, `ln`) |
| statusline refresh, wall | 30 ms | 3.2 ms |
| statusline refresh, peak RSS | 47 MB | 1.9 MB |
| daemon CPU per hook event | (not measured) | 0.35 ms |
| daemon idle RSS | 53.6 MB | 47.2 MB |
| daemon idle private memory (`Private_Dirty`) | 8.8 MB | 7.4 MB |
| daemon threads | 7 | 4 |
| daemon idle CPU, 60 s | 0 ticks, plus a prune timer every 5 min | 0 ticks, 0 context switches, no timers |
| daemon idle exit | 24 h | 6 h |

About 40 MB of the daemon's RSS is the node binary's own pages, shared with
every other Node process (Claude Code included): a bare
`node -e 'setInterval(()=>{},1e9)'` has 42.7 MB RSS and 6.4 MB private. The
daemon runs with `--max-old-space-size=16 --max-semi-space-size=1
--lite-mode --no-expose-wasm --v8-pool-size=1` (`lib/paths.js`): lite mode
(no optimizing compiler) touches about 6 MB less and costs no measurable CPU
at this load (0.35 vs 0.37 ms per event), one V8 worker instead of four drops
three threads; `--jitless`, `--single-threaded` and glibc
`MALLOC_ARENA_MAX=1` saved nothing more. The heap limits mostly cap growth.

Idle means asleep: no polling loop, no periodic timer. The only timers are
one-shots tied to activity (snapshot debounce, usage holds and throttle, the
next prune deadline, long-poll timeouts, the idle exit) and a 1 s FIFO probe
that runs only while a permission prompt is pending. V8 runs a few
memory-reducer GCs in the first minute after a burst, then nothing (strace
shows no syscalls).

## Portability notes

* Tested here with dash and bash; the scripts use only POSIX sh plus `[ -e ]`
  style tests, `kill -0`, `read -r`, `$(( ))` and `${var%%pattern}`, which
  zsh in sh mode and macOS's bash 3.2 `/bin/sh` also have. macOS has not been
  run: it relies on `mkfifo -m`, a FIFO opened read-write (`exec 3<>fifo`,
  supported by Darwin), `ln` and `fs.watch` over FSEvents.
* Hard links need the state dir on a local filesystem; where `ln` fails the
  clients fall back to `mv`.
* The statusline default line reads the JSON with pattern matching, not a
  parser: it assumes Claude Code's key names and that string values have no
  escaped quotes. A miss only drops a part of the line (the usage recorded
  by the daemon is parsed properly in Node).
* The daemon's liveness check in the clients is `kill -0 <pid from
  hostd.pid>`: after a hard crash, a recycled pid can delay the automatic
  restart until the phone's next `status`/`events` (which pings the socket
  and restarts it).

## Development

```sh
cd host && node --test test/*.test.js
host/bench.sh 200        # per-event cost on this machine (throwaway state dir)
```

`test/state.test.js` covers the reducer, `test/settings.test.js` the
settings merge, `test/transcript.test.js` the transcript reader,
`test/statusline.test.js` usage mapping, statusLine wiring and 0.3 migration,
the sh statusline (default line parity with `lib/statusline.js`, hold and
park throttle, `--chain` passthrough) through a real daemon,
`test/chat.test.js` the `transcript`/`send`/`interrupt` commands (with fake
`tmux`/`herdr` binaries that record their arguments),
`test/summarize.test.js` the `summarize` command with a fake `claude`
(argv, passthrough, markdown and word cap, timeout kill, busy, truncation),
and
`test/daemon.test.js` spawns a real daemon on a temp socket and drives the sh
hook and the CLI through spool handoff (daemon down, ordering, staging
cleanup), tmux/Herdr location, the FIFO permission flows (allow, deny,
always, timeout, killed hook, daemon stopped or killed mid-wait, no daemon at
all), long-poll, restart and doctor.
