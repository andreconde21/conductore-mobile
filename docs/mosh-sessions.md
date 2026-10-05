# Mosh sessions: how their servers end

Every Mosh session runs a `mosh-server` on the machine, with the session's
shell (and the Herdr or tmux client in it) under it. A server whose client
is gone is never used again: dart_mosh cannot resume a session from a new
client (see [session-restore.md](session-restore.md)). Before CON-086 such
servers piled up: André's laptop had 50 (38 of them 19 to 107 hours old
and never typed into), dev-central about 160, each with a Herdr client
redrawing.

## Why they were left behind

- **Close while connecting.** Closing a tab, or a quick open and close,
  while the session was still connecting closed the late session's UDP
  socket only (`TerminalSessionController.connect`, the stale-generation
  branch). The server had already heard from the client, so it never
  timed out: one server per such close.
- **The app killed in the background** (iOS does it), or the desktop app
  quitting: nothing was closed. The next run's session restore then
  starts a new server for every reattaching tab, two at a time
  (`SessionRestoreController.maxParallel`), which is the pairs of servers
  created in the same second.
- **Reconnect on a dead network.** Reconnect typed Ctrl-D (shell) or the
  tmux detach into a session that could no longer deliver it, then
  started a new server. Only Herdr sessions were stopped over SSH.
- **dart_mosh's `MoshSession.close`** only closes the UDP socket. The real
  `mosh` client tells the server it is quitting; dart_mosh never did, so
  every close that did not end the shell first left a server.
- **No server-side timeout** before 2026-09-25, then 7 days.

A single connect starts one server. The CON-058 side-connection bootstrap
gives up after 4 s and the terminal starts its own; a server the side
connection still starts after that is never told to a client, and
mosh-server exits after 60 s without one (checked against mosh 1.4.0).

## How they end now

1. **On close** (`MoshTerminalSession.close`, whatever closes it: Close,
   Reconnect, removing a machine, a lock, a stream error, a late connect)
   the app sends the server mosh's own shutdown request (`new_num =
   uint64(-1)`, `MoshServerShutdown`), from a socket bound when the session
   started, so it goes out even while the app is quitting. The server
   acknowledges it, hangs up the session's terminal and exits. A shell
   that already exited is not asked again.
2. **No answer within 2 s:** the server's pid (from the bootstrap's
   `[mosh-server detached, pid = N]`) is stopped over the machine's side
   connection: SIGTERM, only if that pid is still a `mosh-server`, and
   `kill` only reaches the user's own processes. Never by pattern.
3. **Still unknown** (no network, a security-key host without a side
   connection, the app killed): the pid stays in the ledger
   (`MoshServerLedger`, in secure storage), and the next mosh-server
   bootstrap on that machine (`user@host:port`) ends it first, in the same
   SSH command. Entries are dropped after twice the network timeout.
4. **Quitting the desktop app** disconnects every session first (at most
   2.5 s), so the steps above run.
5. **Safety net on the server**, set by the bootstrap:
   - `MOSH_SERVER_NETWORK_TMOUT=86400`: a server that has not heard from
     its client for 24 h exits on its own.
   - `MOSH_SERVER_SIGNAL_TMOUT=3600`: SIGUSR1 only ends a server whose
     client has been silent for an hour. A cleanup job such as
     `pkill -USR1 -u "$USER" mosh-server` then leaves connected sessions
     alone (without the variable, SIGUSR1 ends every server).

   Both are constants in `mosh_server_cleanup.dart`. Servers started by
   older app versions have neither; end them once by hand.

A network change keeps the same server: the client rebinds its socket
(`rehome`). A suspended app sends nothing and resumes the same session
while the server is within its timeout.

## Checking it in Docker

`test/features/terminal/mosh_lifecycle_docker_test.dart` counts the
servers a real sshd + mosh 1.4.0 container is left with after connect,
reconnect on a dead network, a network change, suspend and resume, an app
killed and restored, close, and 5 quick open/close cycles, for a shell and
a Herdr session. It is skipped unless pointed at a throwaway container on
a private network (no host mounts; the container drops packets with
iptables to simulate a dead network):

```sh
docker network create --internal mosh-test
docker run -d --rm --name mosh-test --cap-add NET_ADMIN --network mosh-test <image>
CONDUCTORE_MOSH_DOCKER=mosh-test@<container ip> \
CONDUCTORE_MOSH_KEY=<private key in the image's authorized_keys> \
  flutter test test/features/terminal/mosh_lifecycle_docker_test.dart
```

The image needs `openssh`, `mosh-server`, `procps` and `iptables`, a user
`dev` with the key, and `herdr` on the PATH.
