# Gemini CLI fixtures

Written by a real Gemini CLI 0.62.0 installed with npm inside Docker
(`node:22-bookworm-slim`, `--network none`, a scratch `HOME`, no account,
`GEMINI_API_KEY=fake`): the model API was a local mock of the Gemini API
(`GOOGLE_GEMINI_BASE_URL`, SSE `streamGenerateContent`) that answered each
prompt with a scripted reply, so every line below came from Gemini itself.
The TUI ran in tmux; the prompts were answered with keys sent to the pane.

| File | What |
| --- | --- |
| `0.62.0/session-tui.jsonl` | The session file of one TUI session: `touch made.txt` (prompted, allowed once), a `write_file` (prompted, refused with Esc: Gemini cancels the turn and re-records its rolled back history, then `$set.messages`), `read_file` (not prompted), `write_todos` (prompted, allowed), a reply with a thought |
| `0.62.0/hooks-tui.jsonl` | The hook input Gemini sent for that session, in order (`body`), with the event name from argv, the hook's parent command line (the relaunched `node … gemini` child) and its `TMUX_PANE`. No hook fires when a prompt is answered or refused; `PreCompress` fires on every turn; `SessionEnd` comes up to three times |
| `0.62.0/projects.json` | `~/.gemini/projects.json` of that run (directory to session folder) |

Also seen in those runs (not in a file): headless `gemini -p` refuses an
untrusted folder (exit 55) unless `--skip-trust` or
`GEMINI_CLI_TRUST_WORKSPACE=true`, and still records a session file; the
first TUI start in a folder asks to trust it and restarts Gemini.
