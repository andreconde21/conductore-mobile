import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:conduit/core/app_failure.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/sftp/domain/sftp_session.dart';

/// A runner whose connection can be dropped on purpose; the next command
/// reconnects (a network change leaves idle SSH sockets half dead).
abstract interface class ReconnectingCommandRunner {
  Future<void> dropConnection();
}

/// A runner that knows the address its connection reached.
abstract interface class AddressedCommandRunner {
  /// The machine's address, while the connection is up over TCP.
  InternetAddress? get remoteAddress;
}

/// One connection per machine for every side channel: the agent monitor,
/// its long-poll, the home board, usage, the digest, the chat, the
/// preview watcher, tab strips and the connect flow all run their
/// commands as exec channels of the same SSH connection instead of each
/// opening (and authenticating) its own.
///
/// [lease] hands out a runner per caller, as before; the caller still
/// closes it. The connection stays open while any lease does, and for
/// [linger] after the last one closes, so a page that closes and reopens
/// its runner (the home board on every visit) reuses it. A machine whose
/// address or login changed gets a new connection. At most
/// [maxChannels] commands run at once per connection (OpenSSH allows 10
/// sessions per connection by default); later ones wait their turn.
class SharedCommandRunners {
  SharedCommandRunners(
    this._open, {
    this.linger = const Duration(seconds: 30),
    this.maxChannels = 8,
    Stream<void>? networkChanges,
  }) {
    _networkSubscription = networkChanges?.listen((_) => dropConnections());
  }

  final StdinAgentCommandRunner Function(SavedHost host) _open;
  final Duration linger;
  final int maxChannels;
  final Map<String, _SharedConnection> _connections = {};
  StreamSubscription<void>? _networkSubscription;

  /// Open connections, for tests and diagnostics.
  int get connectionCount => _connections.length;

  /// A runner for [host] on its shared connection; close it when done.
  StdinAgentCommandRunner lease(SavedHost host) {
    final key = _keyOf(host);
    final connection = _connections[key] ??= _SharedConnection(
      _open(host),
      maxChannels,
    );
    connection.leases += 1;
    connection.lingerTimer?.cancel();
    connection.lingerTimer = null;
    return _Lease(this, key, connection);
  }

  void _release(String key, _SharedConnection connection) {
    connection.leases -= 1;
    if (connection.leases > 0) return;
    connection.lingerTimer = Timer(linger, () {
      if (connection.leases > 0 || _connections[key] != connection) return;
      _connections.remove(key);
      unawaited(connection.close());
    });
  }

  /// Drops every idle connection's socket (the network changed); each
  /// reconnects on its next command. Commands in flight fail, as they
  /// would have on the old network.
  void dropConnections() {
    for (final connection in _connections.values) {
      if (connection.runner case final ReconnectingCommandRunner runner) {
        unawaited(runner.dropConnection());
      }
    }
  }

  Future<void> dispose() async {
    await _networkSubscription?.cancel();
    final connections = List.of(_connections.values);
    _connections.clear();
    for (final connection in connections) {
      connection.lingerTimer?.cancel();
      await connection.close();
    }
  }

  /// What makes two saved records the same connection: the machine and
  /// how it signs in, not its name, tags or agent settings. A session's
  /// host (`<machine id>#herdr:w1`, which Herdr's focus and the terminal's
  /// Mosh start run on) is its machine: a workspace opened from the home
  /// board rides on the connection the board already has.
  static String _keyOf(SavedHost host) {
    final json = host.toJson();
    return jsonEncode([
      baseHostId(host.id),
      for (final field in const [
        'host',
        'port',
        'username',
        'authMethod',
        'password',
        'privateKey',
        'passphrase',
        'hardwareKeys',
        'externalAuthOfferKey',
        'forwardAgent',
        'connectionTimeoutSeconds',
      ])
        json[field],
    ]);
  }
}

class _SharedConnection {
  _SharedConnection(this.runner, this.maxChannels);

  final StdinAgentCommandRunner runner;
  final int maxChannels;
  int leases = 0;
  int running = 0;
  Timer? lingerTimer;
  final Queue<Completer<void>> _waiting = Queue();

  /// Waits for a free channel, at most [timeout].
  Future<void> acquire(Duration timeout) async {
    if (running < maxChannels) {
      running += 1;
      return;
    }
    final turn = Completer<void>();
    _waiting.add(turn);
    try {
      await turn.future.timeout(timeout);
    } on TimeoutException {
      if (_waiting.remove(turn)) {
        throw const AppFailure('The command timed out.');
      }
      // Handed the channel just as time ran out: keep it.
    }
  }

  void releaseChannel() {
    if (_waiting.isNotEmpty) {
      _waiting.removeFirst().complete();
    } else {
      running -= 1;
    }
  }

  Future<void> close() async {
    try {
      await runner.close();
    } catch (_) {
      // Already gone.
    }
  }
}

/// One caller's handle on a shared connection.
class _Lease
    implements
        StdinAgentCommandRunner,
        AddressedCommandRunner,
        SftpChannelRunner {
  _Lease(this._pool, this._key, this._connection);

  final SharedCommandRunners _pool;
  final String _key;
  final _SharedConnection _connection;
  bool _closed = false;

  Future<T> _withChannel<T>(Duration timeout, Future<T> Function() body) async {
    if (_closed) {
      throw const AppFailure('This connection is closed.');
    }
    await _connection.acquire(timeout);
    try {
      return await body();
    } finally {
      _connection.releaseChannel();
    }
  }

  @override
  Future<AgentCommandResult> run(String command, {required Duration timeout}) =>
      _withChannel(
        timeout,
        () => _connection.runner.run(command, timeout: timeout),
      );

  @override
  Future<AgentCommandResult> runWithStdin(
    String command, {
    required String stdin,
    required Duration timeout,
    Future<void>? cancel,
  }) => _withChannel(
    timeout,
    () => _connection.runner.runWithStdin(
      command,
      stdin: stdin,
      timeout: timeout,
      cancel: cancel,
    ),
  );

  @override
  Future<SftpSession?> openSftp() async {
    if (_closed) {
      throw const AppFailure('This connection is closed.');
    }
    return switch (_connection.runner) {
      final SftpChannelRunner runner => runner.openSftp(),
      _ => null,
    };
  }

  @override
  InternetAddress? get remoteAddress => switch (_connection.runner) {
    final AddressedCommandRunner runner => runner.remoteAddress,
    _ => null,
  };

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _pool._release(_key, _connection);
  }
}
