import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:conduit/core/app_failure.dart';
import 'package:conduit/core/connection_problem.dart';
import 'package:conduit/features/agent_attention/data/remote_tool_command.dart';
import 'package:conduit/features/agent_attention/data/shared_command_runners.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/terminal/data/ssh_client_factory.dart';
import 'package:conduit/features/terminal/data/ssh_error_formatter.dart';
import 'package:conduit/features/terminal/data/tcp_ssh_socket.dart';
import 'package:conduit/features/terminal/domain/host_key_verifier.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

/// Runs agent-provider commands over a dedicated SSH exec channel.
///
/// Uses the same authentication stack as the terminal and SFTP (via
/// [SshClientFactory]) but its own connection, opened lazily on first use
/// and kept for subsequent polls; a broken connection is dropped so the
/// next call reconnects. A command that times out closes its own channel
/// only: the connection is dropped only when it is gone or a keep-alive
/// ping finds it dead (CON-089), so one slow command no longer cuts every
/// feature sharing it. Never touches the interactive PTY.
///
/// Commands are POSIX shell scripts, as for the local runner; each is sent
/// through [posixShellCommand] so the account's login shell (fish, csh)
/// never parses them, or any path or name quoted into them.
class SshAgentCommandRunner
    implements
        StdinAgentCommandRunner,
        ReconnectingCommandRunner,
        AddressedCommandRunner {
  SshAgentCommandRunner(
    this._hostKeyVerifier,
    this._host, {
    @visibleForTesting Future<SSHClient> Function()? connect,
  }) : _connectClient = connect;

  final HostKeyVerifier _hostKeyVerifier;
  final SavedHost _host;
  final Future<SSHClient> Function()? _connectClient;

  Future<SSHClient>? _client;
  bool _closed = false;

  InternetAddress? _remoteAddress;

  @override
  InternetAddress? get remoteAddress => _remoteAddress;

  @override
  Future<AgentCommandResult> run(
    String command, {
    required Duration timeout,
  }) async {
    final client = await _connect();
    SSHSession? session;
    try {
      final deadline = DateTime.now().add(timeout);
      Duration left() {
        final rest = deadline.difference(DateTime.now());
        return rest.isNegative ? Duration.zero : rest;
      }

      session = await client
          .execute(posixShellCommand(command))
          .timeout(left());
      final stdout = BytesBuilder(copy: false);
      final stderr = BytesBuilder(copy: false);
      final stdoutDone = Completer<void>();
      final stderrDone = Completer<void>();
      session.stdout.listen(
        stdout.add,
        onDone: stdoutDone.complete,
        onError: (Object _) => stdoutDone.complete(),
      );
      session.stderr.listen(
        stderr.add,
        onDone: stderrDone.complete,
        onError: (Object _) => stderrDone.complete(),
      );
      await Future.wait([
        stdoutDone.future,
        stderrDone.future,
        session.done,
      ]).timeout(left());
      return AgentCommandResult(
        stdout: utf8.decode(stdout.takeBytes(), allowMalformed: true),
        stderr: utf8.decode(stderr.takeBytes(), allowMalformed: true),
        exitCode: session.exitCode,
      );
    } on TimeoutException {
      // This command is slow (a busy host, a long answer): close its
      // channel only. Whether the link itself is dead, a ping tells.
      if (session != null) _abort(session);
      _dropIfDead(client);
      throw const AppFailure('The command timed out.');
    } catch (error) {
      if (client.isClosed) {
        await _dropClient();
      } else {
        _dropIfDead(client);
      }
      // Authentication and the handshake happen on the first command, so
      // this is where a dropped or rejected connection shows up.
      throw ConnectionFailure(
        'Running a command on ${_host.name} failed.',
        describeSshConnectionError(error),
        kind: classifyConnectionError(error),
      );
    }
  }

  /// Drops [client] when a keep-alive ping gets no answer in time (the
  /// ping closes it then) or it is already gone; keeps it otherwise.
  void _dropIfDead(SSHClient client) {
    Future<void> dropIfCurrent() async {
      final current = _client;
      if (current == null) return;
      try {
        if (!identical(await current, client)) return;
      } catch (_) {
        return;
      }
      await _dropClient();
    }

    if (client.isClosed) {
      unawaited(dropIfCurrent());
      return;
    }
    unawaited(
      client.ping().then((_) {}, onError: (Object _) => dropIfCurrent()),
    );
  }

  Future<SSHClient> _connect() async {
    if (_closed) {
      throw const AppFailure('This connection is closed.');
    }
    try {
      final client = await (_client ??=
          _connectClient?.call() ??
          SshClientFactory(_hostKeyVerifier).connect(_host));
      final socket = client.socket;
      _remoteAddress = socket is TcpSshSocket ? socket.remoteAddress : null;
      return client;
    } catch (error) {
      _client = null;
      throw ConnectionFailure(
        'Could not reach ${_host.name}.',
        describeSshConnectionError(error),
        kind: classifyConnectionError(error),
      );
    }
  }

  @override
  Future<AgentCommandResult> runWithStdin(
    String command, {
    required String stdin,
    required Duration timeout,
    Future<void>? cancel,
  }) async {
    final client = await _connect();
    final SSHSession session;
    try {
      session = await client.execute(posixShellCommand(command));
    } catch (error) {
      if (client.isClosed) {
        await _dropClient();
      } else {
        _dropIfDead(client);
      }
      throw ConnectionFailure(
        'Running a command on ${_host.name} failed.',
        describeSshConnectionError(error),
        kind: classifyConnectionError(error),
      );
    }
    final stdout = BytesBuilder(copy: false);
    final stderr = BytesBuilder(copy: false);
    final stdoutDone = Completer<void>();
    final stderrDone = Completer<void>();
    session.stdout.listen(
      stdout.add,
      onDone: stdoutDone.complete,
      onError: (Object _) => stdoutDone.complete(),
    );
    session.stderr.listen(
      stderr.add,
      onDone: stderrDone.complete,
      onError: (Object _) => stderrDone.complete(),
    );
    session.stdin.add(utf8.encode(stdin));
    // Closing sends end of file; the sink's own future only completes
    // with the channel.
    unawaited(session.stdin.close().catchError((Object _) {}));
    final finished = Future.wait([
      stdoutDone.future,
      stderrDone.future,
      session.done,
    ]).then((_) => true);
    final cancelled = cancel?.then((_) => false);
    try {
      final completed = await Future.any([
        finished,
        ?cancelled,
      ]).timeout(timeout);
      if (!completed) {
        _abort(session);
        throw const AgentCommandCancelled();
      }
      return AgentCommandResult(
        stdout: utf8.decode(stdout.takeBytes(), allowMalformed: true),
        stderr: utf8.decode(stderr.takeBytes(), allowMalformed: true),
        exitCode: session.exitCode,
      );
    } on TimeoutException {
      _abort(session);
      _dropIfDead(client);
      throw const AppFailure('The command timed out.');
    }
  }

  /// Lets go of [session]: a TERM signal (OpenSSH ignores it without a
  /// PTY) and closing the channel. The remote process may run on until
  /// its own time limit; callers must ignore its reply, not rely on it
  /// dying.
  static void _abort(SSHSession session) {
    try {
      session.kill(SSHSignal.TERM);
    } catch (_) {}
    try {
      session.close();
    } catch (_) {}
  }

  Future<void> _dropClient() async {
    final pending = _client;
    _client = null;
    _remoteAddress = null;
    if (pending != null) {
      try {
        (await pending).close();
      } catch (_) {
        // The connection is already gone.
      }
    }
  }

  @override
  Future<void> dropConnection() => _dropClient();

  @override
  Future<void> close() async {
    _closed = true;
    await _dropClient();
  }
}
