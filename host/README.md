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
    phone ──ssh user@host "conductore-hostd status|events|decide|trust|rules|transcript|send|ports|usage|summarize|guide|digest|turns|diff|undo"

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
hook handlers (eleven on a Claude Code that knows the two newer events, see
How it works) into `~/.claude/settings.json` (backup in `settings.json.bak`),
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
| `~/.conductore/hostd.sock` | socket, mode 0600 (up to 0.7 it was `$XDG_RUNTIME_DIR/conductore/hostd.sock` when the starter had that variable; the CLI still finds a daemon running there) |
| `~/.conductore/spool/` | events and statusline reports waiting for the daemon |
| `~/.conductore/tmp/` | staging files of the sh clients, FIFOs of waiting permission prompts |
| `~/.conductore/usage/` | statusline holds and parked reports (see Usage) |
| `~/.conductore/hostd.pid` | lock and pid of the running daemon (ignored when that pid is not a running `conductore-hostd`) |
| `~/.conductore/node` | node binary the sh clients start the daemon with |
| `~/.conductore/spawn.at` | time of the last start attempt |
| `~/.conductore/state.json` | atomic snapshot of the state, read by `status` when the daemon is down |
| `~/.conductore/ports.json` | listening ports and the seq each first appeared at (`ports`) |
| `~/.conductore/usage-cache.json` | `usage`: per-transcript offsets and daily token sums, last 31 days (about 1.3 MB for 1,100 transcripts) |
| `~/.conductore/cswap-cache.json` | `usage` with cswap: the last `cswap list` answer (masked rows only), 60 s |
| `~/.conductore/summarize.lock` | pid of the running `summarize` (one at a time; never the text) |
| `~/.conductore/guide.lock` | pid of the running `guide` (one at a time; never the request) |
| `~/.conductore/activity.json` | per-agent activity log for `digest` (compact entries, no tool input; see `digest`), mode 0600 |
| `~/.conductore/digest.json` | `digest --summaries`: the rolling summary per agent and today's token use of those calls, mode 0600 |
| `~/.conductore/digest.lock` | pid of the running `digest --summaries` (one at a time) |
| `~/.conductore/turns.json` | per-turn snapshot records for `turns` / `diff` / `undo` (prompt headline, times, snapshot commits, changed files), mode 0600 |
| `~/.conductore/hostd.log` | log, rotated once at 1 MB to `hostd.log.1` |
| `~/.conductore/always-rules.json` | record of every rule added through an "always" decision |
| `~/.conductore/rules.json` | approval rules and time-boxed trust the hook answers by itself (see Approval rules), mode 0600 |
| `~/.conductore/auto-approved.json` | what those rules answered in the last 24 h (at most 500 entries and 128 KB, no tool input), mode 0600 |

Environment: `CONDUCTORE_PERMISSION_TIMEOUT` (seconds the hook waits for the
phone, default 120, read by the hook), `CONDUCTORE_IDLE_EXIT_S` (daemon idle
exit, default 21600 = 6 h, 0 = never), `CONDUCTORE_USAGE_THROTTLE_MS`
(default 10000, see Usage), `CONDUCTORE_LOG=debug` (log every state change),
`CONDUCTORE_HOME`, `CONDUCTORE_SOCKET`, `CONDUCTORE_CLAUDE_SETTINGS`
(overrides, mainly for tests; the socket defaults to `<home>/hostd.sock`).
The daemon reads its environment when it starts, from whichever client
started it.

### PATH for the phone's SSH shell

SSH exec channels get a non-login shell whose PATH often lacks `~/.local/bin`.
The phone should run commands as
`sh -c 'PATH="$HOME/.local/bin:$PATH" exec conductore-hostd status'`
(same trick the app already uses for Herdr) or call the binary by absolute path.

## How it works

`conductore-hostd install` registers `conductore-hook <Event>` for
SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, PostToolUseFailure,
PermissionRequest, Notification, Stop, StopFailure, SubagentStop and
SessionEnd, all with an empty matcher. PostToolUseFailure (a failed tool
call, e.g. a command that exited non-zero) and StopFailure (a turn that
ended on an API error) feed `digest`, and are registered only when
`claude --version` says the local Claude Code knows them: 2.1.119 or newer
for PostToolUseFailure (the first release its changelog names it in),
2.1.78 for StopFailure. Before 2.1.101 Claude Code ignored the whole
settings.json over one unknown hook event name, so with no `claude`, no
answer in 5 s or an unreadable version neither is registered. Running
`install` again after a Claude Code update (or downgrade) adds (or takes
off) them; `install` prints them in `skipped` with the reason, `doctor`
reports them as `optional hooks`, `uninstall` removes them. Without them
`digest` reads failures and API errors from the transcripts instead.
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

Not every session sends SessionEnd (Claude Code killed, crashed, its SSH
session dropped, a reboot). The hook passes Claude Code's pid (its parent, or
its grandparent through `sh -c`, read from `/proc` without a fork); the daemon
records it with the process start time when the process really is Claude
Code, and ends the agent (`reason: expired`) once that process is gone. It
checks at start and on every `status` / `events`, so nothing runs at idle.
Without `/proc` (macOS) an agent ends after 24 h without any event.

### Agent states

