import 'dart:async';

import 'package:dartssh2/dartssh2.dart';

/// What an SSH connection is for, which sets its keep-alive in the
/// background.
enum SshConnectionRole {
  /// A terminal shell: kept alive in the background too, slowly, so the
  /// NAT mapping and the server's idle timeout do not drop it.
  terminal,

  /// Exec, SFTP and port-forward connections: they reconnect on their next
  /// use, so they send no keep-alive while the app is in the background.
  side,
}

/// How often every SSH connection of the app sends a keep-alive (CON-089).
///
/// dartssh2 pinged every 10 s on every connection, 360 round trips an hour
/// each, so the radio never idled. Now: the "SSH keepalive" setting in the
/// foreground (30 s by default, or off), and in the background
/// [backgroundTerminalInterval] for terminals and nothing for the others.
/// A ping without a reply in [replyTimeout] closes the connection.
class SshKeepalivePolicy {
  SshKeepalivePolicy();

  /// The app's policy, fed by the settings and the app lifecycle.
  static final instance = SshKeepalivePolicy();

  static const defaultForegroundSeconds = 30;

  /// The choices the setting offers; 0 is off.
  static const choices = [0, 15, 30, 60, 120];

  static const backgroundTerminalInterval = Duration(minutes: 2);

  /// How long a keep-alive waits for the server before the link counts as
  /// dead (the vendored dartssh2's `keepAliveTimeout` default).
  static const replyTimeout = Duration(seconds: 15);

  int _foregroundSeconds = defaultForegroundSeconds;
  bool _background = false;
  final _clients = <SSHClient, SshConnectionRole>{};

  int get foregroundSeconds => _foregroundSeconds;

  set foregroundSeconds(int seconds) {
    if (seconds == _foregroundSeconds) return;
    _foregroundSeconds = seconds;
    _apply();
  }

  bool get background => _background;

  /// The app went to the background (true) or came back (false). Coming
  /// back pings every connection once, so a link that died meanwhile is
  /// noticed within [replyTimeout] instead of at the next use.
  set background(bool value) {
    if (value == _background) return;
    _background = value;
    _apply();
    if (!value && _foregroundSeconds > 0) {
      for (final client in _clients.keys.toList()) {
        unawaited(client.ping().catchError((_) {}));
      }
    }
  }

  /// The keep-alive interval for a [role] connection now; null is none.
  Duration? intervalFor(SshConnectionRole role) {
    if (_foregroundSeconds <= 0) return null;
    final foreground = Duration(seconds: _foregroundSeconds);
    if (!_background) return foreground;
    return switch (role) {
      SshConnectionRole.terminal =>
        foreground > backgroundTerminalInterval
            ? foreground
            : backgroundTerminalInterval,
      SshConnectionRole.side => null,
    };
  }

  /// Follows [client] until it closes.
  void register(SSHClient client, SshConnectionRole role) {
    _clients[client] = role;
    client.keepAliveInterval = intervalFor(role);
    unawaited(
      client.done
          .then<void>((_) {}, onError: (_) {})
          .whenComplete(() => _clients.remove(client)),
    );
  }

  /// How many connections it follows (tests).
  int get trackedCount => _clients.length;

  void _apply() {
    _clients.forEach((client, role) {
      client.keepAliveInterval = intervalFor(role);
    });
  }
}
