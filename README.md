# Conductore

Drive Claude Code, Herdr and tmux sessions on your own machines from your phone or desktop, over SSH or Mosh, with no relay server and no account.

[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
![Flutter](https://img.shields.io/badge/Flutter-3.44.1-02569B?logo=flutter)
[![Latest release](https://img.shields.io/github/v/release/andreconde21/conductore-mobile?include_prereleases&label=release)](../../releases)

Conductore runs on Android, iOS, Linux, Windows and macOS from one Flutter
code base, and on desktops and tablets it opens a sidebar and split-pane
shell. It is a fork of
[Conduit](https://github.com/gwitko/Conduit) by gwitko.

<table>
  <tr>
    <td align="center"><img src="docs/screenshots/01-home.png" width="200" alt="Home screen with live session previews"><br><sub>Home: live sessions and other workspaces</sub></td>
    <td align="center"><img src="docs/screenshots/10-chat-working.png" width="200" alt="Chat View with a table, an agent card and the working indicator"><br><sub>Chat View while Claude works</sub></td>
    <td align="center"><img src="docs/screenshots/09-quick-switcher.png" width="200" alt="Quick switcher with a waiting agent and open sessions"><br><sub>Quick switcher</sub></td>
    <td align="center"><img src="docs/screenshots/02-terminal.png" width="200" alt="Terminal on a Herdr session running Claude Code"><br><sub>Terminal on a Herdr session</sub></td>
  </tr>
</table>

<p align="center"><img src="docs/screenshots/24-desktop-shell-chat-split.png" width="820" alt="The desktop shell on Linux: sidebar tree, a terminal and Chat View side by side"><br><sub>The desktop shell: sidebar, a terminal and Chat View in two splits</sub></p>

More in [Screenshots](#screenshots). Jump to [Install](#install).

## Why

- **Your machines, your keys.** Hosts, keys and trusted fingerprints stay on
  your devices. No account, no cloud, no subscription.
- **No relay.** The app connects straight to your machines over SSH or Mosh,
  usually through Tailscale. Nothing sits in the middle and nothing on the host
  listens on a new port. Device sync goes through one of your own machines.
- **Agents first.** The app is built around watching and steering coding agents
  (Claude Code) inside Herdr and tmux, not around a generic terminal.

## New in preview 17

- **Review mode and undo** (companion 1.0): the companion snapshots the
  repository at the start and end of every Claude turn, so you can review a
  turn file by file on swipeable cards with coloured diffs, reject a single
  file (it is reverted), comment on lines, send feedback, or undo the whole
  turn and redo it. It opens from Chat View, the dashboard, the inbox, or
  after each turn if you want. The voice guide knows "undo that" and
  "review", and asks before it undoes.
- **Usage explorer**: ranges from today to 30 days or your own, a day
  chart you tap to see that day's hours, projects, models, sessions,
  machines and accounts, rows that filter the whole view, tokens or cost,
  the change from the previous period, and a CSV export.
- **Chat View messages**: long-press (or right-click) any message to copy
  it with or without Markdown, share it, quote it in your reply, select
  its text or send it to another agent. Code blocks have their own copy
  button, and **find in the conversation** (Ctrl+F, Cmd+F) counts and
  highlights matches and loads older messages as needed.
- **Android widget and tile** show the dashboard: the needs-you and stuck
  counts, up to three agent lines and both limit rings, in the app's
  theme. Tapping a line opens that agent.
- **Safe SFTP saves**: an edited file is written to a temporary file and
  renamed over the original, so a dropped connection never leaves it half
  written.
- Host companion **1.0.0**, with `turns`, `diff`, `undo` and `redo`, and
  usage by range, hour and session.

<table>
  <tr>
    <td align="center"><img src="docs/screenshots/37-review-cards.png" width="200" alt="Review mode: a file card with a coloured diff, accept and reject"><br><sub>Review a turn file by file</sub></td>
    <td align="center"><img src="docs/screenshots/38-usage-explorer-day.png" width="200" alt="Usage explorer: one day by hour, project and session"><br><sub>Usage explorer: one day</sub></td>
    <td align="center"><img src="docs/screenshots/39-chat-message-menu.png" width="200" alt="Chat View message menu: copy, share, quote, send to another agent"><br><sub>A message's menu</sub></td>
    <td align="center"><img src="docs/screenshots/40-chat-find.png" width="200" alt="Chat View find bar with highlighted matches"><br><sub>Find in the conversation</sub></td>
  </tr>
</table>

## New in preview 16

- **Agents dashboard**, from the home bar (and above the sessions on the
  desktop): what each agent did since your last look, grouped as Needs
  you, Stuck, Working and Done, with its facts (files and lines changed,
  test runs, failed commands, tokens and cost), a flag when an agent looks
  stuck, and approval, Answer, Chat and Terminal buttons on each card. A one- or
  two-sentence Claude summary is made only when you open it and only for
  agents that changed; Settings › Agents › Dashboard turns summaries off
  and sets when an agent counts as stuck. Ask the voice guide to "catch me
  up" to hear it.
- **Sent messages show at once** in Chat View as a pending bubble
  (Sending…, then Sent) until Claude's transcript has them; a refused send
  offers Retry and Edit.
- **The default view everywhere**: a workspace opens in Chat View or the
  terminal, as set in Settings › Terminal › Open Claude sessions in, from
  the home screen, the switcher, notifications and the dashboard alike.
- Fixes from the code review's leftovers: live preview keeps working after
  a reconnect, Talk no longer sends a cut-off phrase when another mic takes
  over and follows the thread while it listens, agents in a named
  (non-default) Herdr session can be sent prompts, and builds can set a
  mirror for the local shell's rootfs
  ([Local-shell rootfs mirror](#local-shell-rootfs-mirror)).
- Host companion **0.9.0**, with `digest` for the dashboard.

<table>
  <tr>
    <td align="center"><img src="docs/screenshots/35-agents-dashboard.png" width="200" alt="Agents dashboard: needs you, stuck and done cards with facts and summaries"><br><sub>The agents dashboard</sub></td>
    <td align="center"><img src="docs/screenshots/36-chat-pending-bubble.png" width="200" alt="Chat View with a just-sent message as a pending bubble"><br><sub>A sent message, pending</sub></td>
  </tr>
</table>

## New in preview 15

- **Voice guide**: talk to the app hands-free. Common phrases ("what's
  waiting", "open api", "approve", "read the last reply") work offline in
  English and Portuguese; anything else goes to Claude through the
  companion's `guide` command. It answers aloud and asks before it acts,
  and a high-risk approval is always confirmed. Start it with the
  headset-mic button on the home screen, the Quick Settings tile, a long
  press on Talk, or the headset's assistant button. Settings › Chat &
  Voice › Voice guide.
- **Smart approvals** (companion 0.8):
  - a Low, Medium or High risk label, with a reason, on every approval;
  - **Trust…** allows exactly that call for N minutes, and **Always**
    saves a rule in Claude Code's `Tool(pattern)` syntax;
  - **Approve all safe** for the low-risk ones, and a list of what was
    auto-approved, with Undo;
  - Settings › Agents › Approval rules lists, edits and revokes each
    machine's rules;
  - high risk always asks, and the terminal prompt is unchanged.
- **Voice on iPhone**: dictation, read-aloud and Talk. A call pauses
  reading and it resumes afterwards; AirPods work for both.
- **Every cswap account in Usage**: an Accounts section with each Claude
  account's limits, a "+N accounts" chip on the usage bar, and switching
  the account for new sessions, after a confirmation.
- **This computer**: the PC recognises its own synced machine entry and
  folds it into *This computer*.
- **Chat View**: the mic and Talk on every way in; messages from other
  Claude sessions show as their own rows, never as yours, and "*X*
  finished" rows carry a teammate's result.
- **Security and reliability** from a full code review:
  - approving from a lock-screen notification needs an unlock, and the app
    lock locks again after a time in the background you choose
    (Settings › Security);
  - a changed host key is replaced in two steps, with SHA256 fingerprints;
  - reconnecting no longer leaks the old connection, SSH handshakes time
    out, and a sync never loses edits made while it runs;
  - remote commands are safe under fish, and Android backup is off;
  - the companion no longer crashes under load, checks the pane before it
    types, and keeps its socket in one place.
- Host companion **0.8.1**, with `guide`, `trust`, `rules`, `approve-low`,
  `approvals` and `cswap-switch`.

<table>
  <tr>
    <td align="center"><img src="docs/screenshots/30-approval-risk.png" width="200" alt="Chat View approval card with a Low risk label, Trust… and Always"><br><sub>A risk label, Trust… and Always</sub></td>
    <td align="center"><img src="docs/screenshots/31-approval-rules.png" width="200" alt="Approval rules for the workstation: a timed trust and standing rules"><br><sub>Settings › Agents › Approval rules</sub></td>
    <td align="center"><img src="docs/screenshots/32-voice-guide.png" width="200" alt="Voice guide card on the home screen asking to confirm an approval"><br><sub>The voice guide asks before it approves</sub></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/screenshots/33-usage-accounts.png" width="200" alt="Usage explorer with an Accounts section for two cswap accounts"><br><sub>Usage for every cswap account</sub></td>
    <td align="center"><img src="docs/screenshots/34-chat-peer-messages.png" width="200" alt="Chat View with a message from another session and a finished row"><br><sub>Another session's message, a teammate finished</sub></td>
  </tr>
</table>

## New in preview 14

- **Desktop shell** on desktops and tablets (900 dp and wider):
  - a sidebar tree of machines, Herdr workspaces, tabs and agents, and tmux
    sessions and windows, with state dots, unread markers, a **Needs you**
    group, pins, groups, a filter, drag and drop, and a resizable,
    collapsible width;
  - up to 4 split panes that mix terminal, Chat View, file, diff and
    preview, with Chat View opening as a tab;
  - a dashboard home (Needs you, usage, live previews, other workspaces)
    and a right panel (inbox, preview, usage);
  - shortcuts: Ctrl+Shift+\ splits right, Ctrl+Shift+- splits down,
    Alt+arrows move between splits and Ctrl+Shift+U opens the next unread
    (on macOS Cmd+D, Cmd+Shift+D, Cmd+Option+arrows and Cmd+Shift+U).

  Phones are unchanged. See [docs/desktop.md](docs/desktop.md#the-desktop-shell).
- **Usage at a glance** (companion 0.6 or newer): Claude's 5-hour and weekly
  limit rings, today's tokens and an estimated cost at API prices, and a
  breakdown by machine, project, model and day, with Codex when it is
  installed. It shows in a bar on the phone's home screen, the Usage tab,
  and rings on the Android widget and Quick Settings tile. An optional alert
  fires at 80% of the 5-hour window.
- **Voice**:
  - new messages, unlocking and notification sounds no longer cut speech
    off, and calls pause and resume it;
  - read-aloud length: Brief (the default; say "more" in Talk), Full, or a
    Claude summary (companion 0.7 `summarize`);
  - tool activity in Chat View: Show all, Collapsed (the default) or Hidden;
  - speech stays with its own chat when agents open and close;
  - read-aloud and Talk have toggles that are always in the header;
  - the mic is never hidden: it is muted with an explanation instead, and
    Dictate is in the terminal palette and pill.
- **Clearer connection errors**: "Can't reach *machine*", with a Tailscale
  hint for 100.x and `ts.net` addresses, and plain sign-in and host key
  messages, each with Details and Retry. Back from Chat View goes straight
  home.
- **Privacy**: crash reports (self-hosted GlitchTip) and anonymous usage
  counts (self-hosted Plausible), each with a switch in Settings › Privacy.
  See [Privacy](#privacy).
- Host companion **0.7.0**, with the `usage` and `summarize` commands.

<table>
  <tr>
    <td align="center"><img src="docs/screenshots/25-home-usage.png" width="200" alt="Usage bar with limit rings on the phone's home screen"><br><sub>Usage bar on the home screen</sub></td>
    <td align="center"><img src="docs/screenshots/26-usage-breakdown.png" width="200" alt="Usage explorer: limit rings, ranges, a week by day and tokens per project"><br><sub>Usage in detail (the explorer since preview 17)</sub></td>
    <td align="center"><img src="docs/screenshots/27-chat-tool-activity.png" width="200" alt="Chat View with collapsed tool calls, one run opened"><br><sub>Tool activity collapsed</sub></td>
    <td align="center"><img src="docs/screenshots/28-chat-menu.png" width="200" alt="Chat View menu: read-aloud length and tool activity"><br><sub>The Chat View menu</sub></td>
  </tr>
</table>

<p align="center"><img src="docs/screenshots/22-desktop-shell-dashboard.png" width="820" alt="Desktop shell dashboard: Needs you, usage, recent sessions and other workspaces"><br><sub>The desktop shell's dashboard home</sub></p>

## New in preview 13

- **Settings screen**: one searchable page for every preference, with the
  section list and the open section side by side on a desktop.
- **Import refresh**: machines imported from a backup show their workspaces
  on the home screen straight away, without a restart.
- **This computer** on the desktop: a local terminal, Herdr and tmux on the
  machine the app runs on, listed with your other machines.
- **Herdr and tmux tabs**: a compact tab label with a tab list on phones, a
  full tab strip on desktops, and rename, move and close.
- **Desktop shortcuts and zoom**: standard terminal shortcuts,
  Ctrl+PgUp/PgDn between tabs, and Ctrl+wheel, Ctrl+= or Ctrl+- to zoom
  (Cmd on macOS).
- **Desktop dialogs**: pickers open as centred dialogs and action menus as
  popovers instead of bottom sheets.

<table>
  <tr>
    <td align="center"><img src="docs/screenshots/07-settings.png" width="200" alt="Settings section list on a phone"><br><sub>Settings on a phone</sub></td>
    <td align="center"><img src="docs/screenshots/18-herdr-tabs.png" width="200" alt="Compact Herdr tab label and the tab list"><br><sub>Herdr tabs: compact label and tab list</sub></td>
  </tr>
</table>

<p align="center"><img src="docs/screenshots/17-desktop-settings.png" width="820" alt="Settings on a 1280x800 desktop window, two panes"><br><sub>Settings on the desktop: sections beside the open one</sub></p>

<table>
  <tr>
    <td align="center"><img src="docs/screenshots/20-desktop-this-computer.png" width="400" alt="Machine list with This computer first"><br><sub>This computer in the machine list</sub></td>
    <td align="center"><img src="docs/screenshots/21-desktop-connect-dialog.png" width="400" alt="Connect picker as a centred dialog"><br><sub>The connect picker as a centred dialog</sub></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/screenshots/15-desktop-terminal.png" width="400" alt="Desktop terminal with the Herdr tab strip"><br><sub>The tab strip under the session tabs</sub></td>
    <td align="center"><img src="docs/screenshots/19-desktop-tab-popover.png" width="400" alt="Tab actions popover on the desktop"><br><sub>Tab actions as a popover</sub></td>
  </tr>
</table>

## New in preview 12

- **Desktop builds** for Linux, Windows and macOS, next to the Android and
  iOS apps.
- **Quick switcher** for sessions, workspaces and agents that need you.
- **Voice**: read replies aloud, hands-free Talk mode, continuous dictation.
- **Chat View**: working indicator, real tables, agent cards, and a thread
  that holds still while you read.
- **Device sync** through your own machine, set up with a QR code.
- **Live preview** finds dev servers by itself and sends screenshots to
  Claude.
- **Session restore**, **image paste** and **drag scrolling** in full-screen
  programs.
- Host companion **0.5.0**.

## Features

### Agents

- **Chat View** for Claude Code sessions: read the conversation as chat and
  reply from a composer, instead of reading the raw TUI.
  - A live working indicator says what Claude is doing and for how long.
  - Markdown tables render as tables, scrollable and full screen.
  - Messages from other agents and Claude sessions, task notices, shell and
    slash commands each get their own card, never shown as yours; a
    teammate that finished gets one "*X* finished" row.
  - Scrolled up, the thread stays still. New messages wait behind a pill.
  - What you send shows at once as a pending bubble.
  - Long-press a message to copy, share, quote it or send it to another
    agent; find in the conversation with Ctrl+F (Cmd+F).
- **Voice** (Android and iPhone): read Claude's final answer aloud, and
  hands-free **Talk mode** that listens, sends after a pause, reads the
  answer and answers approvals by voice. Dictation keeps listening across
  pauses. The mic and Talk are in Chat View whichever way you open it.
- **Voice guide**: talk to the whole app hands-free: ask what is waiting,
  open an agent, approve, read a reply or switch accounts. Common phrases
  work offline in English and Portuguese, the rest goes to Claude through
  the companion (0.8). It confirms aloud before it acts, always for high
  risk.
- **Read-aloud length** (Brief, Full or a Claude summary) and **tool
  activity** in Chat View (Show all, Collapsed or Hidden), from the header
  menu or Settings.
- **Agents dashboard**: since your last look, each agent's facts (files,
  lines, tests, failed commands, tokens and cost), stuck flags, and a Claude
  summary made only when you open it (companion 0.9).
- **Review mode and undo** (companion 1.0): every turn is snapshotted;
  review it file by file, reject one file, send feedback, or undo the turn.
- **Inbox** of every agent across your machines, with permission requests you
  answer with Allow, Deny or Always, and a Usage tab.
- **Smarter approvals** (companion with `smart-approvals`): every request
  carries a Low, Medium or High risk label with a one-line reason. "Trust…"
  allows a pattern such as `Bash(npm test *)` for 15 min, 1 h or until the
  session ends, in one session, one repo or all repos; "Always" saves the
  same kind of rule until revoked. The companion answers matching requests by
  itself, even with the phone offline, and never answers a high-risk one.
  "Approve all N safe" clears the low-risk ones in one go, the inbox lists
  what was auto-approved in the last 24 h with "Undo trust", and Settings ›
  Agents › Approval rules lists and edits each machine's rules.
- **Usage** (companion 0.6 or newer): Claude's 5-hour and weekly limits,
  tokens and an estimated cost per day, machine, project and model, Codex
  too. On the home screen, the widget and the Quick Settings tile, with an
  optional alert at 80% of the 5-hour window. The usage explorer (companion
  1.0) shows any range, a day by the hour, filters and a CSV export. With
  [cswap](https://github.com/realiti4/claude-swap) on the machine
  (companion 0.8), every Claude account's limits, and a confirmed switch.
- **Notifications with actions**: one notification per agent, updated in place
  with what it needs now ("api · VTM needs you: Approve Bash: npm test · +2
  more"). Approve or deny the first request, or jump to the agent's exact
  pane, straight from the notification; approving from the lock screen asks
  you to unlock first. It alerts only when an agent newly needs you, goes away
  once everything is answered, and all agents stack under one summary that
  opens the dashboard.
- **Home screen widget and Quick Settings tile** (Android) showing the
  dashboard: agents that need you or are stuck, and the limit rings.
- Agent attention dashboard that polls Herdr and shows which agents are
  working, waiting, or finished.

Most of this needs the [host companion](#host-companion) on the machine.

### Sessions, Herdr and tmux

Both multiplexers are first-class: everything below works for Herdr and for
tmux.

- **Home screen built around your servers**: pick one, several or all machines;
  your open sessions show as live previews (grid, large tiles or a list) with
  Mosh/SSH badges and each agent's state, and **Other workspaces** lists the
  Herdr workspaces and tmux sessions you have not opened yet.
- **Quick switcher**: agents waiting on you, open sessions with live
  thumbnails, other workspaces and recents, with search. Swipe the top row
  or press Ctrl+Shift+K (Cmd+K on macOS).
- **Chat View or Terminal by default**: choose how Claude sessions open, per
  session or for all.
- **Session restore**: open sessions come back after an app restart and
  reconnect by themselves ([docs/session-restore.md](docs/session-restore.md)).
- **Several sessions on one Herdr server**: Herdr shares one focus between
  all its clients, so the session in use takes it back before it takes
  input, and the other tiles show their own last screen
  ([docs/herdr-shared-focus.md](docs/herdr-shared-focus.md)).
- **Navigators** for Herdr and tmux: every pane with its agent and state, tap to
  switch, one-tap **Split right / Split down / New tab / New workspace** (tmux:
  new window), windows or tabs 1-9, zoom, kill pane and detach. Long-press the
  toolbar's Herdr or tmux button for the split menu.
- **Gestures**: swipe for tabs or windows, two fingers sideways for panes, two
  fingers up/down for workspaces (Herdr) or scrollback (tmux), pinch for the
  font size. Every mapping is configurable.
- **Deep links** from notifications, the home screen and the inbox open an
  agent at its exact workspace, tab and pane, in Herdr or tmux.
- **The host's own keybindings**: Herdr keys are read from the machine's
  `~/.config/herdr/config.toml`, falling back to Herdr's defaults.
- **Configurable multiplexer prefix**, including Ctrl+Space.
- Official tmux and Herdr logos, per-host tmux auto attach/create, start
  directory and scrollback mode.

### Terminal

- **Compact pill toolbar** with modifiers, arrows, function keys, snippets and
  your own key combos. Its layout is configurable.
- **Drag scrolling in full-screen programs**: a one-finger drag scrolls Herdr,
  tmux, vim, htop and Claude Code's full-screen view like a mouse wheel
  ([docs/terminal-drag-scrolling.md](docs/terminal-drag-scrolling.md)).
- **Chat mode composer**: a line or multiline prompt editor with per-session
  drafts, voice dictation, and images from the gallery, camera or clipboard.
  Images are uploaded over SFTP and their path is inserted into the prompt.
- **Image paste** (Android): paste a clipboard image into the terminal, Chat
  View or chat mode. It is uploaded and its path typed for you.
- **Menu buttons** for common Claude Code prompts and commands.
- **OSC 52 clipboard**: text copied by vim, Neovim, Claude Code or tmux on the
  host lands on the device clipboard. The host can never read your
  clipboard.
- **Tappable links and paths**, with an in-app preview for localhost links.
- **Recent directories** per machine, from OSC 7, tmux and the companion, to
  open a shell, tmux window or Herdr tab in one.
- **SFTP browser** with bookmarks, a file viewer and editor, uploads and
  downloads. Saves go through a temporary file and a rename, so a dropped
  connection never leaves a half-written file.
- **Git diff view** of a repository's working tree.
- **Live preview** of a dev server running on the host.
  - A **Preview ready** chip appears when a new dev server starts, found by
    the companion, `ss` or the terminal output.
  - Phone, Tablet and Desktop viewport widths, remembered per port.
  - **Screenshot to Claude** with a quick annotation (Android and macOS).
- **Share to agent**: share text, links or images from any Android app into a
  session.
- Touch mode indicator: taps select text, click, or scroll history.

### Connectivity and sync

- SSH with password, OpenSSH private keys (import, or generate `ed25519` on
  the device) and server-driven auth.
- Mosh through [dart_mosh](https://github.com/gwitko/dart_mosh), a clean-room
  Dart implementation that survives Wi-Fi drops and network changes.
- Hardware security keys (`ed25519-sk`, `ecdsa-sk`) over USB or NFC, several
  per host (phones only).
- Optional per-host SSH agent forwarding.
- Host key trust you review and manage yourself, with SHA256
  fingerprints. A changed key is never trusted silently: you confirm the
  new fingerprint in a second step.
- Works over Tailscale like any other network: point a host at its tailnet
  name or IP.
- Plain connection errors: "Can't reach" (with a Tailscale hint for
  tailnet addresses), failed sign-in and untrusted host key, each with
  Details and Retry.
- **Device sync through one of your own machines**, end-to-end encrypted, no
  cloud: saved machines, snippets, settings, connect preferences and the
  session list. Add a device by scanning a QR code and typing six words
  (desktops paste the code). Passwords and keys sync only if you turn that
  on ([docs/sync.md](docs/sync.md)).
- Encrypted backups of settings, machines and trusted keys (same format as
  sync), and an optional device-auth app lock that locks again after a
  time in the background you choose (Settings › Security). Android's own
  cloud backup and device transfer are off: machines move with these
  backups or sync.

### Desktop

- **Desktop shell** on desktops and tablets: a sidebar tree of machines,
  workspaces, tabs and agents with a Needs you group, pins and groups; up
  to 4 splits mixing terminal, Chat View, file, diff and preview; a
  dashboard home; and a right panel for the inbox, preview and usage.
- The same app on Linux, Windows and macOS, with the terminal **keyboard
  first**: keys go straight to the shell, Alt is Meta, mouse selection and
  wheel scrollback. The on-screen keys are one toggle away.
- Ctrl+Shift+C and Ctrl+Shift+V to copy and paste (Cmd on macOS).
- Omarchy theme sync works the same way, so the app follows the theme of
  your Omarchy PC.
- A synced machine that is the PC itself (the phone's SSH entry for it)
  folds into *This computer* on that PC, matched by host key or address,
  and stays a normal SSH machine on your other devices
  ([docs/desktop.md](docs/desktop.md#this-computer-and-a-synced-entry-for-the-same-pc)).
- What each platform supports, and why, is in
  [docs/desktop.md](docs/desktop.md).

### Look

- All 22 [Omarchy](https://omarchy.org) themes, dark and light, from
  Catppuccin and Tokyo Night to Rose Pine and White. Everforest is the
  default. Each theme colours the terminal (its 16 ANSI colours, exactly as
  Omarchy's alacritty config) and the whole app.
- Omarchy-style chrome: flat surfaces from the theme background, thin
  borders, square corners, monospace headings.
- JetBrains Mono Nerd Font, Omarchy's font, is the default terminal font,
  with every Nerd Font icon for prompts and Herdr. Atkynson Mono and the
  system monospace stay selectable.
- Theme sync with your PC: in Appearance, pick a saved machine under
  "Follow Omarchy theme from machine". The app reads its current Omarchy
  theme and font over SSH when it starts or comes back, including your own
  custom themes.

## Screenshots

Rendered from the app's own widgets with demo data by
`tools/render-screenshots.sh`: Everforest theme, a 1080x2400 phone, and a
1280x800 desktop window.

<table>
  <tr>
    <td align="center"><img src="docs/screenshots/11-talk-mode.png" width="200" alt="Talk mode sending a spoken reply"><br><sub>Talk mode: a spoken reply, sent after a pause</sub></td>
    <td align="center"><img src="docs/screenshots/03-chat-view.png" width="200" alt="Chat View with an approval"><br><sub>Chat View with an approval</sub></td>
    <td align="center"><img src="docs/screenshots/04-agents-inbox.png" width="200" alt="Agents inbox"><br><sub>Inbox: approvals, then working and done agents</sub></td>
    <td align="center"><img src="docs/screenshots/14-live-preview-ready.png" width="200" alt="Preview ready chip over a Vite dev server"><br><sub>Live preview finds a new dev server</sub></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/screenshots/12-sync.png" width="200" alt="Sync settings with three devices"><br><sub>Sync: what to sync and your devices</sub></td>
    <td align="center"><img src="docs/screenshots/13-sync-add-device.png" width="200" alt="Add a device with a QR code and six words"><br><sub>Add a device: QR code and six words</sub></td>
    <td align="center"><img src="docs/screenshots/05-herdr-navigator.png" width="200" alt="Herdr navigator sheet"><br><sub>Herdr navigator: splits, tabs, every pane</sub></td>
    <td align="center"><img src="docs/screenshots/06-menu-buttons.png" width="200" alt="Menu buttons over a Claude Code permission prompt"><br><sub>Menu buttons answer a prompt in one tap</sub></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/screenshots/07-settings.png" width="200" alt="Settings section list"><br><sub>Settings: every preference, searchable</sub></td>
    <td align="center"><img src="docs/screenshots/08-agent-hooks.png" width="200" alt="Agent hooks screen showing Active"><br><sub>Agent hooks: companion status and checks</sub></td>
    <td align="center"><img src="docs/screenshots/18-herdr-tabs.png" width="200" alt="Compact Herdr tab label and the tab list"><br><sub>Herdr tabs on a phone</sub></td>
    <td align="center"><img src="docs/screenshots/29-cant-reach.png" width="200" alt="Can't reach build-box, with a Tailscale hint and details"><br><sub>Can't reach: a Tailscale hint and details</sub></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/screenshots/25-home-usage.png" width="200" alt="Usage bar with limit rings on the phone's home screen"><br><sub>Usage bar on the home screen</sub></td>
    <td align="center"><img src="docs/screenshots/26-usage-breakdown.png" width="200" alt="Usage explorer: limit rings, ranges, a week by day and tokens per project"><br><sub>Usage explorer: a week by day and project</sub></td>
    <td align="center"><img src="docs/screenshots/27-chat-tool-activity.png" width="200" alt="Chat View with collapsed tool calls, one run opened"><br><sub>Chat View: tool calls collapsed</sub></td>
    <td align="center"><img src="docs/screenshots/28-chat-menu.png" width="200" alt="Chat View menu: read-aloud length and tool activity"><br><sub>Read-aloud length and tool activity</sub></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/screenshots/30-approval-risk.png" width="200" alt="Chat View approval card with a Low risk label, Trust… and Always"><br><sub>Approvals: risk label, Trust… and Always</sub></td>
    <td align="center"><img src="docs/screenshots/31-approval-rules.png" width="200" alt="Approval rules for the workstation: a timed trust and standing rules"><br><sub>Approval rules per machine</sub></td>
    <td align="center"><img src="docs/screenshots/32-voice-guide.png" width="200" alt="Voice guide card on the home screen asking to confirm an approval"><br><sub>Voice guide: a spoken confirmation</sub></td>
    <td align="center"><img src="docs/screenshots/33-usage-accounts.png" width="200" alt="Usage explorer with an Accounts section for two cswap accounts"><br><sub>Usage: every cswap account</sub></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/screenshots/34-chat-peer-messages.png" width="200" alt="Chat View with a message from another session and a finished row"><br><sub>Chat View: other sessions and teammates</sub></td>
    <td align="center"><img src="docs/screenshots/35-agents-dashboard.png" width="200" alt="Agents dashboard: needs you, stuck and done cards with facts and summaries"><br><sub>Agents dashboard: facts and summaries</sub></td>
    <td align="center"><img src="docs/screenshots/36-chat-pending-bubble.png" width="200" alt="Chat View with a just-sent message as a pending bubble"><br><sub>A sent message shows at once</sub></td>
    <td align="center"><img src="docs/screenshots/37-review-cards.png" width="200" alt="Review mode: a file card with a coloured diff, accept and reject"><br><sub>Review mode: one card per file</sub></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/screenshots/38-usage-explorer-day.png" width="200" alt="Usage explorer: one day by hour, project and session"><br><sub>Usage explorer: a day by the hour</sub></td>
    <td align="center"><img src="docs/screenshots/39-chat-message-menu.png" width="200" alt="Chat View message menu: copy, share, quote, send to another agent"><br><sub>Message menu</sub></td>
    <td align="center"><img src="docs/screenshots/40-chat-find.png" width="200" alt="Chat View find bar with highlighted matches"><br><sub>Find in the conversation</sub></td>
  </tr>
</table>

<p align="center"><img src="docs/screenshots/22-desktop-shell-dashboard.png" width="820" alt="Desktop shell dashboard: Needs you, usage, recent sessions and other workspaces"><br><sub>Desktop shell: the dashboard home</sub></p>

<p align="center"><img src="docs/screenshots/23-desktop-shell-split.png" width="820" alt="Desktop shell with two terminal splits side by side"><br><sub>Desktop shell: two sessions in splits, the tab strip above</sub></p>

<p align="center"><img src="docs/screenshots/24-desktop-shell-chat-split.png" width="820" alt="Desktop shell with a terminal and Chat View in splits, a group and a pin in the sidebar"><br><sub>Desktop shell: a terminal beside its Chat View, with a pin and a group</sub></p>

## Install

Builds are previews. Get them from
[Releases](../../releases/tag/v0.1.0-conductore.17) or, for the Outsmartis
team, from the store test channels. Each release lists `SHA256SUMS` files
next to the downloads.

### Android

- **APK from Releases.** Download the APK for your device, usually
  `conductore-v<version>-arm64-v8a.apk` (`armeabi-v7a` for older 32-bit
  phones, `x86_64` for emulators), and `SHA256SUMS-v<version>.txt`. Check
  it, then open the APK on the phone and allow installing from that source.

  ```sh
  sha256sum -c SHA256SUMS-v*.txt --ignore-missing
  ```

  Every release is signed with the same key, so a new APK installs over the
  previous one and keeps your machines and settings.
- **Google Play internal testing**, for team testers: accept the testing
  invite, then install Conductore from Play. Play updates it.

### iOS

**TestFlight**, for team testers on the internal group: install TestFlight,
accept the invite and install Conductore. New builds arrive in TestFlight
automatically. There is no public iOS build yet.

### Linux (x64)

1. Download `conductore-v<version>-linux-x64.tar.gz` and
   `SHA256SUMS-desktop-v<version>.txt`, and check it as above.
2. Install the runtime dependencies. Saved hosts and keys live in the Secret
   Service, so a keyring daemon has to be running.

   ```sh
   # Arch / Omarchy
   sudo pacman -S --needed gtk3 libsecret gnome-keyring
   # Debian / Ubuntu
   sudo apt install libgtk-3-0 libsecret-1-0 gnome-keyring
   ```

3. Unpack and run:

   ```sh
   tar -xzf conductore-v<version>-linux-x64.tar.gz
   cd conductore && ./conductore
   ```

For a launcher entry, see [docs/desktop.md](docs/desktop.md#linux).

### Windows (x64)

Unzip `conductore-v<version>-windows-x64.zip` and run
`conductore\conductore.exe`. Keep the folder together. The app is not
signed, so SmartScreen warns the first time: click **More info**, then
**Run anyway**. Windows 10 or 11.

### macOS

Unzip `conductore-v<version>-macos.zip` and move `Conductore.app` to
Applications. The app is not notarised, so the first time
**right-click (or Control-click) it, choose Open, then Open**. On macOS 15
and later, use **System Settings, Privacy & Security, Open Anyway** if
there is no Open button. macOS may ask once to let Conductore use your login
keychain, where it keeps hosts and keys. Apple silicon and Intel, macOS
10.15 or later.

## Host companion

The companion is a small Node.js daemon plus a Claude Code hook client that
runs on the machine where your agents run. It turns Claude Code hook events
into a live view of every agent (working, waiting for input, waiting for
permission, ended) and lets the app answer permission prompts. The app
talks to it only through SSH exec commands. It opens no ports and needs no
relay.

Preview 17 bundles **companion 1.0.0**. What the app asks it for, by the
version that added it:

- `turns`, `diff`, `undo` and `redo` (1.0), for Review mode. The companion
  snapshots the repository at the start and end of every Claude turn as git
  objects under `refs/conductore/snapshots/`, never a commit on your
  branch, pruned after 7 days. `undo` puts the work tree, or single files,
  back to before the turn, and is refused while the agent works.
- `digest` (0.9), for the agents dashboard: each agent's facts and stuck
  flags, and, only when the app asks, a short summary per agent that
  changed.
- `guide` (0.8), for the voice guide: what the phone did not recognise
  becomes one action from a closed list. It gets only short ids and labels,
  never transcripts.
- `trust`, `rules`, `approve-low` and `approvals` (0.8), for smart
  approvals. Rules live in `~/.conductore/rules.json`, never in Claude
  Code's settings; the daemon allows a matching request by itself, even
  with the phone offline, and never a high-risk one.
- `usage` (0.6; ranges, hours and sessions in 1.0, every cswap account in
  0.8) and `cswap-switch` (0.8), for the usage bar, tab and explorer.
- `summarize` (0.7), for the Claude summary read-aloud length, and `ports`
  (0.5), for the Preview ready chip.

`summarize`, `guide` and `digest` summaries use Claude Haiku through
`claude -p` with no tools, no hooks and no session saved, and store nothing.
The app offers the update on the Agent hooks screen. Older companions keep
working without the features they lack.

It is built to stay out of the way. Claude Code hooks and the status line are
small POSIX `sh` scripts that hand each event to a background daemon and exit;
only the daemon and the commands the app runs use Node.js. Measured on a
Linux server with companion 0.4.0:

| | Cost |
|---|---|
| Per hook event | about 2.5 ms and 1.9 MB |
| Per status line refresh | about 3 ms and 1.9 MB |
| Daemon when idle | no CPU, no wakeups; about 7 MB private memory |
| Disk | under 200 KB, no dependencies |

It is light: no npm dependencies, not a service, and it exits by itself after
24 hours without a request.

**Install from the app.** Open a machine's Agent hooks screen and tap install.
The app uploads the companion over SFTP as one archive, unpacks it with
`tar`, checks each file's sha256 and runs its installer.

**Install by hand.** Needs Node.js 18 or newer on Linux or macOS.

```sh
git clone https://github.com/andreconde21/conductore-mobile && cd conductore-mobile/host && ./install.sh
conductore-hostd doctor
```

**Uninstall** from the same app screen, or:

```sh
host/install.sh --uninstall
```

What it changes on the host:

- It adds hook handlers to `~/.claude/settings.json` and keeps a backup. Your
  existing hooks stay untouched, and running it again changes nothing.
- It wraps your Claude Code status line instead of replacing it: your command
  still runs and its output is unchanged. Uninstalling puts it back.
- It installs `conductore-hostd` and `conductore-hook` into `~/.local/bin` and
  keeps its state in `~/.conductore`.

Details, the command reference and the JSON contract are in
[host/README.md](host/README.md).

## Privacy

Conductore sends two things to servers Outsmartis runs itself, to help fix
bugs:

- **Crash reports** to GlitchTip: the error type, a scrubbed message, the
  app's own stack frames, app version, platform and coarse device facts.
  Saved machines' names, addresses, users and secrets, IPs, hostnames,
  paths, file names, keys and tokens are removed on the device first.
- **Anonymous usage counts** to Plausible: app opened, screens shown,
  connections made (SSH or Mosh, Herdr or tmux, worked or failed and a
  coarse reason), Chat View, voice and companion version. No identifiers.

Nothing from your machines or terminals is sent: no commands, output,
clipboard, chat text or transcripts. Both are on by default and each has a
switch in **Settings › Privacy** (stored on the device, applied at once);
the app says so once on the home screen. Development builds send nothing.
Details: [docs/privacy-policy.md](docs/privacy-policy.md).

Android's cloud backup and device transfer are off for Conductore, so none
of its data goes to a Google backup. Your own encrypted backup file and
device sync are the ways to move machines to a new phone.

Builds from source can point elsewhere or turn either half off:

```sh
flutter build apk --flavor full \
  --dart-define=CONDUCTORE_SENTRY_DSN= \
  --dart-define=CONDUCTORE_PLAUSIBLE_HOST=
```

`CONDUCTORE_SENTRY_DSN`, `CONDUCTORE_PLAUSIBLE_HOST` and
`CONDUCTORE_PLAUSIBLE_DOMAIN` replace the endpoints (empty turns that half
off), `CONDUCTORE_TELEMETRY_ENV` sets the release channel (default
`preview`), and `CONDUCTORE_TELEMETRY_IN_DEBUG=true` makes a debug build
send, for checking the pipeline by hand.

## Branches

- `main`: Conductore. Releases are tagged `v0.1.0-conductore.N`.
- `master`: an unmodified mirror of upstream Conduit, kept for merging upstream
  fixes.

## Building from source

Requirements: Flutter 3.44.1, plus JDK 17 for Android, Xcode for iOS and
macOS, Visual Studio with C++ for Windows, and the GTK and libsecret
development packages for Linux (see [docs/desktop.md](docs/desktop.md)).

```sh
flutter pub get
flutter run
flutter test --concurrency=2
```

Desktop builds: `flutter build linux`, `flutter build windows` or
`flutter build macos`, each with `--release`.

Release APKs are built with the script below. It builds from a clean tree and
refuses an APK whose compiled app code is stale. Pass the previous release APK
to also check that the app code changed.

```sh
tools/build-release.sh [previous-release.apk]
```

Release builds do not include the local Arch Linux shell's native binaries.

### Local-shell rootfs mirror

The on-device shell downloads its distribution archives from upstream's
release, [gwitko/conduit-rootfs `rootfs-pd-v4.37.0`](https://github.com/gwitko/conduit-rootfs/releases/tag/rootfs-pd-v4.37.0).
Each archive's sha256 is pinned in
`lib/features/local_shell/local_shell_config.dart`, so any copy of the same
files works. A build tries a primary source first and then a fallback, both
set at build time:

```sh
flutter build apk --release --flavor full --split-per-abi \
  --dart-define=ROOTFS_BASE_URL=https://github.com/andreconde21/conductore-mobile/releases/download/rootfs-pd-v4.37.0 \
  --dart-define=ROOTFS_FALLBACK_BASE_URL=https://github.com/gwitko/conduit-rootfs/releases/download/rootfs-pd-v4.37.0
```

Both default to upstream, so a build without them behaves as before
(`tools/build-release.sh` passes none). To
mirror the archives to a release on andreconde21/conductore-mobile:

```sh
tag=rootfs-pd-v4.37.0
mkdir rootfs-mirror && cd rootfs-mirror
gh release download "$tag" --repo gwitko/conduit-rootfs --pattern '*-aarch64-pd-*.tar.xz'
sha256sum *.tar.xz   # compare with the pins in local_shell_config.dart
gh release create "$tag" --repo andreconde21/conductore-mobile \
  --title "Local-shell rootfs ($tag)" --notes "Mirror of gwitko/conduit-rootfs $tag." \
  --prerelease *.tar.xz
```

Keep the tag and the file names unchanged, because the app appends each file
name to the base URL. Then pass the mirror's download URL as
`ROOTFS_BASE_URL`.

Tagged releases (`v*`) are built by GitHub Actions and go to Google Play
internal testing, TestFlight and a GitHub prerelease with the APKs and the
Linux, Windows and macOS bundles; see
[docs/release-pipeline.md](docs/release-pipeline.md). The privacy policy is
[docs/privacy-policy.md](docs/privacy-policy.md).

## Credits

- Based on [Conduit](https://github.com/gwitko/Conduit) by
  [gwitko](https://github.com/gwitko). The terminal is
  [conduit_vt](https://github.com/gwitko/conduit_vt), a fork of xterm.dart, and
  Mosh is [dart_mosh](https://github.com/gwitko/dart_mosh).
- Includes contributions by [DrMulungu](https://github.com/DrMulungu) salvaged
  from upstream pull requests
  [#143](https://github.com/gwitko/Conduit/pull/143) to
  [#148](https://github.com/gwitko/Conduit/pull/148) and
  [#150](https://github.com/gwitko/Conduit/pull/150): the Herdr key, SFTP
  bookmarks, the file viewer and editor, tappable paths, touch mode, the prompt
  composer and the agent attention dashboard.
- Inspired by [Moshi](https://getmoshi.app). No Moshi code was copied.
- Other Conduit contributors are listed in [CONTRIBUTORS.md](CONTRIBUTORS.md).

## License

Conductore's own source code is licensed [Apache-2.0](LICENSE), as is
Conduit's.

Bundled third-party components keep their own licenses:

- **PDFium** (`libpdfium.so`, bundled through the `pdfrx` package) is under
  Apache-2.0 and BSD-3-Clause-style terms.
- **Atkinson Mono Nerd Font** is under the SIL Open Font License 1.1, see
  [assets/fonts/LICENSE-AtkynsonMono.txt](assets/fonts/LICENSE-AtkynsonMono.txt).
- Dart package licenses are shown in the app's license screen.

The source also contains Conduit's optional on-device Arch Linux shell. Its
native binaries (proot, busybox, GNU tar and others, packaged by
[Termux](https://termux.dev)) are not part of Conductore release builds. If you
build them yourself with `tools/build-local-shell-binaries.sh`, they come under
their own GPL, LGPL and permissive licenses. The component list, license texts
and GPL/LGPL source offer are in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and
[third_party/source-offer](third_party/source-offer).