| state | set by |
| --- | --- |
| `working` | UserPromptSubmit, PreToolUse, PostToolUse, a permission decision |
| `waiting_input` | SessionStart, Stop, StopFailure, Notification `idle_prompt` / `agent_needs_input`, PreToolUse of AskUserQuestion or ExitPlanMode |
| `needs_permission` | PermissionRequest (until decided), Notification `permission_prompt`, a PermissionRequest that timed out (the prompt is now in the terminal) |
| `ended` | SessionEnd; its Claude Code process gone, or 24 h without an event when the process is unknown (`expired`) |

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
      "tmux": { "session": "main", "window": 2, "paneId": "%5", "windowName": "reviewer",
                "socket": "/tmp/tmux-1000/default", "panePid": 48213 },
      "herdr": { "workspaceId": "w1", "tabId": "w1:t1", "paneId": "w1:p1", "name": null },
      "process": { "pid": 31515, "startTime": "81423907" },
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
          "createdAt": 1790286139530,
          "risk": { "level": "high", "reason": "Deletes recursively (rm -rf): node_modules" },
          "batchable": false,
          "suggestedRules": ["Bash(rm *)", "Bash(rm -rf node_modules)", "Bash"],
          "repo": "/home/andre/Projects/Foo"
        }
      ]
    }
  ],
  "capabilities": ["smart-approvals", "digest"]
}
```

* `name`: Herdr agent name, else the tmux window name (unless it is a generic
  process name like `node` or `claude`), else the basename of `cwd`. Leading
  status glyphs from Claude Code's terminal title (`⚠`, `✳`, `●`, emoji,
  spinner dots) are stripped first.
* `tmux` / `herdr` are `null` when unknown. `transcriptPath` is the
  `transcript_path` of the latest hook event (null until one carried it).
* `process` (Claude Code's pid and start time in clock ticks) is present
  once the daemon identified it (Linux).
* `lastMessage`: last assistant text (Stop), notification text, or the
  question of an AskUserQuestion; capped at 500 chars.
* `pending[].summary`: one line (command, file path, URL, …) capped at 200
  chars. `toolInput` is the raw input; above 4 KB it is replaced by
  `{"_truncated":true,"preview":"…"}`.
* `usage` is present only once the statusline reported something for the
  session (see Usage).
* `pending[].risk` (`low` / `medium` / `high` and a one-line reason),
  `batchable` (may go into "approve all safe"), `suggestedRules` (most
  specific first) and `repo` (the git work tree of the agent's cwd) are set
  on every request the daemon rated; see Approval rules.
* `lastAutoApprovedAt` (epoch ms): the last time a rule answered one of the
  agent's requests; the phone refreshes its `approvals` list when it moves.
* `capabilities`: what this companion supports, for the phone to gate on
  (also in `version`). `smart-approvals`: risk labels, `rules`, `trust`,
  `approve-low`, `approvals`, `classify`. `digest`: the `digest` command.
  `snapshots`: per-turn snapshots and `turns`, `diff`, `undo`, `redo`.
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
  or the phone was away for more than 1000 changes, or 2 M characters of
  them). Replace everything and
  continue from its `seq`.
* `reason` is the hook event name, `decision:<allow|deny|always|auto|timeout|gone>`,
  `usage` (only the `usage` field changed), `expired` (ended without
  SessionEnd) or `prune`.

Suggested loop on the phone: `status` once, then `events --since <seq>` in a
loop, reconnecting on SSH errors.

### `conductore-hostd decide <requestId> allow|deny|always [--message "..."]`

```json
{"ok":true,"requestId":"3671d8715ac1","decision":"allow","sessionId":"0f2c…"}
```

Unblocks the waiting hook. Errors (exit 1): `unknown request <id>` (already
decided, timed out, or never existed) and `request expired; answer it in the
terminal` (the hook process is gone). `--message` is passed to Claude on deny.
`always` on a high-risk request is answered as a one-time `allow` (no rule
for Claude Code either), with `"note": "high-risk requests always ask: …"`.

### `conductore-hostd approve-low [--ids <id,id,…>] [--session <sessionId>]`

"Approve all N safe": allows every waiting request rated low (with `--ids`,
only those: pass the list the user saw). Everything else is skipped with a
reason, never allowed.

```json
{"ok":true,"approved":[{"id":"3671d8715ac1","sessionId":"0f2c…","toolName":"Bash","summary":"git status"}],
 "skipped":[{"id":"9a0e…","reason":"high risk: review it"},{"id":"nope","reason":"unknown request"}]}
```

### `conductore-hostd trust <requestId> [--rule 'Tool(pattern)'] [--scope repo|session|any] [--minutes 60 | --until-session-end | --forever] [--path <dir>]`

"Trust this for N minutes": saves a rule from a waiting request (default:
a rule for exactly this call, e.g. the exact command, never broader than
what was asked; scope `repo` = the request's `repo`; 60 minutes), allows the request, and allows every other waiting request the
rule covers. `--scope session` limits it to this agent session (and drops
it when the session ends); `--until-session-end` keeps the scope but ends
with the session. Refused for high-risk requests.

```json
{"ok":true,"rule":{"id":"r0a1b2c3d4e","rule":"Bash(npm test *)","scope":{"kind":"repo","path":"/home/andre/Projects/Foo"},
 "expiresAt":1790287039530,"endsWithSession":null,"source":"trust","note":null,"createdAt":1790286139530,"hits":0,"lastUsedAt":null},
 "approved":["3671d8715ac1"]}
