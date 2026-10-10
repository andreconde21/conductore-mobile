# Launcher details provider (CON-075, v2 CON-082, v3 CON-119)

André's launcher Yoke (an OLauncher fork; `com.outsmartis.yoke`, debug
builds `com.outsmartis.yoke.debug`) opens a
details sheet when Conductore's icon is long-pressed. Conductore supplies the
sheet's content through a `ContentProvider`, and since contract 2
(CON-082) takes answers to waiting agents through `ContentProvider.call`.
Contract 3 (CON-119) holds those answers while Conductore is locked and
adds each row's project and "active" standing. This page is the contract
between the two apps.

Code: `android/app/src/main/kotlin/com/gwitko/conduit/LauncherDetailsProvider.kt`
(the provider), `LauncherDetailsModel.kt` (the rows, unit-tested in
`android/app/src/test/.../LauncherDetailsModelTest.kt`) and
`LauncherActions.kt` (the prompts and the `call` actions, unit-tested in
`LauncherActionsTest.kt`) and `LauncherAnswerQueue.kt` (the answers held
for the unlock, unit-tested in `LauncherAnswerQueueTest.kt`). The Dart
side: `LauncherPrompt`
(`lib/features/agent_attention/domain/launcher_prompt.dart`),
`AgentAttentionController.completeLauncherAction` and
`deliverQueuedLauncherAnswer`, and `ProjectLayoutController.launcherFacts`.

## Discovery

Conductore's `<application>` carries

```xml
<meta-data android:name="com.outsmartis.launcher.DETAILS_AUTHORITY"
           android:value="${applicationId}.launcherdetails" />
```

so the authority is `com.outsmartis.conductore.launcherdetails` for the
release build (it follows the applicationId of whatever build is installed).

## Access

- The provider is exported with `readPermission` (and `writePermission`)
  `com.outsmartis.permission.READ_LAUNCHER_DETAILS`, and
  `grantUriPermissions="false"`. `insert`, `update` and `delete` throw
  `UnsupportedOperationException`.
- Conductore declares the permission with
  `protectionLevel="signature|knownSigner"` and
  `knownCerts="@array/launcher_details_known_certs"`. The array holds
  signing-certificate SHA-256 digests as hex without colons (the platform
  hex-decodes them, so case does not matter):
  - `src/main/res/values/launcher_details.xml` (every build): Yoke's release
    key, `C1C53F01F674494483AA0CB16B0190C4CCBE736840580C383C18BC88510AD4DA`.
  - `src/debug/res/values/launcher_details.xml` (Conductore debug builds
    only): the release key plus Yoke's debug key from the dev host's debug
    keystore, `3F81175131F903E5D0704FDDAA885A2B5C1C4CC609310855E2EFEAE446C9E5AA`.
    A release (or profile) Conductore never trusts a debug-signed Yoke.
  - A new Yoke signing key means a new digest here and a Conductore release.
- `knownSigner` exists from API 31. Conductore's minSdk is 24; on API 24-30
  the system ignores the unknown flag and the permission is signature-only,
  so there only an app signed with Conductore's own key can read it.
- The launcher must only `<uses-permission>` it, never declare it: a second
  declaration by a differently signed app fails that app's install
  (`INSTALL_FAILED_DUPLICATE_PERMISSION`).
- Install-time permission: Android grants it when the launcher is installed
  or updated. If the launcher was installed before Conductore, it has to be
  reinstalled (or updated) after Conductore to get it.
- Android 11+ package visibility is per package, and applies to Yoke
  (`com.outsmartis.yoke` and `.debug`) as the querying app: if Yoke already
  sees Conductore (its `MAIN`/`LAUNCHER` intent `<queries>`, or
  `QUERY_ALL_PACKAGES`), it can query the provider. Otherwise Yoke adds
  `<queries><provider android:authorities="com.outsmartis.conductore.launcherdetails" /></queries>`.
  Conductore needs nothing to be seen by Yoke for this; it never queries Yoke.

