import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit/core/app_failure.dart';
import 'package:conduit/core/connection_problem.dart';
import 'package:conduit/features/agent_attention/data/remote_tool_command.dart';
import 'package:conduit/features/agent_attention/data/shared_command_runners.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/terminal/data/mosh_shutdown.dart';
import 'package:conduit/features/terminal/data/ssh_client_factory.dart';
import 'package:conduit/features/terminal/data/tcp_ssh_socket.dart';
import 'package:conduit/features/terminal/domain/host_key_prompt.dart';
import 'package:conduit/features/terminal/domain/host_key_verifier.dart';
import 'package:conduit/features/terminal/domain/mosh_server_cleanup.dart';
import 'package:conduit/features/terminal/domain/mosh_server_ledger.dart';
import 'package:conduit/features/terminal/domain/predictive_terminal_session.dart';
import 'package:conduit/features/terminal/domain/roaming_terminal_session.dart';
import 'package:conduit/features/terminal/domain/ssh_terminal_repository.dart';
import 'package:conduit/features/terminal/domain/ssh_terminal_session.dart';
import 'package:dart_mosh/dart_mosh.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

class MoshTerminalRepository implements SshTerminalRepository {
  const MoshTerminalRepository(
    this._hostKeyVerifier, {
    this.cleanupRunner,
    this.ledger,
  });

  final HostKeyVerifier _hostKeyVerifier;

  /// A command channel to [host] (the machine's shared side connection):
  /// it starts mosh-server, so a machine whose side connection is up (the
  /// home board, the agent monitor, Herdr's focus) needs no SSH handshake
  /// of its own for it, and stops a session's mosh-server when its close
  /// could not reach it. Null disables both; hosts that ask for a
  /// security-key touch per connection never use it.
  final AgentCommandRunner Function(SavedHost host)? cleanupRunner;

  /// The mosh-servers this device started: each bootstrap first ends the
  /// ones on that machine no session holds any more. Null disables it.
  final MoshServerLedger? ledger;

  SshClientFactory get _clientFactory => SshClientFactory(_hostKeyVerifier);

  @override
  Future<SshTerminalSession> connect(
    SavedHost host, {
    required int columns,
    required int rows,
  }) async {
    SSHClient? client;
    final ledger = this.ledger;
    final machine = MoshServerLedger.machineOf(host);
    int? startedPid;
    try {
      // This device's earlier servers there that nothing uses any more (a
      // killed app's, one whose close did not get through) end in the
      // same command that starts the new one.
      final abandoned =
          await ledger?.abandoned(machine) ?? const <MoshServerHandle>[];
      final command = bootstrapCommand(host, abandoned: abandoned);
      final started = await bootstrapOnSideChannel(host, command: command);
      var server = started?.server;
      var address = started?.address;
      if (server == null) {
        // Opened by the user, who may decide on a changed host key.
        client = await withInteractiveHostKeyCheck<SSHClient>(
          () => _clientFactory.connect(host),
        );
        server = await _bootstrap(client, host, command);
        final socket = client.socket;
        address = socket is TcpSshSocket ? socket.remoteAddress : null;
        client.close();
        client = null;
      }

      final handle = MoshServerHandle(
        port: server.port,
        pid: MoshServerHandle.parsePid(server.rawOutput),
        portArgument: _portArgument(host),
      );
      startedPid = handle.pid;
      if (ledger != null) {
        await ledger.forget(machine, [
          for (final ended in abandoned) ?ended.pid,
        ]);
        await ledger.record(machine, handle);
      }

      final cipher = MoshPacketCipher.aesOcb(server.key);
      final remote =
          address ?? (await InternetAddress.lookup(server.host)).first;
      final shutdown = await MoshServerShutdown.bind(
        address: remote,
        port: server.port,
        cipher: cipher,
      );
      final MoshSession session;
      try {
        session = await MoshSession.connect(
          server: server,
          cipher: cipher,
          address: remote,
          columns: columns,
          rows: rows,
        );
      } catch (_) {
        shutdown.close();
        rethrow;
      }
      return MoshTerminalSession(
        session,
        server: handle,
        cleanupRunner: cleanupRunnerFor(host),
        shutdown: shutdown,
        ledger: ledger,
        machine: machine,
      );
    } catch (error) {
      client?.close();
      // Never reached by a client: it exits on its own within a minute.
      if (startedPid != null) {
        unawaited(ledger?.release(machine, startedPid));
      }
      throw ConnectionFailure(
        'Could not start a Mosh session on ${host.host}:${host.port}.',
        error,
        kind: classifyConnectionError(error),
      );
    }
  }

