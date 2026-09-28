# Several sessions on one Herdr server

Herdr keeps **one focus per server**: one focused workspace, and in it one
tab and one pane. Every client attached to that server shows that focus and
types into it: the Herdr TUI on your laptop, and each Conductore session
opened on a Herdr workspace (each one runs its own `herdr` client). Herdr
0.9.1 has no per-client focus, and focusing a workspace from any client, or
with `herdr workspace focus`, moves all of them. This was checked with two
clients on an isolated server: after the second one focused its workspace,
keys typed into the first landed in the second one's workspace.

So five Conductore sessions on five workspaces of one server are five views
of the same screen. Without help, all five previews showed the same
workspace, and typing into one session could land in another workspace
(CON-054).

## The setting: "Phone may move Herdr focus"

Settings › Terminal › **Phone may move Herdr focus** (on a computer: *This
device may move Herdr focus*). It is kept per device and never synced.

> Herdr shares one focus across all screens, including your laptop. Off:
> this device never moves it; typing is sent to the right pane instead.

### Off (the default): your laptop is never disturbed

The app never changes Herdr's focus on its own:

- **Attaching does not focus.** A session opens (and reattaches) with a
  plain `herdr`, which leaves the focus where it is (checked on Herdr 0.9.1:
  attaching and detaching a client does not move it). No focus on a tab
  switch, a tile tap, a deep link, the app coming back or a reconnect.
- **What the app writes goes to the session's own pane, by id.** The
  composer (and dictation into it), Chat View, snippets, quick actions,
  prompt-menu answers, pasted image paths and *cd to a recent directory*
  are sent with `herdr pane send-text` / `pane send-keys` (or `herdr agent
  prompt` for an agent) to the pane the session's workspace has focused in
  its active tab. Herdr remembers that per workspace, whatever the server
  shows, so it lands in the right place without moving anything. If no
  pane can be found, the text is typed into the terminal instead, under the
  rule below.
- **Keys typed into the terminal go out only while Herdr shows the
  session's own workspace.** The app checks where the focus is with
  `herdr workspace list` (read-only; a check counts for 3 seconds and is
  repeated in the background while you type). When Herdr shows another
  workspace, the keys are held, not sent, and a banner says *Herdr is
  showing X (another screen has focus)*, with:
  - **Type in composer**: opens the composer with what you typed; it
    sends to the session's own pane;
  - **Take focus once**: moves Herdr's focus to this session's workspace
    this one time (the laptop follows), then sends the held keys;
  - **Use X here**: you moved to X inside this session's Herdr on purpose;
    the session stays on X and the keys go there;
  - **Discard**: drops the held keys.
  The banner also shows, without held keys, when you open a session whose
  workspace Herdr is not showing.
- **Previews show each session's own workspace.** A session whose
  workspace Herdr does not show is previewed from `herdr pane read
  --source visible --format ansi` of its own pane (read-only, with
  colours), refreshed every 15 seconds while the app is open, else its last
  own screen, with a "Herdr · 05:54" caption.
- **Desktop splits.** The other panes of a Herdr server show their own
  screen, dimmed, with a **Take focus** button; clicking the pane does not
  take the focus.

Gestures and menus that navigate Herdr from the phone (swipe between
workspaces, the navigator, the tab strip) still move Herdr's focus: they
are you driving Herdr, the same as keys typed into it.

### On: the session in use owns the focus

- **The session in use owns the focus.** Whenever a Herdr session becomes
  the one in use, Conductore first runs `herdr workspace focus <its
  workspace>` over the machine's background connection (the one the agent
  monitor and gestures use), then lets the session take input. That covers
  a tab switch, a tile tap on the home screen, the quick switcher, a desktop
  split pane taking the focus, and deep links. Herdr remembers each
  workspace's own tab and pane, so you land where you left it. A session
  attaches with its workspace (and tab or pane) focused.
- **Input waits for the switch.** Keys typed during that round trip are
  held and sent, in order, once Herdr confirms. After a quarter of a second
  a "Switching Herdr to …" hint shows. If Herdr does not confirm within 6
  seconds, or refuses (the workspace was closed), the held keys are
  **dropped, not sent somewhere else**, and the terminal says how many
  characters were not sent.
- **App writes check first.** The composer, snippets, quick actions,
  prompt-menu answers, image paths and `cd` to a recent directory focus the
  session's workspace again before typing, in case the laptop moved the
  focus meanwhile. Chat View sends need none of this: the companion types
  into the agent's pane by pane id (`herdr agent prompt`), whatever is
  focused.
- **The app coming back** to the foreground focuses the session in use
  again, and so does a session that reconnects in the background (its
  startup command focuses its own workspace while it attaches; the focus is
  given back to the session in use 2 seconds later, with its input held).
- **Previews** keep a snapshot of each session's own last screen (taken
  when it stopped owning the focus, or right after it attached), with a
  small "Herdr · 05:54" caption. A session that never had the focus says
  "Shared Herdr view" until you open it.
- **Desktop splits.** The focused pane owns the focus; the other panes
  show their own last screen, dimmed, with "Shared Herdr view. Click to
  focus." A click there only focuses the pane (and its workspace); it is
  never passed to the terminal underneath, which shows another workspace.
- **The laptop follows the phone.** Focusing a workspace from the phone
  moves the Herdr TUI on the laptop too, and the other way round.

### Either way

- Rendering previews never changes Herdr's focus.
- Hosts that sign in with a security key have no background connection (it
  would ask for a touch each time): none of the checks, pane-targeted
  writes or focus moves apply to them. With the setting off they still
  attach without focusing.

## Independent views (power users)

If you want sessions that really do not affect each other, give them
separate Herdr servers: `herdr --session <name>` starts (or attaches to) a
named session with its own socket, its own workspaces and its own focus.
Conductore opens named sessions from the connect picker, and each one is
driven on its own. The catch is that workspaces and agents do not move
between servers: an agent runs in the server it was started in.

For a single agent, `herdr agent attach <agent>` attaches a client straight
to that agent's terminal without Herdr's sidebar or tabs. It does not
follow or change the server's focus (checked on Herdr 0.9.1), but it only
works for panes where Herdr detects an agent, and it shows that one pane.
