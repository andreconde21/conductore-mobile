# Agent notifications

Settings › Agents › Notifications picks one of three modes. The choice is
kept on this device only and never synced, so a phone can notify while a
computer stays quiet. Each machine's own notification level still applies
on top of it.

| Mode | Ongoing status | Alerts |
| --- | --- | --- |
| **Ongoing + urgent** (default) | yes | urgent only |
| **Everything** | no | one per agent for every need, finished turns included (the behaviour before CON-074) |
| **Urgent only** | no | urgent only |

## The ongoing status notification

This is one silent notification that lists every live agent on one line,
starting with the most urgent (needs you, then working, then idle):

```
1 needs you · 2 working · 1 idle
api (Codex) · Needs you · Approve Bash: git push
lf-seguros-web · Working · Fixing the login redirect
cli · Stuck · `npm test` failed 3 times
docs · Idle · Rewrote the intro.
```

- Agents are named as the session tiles name them (CON-079,
  `agent_naming.dart`): an agent in a Herdr pane by its Herdr workspace,
  the name Herdr and sheprd show (CON-116; with an older companion, once
  the app's live view has seen the workspace), else the project, never a
  folder hash. A Claude Code worktree (`<repo>/.claude/worktrees/agent-<hex>`)
  or a Herdr one (`~/.herdr/worktrees/<repo>/<branch>`) is named after its
  repository.
  Agents that are not Claude Code add their kind, for example "(Codex)".
- The text after the state is the pending request, the dashboard's summary
  line or the agent's last message (never its generic "is waiting for your
  input"), else the tool it runs.
- Each agent counts once. Every Herdr workspace or tmux session opened in
  the app is its own session of the machine, but a machine has one monitor
  (one poll loop, one set of agents, alerts keyed by the machine) however
  many of its sessions are open. The status also keys agents by pane, so
  Herdr's sighting of an agent its hooks also report (or a second agent in
  the same pane) folds into one, the hook-reported and then the most urgent
  one winning.
- Idle agents (their turn ended, or finished) drop out 30 minutes after
  their last change. Agents that need you and working agents always stay.
- The title counts exactly the agents listed: "N need you · N working ·
  N idle". A dashboard stuck flag does not have its own count: the agent
  counts under its state and its line says "Stuck" with the reason.
- Up to five agents are listed; "+N more" counts the other agents.
- The machine is named, as a suffix "(dev-central)", only when agents of
  more than one machine are listed.
- It is updated in place without sound, at most once every 5 seconds. The
  latest version wins, and removing it is never delayed. If nothing changes
  it is re-sent every 10 minutes. On Android 8 or later a status that nobody
  refreshes disappears after 30 minutes, so an app that was killed does not
  leave a stale list behind.
- Tapping it opens the agents dashboard.
- On a secure lock screen it shows only "Conductore: 3 agents".
- **Android:** it uses the same notification id and channel ("Status",
  low importance) as the background-connection service. While live
  sessions are kept running in the background, the status *is* that
  service's notification, so there is only ever one notification. Its
  title carries the agent counts; the session count ("2 active sessions")
  shows only while there is no agent status. When the service stops, the status
  is detached and stays as a plain ongoing notification.
- **iOS:** none, see below.

## Urgent alerts

An agent has at most one alert, and it is posted only for these needs:

