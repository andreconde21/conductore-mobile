# Cursor CLI fixtures

Written by a real Cursor CLI (`agent`, also linked as `cursor-agent`)
2026.10.01-e373342, installed with `curl https://cursor.com/install | bash`
inside Docker (`node:22-bookworm`, a scratch `HOME`, no host mounts, no
Cursor account). Cursor's API was a local mock (`agent -e
http://127.0.0.1:8999`, `network.useHttp1ForAgent: true` in
`cli-config.json`) that answered the API key exchange, the model list and
the agent stream (`agent.v1.AgentService/RunSSE` + `BidiAppend`): a reply,
a shell call, a second reply, then the conversation checkpoint and its
message blobs. Everything below was written by Cursor itself; only the
model's messages came from the mock.

| File | What |
| --- | --- |
| `2026.10.01/hooks-tui.jsonl` | Hook input of an interactive session (the TUI in tmux), in order: `event` is the hook's argv, `body` the stdin JSON. Turn 1 runs `echo` (not allowlisted: Cursor asked "Run this command?", answered `y` in the terminal), turn 2 runs `ls` (allowlisted: no prompt), then Ctrl+C twice. `afterShellExecution` is recorded too (we do not register it) |
| `2026.10.01/claude-hooks-in-cursor.jsonl` | The same session's events as Cursor delivered them to the hooks in `~/.claude/settings.json` (Cursor runs Claude Code's hooks as well, with its own payload) |
| `2026.10.01/transcript-tui.jsonl` | `~/.cursor/projects/home-u-proj/agent-transcripts/<id>/<id>.jsonl` of that session |
| `2026.10.01/transcript-aborted.jsonl` | The transcript of a turn interrupted with Esc |
| `2026.10.01/cli-config.json` | The `cli-config.json` Cursor wrote (allowlist mode, `Shell(ls)`) |

What the runs showed:

* Hooks live in `~/.cursor/hooks.json` (`{"version":1,"hooks":{"<event>":[{"command":…}]}}`);
  Cursor runs each as `bash -c '<command> <<CURSOR_HOOK_EOF …'`, so the
  hook's grandparent is the `agent` process: node with comm `MainThread`,
  argv `[…/bin/agent, --use-system-ca, …/cursor-agent/versions/<v>/index.js, …]`.
  The hook inherits the agent's `TMUX`/`TMUX_PANE`.
* `beforeShellExecution` fires before Cursor's own prompt, for every
  command. `{"permission":"allow"}` does not skip that prompt (verified);
  only `deny` and `ask` change anything. Empty output = no effect.
* Headless `agent -p` fires `sessionStart`, `preToolUse`,
  `beforeShellExecution`, `postToolUse`, `sessionEnd` but not
  `beforeSubmitPrompt`, `stop` or `afterAgentResponse`.
* `stop` and `afterAgentResponse` arrive in either order. Esc gives a
  `stop` with `status: "aborted"`, then one with `status: "error"`.
* `transcript_path` is null until the first turn is written.
* The transcript has no timestamps and no tool results.
