# sheprd view sync (CON-077), contract v1

Conductore can mirror sheprd's sidebar: projects, members, hidden
workspaces, order, and each agent's presence (unread, kept, dismissed). It
can also write presence marks back. The app has an opt-in setting for this,
"Sync with sheprd", which is off by default. Nothing in this contract is
specific to one team: machine names, groups and paths all come from the
user's own sheprd.

Status: agreed with the sheprd agent on 2026-10-05. sheprd writes
`view.json` only when `share_view = true` is set in its `sidebar.toml`
(default false). The relay forwards it to each machine, with `self` set
per machine, and drains each machine's `view-updates.jsonl` into the hub's
file, so there is one applier. v1 covers marks only; layout edits wait for
v2. While sync is on and no machine shares a view, Conductore keeps its
own layout and says how to turn sharing on.

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
    "local/w1:p2": {"presence": "idle",    "state_seq": 7,  "unread": false, "dismissed": true,  "kept": true}
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
  unread, keep and dismiss go back through the companion. The app's own
  layout edits are paused while sync is on. When sync is off, the app's own
  grouping is back unchanged.

## Open questions for sheprd

1. Can the relay carry `view.json` and drain `view-updates.jsonl` on its
   existing connection, or does it need its own channel?
2. Is `self` easy to produce on each machine? It is the hub's endpoint
   label for that machine.
3. Should layout edits (move to a project, hide) be write-back ops in v2?
   v1 covers marks only.
