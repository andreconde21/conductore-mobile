# sheprd view sync (CON-077, CON-101), contracts v1 and v2

Conductore can mirror sheprd's sidebar: projects, members, hidden
workspaces, order, and each agent's presence (unread, kept, dismissed). It
can also write presence marks back. The app has an opt-in setting for this,
"Sync with sheprd", which is off by default. Nothing in this contract is
specific to one team: machine names, groups and paths all come from the
user's own sheprd.

Status: agreed with the sheprd agent on 2026-10-05, shipped in sheprd
0.9.3-15. sheprd writes
`view.json` only when `share_view = true` is set in its `sidebar.toml`
(default false). The relay forwards it to each machine, with `self` set
per machine, and drains each machine's `view-updates.jsonl` into the hub's
file, so there is one applier. v1 covers marks only; layout edits wait for
v2. While sync is on and no machine shares a view, Conductore keeps its
own layout and says how to turn sharing on.

Contract v2 (CON-101, draft of 2026-10-09, awaiting the sheprd agent's
review) adds layout edits from the app: moving a workspace to a project or
to Other, hide/show, creating, renaming, pinning and deleting projects,
their match rules and short tag, reordering, and "remove from active" /
"keep active". See [Contract v2: layout edits](#contract-v2-layout-edits).
v1 stays as it is: v2 only adds keys to `view.json` and a new line version
to `view-updates.jsonl`.

## What sheprd keeps today (read from its source, `main` @ ed339c45)

- `<config_dir>/sidebar.toml` (`~/.config/herdr/sidebar.toml`) on the
  machine that runs the sheprd client (the hub) holds the layout
  (`group`, `hidden`, `ungrouped`, `show_hidden`, `compact`, `active_only`,
  `other_collapsed`, `recent_hours`) and the marks:
  - `unread = ["machine/pane_id"]`: cleared when the agent gets focus;
  - `dismissed = ["machine/pane_id@state_change_seq"]`: the mark lapses at
    the agent's next state change, and only the last 200 are kept;
  - `kept = ["machine/pane_id"]`.
- Keys are written from the hub's point of view. `machine` is the herdr
  endpoint label in lower case, and the hub itself is `local`. Workspace
  keys are `machine/<workspace_id>:<label>`, or the older `machine/<label>`.
  Agent keys are `machine/<pane_id>`.
- `presence()` resolves to `blocked | unread | done | working | idle` in
  this order: an `unread` mark wins; then `working`; then `blocked` or
  `done`, unless the agent was dismissed at its current seq; otherwise
  `idle`.
- `sheprd-msg relay` runs on the hub and holds one SSH connection to each
  saved machine. Through that connection it publishes `peers/<hub>.json`
  and drains `~/.local/state/sheprd-msg/outbox.jsonl` (under `flock`, then
  truncates it).

Conductore's companion runs on every machine the app connects to.
`sidebar.toml` exists only on the hub, so the view has to reach the other
machines as a file that the relay keeps up to date.

## Files

Both files live in `~/.local/state/sheprd/`, a fixed path under `$HOME`,
like sheprd-msg's state. Conductore never writes `sidebar.toml`.

| file | written by | read by |
|---|---|---|
| `view.json` | sheprd: the client on the hub, the relay on every other machine | Conductore's companion, read-only |
| `view-updates.jsonl` | Conductore's companion, append-only | sheprd: the client on the hub, the relay elsewhere, which then empties it |
| `view-updates.lock` | whoever appends or drains | the same two |

### `view.json`

sheprd writes `view.json` atomically (a temporary file, then a rename), only
when it changes, and at least every 30 s while sheprd runs. Like
`sheprd-status.json`, the rewrite shows that sheprd is alive. The file must
stay at or under 1 MiB.

```json
{
  "version": 1,
  "updated": 1759612345,
  "source": "sheprd 0.6.2",
  "hub": "laptop",
  "self": "dev",
  "layout": {
    "compact": false, "active_only": true, "recent_hours": 24,
    "show_hidden": false, "other_collapsed": false,
    "hidden": ["dev/w3:scratch"],
    "ungrouped": [],
    "group": [
      {"name": "Storefront", "pinned": true, "collapsed": false,
       "members": ["local/w1:notes", "dev/w2:sf"], "match": ["storefront"], "short": "SF"}
    ]
  },
  "agents": {
    "dev/w2:p1":   {"presence": "unread",  "state_seq": 41, "unread": true,  "dismissed": false, "kept": false},
    "local/w1:p2": {"presence": "idle",    "state_seq": 7,  "unread": false, "dismissed": true,  "kept": true, "removed": false}
  },
  "order": ["local/w1:notes", "dev/w2:sf", "dev/w9:misc"],
  "focus": "local/w1:p2"
}
```

| key | type | meaning |
|---|---|---|
| `version` | int | `1`. A reader ignores a file whose version it does not know. |
| `updated` | int | Unix seconds of the last write. A file older than 120 s means sheprd is not running: readers show the view as stale. |
| `source` | string ≤ 64 | Who wrote the file (informational). |
| `hub` | string ≤ 64 | The sheprd-msg name of the hub (`name` in `sheprd-msg.toml`, else its hostname). |
| `self` | string ≤ 64 | The machine key that the keys in this file use for the machine holding the file: `local` on the hub, else the hub's endpoint label for this machine, in lower case. |
| `layout` | object | The layout keys of `sidebar.toml`, with the same names and types, and without `unread`, `dismissed` or `kept`. |
| `agents` | object | Agents sheprd sees now, plus any agent that has a mark, keyed `machine/pane_id`. At most 2000. |
| `agents.*.presence` | enum | sheprd's `presence()`: `blocked`, `unread`, `done`, `working` or `idle`. |
| `agents.*.state_seq` | int | herdr's `state_change_seq` when sheprd last saw the agent. |
| `agents.*.unread` / `kept` | bool | The marks. |
| `agents.*.dismissed` | bool | Dismissed at the current `state_seq`. |
| `agents.*.removed` | bool | Optional (sheprd 0.9.3-15). The user took the agent out of sheprd's active view; it lapses at the agent's next state change. Readers that mirror the active filter hide it there and still list it under all agents. There is no write-back op for it in v1. |
| `order` | string[] | Optional. Workspace keys in sidebar display order, hidden ones included. |
| `focus` | string \| null | Optional. The agent key focused in sheprd ("what is open"). |

Unknown keys are ignored, so a later v1 writer may add keys. A change of
meaning gets a new `version`.

### `view-updates.jsonl`

Each line is one JSON object, UTF-8, at most 1024 bytes, ending in `\n`:

```json
{"v":1,"id":"c-1759612400123-3f9a","at":1759612400,"from":"conductore","op":"unread","agent":"dev/w2:p1"}
{"v":1,"id":"c-1759612401456-08bd","at":1759612401,"from":"conductore","op":"dismiss","agent":"dev/w2:p1","state_seq":41}
```

| key | type | rule |
|---|---|---|
| `v` | int | `1` |
| `id` | string | Matches `[A-Za-z0-9_-]{8,64}` and is unique. sheprd skips an id it has already applied (it remembers the last 500). |
| `at` | int | Unix seconds. |
| `from` | string ≤ 32 | `conductore`, for logs. |
| `op` | enum | See the table below. |
| `agent` | string | Matches `^[^/\x00-\x1f\x7f]{1,64}/[A-Za-z0-9:._-]{1,64}$`, the hub-view key, as in `view.json` `agents`. |
| `state_seq` | int ≥ 0 | Required for `dismiss`; not used by the other ops. |

| op | sheprd applies |
|---|---|
| `unread` | `layout.mark(agent, seq, true)` |
| `read` | removes `agent` from `unread` (what focusing the agent does) |
| `dismiss` | `layout.mark(agent, state_seq, false)` |
| `keep` | adds `agent` to `kept` if it is missing |
| `unkeep` | removes `agent` from `kept` |

The ops set a state; they never toggle it, so replaying a line is harmless.
sheprd applies lines in file order. It skips, and logs, a line that does
not parse, has an unknown `v` or `op`, or has an invalid key. An `agent`
that sheprd does not know is still applied: marks are plain strings in
`sidebar.toml`. After applying, sheprd rewrites `view.json`, so the writer
sees the result there. Conductore shows a mark as pending until a
`view.json` with a newer `updated` reflects it, and drops it after 2
minutes without one.

### Appending and draining

Node has no `flock`, so both sides use a lock file instead:

- **Lock:** create `view-updates.lock` with `O_CREAT|O_EXCL`, holding the
  pid. Release it by unlinking. A lock older than 10 s is stale and may be
  removed. Retry for up to 2 s.
- **Writer (Conductore):** take the lock. Refuse to append when the file is
  already 256 KiB or more, because that means nothing is draining it. Then
  append the line with one `O_APPEND` write and release the lock. The
  writer creates `~/.local/state/sheprd/` (mode 0700) if it is missing and
  creates the file with mode 0600. It touches no other file.
- **Drainer (sheprd):** take the lock, read the file, truncate it to 0,
  release the lock, then apply the lines. On machines other than the hub,
  the relay does this over its SSH connection, the same way it drains the
  outbox, and hands the lines to the client. A drainer may also `flock` the
  file; that does no harm.

## Contract v2: layout edits

v2 lets the app edit sheprd's layout while sync is on. Nothing changes for
v1: the five marks keep `"v":1` lines, so a sheprd that knows only v1 keeps
applying them. Everything new is a `"v":2` line, which a v1 sheprd already
skips (it logs an unknown `v`).

### What sheprd adds to `view.json`

`view.json` keeps `"version": 1` (its meaning does not change) and gains
two optional keys:

| key | type | meaning |
|---|---|---|
| `updates` | int | The highest `view-updates.jsonl` line version this sheprd applies. Absent means `1`. A v2 sheprd writes `2`. Conductore sends v2 lines only when the view it bases them on says `2`, and otherwise keeps its layout actions paused with a hint naming the sheprd version needed. |
| `rejected` | object[] | Optional, at most the last 50: `{"id": "<line id>", "why": "<≤ 120 chars>"}` for each v2 line sheprd skipped because a rule below refused it (not for lines that did not parse). The app drops that pending edit at once and shows `why`, instead of waiting for the 2-minute timeout. An entry stays listed for at least 2 minutes. |

### v2 lines

Same file, lock, size limits and drain as v1, with two differences: a line
may be up to **4096 bytes** (v1 lines stay ≤ 1024; sheprd raises its line
cap to 4096 for all lines), and `v` is `2`. `id`, `at` and `from` are as in
v1, and the id de-duplication (last 500 ids) covers v2 lines too, so a
replayed line is skipped by id even where an op is not idempotent on its
own.

Common field rules:

| field | rule |
|---|---|
| `workspace` | A workspace key in the hub's names, as in `layout` (`machine/<id>:<label>` or `machine/<label>`): `^[^/\x00-\x1f\x7f]{1,64}/[^\x00-\x1f\x7f]{1,256}$`. Matched with sheprd's `same_workspace()`, so the id wins over the label. |
| `agent` | As in v1. |
| `state_seq` | As in v1: a whole number ≥ 0. |
| `project` | A project name as `layout.group[].name` spells it: 1–128 characters, no control characters, not blank, no leading or trailing spaces. Looked up **exactly** (case-sensitive), as sheprd's `group_mut()` does, except where an op says otherwise. |
| `to` | A new project name, same rules as `project`. |
| `match` | At most 32 strings, each 1–128 characters, no control characters, no commas; sheprd stores them as given (the app sends them trimmed and lower-cased). |
| `short` | 0–8 characters, no control characters; `""` clears the tag. |

| op | fields | sheprd applies | refused (skipped, listed in `rejected`) when |
|---|---|---|---|
| `assign` | `workspace`, `project` (may be `""`) | `layout.assign(workspace, project)`: `""` moves it to Other (`ungrouped`); a project is matched case-insensitively and made when missing, as sheprd's "Move to project…" does. | never |
| `hide` | `workspace` | adds it to `hidden` unless `is_hidden()` | never (already hidden is a no-op) |
| `show` | `workspace` | removes every `hidden` entry that is `same_workspace()` | never |
| `project-create` | `project`, optional `match` | appends `[[group]]` with that name and rules | a project of that name exists, in any case (`"exists"`) |
| `project-rename` | `project`, `to` | `group_mut(project).name = to` | `project` is missing (`"renamed or deleted meanwhile"`), or another project is already called `to` in any case (`"name taken"`) |
| `project-pin` | `project`, `pinned` (bool) | sets `pinned` | `project` is missing |
| `project-rules` | `project`, `match`, optional `was` (string[]) | sets the rules to `match` | `project` is missing, or `was` is given and differs from the current rules (compared as sets, case-insensitive): someone else edited them (`"rules changed meanwhile"`) |
| `project-short` | `project`, `short` | sets `short`, or removes it for `""` | `project` is missing |
| `project-delete` | `project`, optional `members` (string[]) | removes the group; its workspaces go to Other or to a project whose rule catches them, as sheprd's own Delete does | `project` is missing, or `members` is given and is not the same set (by `same_workspace()`) as the group's current explicit members (`"project changed meanwhile"`) |
| `project-move` | `project`, `before` (a project name, or `""`) | takes the group out of the list and puts it right before `before`, or after the last group with the same `pinned` value for `""`. Display order stays "pinned first, then file order". | `project` or `before` is missing, or `before` has a different `pinned` value (`"pinned projects stay above"`) |
| `member-move` | `workspace`, `before` (a workspace key, or `""`) | as sheprd's own drag inside a project: takes `group_members_in_view()` for the workspace's project, moves `workspace` right before `before` (or to the end), and stores that list as the group's `members` (rule matches become explicit, so the order sticks) | the workspace is in no project (Other), or `before` is not in the same project's view |
| `remove-active` | `agent`, `state_seq` | `layout.remove_from_active(agent, state_seq)` | never |
| `keep-active` | `agent` | `layout.keep_active(agent)` | never |

Apart from `project-move` and `member-move`, the ops set a state; those two
are protected from replay by their id. Lines are applied in file order, so
an app that needs two steps (create a project it found from the agents,
then pin it) writes two lines in one append. A line that does not parse, or
breaks a field rule, is skipped and logged like a bad v1 line.

Conflicts are always resolved for sheprd's file: a refused line changes
nothing. The app never retries a refused edit on its own; it shows the
reason, drops the pending edit, and the user sees sheprd's current layout.

### Examples

```json
{"v":2,"id":"c-1760040000123-3f9a","at":1760040000,"from":"conductore","op":"assign","workspace":"dev/w2:sf","project":"Storefront"}
{"v":2,"id":"c-1760040001456-08bd","at":1760040001,"from":"conductore","op":"project-rename","project":"Storefront","to":"Shop"}
{"v":2,"id":"c-1760040002789-77aa","at":1760040002,"from":"conductore","op":"project-rules","project":"Shop","match":["shop","storefront"],"was":["storefront"]}
{"v":2,"id":"c-1760040003012-0c1d","at":1760040003,"from":"conductore","op":"remove-active","agent":"dev/w2:p1","state_seq":41}
```

### Confirmation in the app

As for marks: an edit shows as pending (applied on top of sheprd's layout,
with a spinner) until a `view.json` with a newer `updated` reflects it, or
lists its id in `rejected` (dropped at once with the reason), or 2 minutes
pass (dropped with "sheprd didn't apply this"). "Reflects" is checked per
op: the workspace is an explicit member of the project (`assign`), in or
out of `hidden`, the project exists / was renamed / has that pin, rules,
tag or position, or is gone, the agent's `removed` / `kept` flag.

### Conductore's companion (capability `sheprd-view-2`)

`conductore-hostd sheprd-view-update --json '<op>'` takes one op object, or
an array of up to 8, without `v`, `id`, `at` and `from`. It checks each
against the rules above, then appends all the lines in one write under the
lock and returns `{ok: true, ids: [...]}`; on any bad op it appends
nothing. The v1 form (`--op … --agent …`) is unchanged. `sheprd-view`
passes `updates` and `rejected` on.

## Conductore side
## Conductore side

- Companion, capability `sheprd-view`:
  - `conductore-hostd sheprd-view` returns `{found: false}` or
    `{found: true, path, stale, view}`. `view` is the checked v1 content.
    An unknown version or a bad file gives `{found: true, error}`.
  - `conductore-hostd sheprd-view-update --op <op> --agent <key>
    [--state-seq N]` appends one line and returns `{ok: true, id}`.
- App: when "Sync with sheprd" is on, the project views use `view.layout`
  (the newest `updated` across the machines that report one) and show the
  presence it reports. Keys under `self` are that machine. Under `local`
  is the hub, which is recognised by its name or address. Mark read,
  unread, keep and dismiss go back through the companion. With v2 (the
  view says `updates: 2` and the companion has `sheprd-view-2`), layout
  edits go back too, as v2 lines; otherwise they are paused while sync is
  on, with a hint naming what to update. When sync is off, the app's own
  grouping is back unchanged and v2 is not used.

## Open questions for sheprd

1. Can the relay carry `view.json` and drain `view-updates.jsonl` on its
   existing connection, or does it need its own channel?
2. Is `self` easy to produce on each machine? It is the hub's endpoint
   label for that machine.
3. Should layout edits (move to a project, hide) be write-back ops in v2?
   v1 covers marks only. (Answered: yes, see contract v2.)
