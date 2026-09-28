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

## What Conductore does about it

- **The session in use owns the focus.** Whenever a Herdr session becomes
  the one in use, Conductore first runs `herdr workspace focus <its
  workspace>` over the machine's background connection (the one the agent
  monitor and gestures use), then lets the session take input. That covers
  a tab switch, a tile tap on the home screen, the quick switcher, a desktop
  split pane taking the focus, and deep links. Herdr remembers each
  workspace's own tab and pane, so you land where you left it.
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
- **Previews show each session's own workspace.** A session whose server is
  focused on another session keeps a snapshot of its own last screen (taken
  when it stopped owning the focus, or right after it attached) for its home
  tile, list row and switcher thumbnail, with a small "Herdr · 05:54"
  caption. Rendering previews never changes Herdr's focus. A session that
  never had the focus says "Shared Herdr view" until you open it.
- **Desktop splits.** Several panes can show Herdr sessions of one server,
  but only one can have Herdr's focus. The focused pane owns it; the other
  panes show their own last screen, dimmed, with "Shared Herdr view. Click
  to focus." A click there only focuses the pane (and its workspace); it is
  never passed to the terminal underneath, which shows another workspace.

## Side effects

- **The laptop follows the phone.** Focusing a workspace from the phone
  moves the Herdr TUI on the laptop too, if it is attached to the same
  server, and the other way round. Conductore only moves the focus when a
  session becomes the one in use, when the app comes back, and before it
  types.
- Hosts that sign in with a security key have no background connection (it
  would ask for a touch each time), so none of the above applies to them:
  switching sessions there still shows whatever Herdr has focused.

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
