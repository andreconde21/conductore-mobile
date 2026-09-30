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

/// Runs agent-provider commands over a dedicated SSH exec channel.
///
/// Uses the same authentication stack as the terminal and SFTP (via
/// [SshClientFactory]) but its own connection, opened lazily on first use
/// and kept for subsequent polls; a broken connection is dropped so the
/// next call reconnects. Never touches the interactive PTY.
///
/// Commands are POSIX shell scripts, as for the local runner; each is sent
/// through [posixShellCommand] so the account's login shell (fish, csh)
/// never parses them, or any path or name quoted into them.
class SshAgentCommandRunner
    implements
        StdinAgentCommandRunner,
        ReconnectingCommandRunner,
        AddressedCommandRunner {
  SshAgentCommandRunner(this._hostKeyVerifier, this._host);

  final HostKeyVerifier _hostKeyVerifier;
  final SavedHost _host;

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
    try {
      final result = await client
          .runWithResult(posixShellCommand(command))
          .timeout(timeout);
      return AgentCommandResult(
        stdout: utf8.decode(result.stdout, allowMalformed: true),
        stderr: utf8.decode(result.stderr, allowMalformed: true),
        exitCode: result.exitCode,
      );
    } on TimeoutException {
      // A hung exec channel usually means the connection is going away;
      // drop it so the next poll starts fresh.
      await _dropClient();
      throw const AppFailure('The command timed out.');
    } catch (error) {
      await _dropClient();
      // Authentication and the handshake happen on the first command, so
      // this is where a dropped or rejected connection shows up.
      throw ConnectionFailure(
        'Running a command on ${_host.name} failed.',
        describeSshConnectionError(error),
        kind: classifyConnectionError(error),
      );
    }
  }

  Future<SSHClient> _connect() async {
    if (_closed) {
      throw const AppFailure('This connection is closed.');
    }
    try {
      final client = await (_client ??= SshClientFactory(
        _hostKeyVerifier,
      ).connect(_host));
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
      await _dropClient();
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
