# Device sync

Setting: **Settings › Sync**. Code: `lib/features/sync/`.

Sync keeps saved machines, snippets, settings, connect preferences and the
session list the same on every device, through **one saved machine you
choose (the hub)**. There is no cloud service, no new port and nothing to
install: the app reads and writes files over the SSH/SFTP connection it
already uses (`SshAgentCommandRunner` for commands, `SftpRepository` for
transfers). It works without the companion.

## On the hub

```
~/.conductore/sync/<vault>.bundle   encrypted records (all data)
~/.conductore/sync/<vault>.meta     version, updatedAt, device list (plain)
~/.ssh/authorized_keys              "<key> conductore-device <name>" lines
```

A push uploads `<vault>.bundle.<device>.tmp` and `<vault>.meta.<device>.tmp`
by SFTP, then a POSIX `sh` script takes a `mkdir` lock (a lock older than two
minutes is broken), checks that the meta version is still the one this
device pulled and renames both into place (exit 3: another device won, so
the app merges again and retries). Commands are built in
`SyncHubCommands` with fixed ids (32 hex characters) and only real SSH
keys as input; tests run them against a real shell.

## Encryption

- The bundle (and every file backup; they share the format and each opens
  the other with its passphrase) is XChaCha20-Poly1305 with a random 192-bit
  nonce. The key is Argon2id(passphrase, salt), 64 MiB, 3 passes; the salt
  and cost are in the readable header, which is the AEAD's associated data.
- Package: `cryptography` 2.9 (pure Dart; already in the tree through
  `fido2`, now a direct dependency). Argon2id runs on a background isolate
  and matches the reference `argon2` CLI (test vector in
  `test/features/sync/sync_crypto_test.dart`).
- The derived key is kept in secure storage, so the passphrase is typed
  once per device. The hub never sees it or the plaintext.
- A device that cannot decrypt the hub's bundle (another passphrase) reports
  an error and never pushes over it.

## What syncs

| Switch | Records | Default |
| --- | --- | --- |
| Saved machines | `host:<id>` (everything but secrets, hardware keys, last-connected time, and for the hub its login), `hosts:sortMode`, `hosts:manualOrder`, `knownHost:<host>:<port>` | on |
| SSH keys and passwords | `secret:host:<id>` (password, private key, passphrase, hidden snippet text), `secret:snippet:<id>` | **off**, with a warning |
| Snippets | `snippet:<id>` (hidden text blanked) | on |
| Appearance and terminal settings | `setting:<name>` per `AppSettingsCodec` key | on |
| Connect preferences and recents | `connect:<hostId>`, `recentDirs:<hostId>` | on |
| Session list | `sessions` (the restore-on-launch list) | on |
| Continue where you left off | `continuity:<device id>`, one per device (see below) | on |

Hardware-key stubs never sync (file backups with credentials keep them).
Each device keeps its own login to the hub.

## Merge

Every record carries a clock: wall time, a Lamport counter, the device id.
A device diffs its data against what it last synced (hash of each value as
applied locally), stamps changed records with the time it first noticed the
change (so offline edits keep their age), turns vanished ones into
tombstones, then does per-record last-writer-wins against the hub. A record
edited on both sides since the last sync is a conflict: the newer edit wins
and the other value is kept in **Sync activity**, where **Keep mine** puts a
lost local edit back as a new edit. Tombstones expire after 180 days.
Records of switched-off categories, and record types a newer app wrote, pass
through untouched.

At a device's first sync the hub's version wins where both have an item
(listed in Sync activity); machines with the same host, port and user take
the hub's ids so they merge instead of showing twice.

## Schedule

Push 5 s after a local change (skipped when nothing really changed), pull on
start and resume and every 3 minutes while the app is open, and on **Sync
now**. Leaving the app pushes a pending change at once.

## Continue where you left off

Each device writes one record, `continuity:<device id>`, and only reads the
others': the merge never takes another device's record for a local edit or
delete. A record holds when the device was last in use, where it is (the
saved machine, the tmux session or Herdr workspace and tab, terminal or
Chat view, the Claude session id, the Chat view message being read, the
desktop's layout name), its last eight places, and its unsent Chat view
drafts. Settings › Sync lets each device leave out places, drafts or the
scroll position; turning the switch off sends an empty record first.

A desktop's "This computer" goes out as the saved machine that is that
desktop (the phone's SSH entry for it), and a place on that machine comes
back as "This computer" there. Without such a machine the place is shown
but cannot be opened elsewhere.

The record goes out at most every 10 s while it changes (2 s after the
first change of a burst) and at once when the app leaves the screen (a
desktop window losing focus too). A desktop that regains focus, or gets
input after 5 minutes without any, pulls. When a device opens or wakes,
another device used since, within 2 hours, somewhere else, is offered:
a dismissible row on the phone's home, a corner card on the desktop, and
"Continue on…" in the desktop palette and the phone's session menu.

Drafts merge last-writer-wins, never silently: another device's newer
draft fills an empty composer with a "from" hint; next to a different
local draft both are offered (use it, both, keep mine); a draft sent or
cleared elsewhere offers to clear it here. Drafts only travel inside the
encrypted bundle, never in backups, telemetry or the Sync activity list.

Continuity stays out of file backups and the Sync activity list, and a
continuity change never makes pages reload their saved data.

Why the hub and not the companion: the hub already carries every device's
data end to end encrypted, works for every machine (tmux-only hosts, "This
computer", machines without the companion) and needs no host to hold
drafts in the clear. Its latency is what matters here: a device pulls when
it opens or wakes, which is exactly when the offer is shown, and the
device left behind pushed within 10 s or on leaving.

## Adding a device

1. On a syncing device: **Add a device**, name it, confirm. The app
   generates an ed25519 key and appends it to the hub's `authorized_keys`
   (key comment `conductore-device <name>`).
2. It shows a QR code (and **Copy setup code** for desktops) with the hub's
   address, its host key fingerprint and a sealed secret: the new key's seed
   and the sync key, under Argon2id (19 MiB, 2 passes) of **six words** from
   a 256-word list (48 bits). All readable fields are associated data.
3. On the new device: **Join with a setup code**, scan (Android/iOS, with
   `mobile_scanner`) or paste, type the words. It saves the hub with that
   key and pins the host key, installs a key of its own through it, removes
   the one-time key with the new one, then pulls everything.
   On Android the barcode model is not in the APK: the first scan on a
   fresh install waits while Google Play services downloads it, showing
   "Getting the scanner ready…", then scans by itself.

**Manual path**: save the hub machine by hand, then **Set up sync** with the
same machine and passphrase.

Removing a device deletes its `authorized_keys` line and lists it as
revoked in the meta (a revoked device turns sync off and keeps its data). It
does not change the sync key; a device that should lose access to data
synced later needs a new passphrase (turn off with "delete hub data", set up
again).

## Turning off

Keeps all local data. Optionally deletes the hub's bundle and meta, which
stops the other devices too.
