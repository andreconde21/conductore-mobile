import 'dart:async';
import 'dart:convert';

import 'package:conduit/core/app_failure.dart';
import 'package:conduit/core/connection_problem.dart';
import 'package:conduit/features/agent_attention/data/remote_tool_command.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/terminal/data/ssh_client_factory.dart';
import 'package:conduit/features/terminal/data/tcp_ssh_socket.dart';
import 'package:conduit/features/terminal/domain/host_key_prompt.dart';
import 'package:conduit/features/terminal/domain/host_key_verifier.dart';
import 'package:conduit/features/terminal/domain/mosh_server_cleanup.dart';
import 'package:conduit/features/terminal/domain/predictive_terminal_session.dart';
import 'package:conduit/features/terminal/domain/roaming_terminal_session.dart';
import 'package:conduit/features/terminal/domain/ssh_terminal_repository.dart';
import 'package:conduit/features/terminal/domain/ssh_terminal_session.dart';
import 'package:dart_mosh/dart_mosh.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

class MoshTerminalRepository implements SshTerminalRepository {
  const MoshTerminalRepository(this._hostKeyVerifier, {this.cleanupRunner});

  final HostKeyVerifier _hostKeyVerifier;

  /// A command channel to [host], used to stop a session's mosh-server
  /// after it was left without a client (a Herdr detach). Null disables
  /// that; hosts that ask for a security-key touch per connection never
  /// get one.
  final AgentCommandRunner Function(SavedHost host)? cleanupRunner;

  SshClientFactory get _clientFactory => SshClientFactory(_hostKeyVerifier);

  @override
  Future<SshTerminalSession> connect(
    SavedHost host, {
    required int columns,
    required int rows,
  }) async {
    SSHClient? client;
    try {
      // Opened by the user, who may decide on a changed host key.
      client = await withInteractiveHostKeyCheck<SSHClient>(
        () => _clientFactory.connect(host),
      );
      final server = await _bootstrap(client, host);
      final socket = client.socket;
      final address = socket is TcpSshSocket ? socket.remoteAddress : null;
      client.close();
      client = null;

      final session = await MoshSession.connect(
        server: server,
        cipher: MoshPacketCipher.aesOcb(server.key),
        address: address,
        columns: columns,
        rows: rows,
      );
      return MoshTerminalSession(
        session,
        server: MoshServerHandle(
          port: server.port,
          pid: MoshServerHandle.parsePid(server.rawOutput),
          portArgument: _portArgument(host),
        ),
        cleanupRunner: cleanupRunnerFor(host),
      );
    } catch (error) {
      client?.close();
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

  /// The `mosh-server new` command for [host], with an idle timeout so a
  /// server left without its client exits eventually.
  @visibleForTesting
  static String bootstrapCommand(SavedHost host) =>
      '$moshServerTimeoutEnv ${_bootstrapFor(host).command()}';

  Future<MoshServerConfig> _bootstrap(SSHClient client, SavedHost host) async {
    // Through sh, so the `VAR=value cmd` prefix works under any login shell.
    final session = await client.execute(
      posixShellCommand(bootstrapCommand(host)),
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
        PredictiveTerminalSession,
        ReapableTerminalSession {
  MoshTerminalSession(this._session, {this.server, this.cleanupRunner}) {
    _errorSubscription = _session.errors.listen((error) {
      if (!_closed) {
        _stderr.add(utf8.encode('$error\r\n'));
      }
    });
  }

  final MoshSession _session;

  /// The mosh-server behind this session, when the bootstrap named it.
  final MoshServerHandle? server;

  /// A command channel to the machine for [reapServer]; null disables it.
  final AgentCommandRunner Function()? cleanupRunner;

  final _stderr = StreamController<List<int>>.broadcast();
  StreamSubscription<Object>? _errorSubscription;
  bool _closed = false;

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

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    await _errorSubscription?.cancel();
    await _session.close();
    await _stderr.close();
  }

  @override
  Future<void> reapServer() async {
    final handle = server;
    final runner = cleanupRunner;
    if (handle == null || runner == null) {
      return;
    }
    await reapMoshServer(handle, runner);
  }
}
