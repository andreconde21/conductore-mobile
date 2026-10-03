'use strict'

// JSDoc only: the shapes of the agent adapter interface (CON-045). Nothing
// requires this file at run time. The contract test
// (test/helpers/adapter-contract.js) checks every adapter against it, and
// docs/agent-adapters.md explains how to add one.

/**
 * One agent's adapter: a CommonJS module in lib/adapters/<id>.js, listed in
 * MODULES of lib/adapters/index.js. Only `id`, `label`, `capabilities` and
 * `normalize` are required; everything else is optional and the
 * capability flags tell the phone what exists. Require heavy modules
 * lazily: the daemon loads an adapter for every event of its agent.
 *
 * @typedef {object} AgentAdapter
 * @property {string} id      'claude' | 'codex' | 'opencode' | ...; also the
 *                            `kind` of its agents and the `agent=` spool header
 * @property {string} label   'Claude Code', 'Codex', ...
 * @property {() => Capabilities} capabilities   static flags (no detection)
 *
 * Detection and registration (`install`, `uninstall`, `doctor`)
 * @property {(env?: object) => {present: boolean, version: string|null, bin: string|null}} [detect]
 * @property {(ctx: {hookBin: string, statuslineBin?: string, env?: object}) => object} [install]
 *           idempotent, backs up what it edits, never writes the agent's
 *           main config (design doc, "Integration rule"); returns what
 *           `install` prints for it, or { error }
 * @property {(ctx: object) => object} [uninstall]   removes only our entries
 * @property {() => Promise<Array<{name: string, ok: boolean, detail: string}>>} [doctor]
 *
 * Events
 * @property {(raw: object, header: object) => object|null} normalize
 *           One spool entry's JSON (and its header lines) -> the event the
 *           daemon reduces, in Claude Code's hook vocabulary (see below),
 *           with `agent_kind` set to the adapter id. Null drops it.
 * @property {(pid: number|string) => {pid: number, startTime: string}|null} [identifyProcess]
 *           the agent process a hook reported (header agent_pid, or
 *           claude_pid), only when it really is that agent
 *
 * Approvals
 * @property {'hook'|'server'|'observe'|'none'} [approvals]
 *           hook: a blocking hook waits on a FIFO (Claude Code, Codex);
 *           server: the adapter answers through the agent (OpenCode plugin);
 *           observe: the phone can only watch (Gemini)
 * @property {(event: object, decision: string, message?: string, answers?: object) => string} [hookAnswer]
 *           the whole line the waiting hook prints ('\n' = let the agent's
 *           own prompt ask). decision: allow | deny | always | answer | timeout
 * @property {(event: object, answers: object) => {updatedInput?: object, error?: string}} [checkAnswers]
 * @property {(toolName: string) => ToolKind} [toolKind]
 *
 * Chat and dashboard facts
 * @property {(agent: object, opts: object) => object} [readTranscript]
 *           one `transcript` page or { error }. Claude Code returns its own
 *           entries; every other agent returns a chat-items.js page.
 *           opts: since, before, tailBytes, maxBytes (byte paging) or
 *           cursor, beforeCursor (opaque paging)
 * @property {(agent: object, opts: {since: number, repliesSince: number, runsSince: number}) => Tail|null} [readTail]
 *
 * Input
 * @property {'pane'|'server'} [inputVia]
 * @property {(agent: object, text: string, opts: {enter: boolean}) => Promise<object>} [sendPrompt]
 *           server path; without it the prompt is typed into the pane
 * @property {(agent: object) => Promise<object>} [interrupt]   server path
 * @property {string} [interruptKey]   pane key (pane.js name), default 'escape'
 *
 * Usage
 * @property {string} [usageSection]   its key in `usage` (usage.js computes it)
 * @property {(input: object) => object|null} [liveUsage]   context and limits
 *
 * Brain
 * @property {{defaultModel: string, missing: {error: string, message: string}, locate: (env: object) => BrainRunner|null}} [brain]
 *
 * Accounts
 * @property {(opts: object) => Promise<object>} [accounts]
 * @property {(opts: object) => Promise<object>} [switchAccount]
 */