```

### `conductore-hostd rules [list|add|edit|remove]`

```sh
conductore-hostd rules                                  # {"rules":[…active…],"now":…}
conductore-hostd rules add 'Bash(npm test *)' --scope repo --path ~/Projects/Foo [--minutes 15]
conductore-hostd rules add 'Read' --scope session --session <sessionId>
conductore-hostd rules edit <ruleId> [--rule '…'] [--scope …] [--minutes N | --forever]
conductore-hostd rules remove <ruleId>                  # {"ok":true,"removed":{…}}
```

`add` and `edit` answer waiting requests the rule now covers
(`"approved": [ids]`). Expired rules are not listed and are dropped the
next time the file is written.

### `conductore-hostd approvals [--hours 24]`

The active rules plus what they answered, newest first:

```json
{"rules":[…],"now":1790286139530,
 "autoApproved":[{"requestId":"5b7c…","at":1790286139530,"sessionId":"0f2c…","agent":"Foo","cwd":"/home/andre/Projects/Foo",
   "toolName":"Bash","summary":"npm test","risk":{"level":"low","reason":"Runs tests: npm test"},
   "ruleId":"r0a1b2c3d4e","rule":"Bash(npm test *)","scope":{"kind":"repo","path":"/home/andre/Projects/Foo"}}]}
```

### `conductore-hostd classify [--tool Bash --command '…' | --file <path> | --url <url>] [--cwd <dir>]`

The risk label and rule suggestions for one tool call, without the daemon
(or `{"tool_name","tool_input","cwd"}` on stdin):
`{"risk":{"level":"low","reason":"Runs tests: npm test"},"batchable":true,"suggestedRules":["Bash(npm test *)","Bash(npm *)","Bash"],"repo":"/home/andre/Projects/Foo"}`.

### `conductore-hostd focus <sessionId>`

Runs `herdr agent focus <paneId>` when the agent has a Herdr pane, else
`tmux -S <socket> select-window -t <paneId>` and `select-pane -t <paneId>`,
after the same pane check as `send`. Prints `{"ok":true,"via":"tmux","target":"main:2","paneId":"%5"}`.

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
  `--max-bytes` (a prompt with pasted images, a big tool result); it is read
  and returned on its own, or skipped when it is over 64 MB.
* Kept line types: `user`, `assistant`, `system` (`subtype`, `content`
  capped at 500 chars, `level`) and `summary`. A prompt the user typed while
  the agent was working, which Claude Code records only as a
  `queued_command` attachment, comes back as a `user` entry with
  `queued: true` (the attachment's `prompt` as `message.content`); queued
  task notifications and teammate or coordinator messages do not. Other
  attachments, queue operations, file-history snapshots, cost state and
  other bookkeeping lines are dropped. `isMeta`, `isCompactSummary` and `isApiErrorMessage` are
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
* tmux (always `tmux -S <socket> …`): single line `tmux send-keys -t <pane> -l -- <text>`; multiline
  `tmux load-buffer -b conductore-<rand> -` (text on stdin) then
  `tmux paste-buffer -p -d -b … -t <pane>` (bracketed paste, so newlines do
  not submit). Enter follows as a separate `send-keys … Enter` after 150 ms
  (`CONDUCTORE_SEND_ENTER_DELAY_MS`): Claude Code treats text and CR in one
  read as a paste and would insert a newline instead of submitting.
* Everything goes through `execFile`/`spawn` with an argument array; the
  text never passes through a shell.
* Pane check, right before typing (also for `interrupt` and `focus`): a
  recorded pane id can belong to someone else by now (tmux reuses ids after
  a pane closes or its server restarts; the agent may run on another tmux
  server). tmux commands go to the agent's own server (`-S`, the socket from
  the hook's `$TMUX`), and the pane must still run the process recorded with
  it (`#{pane_pid}`); a Herdr pane must still run this Claude session
  (`herdr pane list`); and Claude Code itself must still run (`process`).
  Otherwise nothing is typed and the error says why: `tmux pane %5 no longer
  holds this session (closed, or its id reused)`, `tmux pane %5 is gone: …`,
  `Herdr pane w1:p1 no longer holds this session`, `the agent's Claude Code
  process has exited; nothing was typed`, `cannot verify tmux pane %5
  (recorded by an older companion); …` (fixed by the agent's next event).
  A Herdr pane that fails its check falls back to a tmux pane that passes.
* Errors: `unknown session <id>`, `session has ended`, `agent is waiting for
  a permission decision; answer it first` (typing would answer the prompt),
  `session not in tmux or Herdr`, the pane check's, and the multiplexer's
  own error.

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

#### Every Claude account (cswap)

With [cswap](https://github.com/realiti4/claude-swap) (a Claude Code
multi-account switcher) on PATH or at `~/.local/bin/cswap`, `claude` also
carries the limits of every account it manages, from `cswap list --json`:

```json
"claude":{…,
  "cswap":{"present":true,"activeSlot":1,"fetchedAt":1790497409198},
  "accounts":[
    {"slot":1,"alias":"work","label":"work","active":true,"disabled":false,"status":"ok",
     "limits":{"5h":{"usedPct":17,"resetsAt":1790513999667,"expired":false},
               "7d":{"usedPct":5,"resetsAt":1791064799667,"expired":false}},
     "usageAt":1790497196000,
     "perModel":[{"model":"Fable","usedPct":7,"resetsAt":1791064799667,"expired":false}]},
    {"slot":2,"alias":null,"label":"b***@e***.org","active":false,"disabled":true,
     "status":"unavailable","limits":{"7d":{"usedPct":98,"resetsAt":1790542799559,"expired":false}},
     "stale":true,"usageAt":1790457113000}]}
```

* Without cswap, neither field exists (older companions never send them).
  `$CONDUCTORE_CSWAP` overrides the lookup (a path, or empty for none).
* `label` is the alias, else a masked email (first letters and top-level
  domain). No email, organisation, uuid or token is ever printed or cached.
* `status` is cswap's `usageStatus` (`ok`, `unavailable`, `token_expired`,
  `api_key`, …). Without fresh usage the last good measurement is shown
  with `stale: true`; `usageAt` is when it was measured.
