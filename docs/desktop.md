# Desktop builds (Linux, Windows, macOS)

Conductore runs on Linux, Windows and macOS from the same Flutter code as
the phone apps. The desktop builds are **test builds**: unsigned, not in any
store, meant for trying the app with a real keyboard and a big screen. The
goal is one experience across phone and desktop: the same sessions, agents
and settings, laid out for a window instead of a phone. Desktops get the
desktop shell (a sidebar, tabs and splits, a dashboard; see below) and a
keyboard-first terminal.

## Getting a build

CI builds all three on every push to `main` and every PR (`ci.yml`, jobs
*Linux / Windows / macOS desktop build*). Open the run and download the
artifact. Tagged releases attach the same bundles to the GitHub prerelease
(`release.yml`, job *Desktop*):

| Platform | Release asset | CI artifact |
|---|---|---|
| Linux x64 | `conductore-v<version>-linux-x64.tar.gz` | `conductore-linux-x64` |
| Windows x64 | `conductore-v<version>-windows-x64.zip` | `conductore-windows-x64` |
| macOS (Apple silicon + Intel) | `conductore-v<version>-macos.zip` | `conductore-macos` |

`SHA256SUMS-desktop-v<version>.txt` sits next to them.

### Linux

```sh
tar -xzf conductore-v<version>-linux-x64.tar.gz
./conductore/conductore
```

Runtime needs: GTK 3 and **libsecret** with a running Secret Service
(GNOME Keyring or KWallet). Saved hosts, keys and settings live in
libsecret. Without a keyring daemon, saving fails. On a minimal system,
install `libgtk-3-0` and `libsecret-1-0` (Debian/Ubuntu) or `gtk3` and
`libsecret` (Arch/Omarchy), plus `gnome-keyring`.

To get a launcher entry, move the folder to `/opt/conductore` and copy
`data/conductore.desktop` to `~/.local/share/applications/`. Edit its two
paths if you put the folder elsewhere.

### Windows

