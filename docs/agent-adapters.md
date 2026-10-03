# Agent adapters (companion and app)

CON-045 makes Conductore agent-agnostic. Step 2 (this document's state)
moved Claude Code onto an adapter interface with no behaviour change; Codex
(CON-068) and OpenCode (CON-069) are the next adapters. The research and
the per-agent findings are in the design doc
(`/root/.config/conductore/agent-adapters-design.md`, 2026-09-27); this page
is the code as it is.

## Companion: where things are

| What | File |
| --- | --- |
| Registry (`get`, `forHeader`, `of`, `capabilityMap`, `brain`) | `host/lib/adapters/index.js` |
| Interface and shapes (JSDoc) | `host/lib/adapters/types.js` |
| Claude Code adapter (the reference) | `host/lib/adapters/claude.js` |
| Neutral chat format for new agents | `host/lib/adapters/chat-items.js` |
| Contract every adapter must pass | `host/test/helpers/adapter-contract.js` |
| Claude Code's contract run, byte-compat checks, a fake second adapter through the daemon | `host/test/adapters.test.js` |

Who calls the registry:

* `daemon.js` `process()`: picks the adapter from the spool header
  (`agent=<id>`, none = Claude Code), calls `normalize()` and
  `identifyProcess()`; an unknown agent's event is dropped and its waiting
  hook let go. `settle()` and `approval-ops.js` write `hookAnswer()` into the
  waiting hook's FIFO; `decide … answer` checks with `checkAnswers()`.
  `status` (full replies) carries `adapters`, the capability map.
* `cli.js`: `transcript` (`readTranscript`), `send` (`sendPrompt`, else the
  pane), `interrupt` (`interrupt`, else `interruptKey` in the pane),
  `install` / `uninstall` (Claude Code first, then every other present
  adapter, under `agents`), `doctor` (other adapters' checks appended, all
  optional), `usage` and `cswap-switch` (Claude Code's `accounts`,
  `switchAccount`), `version` (`adapters`).
* `summarize.js`, `guide.js`, `digest.js`: the brain runner
  (`registry.brain(env)` → `runner.run({system, prompt, schema, model,
  timeoutMs})`), same lock, same error codes.
* `digest.js`: `readTail()` of the agent's own adapter (activity meta keeps
  a non-Claude `kind` so ended agents are read by theirs too).

## The one rule: the daemon speaks Claude Code's hook vocabulary

`state.reduce()`, `activity.js`, `turns.js`, `risk.js`, `rules.js` and
`approvals.js` work on Claude Code's hook input: `hook_event_name`
(SessionStart, UserPromptSubmit, PreToolUse, PostToolUse,
PostToolUseFailure, PermissionRequest, PermissionDenied, Notification, Stop,
StopFailure, SubagentStop, SessionEnd), `session_id`, `cwd`,
`transcript_path`, `tool_name`, `tool_input`, `last_assistant_message`, …
An adapter's `normalize()` maps its agent's events onto that, and sets
`agent_kind` to its id (that becomes the agent's `kind`).

Claude Code's tool names are the neutral tool vocabulary: map Codex
`exec_command` / Cursor `Shell` to `Bash`, `apply_patch` to `Edit`, a
question to `AskUserQuestion`, a plan to `ExitPlanMode`. Then risk labels,
rule matching (`Bash(npm test *)`), "approve all safe", the activity log and
the dashboard facts work unchanged. Optional extras on the event:

* `tool_kind`: the pending request's `toolKind` (bash, edit, write, read,
  search, web, task, mcp, todo, question, plan, other);
* `answerable: false`: the phone can only watch the request (Gemini).

Neither is ever set for Claude Code, so its JSON is unchanged.

## How to add an adapter

1. Create `host/lib/adapters/<id>.js` exporting at least `id`, `label`,
   `capabilities()` and `normalize()`; add what the agent supports
   (types.js lists every optional member). Require heavy modules lazily: the
   daemon loads the adapter on its agent's first event.
2. Add one line to `MODULES` in `host/lib/adapters/index.js` (after
   `claude`: the order decides the default brain).
3. Events in:
   * hook-based agents (Codex, Gemini, Cursor): register
     `conductore-hook --agent <id> <Event>` from `install()`. The sh hook
     writes `agent=<id>` into the spool header; everything else (FIFO wait
     for PermissionRequest, timeout, watchdog) is shared. Never write the
     agent's main config (design doc, "Integration rule").
   * plugin-based agents (OpenCode): the plugin writes spool files itself,
     same format (`host/lib/spool.js`), with `agent=<id>`.