  /// The command channel that stops [host]'s orphaned mosh-server; null
  /// for security-key hosts, where every connection asks for a touch.
  @visibleForTesting
  AgentCommandRunner Function()? cleanupRunnerFor(SavedHost host) {
    final cleanup = cleanupRunner;
    if (cleanup == null || host.authMethod == SshAuthMethod.hardwareKey) {
      return null;
    }
    return () => cleanup(host);
  }

  static MoshSshBootstrap _bootstrapFor(SavedHost host) {
    final ports = MoshPortRange.tryParse(host.moshPorts);
    return ports == null
        ? MoshSshBootstrap(locale: host.moshLocale)
        : MoshSshBootstrap(
            locale: host.moshLocale,
            serverPort: ports.first,
            serverPortEnd: ports.last,
          );
  }

  /// The `-p` value the bootstrap passes for [host].
  static String _portArgument(SavedHost host) {
    final bootstrap = _bootstrapFor(host);
    return bootstrap.serverPort == bootstrap.serverPortEnd
        ? '${bootstrap.serverPort}'
        : '${bootstrap.serverPort}:${bootstrap.serverPortEnd}';
  }

  /// The `mosh-server new` command for [host], with the timeouts that let
  /// a server left without its client exit on its own, after ending the
  /// [abandoned] servers.
  @visibleForTesting
  static String bootstrapCommand(
    SavedHost host, {
    Iterable<MoshServerHandle> abandoned = const [],
  }) =>
      '${killAllCommand(abandoned)}'
      '$moshServerTimeoutEnv ${_bootstrapFor(host).command()}';

  /// How long the side connection may take to start mosh-server (not to
  /// connect) before the terminal opens a connection of its own: a stale
  /// side connection must not hold the terminal up for a whole connection
  /// timeout. A mosh-server started too late exits on its own, after a
  /// minute without a client (checked against mosh 1.4.0), so it is not
  /// a second session.
  static const sideChannelBootstrapTimeout = Duration(seconds: 4);

  /// Starts mosh-server over [cleanupRunnerFor] [host], with the address
  /// that connection reached (Mosh must use that one: the first address
  /// a name resolves to may be one SSH could not reach); null when that
  /// did not work for a reason a connection of the terminal's own may not
  /// share (a changed host key, which only it may ask about; a stale side
  /// connection; unexpected output). A machine that cannot be reached
  /// fails here, rather than being tried twice.
  @visibleForTesting
  Future<({MoshServerConfig server, InternetAddress? address})?>
  bootstrapOnSideChannel(SavedHost host, {String? command}) async {
    final runner = cleanupRunnerFor(host)?.call();
    if (runner == null) return null;
    try {
      final result = await runner.run(
        command ?? bootstrapCommand(host),
        timeout: sideChannelBootstrapTimeout,
      );
      return (
        server: MoshServerConfig.parse(
          '${result.stdout}${result.stderr}',
          host: host.host.trim(),
        ),
        address: switch (runner) {
          final AddressedCommandRunner addressed => addressed.remoteAddress,
          _ => null,
        },
      );
    } on ConnectionFailure catch (failure) {
      if (failure.kind == ConnectionProblemKind.unreachable) rethrow;
      return null;
    } catch (_) {
      return null;
    } finally {
      unawaited(runner.close().catchError((Object _) {}));
    }
  }