Unzip `conductore-v<version>-windows-x64.zip` and run
`conductore\conductore.exe`. Keep the folder together: the exe loads the
DLLs and `data\` next to it. SmartScreen warns about an unsigned app the
first time: **More info → Run anyway**. Windows 10 or 11, x64.

### macOS

Unzip and move `Conductore.app` to Applications. The app is ad-hoc signed,
not notarised, so Gatekeeper blocks a double-click the first time:
**right-click (or Control-click) → Open → Open**. On macOS 15 and later, if
there is no Open button, go to **System Settings → Privacy & Security** and
click **Open Anyway**. Alternatively run:

```sh
xattr -dr com.apple.quarantine /Applications/Conductore.app
```

macOS 10.15 or later.

### Building locally

The desktop toolchains are the usual Flutter ones; see
`.github/workflows/ci.yml` for the exact setup.

```sh
flutter build linux --release     # Ubuntu: clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev libsecret-1-dev libstdc++-12-dev
flutter build windows --release   # Visual Studio 2022 with "Desktop development with C++"
flutter build macos --release     # Xcode
```

Outputs: `build/linux/x64/release/bundle/`,
`build/windows/x64/runner/Release/`,
`build/macos/Build/Products/Release/Conductore.app`.

Desktop icons come from `tools/render_launcher_icon.py --desktop` (the
Windows `.ico`, the macOS AppIcon set and the Linux window icon).

## The desktop shell

On a desktop (and on a tablet at least 900 dp wide) the home screen and
the terminal are one window instead of two pages. Phones, and tablets
narrower than 900 dp, keep the phone layout.

- **Sidebar** (left, drag its edge between 220 and 420 px, or collapse it
  to icons). A tree of every machine, *This computer* first: its Herdr
  workspaces and tmux sessions, then their tabs or windows, then the agent
  panes. Each row has its logo (tmux, Herdr, or the agent's badge), a
  human name, a state dot (working, needs you, done, idle), the agent
  kind, and a tab mark when a session in the app shows it. A *Needs you*
  group on top lists what waits on you. The filter field narrows the tree.
  Click a row to open it; the chevron opens it in the tree (a tmux
  session lists its windows then). Right-click (or long-press) for *Open
  in a split*, *Mark as read / unread*, *Pin*, groups and the machine's
  actions. Drag machines, workspaces and pins to reorder them; drop a
  machine on a group to move it there. Groups ("Clients", "Infra") are
  made from a machine's menu (*New group…*).
- **Unread.** A row turns bold with a dot when something happened that you
  have not seen: new output in a session that is not on screen (tmux
  `session_activity`, or the terminal of an open session), an agent that
  finished, or one that needs you. Looking at it clears it; parents count
  their unread rows. Ctrl+Shift+U (Cmd+Shift+U) opens the next one.
- **Tabs and splits.** The tabs across the top hold every open view:
  terminal sessions, Chat View, files, git diffs and live previews. Drag a
  tab onto the left, right, top or bottom edge of a pane to split it, or
  onto its middle to show it there (up to four panes). Drag the dividers to
  resize. A tab's right-click menu splits too. A split can mix views: a
  terminal next to the agent's Chat View, Claude next to its live
  preview. Alt+arrows move between panes. Ctrl+Shift+\ splits right and
  Ctrl+Shift+- splits down, with the most recent view that is not on
  screen, or a new session when every view is. The layout is saved and
  comes back with the sessions (*Restore sessions on launch*).
- **Dashboard.** With no view open, or after the home button at the left
  of the tabs, the main area shows columns: *Needs you* cards (with
  Allow / Deny for approvals the companion relays), a usage slot, the
  open sessions as live previews, and the other workspaces per machine.
- **Right panel.** The Agents button (the pulse icon) opens the agent
  inbox with approvals on the right; the globe opens the live preview of
  the focused session. Drag its edge to resize it.
- Sidebar width, collapsed state, groups, pins, order, the split layout
  and the unread markers are kept per device (secure storage, key
  `conduit.desktop_shell.v1`). They are not synced or backed up.

## Using it on a desktop

- **Keyboard.** Keys go straight to the remote shell. Ctrl+C, Ctrl+A,
  Ctrl+V, Ctrl+[ ] \ / reach the shell. Alt is Meta on Linux and Windows,
  so Alt+b and Alt+f move by word. On macOS, Option composes characters,
  like Terminal.app. Arrows, Home/End, PgUp/PgDn and F1 to F12 send xterm
  sequences, including modifiers.
- **Copy and paste.** Ctrl+Shift+C and Ctrl+Shift+V (or Shift+Insert) on
  Linux and Windows. Cmd+C, Cmd+V and Cmd+A on macOS.
- **Quick switcher.** Ctrl+Shift+K (Cmd+K on macOS) opens it from the home
  screen and the terminal. The key never reaches the shell; plain Ctrl+K
  does.
- **Mouse.** Drag to select, and use the wheel to scroll back. The phone
  swipe gestures only react to touch, so a mouse drag never switches tmux
  windows.
- **Zoom.** Ctrl + mouse wheel (Cmd + wheel on macOS) or a trackpad pinch
  changes the terminal font size, like the phone's pinch, and it is saved
  the same way. A plain wheel still scrolls.
- **Shortcuts.** Ctrl+Shift+/ (Cmd+/ on macOS) or *Keyboard shortcuts* in
  the terminal menu lists them all:

  | Action | Linux / Windows | macOS |
  |---|---|---|
  | Zoom in / out / reset | Ctrl+= (or Ctrl++) / Ctrl+- / Ctrl+0 | Cmd+= / Cmd+- / Cmd+0 |
  | New session on this machine (connect picker) | Ctrl+Shift+T | Cmd+T |
  | Close session | Ctrl+Shift+W | Cmd+W |
  | Next / previous session | Ctrl+Tab / Ctrl+Shift+Tab | Ctrl+Tab / Ctrl+Shift+Tab, Cmd+Shift+] / Cmd+Shift+[ |
  | Previous / next Herdr tab or tmux window | Ctrl+PgUp / Ctrl+PgDn | Ctrl+PgUp / Ctrl+PgDn |
  | Go to session 1 to 9 | Alt+1 to Alt+9 | Cmd+1 to Cmd+9 |
  | Fullscreen terminal | F11 | Ctrl+Cmd+F or F11 |
  | Keyboard shortcuts | Ctrl+Shift+/ | Cmd+/ |
  | Split right / down | Ctrl+Shift+\ / Ctrl+Shift+- | Cmd+D / Cmd+Shift+D |
  | Move between splits | Alt+arrows | Cmd+Option+arrows |
  | Next unread | Ctrl+Shift+U | Cmd+Shift+U |

  None of these reach the shell. Two choices avoid clashes with shells and
  TUIs. Go to session uses Alt+digit, because Ctrl+2 to Ctrl+8 are control
  characters (Ctrl+6 is vim's alternate file). The price is readline's
  rarely used Alt+digit argument. Help is Ctrl+Shift+/ because Ctrl+/ sends
  ^_ (undo) and F1 belongs to htop and mc. Ctrl+Shift+- used to send
  Ctrl+_ (undo) to the shell; it now splits down, and Ctrl+/ still sends
  the same ^_. Alt+arrows only move between splits when a split lies that
  way; otherwise they reach the shell as before (word motion). Close asks
  first when the session is a plain
  shell, because closing it ends what runs there. tmux and Herdr sessions
  just detach. Fullscreen hides the app's chrome, not the OS window
  decorations. There is no scrollback search yet (conduit_vt has none).
- **Menus and sheets.** Nothing slides up from the bottom on desktop.
  Action menus open as popovers at the click. Pickers and forms, such as
  the connect picker, open as centred dialogs. The Herdr and tmux
  navigators slide in from the right; the agent inbox opens in the
  shell's right panel. The quick switcher
  and snippets open as a command palette at the top. Esc closes any of
  them, and the first field has the focus. Phones keep the bottom sheets.
  All of these go through `lib/core/presentation/adaptive_modal.dart`.
- **On-screen keys.** The pill and key rows are hidden by default. The
  *On-screen keys* button above the bottom edge brings them back for the
  multiplexer shortcuts, snippets and the chat button. It resets for each
  terminal screen.
- **Window.** It opens at 1280x800, shrinks to 900x600 at the smallest, and
  the terminal reflows on resize. F11 hides the sidebar and the right
  panel with the terminal's own chrome.

## This computer and a synced entry for the same PC

A phone usually has an SSH entry for the PC (say *omarchy*, at its
Tailscale IP). Device sync copies it to the PC, where it would duplicate
*This computer* and SSH into itself, which mostly fails: keys don't sync
and sshd may be off. So each desktop recognises a saved machine that is
itself and folds it into *This computer* there. The other devices keep it
as a normal SSH machine, and *This computer* itself never syncs.

**How the match is decided** (`SelfMachineMatcher`,
`lib/features/this_computer/`). Linux, macOS and Windows only; phones
never probe.

1. **Host key (strong).** When the saved machine has a trusted host key
   (known hosts sync with the machines) and this device's own SSH host
   public keys are readable (`/etc/ssh/ssh_host_*_key.pub`,
   `%ProgramData%\ssh` on Windows), the key decides both ways. Same key:
   it is this device. Different key: it is another machine, whatever its
   address says (a VM or container behind a forwarded port).
2. **Address.** Otherwise the machine's host field, case-insensitively,
   must be one of this device's addresses *on port 22*: any IP of its
   network interfaces (Tailscale's 100.x and `fd7a:115c:a1e0::` ones
   included), `localhost`, `127.0.0.1`, `::1`, the host name, the host
   name plus `.local`, or its MagicDNS name (`omarchy.<tailnet>.ts.net`,
   from `tailscale status --json` when `tailscale` is on PATH, 3 s
   timeout). IPv6 is compared in canonical form.

The device is probed lazily in the background, cached for the session,
and probed again on a network change or app resume. The machines are
matched again after a sync pull or import. A failing probe only drops its
own signal. Restores and deep links wait up to 4 s for the first match.

**What changes on the matching device:**

- The machine is left out of every machine list: the home and the
  machine switcher, the desktop sidebar and dashboard, the quick switcher
  and the connect picker. It stays in storage and in sync untouched, and
  so does its place in a manual machine order.
- *This computer* shows its name: *This computer · omarchy*.
- Whatever targets it opens *This computer* locally: restored sessions,
  a synced session list, notifications and deep links, and sidebar pins,
  groups and order made for it.
- Per-host preferences *This computer* has no value of its own for
  follow the matched machine, read-only: tmux/Herdr on open, session name
  and start directory, the multiplexer prefix, a session's *Open in*
  choice and the live preview port. Set one on *This computer* and it
  becomes its own. Nothing is ever written to the synced machine.
- **Settings › Sync & backup › This computer on your other devices** says
  *Also shown as omarchy on your other devices*, with a switch *Show it
  separately here too* (per device, off by default) for SSH-to-self.

If the PC is also the sync hub, sync itself still reaches it through that
saved machine over SSH, as before.

## What each platform supports

| Feature | Linux | Windows | macOS | Why |
|---|---|---|---|---|
| SSH, Mosh, SFTP, tmux / Herdr | yes | yes | yes | Pure Dart (dartssh2, dart_mosh over UDP) |
| Chat View, agent inbox, themes | yes | yes | yes | Flutter UI |
| Live preview (port forward) | browser | browser | embedded | webview_flutter has no official Linux/Windows implementation. The forward runs and *Open in browser* opens it |
| HTML files in the SFTP viewer | source | source | rendered | Same web view gap |
| PDF viewer | yes | yes | yes | pdfrx (PDFium, fetched at build time) |
| App lock | no | Windows Hello | Touch ID / password | local_auth has no Linux implementation. On Linux the app starts unlocked |
| Secret storage | libsecret | Credential Manager | login keychain | flutter_secure_storage |
| Attach image to a prompt | file picker | file picker | file picker | image_picker's desktop implementations pick files. No camera |
| Hardware security keys (`sk-` SSH keys) | no | no | no | FIDO runs over NFC (flutter_nfc_kit) or Android USB. Use a regular OpenSSH key on desktop. Connecting with an `sk-` key says so |
| This computer (local terminal) | yes | yes | yes | The machine list starts with *This computer*: the login shell in a flutter_pty PTY (`$SHELL -l`; PowerShell, cmd or WSL on Windows, from the machine menu's *Shell…*). Local tmux sessions and Herdr workspaces, the companion (Agent hooks installs it locally), git diff, files and live preview (127.0.0.1 directly) all work without SSH. Commands run with `sh -c` and the usual tool directories on PATH; on Windows only through WSL. Per device: never backed up or synced |
| Proot local shell | no | no | no | Android's proot Linux section (arm64 binaries) |
| Dictation, read-aloud (Talk) | no | no | no | `conduit/speech` and `conduit/tts` channels, implemented on Android and iOS |
| Live preview screenshot to Claude | no | no | yes | Needs the embedded page. Android uses PixelCopy |
| Paste a clipboard image as a file | no | no | no | Android `conduit/clipboard_image` bridge. Paste falls back to text |
| Sync setup | paste code | paste code | paste code | The QR scanner (mobile_scanner) is phone-only. Desktops paste the setup code |
| Share target, home widget, Quick Settings tile, notification Allow/Deny, clipboard images, background keep-alive | no | no | no | Android platform channels (MainActivity). `PlatformFeatures` hides them |
| Keep screen on, network change reconnect | yes | yes | yes | wakelock_plus, connectivity_plus (NetworkManager on Linux) |

Gating lives in `lib/core/platform_features.dart`. Every flag reads
`defaultTargetPlatform`, so a widget test can check the desktop UI with
`TargetPlatformVariant`.

## macOS sandbox and keychain

- **The App Sandbox is off** (`macos/Runner/*.entitlements`). A terminal
  needs the user's shell, files, `~/.ssh` and Homebrew. Inside the sandbox
  a future local terminal would get a container home instead. Apps
  distributed outside the Mac App Store may be unsandboxed. The
  entitlements still list `network.client`, `files.user-selected.read-write`
  and `files.downloads.read-write`, so switching `app-sandbox` to `true` for
  a store build keeps SSH, Mosh, the file pickers and SFTP downloads
  working.
- **Keychain.** flutter_secure_storage defaults to the data-protection
  keychain, which needs the restricted `keychain-access-groups`
  entitlement. An ad-hoc signed app carrying it is killed at launch.
  `lib/core/secure_storage.dart` uses the login keychain on macOS instead,
  which needs no entitlement. macOS may ask once to allow Conductore into
  the login keychain. A Developer ID signed build could move to the
  data-protection keychain, but existing items would not follow.
- **Signing and notarisation** need an Apple Developer ID certificate. They
  are not set up. Until then, see the Gatekeeper steps above.

## Known limitations

- Unsigned builds on all three platforms (Gatekeeper, SmartScreen).
- No auto-update. Download the next release by hand.
- Linux and Windows builds are x64 only. There is no ARM64 Linux or Windows
  build yet.
- The on-screen keys toggle is per screen and not remembered.
- The prompt menu buttons, the on-screen keys and the compose bar sit
  under all panes and act on the focused one.
- On macOS a live preview shown in a pane and in the right panel at once
  runs two web views of the same page.
- No scrollback search (Ctrl+Shift+F) yet, and the shortcuts are not
  configurable.