* Cost: one `cswap list --json` per minute at most (0.1–1 s; cswap reads
  its own usage store), 3 s timeout, its own process group killed on
  timeout, nice 10. The answer, a failure too, is cached 60 s in
  `~/.conductore/cswap-cache.json`; after a failure the last good rows are
  served for 15 minutes with `cswap.stale: true` and `cswap.error`
  (`timeout`, `unavailable`), then `accounts: []`.

### `conductore-hostd cswap-switch <slot> | --best`

Switches the Claude Code account for new sessions on this machine: `cswap
switch <slot> --json`, or `cswap switch --strategy best --json` (the
account with the most headroom). Running sessions keep their account.

```json
{"ok":true,"switched":true,"reason":"switched","strategy":"explicit",
 "from":{"slot":1,"label":"work"},"to":{"slot":2,"label":"b***@e***.org"}}
```

`switched: false` with `reason: "already-active"` (or cswap's other no-op
reasons) when nothing changed. Errors exit 1 with `{"error"}` (emails
masked): cswap missing, a bad slot, cswap's own error, or no answer in 20 s.
The account cache is dropped so the next `usage` shows the new state.

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
  `approveAllSafe`, `trust`, `send`, `read`, `usage`, `catchUp`, `home`,
  `say`;
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

### `conductore-hostd digest [--since <ms>] [--summaries] [--max-agents 10] [--max-ms 30000] [--lang en|pt] [--stuck-working-min 30] [--stuck-errors 3] [--stuck-repeats 5] [--stuck-approval-min 60]`

