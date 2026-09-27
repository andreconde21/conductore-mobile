# Conductore privacy policy

Effective 25 September 2026. Applies to the Conductore app for Android,
iOS, Linux, Windows and macOS, published by Outsmartis, including builds
from Google Play, the App Store, TestFlight and GitHub releases.

## The short version

Conductore is a terminal for your own computers. It has no account, no
advertising and no tracking. What you enter stays on your device and goes
only to the machines you connect to.

To help fix bugs, the app sends two things to servers Outsmartis runs
itself: **crash reports** and **anonymous usage counts**. Neither contains
anything from your machines or terminals, neither identifies you, and each
has its own switch in Settings › Privacy. Both are on by default; the app
says so once, on the home screen, with a link to those switches.

## What the app stores, and where

On your device only:

- **Saved machines and settings.** Host names, ports, user names, tags,
  snippets, themes and other preferences.
- **Credentials.** Passwords and SSH private keys you add are kept in the
  platform's secure storage (Android Keystore, iOS Keychain). They are sent
  only to the machine you are logging in to, as part of SSH authentication.
- **Temporary files.** Files you open, upload or attach are cached on the
  device while you work with them.

Outsmartis never receives any of this. Uninstalling the app deletes it.
If you export a backup, the app writes the file to a location you choose,
encrypted with the password you set. What happens to that file after
that is up to you.

If you turn on device sync, the app stores one file encrypted on your
device with your sync passphrase (Argon2id, XChaCha20-Poly1305) in
`~/.conductore/sync` on a machine of yours that you pick, over SSH, plus a
small unencrypted list of your device names and sync times. Passwords and
SSH keys are included only if you turn that on. Adding a device adds an
SSH key marked `conductore-device` to that machine's
`~/.ssh/authorized_keys`, after you confirm.

## Crash reports and usage counts

Both go only to Outsmartis' own servers: crash reports to a GlitchTip
server (`glitchtip.outsmartis.dev`, the Sentry protocol), usage counts to a
Plausible server (`plausible.outsmartis.dev`). No third party receives
them. Builds made for development send nothing.

**Crash reports** (Settings › Privacy › Send crash reports) are sent when
the app hits an error it did not expect. A report contains:

- the error's type and message, and the code it went through in the app
  and the libraries it is built with (function names, source file names
  of that code, line numbers);
- the app version and build, the platform (Android, iOS, Linux, Windows or
  macOS), the build flavor and the release channel;
- coarse device facts: operating system name and version, device model,
  processor architecture and count, memory size, app memory use and the
  language setting;
- which top-level screen was open before the error (home, terminal, chat,
  settings or files).

Before a report leaves the device, the app removes from the message: the
names, addresses, user names, passwords, tags, tmux names, directories and
snippets of every saved machine; this device's own name and user name; IP
addresses, host and domain names, `user@host` forms, ports, URLs, file
paths and file names, text in double quotes, SSH keys, fingerprints and anything
that looks like a key or token. Messages are cut to a few lines. Reports
never contain a user or device identifier, the device name, terminal
output, commands, clipboard contents, chat text, transcripts, screenshots,
the view hierarchy, network requests or logs.

**Usage counts** (Settings › Privacy › Send anonymous usage stats) are a
few events: the app was opened; a top-level screen was shown (home,
terminal, chat, settings, files); a connection finished (SSH, Mosh or
local; with Herdr, tmux or neither; worked or failed, and if it failed
only whether the machine was unreachable, refused the login, had an
unexpected host key, or something else); Chat View was opened; dictation
or Talk was used; a host companion was found (its version number). Each
event also carries the platform, app version and build flavor. Events are
sent in small batches, at most a few per minute, and dropped when the
device is offline.

The app adds no identifier to usage counts. Plausible does not use
cookies; it counts visitors with a hash of the connection's IP address and
the app's user agent that is rotated every day, and it does not store IP
addresses.

Turning a switch off stops that kind of report immediately. The switches
are stored on the device and are not synced.

## Network connections

Conductore connects only to:

- **Your machines**, over SSH, Mosh and SFTP, using the addresses you enter.
  Agent status, the Conductore host companion (`conductore-hostd`) and theme
  sync all run over those same connections, on machines you control.
- **Web pages you open.** Links open in your browser. Live Preview shows a
  web page served by your own machine over a forwarded port.
- **Outsmartis' GlitchTip and Plausible servers**, for crash reports and
  usage counts, unless you turn them off (see above).
- **GitHub, for the Android local shell only.** When you set up the local
  Linux shell, the app downloads its root filesystem from GitHub. GitHub
  sees an ordinary download request.

## Permissions and why they are used

| Permission | Why |
|---|---|
| Network access | To connect to the machines you add. |
| Local network (iOS) | To reach machines on your home or office network. |
| Microphone (Android) | For dictation into the terminal. The app asks Android for its on-device recognizer. If that is not available, Android's speech service handles the audio under its own policy. The app itself never sends audio anywhere. |
| Microphone and speech recognition (iOS) | For dictation and Talk. The app uses Apple's speech recognizer on the iPhone when it supports your language; otherwise Apple's speech service handles the audio under Apple's policy. The app itself never sends audio anywhere. Replies are read aloud by the iPhone's own voices. |
| Camera and photos | To take or pick a picture that you upload to your machine or attach to a coding agent prompt. On Android the system photo picker and camera app are used, so the app gets only the picture you choose. |
| Notifications (Android) | To show that sessions are kept alive in the background and to tell you when a coding agent on your machine needs you. |
| Foreground service (Android) | To keep your terminal sessions connected while the app is in the background. |
| Biometrics (Face ID, fingerprint) | To unlock the app and your saved credentials, if you turn the lock on. Biometric data never leaves the operating system. |
| NFC | To use a hardware security key (FIDO2) for SSH login. |
| All files access (Android, GitHub builds only) | To let the file browser and local shell reach your phone's shared storage. The Play Store build does not ask for it. |

## Children

Conductore is a developer tool and is not directed at children.

## Changes

Changes to this policy are published in this file, and its history is
public in the repository.

## Contact

Questions or requests: open an issue at
https://github.com/andreconde21/conductore-mobile/issues