4. Approvals: `approvals: 'hook'` + `hookAnswer(event, decision, message,
   answers)` returning the one line the hook prints (`'\n'` = let the
   agent's own prompt ask). `'server'` agents answer through the agent; the
   daemon side of that is not built yet (OpenCode, see below).
5. Chat: `readTranscript(agent, opts)` returns a page built with
   `chat-items.js` (`format: "items"`) or `{ error }`; set
   `capabilities().chat = 'items'`. Paging is by opaque cursor
   (`transcript --cursor` / `--before-cursor`). Optionally `readTail()` for
   the dashboard (types.js `Tail`).
6. Brain (optional): `brain.locate(env)` returning a runner whose `run()`
   resolves a `BrainOutcome`. No tools, read-only, no history written, never
   visible as an agent (set `CONDUCTORE_BRAIN=1` on the child and ignore it
   in your hooks/plugin). Use `agent-missing` as the missing error code.
7. Tests: `host/test/<id>-adapter.test.js` running
   `contract(adapter, fixtures)` with fixtures in
   `host/test/fixtures/<id>/` (one per tested agent version), plus the
   adapter's own cases.
8. A line under "## Unreleased" in `host/CHANGELOG`.

Files a new adapter normally touches: its own module, its tests and
fixtures, one line in `index.js`, the CHANGELOG. Anything else (state.js,
daemon.js, cli.js) means the interface is missing something: add the hook
point there in a small, separate commit so parallel adapters do not collide.

## App

* `AgentInfo.kind` (`agent_attention.dart`) was already parsed; a record
  without one is `claude`.
* `AgentKindCapabilities` / `AgentKindCatalog`
  (`lib/features/agent_attention/domain/agent_kinds.dart`) parse the
  companion's `adapters` map; `AgentAttentionSnapshot.kinds` carries it.
  Without a map (older companions) Claude Code gets what it has today and
  every other kind gets nothing.
* `supportsChatView(agent, catalog)` (`session_view_preferences.dart`) is
  the gate the Chat View entry points use; `isClaudeAgent()` stays for the
  wording that is still Claude-specific (step 6).
* `NeutralChatItems.parse()` (`lib/features/chat_view/domain/neutral_chat_items.dart`)
  turns `format: "items"` pages into the app's existing chat rows.

## Codex (CON-068, built)

`host/lib/adapters/codex.js` + `codex-rollout.js`, checked against real
Codex 0.160.0 and 0.130.0 runs in Docker (mock model API;
`host/test/fixtures/codex/README.md`). What the live runs showed, beyond
the design doc:

* Codex's hook input already is Claude Code's (`tool_name: "Bash"`,
  `tool_input.command`); only `apply_patch` (→ Edit with `file_path`) and
  `Interrupt` (→ Stop) need mapping. Allow/deny JSON works as designed.
* Trust: at start Codex asks "Hooks need review" (Trust all) or `/hooks`
  then `t`; it writes `[hooks.state."<hooks.json>:<snake_event>:<group>:<handler>"]
  trusted_hash` to config.toml. `doctor` reads that read-only; the key
  includes the position, so `install` updates our handlers in place.
* Daemon mode: hooks run in `codex app-server` (outlives the TUIs, its
  `TMUX_PANE` is the first TUI's). `origin()` (a new optional adapter
  hook, called by `daemon.process`) finds the session's TUI by cwd and
  takes its pid and pane from `/proc/<pid>/environ`; none when ambiguous.
  SessionEnd arrives a few seconds after a TUI quits.
* Rollouts: tools from `response_item` (both history modes), the user's
  prompt from `item_completed` UserMessage (paginated) or `user_message`
  (legacy). A denied exec has no `CommandExecution` item, only its output.
* Brain: `codex exec --ephemeral --json --sandbox read-only --disable
  shell_tool,unified_exec,hooks,... --ignore-user-config --ignore-rules`;
  `include_apply_patch_tool` is ignored by 0.160 (apply_patch stays, but the
  read-only sandbox rejects it).
* App: `renderableChatFormats` includes `items`; the Chat View pages by
  cursor and replaces an item re-sent with the same id.

## What the next adapters need (from the design doc)

**Codex (CON-068, hooks and pane first; socket later).**
`install()`: our entries in `~/.codex/hooks.json` (`{"hooks":{…}}`, merged
by our mark `conductore-hook --agent codex`), never `config.toml`; tell the
user to trust them once in `/hooks`, and have `doctor()` read the
`[hooks.state]` trust hashes read-only (`capabilities().setup =
['trust-hooks']`). `normalize()`: the 12 Codex hook events map almost 1:1
(Codex has no Notification/StopFailure; SessionStart `source`, Stop
`last_assistant_message`); tool names onto Claude's (`exec_command` → Bash,
`apply_patch` → Edit). Approvals: the PermissionRequest hook prints Claude's
exact decision JSON, so `hookAnswer` can reuse `permission.js` but without
`updatedPermissions` ("always" becomes a Conductore rule; `always: false`).
Liveness: comm `codex`; in daemon mode (0.157+) hooks run in Codex's daemon
environment, so `$TMUX_PANE` and the pid describe the daemon, not the TUI
(needs a live test; location may fall back to matching the pane's cwd).
Chat: rollout JSONL `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-*.jsonl`
(maybe `.zst`), both the paginated `item_completed` TurnItems (0.145+) and
legacy `response_item`, into `chat-items.js`. Usage: already in `usage.js`
(`codexLineHandler`, the `codex` section); limits from `token_count`
`rate_limits`. Brain: `codex exec --ephemeral --json --output-schema <file>
--sandbox read-only --disable shell_tool --skip-git-repo-check
--ignore-user-config -m <model>`. Accounts: show the active account and its
limits only (decision 8).

**OpenCode (CON-069, plugin only, no --port).**
`install()`: drop `~/.config/opencode/plugins/conductore.js`, a file we
own, exporting `{ id, server, setup }` (both loader shapes, like Herdr's);
never touch `opencode.json`. The plugin writes spool files itself with
`agent=opencode` and the pane env from `process.env`, folding child
sessions (`info.parentID`) into the root. `normalize()`: `session.status`
busy/retry → UserPromptSubmit/PreToolUse-like working, `session.idle` →
Stop, `permission.asked` → PermissionRequest, `question.asked` →
AskUserQuestion, `session.error` → StopFailure, `session.deleted` →
SessionEnd. Approvals are `'server'`: the plugin waits for the daemon's
decision and replies through `ctx.client` (`once` / `always` / `reject`);
this needs a daemon op the plugin can long-poll (a waiter without a FIFO),
which does not exist yet. Chat: SQLite via `opencode db "<sql>" --format
json` (read-only; Node 18 has no sqlite), cursor = last part id. Usage:
tokens and cost per assistant message (prefer OpenCode's own cost); no plan
limits (`limits: false`). Brain: `OPENCODE_DB=:memory:
OPENCODE_PERMISSION='{"*":"deny"}' opencode run --pure --format json` with
stdin closed; no schema in `run` (`brainSchema: false`).

## Where main moved since the design doc (2026-09-27)

* `host/lib/agents.js` already exists (agent-to-agent messaging,
  CON-037), so the adapters live in `host/lib/adapters/`, not
  `host/lib/agents/`.
* `status.agents` is the agent list, so the per-kind capability map is
  called `adapters`, not `agents`. It is not a new entry in `capabilities`
  either: that list is asserted exactly by `approvals.test.js`, and the
  map's presence is the feature flag.
* CON-062 (questions and plans) landed after the design: the
  AskUserQuestion answers (`decide … answer`), the plan's `updatedInput`
  echo and the plan's `setMode` "always" all sit in `permission.js`, behind
  `hookAnswer` / `checkAnswers`.
* cswap gained unmanaged logins (1.2.1) and is being reworked (CON-067):
  the adapter only wraps `cswap.accounts` / `switchAccount`.

## Deferred from the design's step 2 table

* 2c: `state.reduce()` still switches on `hook_event_name` (the design
  defers neutral event kinds to the Codex step, where they are testable).
* 2e: risk, rules and activity were not routed through a `toolKind` map:
  Claude Code's tool names are the neutral vocabulary instead, so they need
  no change. `toolKind()` exists for the phone's `pending[].toolKind`.
* 2g: the usage scanners (`claudeLineHandler`, `codexLineHandler`) stay in
  `usage.js` until CON-067 lands, to avoid conflicting with it.
* `talkbawt.js` runs its own `claude -p` for link summaries; not routed
  through the brain runner yet.
