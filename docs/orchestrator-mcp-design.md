# Design note: the companion as an MCP server (CON-037, later)

Status: design only, nothing built.

## Goal

When several tasks start, a lead agent session (Claude Code, Codex, ...)
can run them all:

1. split the work and start the workers;
2. watch the digest;
3. answer low-risk approvals;
4. merge, then report.

High-risk approvals still go to the human. This is how Conductore itself
is built.

## Shape

`conductore-hostd mcp` is a stdio MCP server that the lead agent registers
in its own config. The user adds it (we never write an agent's main
config). Each tool is a thin wrapper over a command the companion already
has, so the CLI, the phone and the orchestrator share one implementation:

| Tool | Command | Notes |
|---|---|---|
| `start_tasks` | `task-start` | tasks, repo, agent, place, cap, attempts |
| `task_runs` | `task-runs list` | runs with linked agents and outcomes |
| `digest` | `digest --since` | facts and stuck flags per agent |
| `agents` / `send` / `wait` / `read` | `agents`, `agent-send`, `agent-wait`, `agent-read` | messages to workers |
| `approve_low` | `approve-low --session` | only the lead's own workers |
| `trust` | `trust` | scope `session` only, time-boxed |
| `status` | `status` | |
| `worktree_list` | `worktree list` | no remove tool |

## Rules

- **Scope:** the lead sees only the runs of batches it started, plus their
  agents (by `batchId`). It never sees the user's other sessions, so
  starting it from a task cannot reach unrelated work.
- **Approvals:** `approve_low` and `trust` answer only requests that risk.js
  classifies as low and that come from those agents. Anything else stays
  pending for the phone. The orchestrator gets no `decide` tool.
- **Untrusted text:** task text, digests and other agents' replies reach
  the lead as data, framed the way `agent-send --context-from` frames
  relayed text.
- **Limits:** a per-batch cap on runs started through MCP, plus the
  machine's cap.
- **Audit:** every tool call is logged to the approvals audit with
  `via: "mcp"`, so the phone can show what the lead did.
- **Merging:** the lead merges branches with its own git. The companion
  adds no merge tool, so the lead's own approval rules govern it.

## Open questions for André

1. Should the orchestrator be allowed to start tasks on other machines
   (through the phone relay), or only on its own machine?
2. Should a worker's high-risk approval also notify the lead, or only the
   phone?
3. Should a run started by the lead be able to move a task to done
   (`markDone`), or should that stay a phone-side choice?