## `content://<authority>/items`

One row per agent Conductore currently monitors (up to 20), in this order:
urgent first (`needsInput` or `blocked`), then `updated_at` newest first.
Ties keep Conductore's own order.

| column | type | meaning |
| --- | --- | --- |
| `id` | string | Stable: `<hostId>/<agentId>`. For an agent from a payload written before CON-075 (no ids yet): `<host>/<name>`. |
| `title` | string | The agent's display name. |
| `subtitle` | string | `<host> · <state label>`, e.g. `dev · Needs input`. |
| `state` | string | One of `working`, `needsInput`, `blocked`, `finished`, `idle`, `unknown` (Conductore's `AgentAttentionState` names, verbatim). |
| `progress` | int | Always `-1` (unknown) for now: no agent provider reports progress. |
| `updated_at` | long | Epoch ms the agent entered its state; the snapshot's time when the provider does not report it. |
| `deep_link` | string or null | Opens that session (below). Null when the agent has no ids. |
| `question` | string or null | Contract 2. What the agent asks (below), at most 600 characters. Null unless `state` is `needsInput` or `blocked`, or when unknown. |
| `options` | string or null | Contract 2. A JSON array of the choice labels, e.g. `["Allow","Always allow","Deny"]`. Null when there are no choices. |
| `answerable` | int or null | Contract 2. 1: the launcher may answer (`choose` when `options` is set, else `reply`); 0: it may not. Null unless `state` is `needsInput` or `blocked`. |
| `answer_note` | string or null | Contract 2. When `answerable` is 0: why, for the sheet (e.g. `High-risk request: open it in Conductore`). Null otherwise. |
| `project` | string or null | Contract 3. The display name of the project Conductore's project view puts the agent in (its sheprd / sidebar.toml layout, else the repo the agent reports); null for Other. |
| `active` | int | Contract 3. 1 when the project view's "active" filter keeps the agent, else 0 (below). |

## `content://<authority>/summary`

Exactly one row.

| column | type | meaning |
| --- | --- | --- |
| `monitoring` | int | 1 while at least one machine is monitored, else 0. |
| `attention_count` | int | Agents needing input or blocked, across all machines. |
| `updated_at` | long | Epoch ms of the last snapshot (0 before the first). |
| `limit_5h_pct` | int | Claude's 5-hour window used, 0-100 (0 once it reset); -1 unknown. |
| `limit_7d_pct` | int | Claude's weekly window, the same way. |
| `contract_version` | int | `3` (this page); `2` from a Conductore before CON-119. Absent (projection fails) from a Conductore with contract 1. Yoke treats a missing column as null. |

## `content://<authority>/themes`

One row per theme Conductore offers: the Omarchy themes it bundles (22), in
its theme picker's order (dark themes, then light ones, each alphabetical as
Omarchy orders them). It changes only when Conductore is updated, so it
sends no change notifications.

| column | type | meaning |
| --- | --- | --- |
| `name` | string | The Omarchy theme directory name, e.g. `tokyo-night`. |
| `label` | string | The display name, e.g. `Tokyo Night`. |
| `mode` | string | `dark` or `light`. |
| `accent`, `background`, `foreground`, `muted`, `selection`, `lighter_background`, `red`, `green`, `yellow`, `blue`, `magenta`, `cyan`, `orange` | string | `#RRGGBB` (uppercase), the theme's resolved Omarchy role. |

The catalog ships as `res/raw/launcher_themes.json`, generated from the
app's theme list: `test/features/home_widget/launcher_themes_test.dart` fails
when it is out of date, and `flutter test --update-goldens` on that file
rewrites it.

## `content://<authority>/pc_theme`

Exactly one row: the theme active on the user's Omarchy PC, as Conductore's
"follow a machine's theme" sync last read it. It is never the theme picked
in the app.

