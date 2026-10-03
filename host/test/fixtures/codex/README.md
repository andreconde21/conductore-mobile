# Codex fixtures

Written by real Codex CLI builds installed with npm inside Docker
(`node:22-bookworm-slim`, `--network none`, a scratch `HOME`, no account):
the model API was a local mock of the OpenAI Responses API (SSE) that
answered with a reasoning item, an `exec_command` call, an `apply_patch`
call and a final message, so every line below came from Codex itself.
Only long instruction texts (system prompt, AGENTS.md, skills, world
state) were shortened, marked `[shortened for the fixture]`.

| File | What |
| --- | --- |
| `0.160.0/rollout-tui.jsonl` | Session file of the interactive TUI on the shared app-server daemon (paginated history): three prompts, an escalated command and a patch approved in the TUI, both denied by the hook, both allowed by the hook |
| `0.160.0/hooks-tui.jsonl` | The hook input Codex sent for that session, in order (`body`), with the event name from argv. The hooks ran in the daemon (`codex app-server`), whose `TMUX_PANE` was the first TUI's |
| `0.160.0/config-hooks-state.toml` | The `[hooks.state]` tables Codex wrote to `config.toml` after `t` (trust all) in `/hooks` |
| `0.160.0/exec-brain.jsonl` | `codex exec --json` stdout of the brain call (`--ephemeral --output-schema`, tools and hooks off) |
| `0.130.0/rollout-exec-legacy.jsonl` | A `codex exec` session of 0.130.0 (legacy history: `user_message`, `agent_message`, `update_plan`) |