The phone's agents dashboard: for every agent, what it did since `--since`
(epoch ms, the user's last look; default two hours ago), whether it looks
stuck, and a one- or two-sentence summary. Exactly one JSON document on
stdout and exit 0 in every case (bad flags: `{"schema":1,"error":"failed","message":…}`).

```json
{"version":"0.8.0","schema":1,"machine":"devbox","generatedAt":1790516991122,"since":1790509791122,
 "source":"daemon","activity":true,
 "thresholds":{"workingMin":30,"sameError":3,"sameCommand":5,"approvalMin":60,"windowMin":60},
 "counts":{"needsYou":1,"stuck":1,"working":2,"done":3,"total":7},
 "agents":[{"sessionId":"0f2c…","name":"api","machine":"devbox","project":"api","cwd":"/home/andre/api",
   "state":"needs_permission","attention":"permission","live":true,"startedAt":…,"endedAt":null,
   "lastActivityAt":1790516900000,"headline":"Tests pass; pushing the branch next.","lastError":null,
   "pending":[{"id":"3671d8715ac1","toolName":"Bash","summary":"git push","createdAt":…,"risk":{"level":"medium","reason":"…"}}],
   "facts":{"turns":3,"files":["lib/a.js","test/a.test.js"],"filesEdited":2,"linesAdded":48,"linesRemoved":9,"lines":"git",
            "commands":14,"failedCommands":2,"testRuns":4,"testsPassed":3,"testsFailed":1,
            "lastTest":{"ok":true,"at":…,"command":"npm test"},
            "waitingPermissionMs":120000,"waitingInputMs":0,
            "tokens":{"input":210,"output":9800,"cacheWrite":42000,"cacheRead":910000,"total":962010},"costUsd":0.41,"partial":false},
   "stuck":[],
   "summary":{"text":"Fixed the date parsing bug and the tests pass. It wants to push the branch: approve or deny.","at":…,"fresh":true},
   "summaryPending":false}],
 "summaries":{"enabled":true,"pending":0,"done":1,"calls":1,"ms":4100,
              "tokens":{"input":2900,"output":60,"cacheWrite":0,"cacheRead":0,"total":2960},"costUsd":0.0032,"model":"claude-haiku-4-5-20251001"},
 "summaryUsageToday":{"runs":3,"calls":4,"tokens":{…},"costUsd":0.011},
 "ms":4180}
```

Facts (free; no Claude):

* The daemon keeps a per-agent activity log from the hook events it
  already parses (`lib/activity.js`): prompts, turn ends, API-error stops,
  edits (file path and an estimate of lines added and removed), Bash
  commands (first line, cut to 120 characters, and whether it is a test
  runner), failed tool calls (PostToolUseFailure: the command or tool and
  the first line of its error) and state changes. Never tool input. At most
  300 entries, 200 file paths and 60 command labels per agent and 64
  agents; an agent stays 24 h after its last entry, so agents the state
  pruned an hour after they ended still show under "done". In memory,
  written to `activity.json` (0600) with the state snapshot's 1 s debounce;
  nothing runs at idle.
* `turns` counts prompts; `files` (relative to the agent's cwd, at most 12)
  and `filesEdited` the edited files; `linesAdded` / `linesRemoved` come
  from `git diff --numstat HEAD` of those files (uncommitted changes, one
  call per repository, 1.5 s cap), else from the edit estimate
  (`lines`: `git`, `mixed`, `estimate`, or null without edits);
  `testRuns`, `testsPassed`, `testsFailed` and `lastTest` from Bash
  commands that run a test runner (npm/yarn/pnpm/bun test, pytest, go test,
  cargo test, flutter/dart test, node --test, jest, vitest, rspec, …) and
  whether they succeeded (PostToolUse) or failed (PostToolUseFailure);
  `failedCommands` every failed tool call; `waitingPermissionMs` /
  `waitingInputMs` the time spent in those states within the window.
* `tokens` and `costUsd` (estimate, `lib/pricing.js`): the assistant
  messages of the window, from the last 2 MB of the agent's transcript
  (`partial: true` when the window starts before that, or before the
  activity log's oldest entry). Only for agents active in the window.
* `attention`: `permission` (a pending request or a terminal prompt),
  `question` (it asked something: AskUserQuestion, ExitPlanMode, or its
  last reply ends with a question mark) or null (working, done, idle). `headline`: the first line of the last assistant
  message (markdown stripped, 160 characters). `live: false`: the agent
  is only in the activity log (it ended and was pruned); nothing can be
  sent to it. `lastError`: `{type, at}` when the last turn ended on an API
  error (also on `status`).
* Agents that ended before `--since` and were quiet since are left out.
  `counts`: needsYou (attention), stuck, working, done (the rest).
* `sources`: where failures and API errors come from: `hooks`, or
  `transcript` when PostToolUseFailure / StopFailure are not registered.
  Then the Bash calls and failed tool calls in the transcript tail (the
  last 2 MB, `partial` when the window starts before it) replace the log's
  command entries, and an API error message the last turn ended on (with
  no prompt after it) counts as an error stop.
* `activity: false`: the daemon predates `digest` (only `status` facts).
  `source` as in `status`.

Stuck flags (free), each `{rule, reason}`:

| rule | when (defaults; flags change them) |
| --- | --- |
| `no-progress` | working for 30 min (`--stuck-working-min`) without editing a file |
| `same-failure` | the same failed command, or the same error, 3 times (`--stuck-errors`) |
| `repeating` | the same command 5 times (`--stuck-repeats`; `git status`, `ls`, `cat` and similar are ignored) |
| `waiting-approval` | a permission request waiting 60 min (`--stuck-approval-min`) |
| `error` | the last turn ended on an API error (rate limit, overload, auth, …) and nobody prompted since |

Repeats count within the last 60 minutes and since the last prompt.

Summaries (`--summaries` only, never on a schedule):

* Without the flag, `digest` answers at once with the facts and the cached
  summaries (`summary.fresh: false` when the agent did something since),
  and sets `summaryPending` on the agents a `--summaries` call would
  summarise: active in the window, changed since their last summary. The
  phone shows the facts, then makes the second call.
* With it, up to `--max-agents` (1–30, default 10) of those, most recently
  active first, are summarised: five agents per `claude -p` call, at most
  two calls at once, all within `--max-ms` (5–120 s, default 30 s,
  counted from the start). Each agent goes in as its facts, stuck reasons,
  what it waits for, its previous summary, its last prompt (500
  characters) and its last three replies since that summary (1,500
  characters each; at most 12,000 characters per agent), never a whole
  transcript. The answer (`--json-schema`: one `{id, summary}` per agent,
  in `--lang`) is stored in `digest.json` (0600) with the activity time it
  covers; the next run of an agent with nothing new reuses it without a
  call. Entries of agents gone for 24 h are dropped, at most 64 are kept.
* It runs `claude -p --tools "" --safe-mode --no-session-persistence
  --output-format json --model haiku --system-prompt <fixed instruction>
  --json-schema <fixed schema>` with the agents on stdin between random
  delimiters, `MAX_THINKING_TOKENS=0`: the same lock-down as `summarize`
  and `guide`. Nice 10, claude in its own process group killed on timeout
  or a signal, one run per user at a time (`digest.lock`; a second run
  gets `summaries.error: "busy"` and the facts).
* `summaries`: `done`, `pending` (still to do: over the cap or failed),
  `calls`, `ms`, `tokens` and `costUsd` as claude reported them, `error`
  (`claude-missing`, `not-logged-in`, `timeout`, `busy`, `failed`).
  `summaryUsageToday` adds up today's runs; `usage` reports the same as
  `companion.digest` (these calls write no transcript, so the transcript
  scan never sees them).
* Cost: one call for five changed agents sends about 2–3k tokens per agent
  (plus ~600 of instruction) and gets ~60 back per agent. See CHANGELOG
  for the measured numbers.

### Turn snapshots: `turns`, `diff`, `undo`, `redo`

For the phone's Review mode and "Undo this turn". The daemon snapshots the
agent's repository at the start of every turn (UserPromptSubmit) and at its
end (Stop or StopFailure; a turn interrupted with Escape sends neither, so
it ends where the next prompt's snapshot starts).

A snapshot is an ordinary commit object whose tree is the work tree as it
is on disk (tracked files, and untracked files that are not ignored) and
whose parent is HEAD, kept by a ref
`refs/conductore/snapshots/<session>/<turn>/before|after`. It is built with
plumbing and a temporary index, never the user's:

    cp .git/index ~/.conductore/tmp/snap-….index        (read once: stat data)
    GIT_INDEX_FILE=<tmp> git add -u
    GIT_INDEX_FILE=<tmp> git ls-files -z -o --exclude-standard
    GIT_INDEX_FILE=<tmp> git update-index --add --remove -z --stdin   (untracked)
    GIT_INDEX_FILE=<tmp> git write-tree
    git commit-tree <tree> -p HEAD      (author Conductore; no hooks run)
    git update-ref refs/conductore/snapshots/<session>/<turn>/before <commit>

So the branch, HEAD, the index, the stash and the work tree are never
touched; `git status`, `git log`, `git stash list` and `git branch` look the
same. Every git runs with `GIT_OPTIONAL_LOCKS=0` (a read never rewrites the
real index), without inherited `GIT_*` variables, at nice 10 (Linux derives
the I/O priority from it), in its own process group, killed after 20 s
(`CONDUCTORE_SNAPSHOT_TIMEOUT_MS`). The hook itself is unchanged: it spools
the event and exits; the daemon queues the snapshot (one at a time) and
never waits for it. Anything that fails makes the snapshot a skip with a
reason in the turn record (logged, unless the cwd is simply not in a git
repository); the agent never notices.

Skipped, before anything is hashed: a cwd outside a git work tree, a repo
whose index is over 16 MB (about 150,000 tracked files;
`CONDUCTORE_SNAPSHOT_MAX_INDEX_BYTES`), more than 20,000 untracked files
(`…_MAX_UNTRACKED`) or 256 MB of them (`…_MAX_UNTRACKED_BYTES`). One
untracked file over 32 MB (`…_MAX_FILE_BYTES`) and nested repositories are
left out of the snapshot (listed as `excluded` in its commit message), and
`undo` never deletes them. `CONDUCTORE_SNAPSHOTS=0` turns snapshots off.

A change the agent makes before the "before" snapshot finished may be in
it: the turn then carries `late: true` (an Edit, Write or Bash call arrived
first). Under normal load the snapshot is done long before the model's
first tool call.

Pruning: the last 50 turns per session (`CONDUCTORE_SNAPSHOT_KEEP_TURNS`)
and 7 days (`CONDUCTORE_SNAPSHOT_KEEP_MS`); a session quiet for 7 days goes
with all its refs. Each repo is also swept (at most every 6 h, after a
snapshot) for snapshot refs older than 7 days whose record was lost. The
refs have no reflog, so `git gc` removes their objects as it does any
unreachable object (after `gc.pruneExpire`, two weeks by default).

Cost measured on development-central on a copy of this repository (1,188
tracked files, 180 MB with `.git`), with the machine at load 75-95 on 12
cores from other builds: 40 ms of CPU per snapshot, 210-230 ms wall at nice
10 (a single `git` start alone takes ~140 ms at nice 10 under that load, 19
ms at nice 0). A snapshot with nothing changed adds one commit object (and
none when it is identical to the last one); with one edited file, four
objects (the blob, the trees on its path, the commit), 24 KB on disk as
loose objects. Hook latency is unchanged (see CHANGELOG).

#### `conductore-hostd turns <sessionId> [--limit 20]`

```json
{"sessionId":"0f2c…","snapshots":true,"source":"daemon","agent":{"name":"api","state":"waiting_input","cwd":"/home/andre/api","endedAt":null},
 "cwd":"/home/andre/api","pending":0,
 "turns":[{"turn":3,"prompt":"Fix the date parsing bug","startedAt":1790526091313,"endedAt":1790526151964,"running":false,
   "repo":"/home/andre/api","files":[{"path":"lib/date.js","status":"M","added":12,"removed":3}],"filesTotal":1,"added":12,"removed":3,
   "committed":false,"late":false,
   "before":{"ref":"refs/conductore/snapshots/0f2c…/3/before","commit":"b9d2…","head":"f2c6…","ms":175,"untracked":0,"excluded":0,"at":…},
   "after":{"ref":"refs/conductore/snapshots/0f2c…/3/after","commit":"63c5…","head":"f2c6…","ms":193,"untracked":1,"excluded":0,"at":…},
   "others":[],"undone":null}]}
```

* Newest first. `prompt`: the first line of the prompt (160 characters).
  `files` (at most 50; `filesTotal` counts all): the paths that differ
  between the two snapshots, `status` `A` `M` `D` `T` (no rename
  detection). `committed`: HEAD moved during the turn.
* `before` / `after` are `null` while queued, or `{"skipped": reason}`.
  `after.fromNext`: the turn was interrupted; its end is the next turn's
  start.
* `others`: sessions with a turn in the same repository at the same time.
  Their changes are in this turn's snapshots too (and an undo reverts them).
* `undone`: `{at, kind: "turn"|"file", ref}` while the last `undo` of the
  turn has not been redone.
* `pending`: snapshots of this session still queued. `source`: `daemon`,
  `file` (daemon down: `turns.json`) or `none`.

#### `conductore-hostd diff <sessionId> <turn> [--file <path>]… [--max-bytes 1048576] [--max-file-bytes 65536] [--context 3]`

The turn's changes between its before and after snapshots (waits up to 25 s
for the session's queued snapshots). A turn still running (or whose end
was not captured) is compared with the work tree as it is now (`live: true`).

```json
{"sessionId":"0f2c…","turn":3,"prompt":"Fix the date parsing bug","repo":"/home/andre/api","startedAt":…,"endedAt":…,
 "live":false,"committed":false,"late":false,"others":[],"added":13,"removed":3,"truncated":false,
 "files":[{"path":"lib/date.js","status":"M","added":12,"removed":3,"binary":false,"mode":"100644","patch":"@@ -10,7 +10,16 @@ …\n"},
          {"path":"logo.png","status":"A","added":0,"removed":0,"binary":true,"patch":null,"oldSize":null,"newSize":48213,"mode":"100644"}]}
```

* `patch`: the hunks of a unified diff (from the first `@@`), capped at
  `--max-file-bytes` per file (`truncated: true`) and `--max-bytes` in all
  (later files `omitted: true`, `patch: null`). Binary files and
  submodules have no patch, only `oldSize` / `newSize`.
* `--file` (repeatable) limits the answer to those paths.
* Errors: `no before snapshot for this turn (<reason>)`, `unknown turn N`,
  `no turns recorded for session …`.

#### `conductore-hostd undo <sessionId> <turn> [--file <path>]… [--dry-run] [--keep-commits]`

Restores the work tree (or only the `--file` paths) to the turn's "before"
snapshot: files the turn changed or deleted come back exactly (content,
mode, symlinks), files created since are deleted (and their directories
when left empty). Without `--file` it restores the whole tree to that
moment, so later turns are undone too (`laterTurns` lists them).

```json
{"ok":true,"sessionId":"0f2c…","turn":3,"dryRun":false,"repo":"/home/andre/api",
 "restored":[{"path":"lib/date.js","action":"write","added":3,"removed":12,"binary":false},
             {"path":"lib/new.js","action":"delete","added":0,"removed":20,"binary":false}],
 "skipped":[],"redo":{"ref":"refs/conductore/snapshots/0f2c…/3/undo-1790526094125"},
 "headMoved":false,"laterTurns":[],"others":[]}
```

* Safety: refused while the agent is `working` or `needs_permission`
  (`code: "busy"`). It first snapshots the current state (the `redo` ref,
  whose message lists the paths restored), then writes files from a
  temporary index with `git read-tree` and `git checkout-index`: the real
  index, HEAD, branches, commits and the stash are never touched. When the
  index stages changes to a restored file, `staged` lists them with a
  `note`.
* Commits: if HEAD is no longer where it was when the turn started (the
  agent committed during the turn, or anyone did since), undo is refused
  with `code: "head-moved"` and the number of commits. There is
  deliberately no option that resets the branch: moving a branch can lose
  work the phone cannot see (other worktrees, pushed commits) and would
  break "never touches HEAD". `--keep-commits` restores the files anyway;
  the commits stay and the work tree shows their changes reverted, ready
  for `git commit` or a manual reset.
* `--dry-run` lists `restored` and `skipped` and changes nothing.
* `added` / `removed` are what the undo does to the file.

#### `conductore-hostd redo <sessionId> <turn> [--dry-run]`

Puts back what the last `undo` of that turn changed (only those paths),
from the snapshot the undo took first; it snapshots the state it replaces
too (`redo-*` ref). Refused while the agent works or when HEAD moved since
the undo. `nothing to redo for this turn` when the last undo was redone.

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
* `version`: `{"version":"0.7.0","protocol":1,"node":"22.23.1","capabilities":["smart-approvals","digest"]}`
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

## Approval rules

The phone can tell the companion to answer some requests by itself: a
time-boxed trust ("Allow `npm test` in this repo for 15 min"), or a rule
saved from "Always". They live in `~/.conductore/rules.json` (mode 0600),
never in Claude Code's settings, so they work with the phone offline and go
away when revoked.

When a PermissionRequest arrives the daemon first rates it (`lib/risk.js`,
below). Unless it is high risk, it checks the active rules (`lib/rules.js`);
a match is answered `allow` at once, before any tmux or Herdr lookup: the
request never shows as pending, the agent stays `working` with
`lastAutoApprovedAt` set, and it is logged in `auto-approved.json` (the
phone's "Auto-approved" list). Claude Code's own terminal prompt is up
meanwhile, exactly as without a rule; the hook's answer clears it. Nothing
is auto-approved unless the user created a rule.

Syntax: Claude Code's own `Tool` / `Tool(content)`:

| Rule | Covers |
| --- | --- |
| `Bash(npm test)` | exactly that command |
| `Bash(npm test *)` | `npm test` and `npm test <anything>` (`*` is any text; `npm test:*` is the same) |
| `Edit(src/**)` | Edit, Write, MultiEdit, NotebookEdit under `src/` of the rule's repo (`**` any depth, `*` one segment, `//abs/path` and `~/path` absolute, a pattern without `/` at any depth) |
| `Read(docs/**)` | Read, Grep, Glob, LS under `docs/` |
| `WebFetch(domain:docs.rs)` | that host and its subdomains |
| `mcp__github` | every tool of that MCP server |
| `Bash`, `Edit`, … | every call of the tool |

A Bash rule covers a compound command (`&&`, `;`, `|`) only when every
command in it is covered; `cd <dir>` and read-only filters after a pipe
(`| tail -20`, `| grep x`) need no rule. A command with `$(…)`, backticks
or unbalanced quotes is covered only by a rule for that exact command (or a
bare `Bash`). Scopes: `repo` (sessions whose cwd is inside the path),
`session` (one agent session; dropped when it ends) or `any`. Expiry is
checked when a rule is used; no timer runs.

### Risk labels

Every request gets `low`, `medium` or `high` and a one-line reason:

* low: read-only tools (Read, Grep, Glob, LS, WebSearch, WebFetch of a
  well-known documentation or package site), read-only commands (`ls`,
  `cat`, `rg`, `git status|diff|log|show`, `docker ps`, …), test and lint
  runs (`npm test`, `pytest`, `go test`, `flutter analyze`, …).
* medium: edits inside the repo, installs, builds, scripts, commits, plain
  pushes, anything unknown (including MCP tools and unknown web sites).
* high: recursive deletes, deletes or writes outside the repo (temp dirs
  excepted), secrets paths (`.env`, `~/.ssh`, `~/.aws`, key files,
  `.git-credentials`, …), `sudo`/`su`, force pushes, hard resets,
  `git clean -f`, `curl … | sh`, network commands to hosts outside a short
  known list, `ssh`/`scp`/`rsync` to remote hosts, global installs,
  publishing, service and cluster changes, edits in `.git/` or
  `.claude/settings*.json`.

High is never batchable and never answered by a rule: it always asks.
The classifier is pure and conservative (unknown means medium, a complex
command takes the highest of its parts). `test/risk.test.js` holds the
sample table.

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
* Snapshots write only objects and refs under `refs/conductore/` in the
  agent's own repository, with git plumbing (no hooks run, no reflog, no
  config read beyond git's own). `undo` / `redo` write files inside the
  repository's work tree only (paths resolving outside it are skipped) and
  refuse while the agent works. A snapshot holds what is on disk, so it can
  contain untracked secrets the repository does not ignore; they stay in
  `.git` until pruned and collected, like any stash.
* `send` types into the agent's pane, which is what the SSH user could do by
  attaching to tmux/Herdr anyway. It refuses while a permission prompt is
  waiting so a prompt cannot answer it by accident.
* `transcript` only reads the `transcript_path` Claude Code reported for a
  known session (absolute, `.jsonl`), and drops thinking text and images.
* Approval rules are created only by the user (phone or CLI), stored 0600
  in the state dir, and can never answer a request rated high. A rule is
  only as narrow as its pattern: `Bash` with scope `any` allows every
  medium-risk command in every repo until revoked.
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
daemon runs with `--max-old-space-size=64 --max-semi-space-size=1
--lite-mode --no-expose-wasm --v8-pool-size=1` (`lib/paths.js`): lite mode
(no optimizing compiler) touches about 6 MB less and costs no measurable CPU
at this load (0.35 vs 0.37 ms per event), one V8 worker instead of four drops
three threads; `--jitless`, `--single-threaded` and glibc
`MALLOC_ARENA_MAX=1` saved nothing more. The heap limits mostly cap growth;
the old-space limit is only a ceiling (idle RSS is the same at 16 and 64 MB).
16 MB was too low: the long-poll buffer (1000 change records, each carrying
the agent's pending prompts) aborted the daemon when a few long permission
prompts waited during heavy subagent activity. The buffer is now also capped
at 2 M characters, and the daemon's stderr goes to `hostd.log`, so a fatal
V8 error leaves a line there.

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
  hostd.pid>` plus, where `/proc` exists, the process name: the daemon sets
  its title to `conductore-hostd` (`/proc/<pid>/comm` reads
  `conductore-host`), so a pid recycled after a reboot or a hard crash does
  not count. The daemon checks the same (the command line, through `ps`
  without `/proc`) before it gives up the lock. On macOS the sh clients have
  only `kill -0`: a recycled pid can delay the automatic restart until the
  phone's next `status`/`events` (which pings the socket and restarts it).

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
`test/risk.test.js` the risk classifier (a table of 260+ real commands and
tool calls) and the shell reader, `test/rules.test.js` rule syntax,
matching, scopes, expiry and suggestions, `test/approvals.test.js` trust,
rules, `approve-low`, the auto-approved log and the hook's auto-answer
latency through a real daemon, `test/audit.test.js` the log's byte cap,
`test/digest.test.js` the activity log (facts from synthetic events, caps,
pruning), the stuck rules and `digest` with a fake `claude` (argv, stdin,
schema, only changed agents, rolling summaries, batches and caps, timeout
kill, lock, the 0600 store) and through a real daemon,
`test/snapshots.test.js` per-turn snapshots through a real daemon on
throwaway repos (the index, stash, HEAD and branch unchanged, untracked in
and ignored out, a slow git never delaying the hook, `turns`, `diff`,
`undo`, per-file undo, `redo`, refusal while working and after a commit,
pruning, the size limits), `test/summarize.test.js` the `summarize` command with a fake `claude`
(argv, passthrough, markdown and word cap, timeout kill, busy, truncation),
`test/cswap.test.js` cswap accounts with a fake `cswap` and a fixture of
the real `list --json` shape (email masking, timeout kill, 60 s cache and
stale fallback, `cswap-switch`),
and
`test/daemon.test.js` spawns a real daemon on a temp socket and drives the sh
hook and the CLI through spool handoff (daemon down, ordering, staging
cleanup), tmux/Herdr location, the FIFO permission flows (allow, deny,
always, timeout, killed hook, daemon stopped or killed mid-wait, no daemon at
all), long-poll, restart and doctor.
