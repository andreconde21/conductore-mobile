# Launcher details provider (CON-075)

André's launcher (`com.outsmartis.launcher`, an OLauncher fork) opens a
details sheet when Conductore's icon is long-pressed. Conductore supplies the
sheet's content through a read-only `ContentProvider`. This page is the
contract between the two apps.

Code: `android/app/src/main/kotlin/com/gwitko/conduit/LauncherDetailsProvider.kt`
(the provider) and `LauncherDetailsModel.kt` (the rows, unit-tested in
`android/app/src/test/.../LauncherDetailsModelTest.kt`).

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
  `knownCerts="@array/launcher_details_known_certs"`
  (`res/values/launcher_details.xml`). That array is still empty (TODO): the
  launcher's signing-certificate SHA-256 goes there.
- `knownSigner` exists from API 31. Conductore's minSdk is 24; on API 24-30
  the system ignores the unknown flag and the permission is signature-only,
  so there only an app signed with Conductore's own key can read it.
- The launcher must only `<uses-permission>` it, never declare it: a second
  declaration by a differently signed app fails that app's install
  (`INSTALL_FAILED_DUPLICATE_PERMISSION`).
- Install-time permission: Android grants it when the launcher is installed
  or updated. If the launcher was installed before Conductore, it has to be
  reinstalled (or updated) after Conductore to get it.
- Android 11+ package visibility is per package: a launcher that already
  sees Conductore (through its `MAIN`/`LAUNCHER` `<queries>`) can query the
  provider. Otherwise add
  `<queries><provider android:authorities="com.outsmartis.conductore.launcherdetails" /></queries>`.

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

## `content://<authority>/summary`

Exactly one row.

| column | type | meaning |
| --- | --- | --- |
| `monitoring` | int | 1 while at least one machine is monitored, else 0. |
| `attention_count` | int | Agents needing input or blocked, across all machines. |
| `updated_at` | long | Epoch ms of the last snapshot (0 before the first). |
| `limit_5h_pct` | int | Claude's 5-hour window used, 0-100 (0 once it reset); -1 unknown. |
| `limit_7d_pct` | int | Claude's weekly window, the same way. |

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
  `ContentObserver` or a re-query on change keeps the sheet live.
- When Conductore's engine goes away, the snapshot is marked not monitoring:
  `items` is empty and `monitoring` is 0, the limits stay.