| column | type | meaning |
| --- | --- | --- |
| `name` | string or null | The PC's theme directory name (`tokyo-night`). Null while the app follows no machine or has not read it yet. A theme the app does not bundle keeps its own name, so it may be missing from `/themes`. |
| `machine` | string or null | The saved machine's name in Conductore; null when unknown. |
| `updated_at` | long | Epoch ms the app read that theme; 0 when `name` is null. It moves only when the theme changes or the snapshot is rewritten for another reason, not on every unchanged re-read. |
| `label` | string or null | Display name. |
| `mode` | string or null | `dark` or `light`. |
| the 13 roles | string or null | `#RRGGBB`, as in `/themes`; for a theme the app does not bundle, the colours read from the PC. |

Conductore calls `notifyChange` on `/pc_theme` when the stored PC theme
changes (another theme, another machine, sync turned off).

A projection is honoured (unknown column: `IllegalArgumentException`);
selection and sort order are ignored. Any other path throws
`IllegalArgumentException`.

## Deep link

`deep_link` is an `intent:` URI, as `Intent.toUri(Intent.URI_INTENT_SCHEME)`
writes it, for Conductore's `MainActivity`:

```
intent:#Intent;action=com.gwitko.conduit.action.OPEN_AGENT_LINE;launchFlags=0x30000000;component=com.outsmartis.conductore/com.gwitko.conduit.MainActivity;S.com.gwitko.conduit.LAUNCH_TARGET=agent;S.com.gwitko.conduit.WIDGET_LINE_TOKEN=<token>;end
```

Open it with

```kotlin
startActivity(Intent.parseUri(deepLink, Intent.URI_INTENT_SCHEME))
```

It is the same launch the home-screen widget's agent lines use. The token is
random and stands for that agent; Conductore resolves it against its stored
snapshot and then opens the session the way an agent notification does. The
link carries no host or session id, so it cannot be edited to open another
session. A token that is no longer valid (the agent is gone, or Conductore
stopped monitoring) opens the agents dashboard instead.

## Data and freshness

- The rows come from the snapshot Conductore stores for its home-screen
  widget and quick-settings tile (`AgentStatusStore`). A query reads
  SharedPreferences only: no SSH, no Flutter engine.
- Conductore writes the snapshot while it runs (at most every 0.5 s, and only
  when something changed). Each write calls
  `notifyChange(content://<authority>/items)` and `/summary`, and the
  returned cursors carry their URI as notification URI, so a
  `ContentObserver` or a re-query on change keeps the sheet live. The PC
  theme travels in the same snapshot.
- When Conductore's engine goes away, the snapshot is marked not monitoring:
  `items` is empty and `monitoring` is 0, the limits and the PC theme stay.

### `project` and `active` (contract 3)

Dart writes each agent's project and a `busy` flag into the snapshot
(and the view's recent-hours window once, `recentHours`); the provider
judges `active` when queried, so it turns 0 on time without a new
snapshot:

- `active` is 1 when the agent is busy or changed state within the
  project view's recent hours (its "Recent hours" setting, from sheprd or
  sidebar.toml, default 24).
