# Starting tasks (CON-037)

A task, or a batch of tasks, starts as agents on a machine. Each task (and
each attempt at it) gets its own git worktree, branch, place and agent. The
companion does the work on the machine; the app picks the tasks, the
machine, the repository, the agent and the place.

## Companion commands

`conductore-hostd worktree <create|list|remove> -` (JSON on stdin):

- `create {repo, branch, base?, location?}` runs `git worktree add -b
  <branch> -- <path> <base>` and nothing else. The main worktree's HEAD,
  index and files are never touched. The command checks its inputs first:
  - the repository must be a git work tree, given as an absolute path or
    `~/…`;
  - the branch must be a new, valid branch name (`git check-ref-format
    --branch`, no leading dash);
  - the base must be a commit;
  - the target must not exist yet and must not be inside the repository.

  The location defaults to the `worktree-location` setting:
  - `next-to-repo` (the default) puts it at `<parent>/<repo>-wt/<branch>`;
  - `herdr` puts it at `~/.herdr/worktrees/<repo>/<branch>`;
  - a template uses `<repo>` and `<branch>`.

  Slashes in the branch name become dashes in the directory name.
- `list {repo}` lists the repository's worktrees.
- `remove {repo, path}` removes a linked worktree. It never removes the main
  one and never uses `--force` (git refuses a worktree with changes). The
  branch stays.

`conductore-hostd task-start -` (capability `task-runs`) takes:

```json
{"repo": "~/src/app", "agent": "claude", "place": "herdr",
 "tasks": [{"ref": "<source>/<id>", "key": "CON-1", "title": "…", "url": "…", "prompt": "…"}],
 "base": "HEAD", "location": null, "attempts": 1, "cap": 3,
 "branchPrefix": "task", "herdrServer": null, "workspaceId": null, "markDone": false}
```

With `"worktree": false` a run works in the repository as it is (no
branch), and links only an agent that started with it. Otherwise it queues one run per task and attempt, on branch
`<prefix>/<slug of the key>[-a<attempt>]` (`-2`, `-3`, ... when the branch
is taken). It then starts runs while fewer than the cap (1 to 20, default
3, across every batch on the machine) are starting or running. Starting a
run takes these steps:

1. Create the worktree.
2. Write the prompt to `~/.conductore/task-runs/<id>/prompt.md` (0600).
3. Open the place:
   - `herdr`: the batch's first run creates an unfocused workspace and uses
     its first pane, and the batch's other runs open tabs in it. Pass
     `workspaceId` to use an existing workspace.
   - `tmux`: `new-window -d` in the default server (a detached session when
     none runs). The user's current window stays selected.
   - `none`: nothing is opened. The run carries `command`, and the app runs
     it in a terminal of its own on the machine.
4. Type the launch line into the place's shell:

   ```sh
   cd '<worktree>' && 'claude' "$(cat '<prompt file>')"
   ```

The prompt goes neither in a command line nor in keystrokes. The launch
command per agent:

| Agent | Command |
|---|---|
| Claude Code | `claude` |
| Codex | `codex` |
| OpenCode | `opencode --prompt` |
| Gemini | `gemini --prompt-interactive` |
| Cursor | `cursor-agent` |

An adapter can override its launch command with `launchArgs()`.

`conductore-hostd task-runs [list | cancel <id> | keep <id> [off] | forget
<id> [--delete-branch] | cap <n>]` (`remove` is `forget`) reports every run,
linked to its agent. The run's states are `queued`,
`starting`, `running`, `finished`, `failed` and `cancelled`, plus:

- `outcome`: `done`, `error` or `gone`;
- `sessionId`, `agentState` and `lastMessage`;
- `herdr` or `tmux` (where the run is) and `error`.

## Following a run to done

- **Linking:** the agent is linked to its run by its working directory. The
  worktree is new, so the first agent that reports a cwd inside it belongs
  to the run.