  Future<MoshServerConfig> _bootstrap(
    SSHClient client,
    SavedHost host,
    String command,
  ) async {
    // Through sh, so the `VAR=value cmd` prefix works under any login shell.
    final session = await SshClientFactory.withinSetupTimeout(
      host,
      client,
      client.execute(posixShellCommand(command)),
    );
    final output = StringBuffer();

    Future<void> drain(Stream<List<int>> stream) => stream.forEach(
      (chunk) => output.write(utf8.decode(chunk, allowMalformed: true)),
    );

    try {
      await Future.wait([
        drain(session.stdout),
        drain(session.stderr),
      ]).timeout(Duration(seconds: host.connectionTimeoutSeconds));
    } on TimeoutException {
      session.close();
      throw const AppFailure('Timed out waiting for mosh-server startup.');
    }

    return MoshServerConfig.parse(output.toString(), host: host.host.trim());
  }
}

class MoshTerminalSession
    implements
        SshTerminalSession,
        RoamingTerminalSession,
        PredictiveTerminalSession {
  MoshTerminalSession(
    this._session, {
    this.server,
    this.cleanupRunner,
    this._shutdown,
    this._ledger,
    this._machine = '',
  }) {
    _errorSubscription = _session.errors.listen((error) {
      if (!_closed) {
        _stderr.add(utf8.encode('$error\r\n'));
      }
    });
    // Before [close], [done] only completes when the server ends the
    // session itself (its shell exited).
    unawaited(
      _session.done.then((_) {
        if (!_closed) _serverEnded = true;
      }),
    );
  }

  final MoshSession _session;

  /// The mosh-server behind this session, when the bootstrap named it.
  final MoshServerHandle? server;

  /// A command channel to the machine, to stop the server when the
  /// shutdown request got no answer; null disables it.
  final AgentCommandRunner Function()? cleanupRunner;

  final MoshServerShutdown? _shutdown;
  final MoshServerLedger? _ledger;
  final String _machine;

  /// How long [close] waits, in the background, for the server to answer
  /// its shutdown request before it stops the server over SSH.
  static const shutdownAckTimeout = Duration(seconds: 2);

  final _stderr = StreamController<List<int>>.broadcast();
  StreamSubscription<Object>? _errorSubscription;
  bool _closed = false;
  bool _serverEnded = false;

  /// Resolves once [close] knows what became of the server.
  @visibleForTesting
  Future<void> serverSettled = Future.value();

  @override
  Stream<List<int>> get stdout => _session.stdout;

  @override
  Stream<List<int>> get stderr => _stderr.stream;

  @override
  Future<void> get done => _session.done;

  @override
  Stream<int> get echoAcks => _session.echoAcks;

  @override
  Duration? get smoothedRtt => _session.smoothedRtt;

  @override
  Future<void> send(List<int> data) async {
    sendWithInputState(data);
  }

  @override
  int sendWithInputState(List<int> data) {
    if (_closed) {
      throw const AppFailure('The Mosh session is closed.');
    }
    return _session.send(data);
  }

  @override
  void resize(int columns, int rows, int pixelWidth, int pixelHeight) {
    if (_closed) {
      return;
    }
    _session.resize(columns, rows);
  }

  @override
  Future<void> rehome() async {
    if (_closed) {
      return;
    }
    await _session.rehome();
  }

  /// Closes the client and ends its server: the server is asked to end
  /// the session (as `mosh` does when it quits) unless it already has, and
  /// stopped over SSH when it does not answer. dart_mosh cannot resume a
  /// session from a new client, so a server left running would never be
  /// used again. The request goes out before this returns; the rest
  /// happens in the background.
  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    serverSettled = _endServer();
    await _errorSubscription?.cancel();
    await _session.close();
    await _stderr.close();
  }

  Future<void> _endServer() async {
    final shutdown = _shutdown;
    final pid = server?.pid;
    if (_serverEnded) {
      shutdown?.close();
      if (pid != null) await _ledger?.forget(_machine, [pid]);
      return;
    }
    var ended = false;
    if (shutdown != null) {
      final acknowledged = shutdown.acknowledged(shutdownAckTimeout);
      shutdown.send(_session.send(const []));
      ended = await acknowledged;
      shutdown.close();
    }
    final handle = server;
    final runner = cleanupRunner;
    if (!ended && handle != null && runner != null) {
      ended = await reapMoshServer(handle, runner);
    }
    if (pid == null) return;
    await (ended
        ? _ledger?.forget(_machine, [pid])
        : _ledger?.release(_machine, pid));
  }
}