- Busy: `working`, `needsInput`, `blocked` or `finished` (the dots the
  view's filter keeps). With "Sync with sheprd" on, sheprd's own active
  view decides instead for the agents it lists (kept in it: busy; taken
  out of it by hand: not).
- `project` is placed the way the agents dashboard places an agent
  (`ProjectLayoutController.projectOfAgent`): the layout's explicit member
  or rule, else Other; with no layout projects, the repo the agent
  reports. The phone home's Projects mode groups whole
  workspaces from the machines' live boards, which the provider never
  has; both read the same layout, so the names match.
- A workspace open in the app keeps all its rows in the view's "active"
  filter; the provider judges each agent on its own.

## Contract 2: questions and answers (CON-082)

### What `/items` carries

Only rows whose `state` is `needsInput` or `blocked` have the four new
columns set; every other row has them null. Conductore derives them from the
agent's live status:

| What waits | `question` | `options` | `answerable` / `answer_note` |
| --- | --- | --- | --- |
| A permission request (low, medium or unrated risk) | `Approve <tool>: <summary> · <risk>`, the risk reason on the next line | `["Allow","Always allow","Deny"]` | 1 |
| A high-risk permission request | the same | null | 0, `High-risk request: open it in Conductore` |
| A request only the agent's own prompt answers (Gemini CLI, Cursor: `terminalOnly`) | the same | null | 0, `Answer it in the terminal` |
| A question (AskUserQuestion) with one single-choice question | the question | its option labels | 1 |
| A question with one free-text (or number) question | the question | null | 1 (`reply` answers it) |
| Several questions, or a pick-several question | the questions, one per line | null | 0, a note |
| A question from a companion that does not send its questions | its summary | null | 0, `Open it in Conductore to answer` |
| Nothing pending (the agent waits for the user's next message) | its last message | null | 1 when Conductore can type into it, else 0 |

When several requests wait, the row is about the first one, and `question`
ends with `(+N more waiting)`. `Always allow` is Claude Code's "Yes, and
don't ask again" (Conductore's `always` decision).

`question` and `options` carry the agent's own text, so they are **not
lock-screen safe**. Conductore stores them apart from the widget snapshot
(their own preferences file, `launcher_prompts`), which the home-screen
widget, the quick-settings tile and the notifications never read; only this
provider serves them, behind the same permission. Do not show them on
Yoke's lock screen either. They are cleared when Conductore's engine stops.

### Answering: `ContentProvider.call`

```kotlin
val result = contentResolver.call(
    Uri.parse("content://com.outsmartis.conductore.launcherdetails"),
    "choose",             // or "reply"
    itemId,               // the row's `id`
    bundleOf("index" to 0), // or bundleOf("text" to "Use main")
)
val ok = result?.getBoolean("ok") == true
val error = result?.getString("error")
```

- `reply`: extras `text` (String, at most 4000 characters, not blank). The
  text is typed into the agent and submitted (Enter), through the companion's
  `send`, which targets the agent's own pane (Herdr's shared focus never
  moves). For a free-text question it is the answer to that question.
- `choose`: extras `index` (Int, 0-based into `options`).
- The result Bundle: `ok` (Boolean) and `error` (String, null when `ok`).
  When Conductore has not finished after 5 seconds, the call returns
  `ok = true` and `queued = true`: the answer is still being sent and its
  outcome is not known (a failure then shows nowhere but in the app's own
  state). Contract 3: an answer held for the unlock returns `ok = true`,
  `queued = true` and `pending_unlock = true` (below). Otherwise `ok` is
  the real outcome.
- After a successful answer Conductore calls `notifyChange` on `/items` (and
  the next snapshot updates it again).
- Call it off the main thread: it may block for up to 5 seconds.

The permission (`com.outsmartis.permission.READ_LAUNCHER_DETAILS`) is
checked on the calling UID inside `call`; a caller without it gets a
`SecurityException`, as a query does.

| `error` | When |
| --- | --- |
| `Unlock your phone first` | The device is locked (`KeyguardManager.isDeviceLocked`), the same rule as the notification buttons. Contract 3 does not change it: nothing is held. |
| `Open Conductore first` | Conductore's engine is not running and left nothing to answer (the row is gone), or an answer could not be held (below). |
| `Unlock Conductore first` | Conductore's app lock is closed and the answer could not be held (the encrypted store failed). Since contract 3 a closed app lock otherwise holds the answer. |
| `That agent isn't waiting any more` | Unknown or stale item id, an agent no longer `needsInput`/`blocked`, or a request answered meanwhile (also an option that no longer matches the request). |
| the row's `answer_note` | The row is not answerable (high risk, terminal-only, several questions, ...). |
| `Pick one of its options` / `It takes a reply, not an option` | `reply` on a row with `options`, or `choose` on one without. |
| `No option N: it has M (0 to M-1)` / `Missing the option index` | A bad `index`. |
| `Type a message first` / `Too long: at most 4000 characters` | A bad `text`. |
| `Already sending an answer to that agent` | One action per item at a time. |
| `Unknown method <m>` | Anything but `reply` and `choose`. |
| other text | What failed while sending, as Conductore words it. |

