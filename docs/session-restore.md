# Restoring sessions after an app restart

Setting: **Settings › Restore sessions on launch** (on by default).

## What is kept

`SessionRestoreController` (`lib/features/sessions/presentation/`) writes
the open-session list to secure storage under
`conductore.open_sessions.v1` (flutter_secure_storage, Android Keystore),
debounced and only when the list changes, and at once when the app goes to
the background. Per session:

- the saved host id;
- the connect target: shell, tmux session name, Herdr workspace id, label,
  tab and named Herdr server, or a directory;
- the custom name from Rename, and the last shown title;
- for a Herdr tab whose workspace was closed, when the app first found it
  gone (a tab restored over a day after that closes on launch, see
  [herdr-shared-focus.md](herdr-shared-focus.md));
- plus which session was active. The list order is the tab order.

No passwords, keys, Mosh session keys or terminal contents are stored.
Local shells are not kept. Turning the setting off deletes the list.

## What comes back

After the app lock is open, the tiles come back at once, disconnected:

| Session | On launch |
| --- | --- |
| Herdr workspace or tmux session (or a machine that starts tmux on connect) | Reconnects by itself and reattaches with the usual startup command (Herdr: focus the workspace/tab, then attach). The active one connects right away, the others while the home grid is on screen, 2 at a time, retried after 3 s, 10 s and 30 s, then "Tap to reconnect". |
| The same on a hardware-key machine | "Tap to reconnect": every connection asks for a key touch. |
| Plain shell or directory shell | "Shell ended · tap to start a new one". Long-press › Close dismisses it. |

A manual lock closes every session but keeps the list, so unlocking
brings them back the same way.

## Mosh: why sessions are not resumed

mosh-server keeps running after the phone app dies, so resuming the same
server looked possible. dart_mosh 0.0.4 does let us build a client from a
known port and key: `MoshServerConfig(host:, port:, key: MoshKey.parse(...))`
and `MoshSession.connect(server:, cipher:)`. It is still not safe or
workable, because the protocol state is private and always starts at zero
(`_sendSeq`, `_assumedAckNum`, `_receivedStateNum` in `MoshSession`):

1. **Nonce reuse.** Client packet nonces are the send sequence number. A
   new client under the old key starts again at 0. That reuses AES-OCB
   nonces, which breaks both confidentiality and integrity of the
   keystrokes.
2. **No screen.** The server sends diffs from the last state the old
   client acknowledged. The new client only accepts a diff whose base is
   its own state 0, so it drops every update and the screen never draws.
3. **Lost input.** The server ignores client input states numbered at or
   below the ones it already received, so early keystrokes vanish.

Making it work needs dart_mosh to persist and restore its sequence and
state counters, or a server-side resync. The real mosh client has no
resume either. So the app does not store the Mosh port or key, and a
restored Mosh session bootstraps a fresh mosh-server over SSH. The work
survives anyway in tmux or Herdr on the machine.

The old mosh-server is not left running: the app remembers the pid of
every mosh-server it starts (never the key), and the restored session's
bootstrap ends the old one first. See [mosh-sessions.md](mosh-sessions.md).