/**
 * Status `adapters.<id>` (and `version`): what the phone may offer for
 * this agent kind. Values only ever get added.
 *
 * @typedef {object} Capabilities
 * @property {string} events          'hooks' | 'plugin' | 'hooks+server' ...
 * @property {string} approvals       'hook' | 'server' | 'observe' | 'none'
 * @property {boolean} always         a native "always allow"
 * @property {boolean} questions      questions answered from the phone
 * @property {boolean} plans          plans approved from the phone
 * @property {string|false} chat      'entries' (Claude Code's format) | 'items' (chat-items.js) | false
 * @property {string|false} send      'pane' | 'server' | false
 * @property {string|false} interrupt 'pane' | 'server' | false
 * @property {boolean} liveUsage      context use per session
 * @property {boolean} limits         account limits
 * @property {boolean} history        token history in `usage`
 * @property {boolean} brain          can run summaries and the voice guide
 * @property {boolean} brainSchema    structured answers
 * @property {string|null} accounts   'cswap' | 'show' | null
 * @property {string} facts           dashboard facts: 'full' | 'partial' | 'none'
 * @property {boolean} undo           per-turn snapshots (agent-neutral today)
 * @property {string[]} [setup]       manual steps, e.g. ['trust-hooks']
 */

/**
 * The daemon's event vocabulary is Claude Code's hook input: an adapter's
 * normalize() maps its agent's events onto it.
 *
 *   hook_event_name  SessionStart | UserPromptSubmit | PreToolUse |
 *                    PostToolUse | PostToolUseFailure | PermissionRequest |
 *                    PermissionDenied | Notification | Stop | StopFailure |
 *                    SubagentStop | SessionEnd (state.js reduce)
 *   session_id, cwd, transcript_path, permission_mode, agent_id (subagent)
 *   tool_name, tool_input   Claude Code's tool names are the neutral ones
 *                    (risk.js, rules.js, activity.js): map exec_command or
 *                    Shell to Bash, apply_patch to Edit, questions to
 *                    AskUserQuestion, plans to ExitPlanMode
 *   last_assistant_message, message, notification_type, error
 *   agent_kind       the adapter id (sets the agent's `kind`)
 *   tool_kind        optional: the pending request's `toolKind`
 *   answerable       optional: false = the phone can only watch the request
 *
 * @typedef {'bash'|'edit'|'write'|'read'|'search'|'web'|'task'|'mcp'|'todo'|'question'|'plan'|'other'} ToolKind
 */

/**
 * What the dashboard reads from a transcript (digest.js readTail).
 *
 * @typedef {object} Tail
 * @property {Array<{at: number, text: string}>} prompts
 * @property {Array<{at: number, text: string}>} replies
 * @property {string|null} lastReply
 * @property {object|null} tokens
 * @property {number|null} costUsd
 * @property {boolean} [partial]   the window did not reach back far enough
 */

/**
 * @typedef {object} BrainRunner
 * @property {string} agent    the adapter id
 * @property {(req: BrainRequest) => Promise<BrainOutcome>} run
 *
 * @typedef {object} BrainRequest
 * @property {string} system     fixed instructions (no user text)
 * @property {string} prompt     the content, on stdin, between delimiters
 * @property {object} [schema]   JSON schema of the answer
 * @property {string} [model]
 * @property {number} timeoutMs
 * @property {(child: object) => void} [onChild]
 * No tools, read-only, no history written, never visible as an agent
 * (Claude Code: --tools "" --safe-mode --no-session-persistence; others:
 * their equivalents plus CONDUCTORE_BRAIN=1, which our hooks ignore).
 *
 * @typedef {object} BrainOutcome
 * @property {boolean} ok
 * @property {string} [error]      the wire code callers print: 'claude-missing'
 *                                 (Claude Code; 'agent-missing' for others),
 *                                 'not-logged-in', 'timeout', 'failed'
 * @property {string} [message]
 * @property {string|null} [text]  the answer as text
 * @property {object|null} [answer]  the structured answer (schema calls)
 * @property {string} [model]
 * @property {string} [noTextReason]
 * @property {object} [tokens]     { input, output, cacheWrite, cacheRead, total }
 * @property {number|null} [costUsd]
 */

module.exports = {}