| Need | When |
| --- | --- |
| Permission | a request waits for Allow or Deny |
| Question | an AskUserQuestion request, a question tool that is still open, a last line that asks something, or a prompt that timed out into the terminal |
| Error | the turn ended on an API error (the companion's `lastError`), or Herdr reports the agent as blocked |
| Stuck | the agents dashboard flags it: no progress, the same failure repeated, a command run over and over, or a long wait for an approval |
| Finished | only with "Also alert when an agent finishes" turned on |

A Permission or Question alert stays answerable from the phone for 15
minutes (the companion's `permission-wait` setting, 1 to 60). If that wait
runs out, the card stays and the answer is typed into Claude Code's own
dialog in the pane ("via terminal"), after the companion checks the screen.

The companion reports a turn that simply ended as `waiting_input`. That
case is not a question: it updates the ongoing status and does not alert.

An alert sounds when the agent enters an urgent state. Moving to a
different urgent state sounds again, except a request that became a
question in the terminal, because that is the same ask. Further updates
are silent. A stuck flag alerts once and then stays quiet until it clears.
The alert disappears once nothing urgent remains (the request was answered
anywhere, the agent moved on, or it ended).

### Actions

| Alert | Buttons |
| --- | --- |
| Low or medium risk approval | Allow, Deny, Open (or Review all when several are pending) |
| High risk approval | Open |
| Single-choice question, 1 to 3 options | one button per option |
| Any other question | Open |
| Question in the text, error, stuck, finished | Reply (when the agent takes prompts), Open |

- **Allow, Deny and the answer buttons** go through the same `decide` call
  as the app (`decide <id> allow|deny`, `decide <id> answer --answers`).
- **Reply** opens an inline text field. The text is typed into the agent
  through the companion's `send`, the same path as Chat View. It is offered
  only for companion agents whose kind takes prompts (`adapters.<kind>.send`)
  and that are not waiting on a permission prompt, because the companion
  refuses to type while one waits. `send` writes to the agent's own pane by
  id, so Herdr's shared focus never moves (docs/herdr-shared-focus.md).
  Once the reply is sent, the alert goes.
- With **Summary only**, Allow, Deny, the answer buttons and Reply are
  hidden, and only Open is left.
- Each button carries a one-use random token. Android 12 and later asks for
  an unlock before a button fires. A tap made on a locked phone is never
  acted on: the buttons are re-posted so that they open the app.
- Taps are handled in the background while the app process runs. Otherwise
  the notification says "Tap to open Conductore and finish", and the
  queued tap completes after the app is unlocked. Reply needs the running
  app and an unlock-protected button, so it is offered only on Android 12
  and later, and only while the app process runs.

### Mute

Swipe an agent's card to the right on the Agents screen (on a desktop,
right-click it and choose **Mute notifications**); swipe again to unmute.
A small bell-off icon marks a muted card.
A muted agent gets no alerts on this device, though the ongoing status
still lists it. Settings shows how many agents are muted and has an
**Unmute all** button. Mutes are keyed by machine and agent session, and
at most 200 are kept.

## Battery and background

- The app polls nothing extra for the ongoing status: it is built from the
  agent monitor's own polls, every 15 seconds or the companion's long-poll.
- For stuck alerts, the agents dashboard's facts (no summaries, so no model
  call) are refreshed every 5 minutes per machine, also with no dashboard
  open, but only in the urgent modes with "Stuck or looping" on.
- **Android:** agent monitoring runs while sessions are connected. With
  live sessions in the background, the existing foreground service
  (`dataSync`) keeps the connections, and therefore the polls and
  notifications, alive. The status notification is that service's
  notification and adds no new wake-ups. Android 15 limits `dataSync`
  services to about 6 hours a day; after that, the polls stop until the app
  is opened again.
- **Permissions:** notifications need POST_NOTIFICATIONS on Android 13 and
  later. The app asks for it the first time a session is live while the app
  is in front. Without it, nothing is posted (the status included), and the
  service still runs, as Android allows.

## iOS

iOS shows no agent notifications. No Live Activity was added, for these
reasons:

- A Live Activity needs a widget extension target. The project has none
  (the home-screen widget is Android only), and adding one means a new
  bundle id, an App Group, and provisioning and signing changes in the
  release pipeline.
- iOS suspends the app soon after it leaves the screen, and its sockets
  die. A Live Activity can then only be updated through ActivityKit push
  notifications, which need APNs and a server to send them. The app has
  neither, so a Live Activity would freeze at the moment the app was
  backgrounded.

A summary notification that is silently replaced has the same problem: it
would be posted once and never updated. Doing this properly requires a
push relay (the companion or Talkbawt sending APNs). The policy and status
code here is platform-neutral and would feed such a relay as it is.