### How it runs

The provider never opens SSH or starts a Flutter engine. It hands the answer
to the running app over the notification channel
(`conduit/agent_notifications`, method `launcherAction`), and the app
completes it with the same code a notification button uses
(`completePermissionAction`: `decide` for Allow / Always / Deny and answers,
`send` for a reply), after checking it against what it would offer for that
agent now. A failure does not rewrite the agent's notification. When the
app cannot take it now, the answer is held (contract 3, below).

### Differences from Yoke's proposal

- Extra columns `answerable` and `answer_note`: with `options` null, a row
  is either a reply box (`answerable` 1) or not answerable from the launcher
  (0, with the reason). Yoke's proposal had no way to tell them apart.
- `question` is null when Conductore has nothing to say (e.g. no last
  message), not an empty string.
- `Always allow` is offered for every permission request that is not high
  risk; high-risk and terminal-only requests have no options at all.
- Several questions and pick-several questions are not answerable (no
  options, `answerable` 0). A free-text question takes `reply`.
- `queued`: after 5 seconds without an outcome `ok` is true and `queued`
  true, rather than waiting longer.
- A caller without the permission gets a `SecurityException`, not
  `ok = false`.
- The extra refusals above (locked phone, app not running, one action per
  item, length and index checks).

## Contract 3: answers held while Conductore is locked (CON-119)

`reply` and `choose` no longer fail while Conductore's app lock is up. The
answer is checked exactly as before (the row's prompt, the option index,
the text), then held, and the call returns `ok = true`, `queued = true`,
`pending_unlock = true` (Bundle booleans). Nothing is sent until the user
unlocks Conductore.

- Held when the app lock is closed (or would be), when Conductore's engine
  is not running but the row still stands (the process died: the stored
  snapshot and prompts outlive it, and the answer goes after the next
  start and unlock), or when the running app could not take it (locked
  meanwhile, still starting).
- The device lock still refuses (`Unlock your phone first`): nothing is
  held from the lock screen.
- Storage: Conductore's own preferences file `launcher_answers`, encrypted
  with AES-256-GCM under a key in the Android Keystore (it never leaves
  the keystore). It survives process death. At most one answer per row (a
  newer one replaces the older), at most 20.
- Expiry: 15 minutes after it was held (the companion's permission wait).
  An expired answer is never sent.
- While answers wait, Conductore shows a notification, `1 answer waits for
  you to unlock Conductore` (`N answers wait ...`). It names no agent and
  carries no answer text; it goes when they are taken, or by itself when
  the last one expires (Android 8+).
- Delivery: right after the next unlock (on the unlocked home page), in
  the order held. For each, Conductore waits for that machine's monitor
  (up to 20 seconds), reads its status again, and sends the answer only
  when the agent still waits on the same request (a reply: the same wait,
  i.e. the agent has not changed state since). Otherwise it is dropped and
  Conductore says so in the app: `Your answer to api on dev wasn't sent: it
  was answered elsewhere.` (or `it waited more than 15 minutes`, or the
  reason it failed). A sent one says `Sent your answer to api on dev.`
- If the store fails, the call fails as contract 2 did
  (`Unlock Conductore first` / `Open Conductore first`).
- A held answer changes nothing in `/items` until it is sent; the next
  snapshot after sending updates the row.

## Changelog

- 3 (CON-119): `reply` / `choose` hold the answer while Conductore is
  locked or not running (`pending_unlock`), encrypted, for 15 minutes, and
  send it after the next unlock if the agent still waits on the same
  request. `/items` gains `project` and `active`; `contract_version` is 3.
- 2 (CON-082): `question`, `options`, `answerable`, `answer_note`, and
  `call` with `reply` / `choose`.
- 1 (CON-075): `/items`, `/summary`, `/themes`, `/pc_theme`.