- **Finishing:** the run is `finished` when one of these happens:
  - the agent ends its first turn (a Stop after it worked): outcome `done`;
  - the turn ends with an API error (StopFailure): outcome `error`;
  - its session ends: outcome `error` if it never worked;
  - its record disappears: outcome `gone`.
- **Advancing the queue:** the daemon checks the runs on every agent change
  (debounced, and with no reads while nothing is queued or running). When
  a run finishes, it starts the next queued run, so a batch advances
  without the phone.
- **Moving the task to done:** when the user opts in (`markDone`), the app
  does it through the task's source with this device's token. It picks the
  source's first done status that is not a cancellation, adds a comment
  naming the branch, and does this once per run.
- **No agent:** a run whose agent never reports from its worktree within
  10 minutes (a missing binary, a shell that never ran the line) fails with
  `errorCode: "no-agent"` and frees its slot.

## Cleaning up (CON-088)

- **Stopping the agent:** a finished, cancelled or no-agent run keeps its
  agent open for review for the `task-agent-keep` setting (`conductore-hostd
  config set task-agent-keep <hours>|forever`; default 24 hours). Then the
  daemon (checked every minute) closes the run's own place:
  - Herdr: `pane.close` of the run's pane, only after `pane.get` shows the
    same tab and a cwd inside the worktree;
  - tmux: `kill-pane` of the run's pane, only after `display-message` shows
    the same window and a cwd inside the worktree;
  - none: SIGTERM to the agent's own process, only while its pid and start
    time still match.

  Never by name or pattern. A pane that no longer passes the check is left
  alone (`agentStopped: "not-ours"`). The outcome is in `agentStopped`
  (`closed`, `signalled`, `gone`, `not-ours`, `unreachable`).
- **Keeping it:** `task-runs keep <id>` keeps that run's agent open until
  the run is forgotten (`keep <id> off` undoes it).
- **Forgetting a run** (`forget`, or `remove`) stops its agent at once, then:
  - removes the worktree with `git worktree remove` only when `git status`
    shows it clean; otherwise it stays and the answer says why
    (`worktree: "kept"`, `worktreeReason`, `worktreePath`);
  - deletes the branch only when its worktree is gone and the branch is
    merged into the repository's HEAD (`git branch -d`), or with
    `--delete-branch` (`git branch -D`);
  - always removes the run's prompt folder.

  A run without a worktree (`worktree: false`) never touches the
  repository. Runs dropped from the list past the newest 200 done ones lose
  their prompt folder too.

Tested on temp repositories (host/test/worktree.test.js and
host/test/task-runs.test.js, with a fake Herdr socket and a fake tmux), and
live in Docker against Herdr 0.9.3 and tmux 3.3 (`docker run --network
none`):

- a workspace and tabs were created;
- prompts with quotes and `$(...)` reached the agent unchanged;
- the agents started in the right worktrees;
- the main worktree was untouched.

## In the app

To start one task, open it in Tasks and tap Start. To start several,
long-press a task, tick the others, then tap "Start N tasks". The Start page
offers these choices:

- **Machine:** one for all the tasks, one per task, or Automatic, which
  picks the least busy machine whose companion has `task-runs`.
- **Repository.**
- **Fresh worktree:** on or off.
- **Place:** Herdr tab, tmux window or none.
- **Agent:** the New workspace picker's detection. With several machines,
  only the agents installed on every one are offered.
- **Attempts.**
- **At once on a machine:** the cap.
- **Mark done in the source when finished:** opt-in, and offered only when
  every task's source has statuses.

The choices are remembered on this device, and the machine and repository
per source.

Started tasks show by batch on the Agents dashboard and under Tasks ›
Started tasks. Each batch has a progress bar (finished, running, waiting,
failed) and each run has its state, branch and actions (copy the command,
stop following, keep the agent open, remove and clean up, remove and delete
the branch). Removing says what the companion kept (a worktree with
changes, an unmerged branch). The app follows the runs only once one of those
views has shown them, so no timer runs at startup.
