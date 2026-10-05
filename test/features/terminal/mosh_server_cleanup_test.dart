import 'dart:async';
import 'dart:io';

import 'package:conduit/core/connection_problem.dart';
import 'package:conduit/features/agent_attention/data/shared_command_runners.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/terminal/data/mosh_terminal_repository.dart';
import 'package:conduit/features/terminal/domain/herdr_keymap.dart';
import 'package:conduit/features/terminal/domain/mosh_server_cleanup.dart';
import 'package:conduit/features/terminal/domain/ssh_terminal_repository.dart';
import 'package:conduit/features/terminal/domain/ssh_terminal_session.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

/// What mosh-server 1.4.0 prints on `mosh-server new` (stdout, then
/// stderr), key redacted.
const _bootstrapOutput =
    'MOSH CONNECT 60001 AAAAAAAAAAAAAAAAAAAAAA\n'
    '\n'
    'mosh-server (mosh 1.4.0) [build mosh 1.4.0]\n'
    'Copyright 2012 Keith Winstein <mosh-devel@mit.edu>\n'
    'License GPLv3+: GNU GPL version 3 or later '
    '<http://gnu.org/licenses/gpl.html>.\n'
    'This is free software: you are free to change and redistribute it.\n'
    'There is NO WARRANTY, to the extent permitted by law.\n'
    '\n'
    '[mosh-server detached, pid = 1142291]\n';

const _ok = AgentCommandResult(stdout: '', stderr: '', exitCode: 0);

class _Repository implements SshTerminalRepository {
  final sessions = <TrackableTerminalSession>[];

  @override
  Future<SshTerminalSession> connect(
    SavedHost host, {
    required int columns,
    required int rows,
  }) async {
    final session = TrackableTerminalSession();
    sessions.add(session);
    return session;
  }
}

void main() {
  group('MoshServerHandle', () {
    test('reads the pid mosh-server prints when it detaches', () {
      expect(MoshServerHandle.parsePid(_bootstrapOutput), 1142291);
      expect(MoshServerHandle.parsePid('MOSH CONNECT 60001 key'), isNull);
    });

    test('with a pid, kills only that pid and only if it is mosh-server', () {
      const handle = MoshServerHandle(port: 60001, pid: 1142291);
      expect(
        handle.killCommand(),
        'case "\$(ps -o comm= -p 1142291 2>/dev/null)" in '
        '*mosh-server) kill 1142291;; esac',
      );
    });

    test('killAllCommand ends each server it can name, silently', () {
      expect(killAllCommand(const []), '');
      expect(
        killAllCommand(const [
          MoshServerHandle(port: 60001, pid: 7),
          MoshServerHandle(port: 60003, portArgument: '60001:60999'),
          MoshServerHandle(port: 60002, pid: 8),
        ]),
        '{ ${const MoshServerHandle(port: 60001, pid: 7).killCommand()}; '
        '${const MoshServerHandle(port: 60002, pid: 8).killCommand()}; } '
        '>/dev/null 2>&1; ',
      );
    });

    test('without a pid, pkills the user\'s server on that exact port', () {
      const handle = MoshServerHandle(port: 60001, portArgument: '60001');
      expect(
        handle.killCommand(),
        'pkill -u "\$(id -un)" -f '
        "'^([^ ]*/)?mosh-server new .*-p 60001( |\$)'",
      );
    });

    test('without a pid and with a port range, kills nothing', () {
      const handle = MoshServerHandle(port: 60003, portArgument: '60001:60999');
      expect(handle.killCommand(), isNull);
    });
  });

  group('reapMoshServer', () {
    test('runs the kill command and closes the runner', () async {
      final runner = ScriptedAgentCommandRunner([_ok]);
      await reapMoshServer(
        const MoshServerHandle(port: 60001, pid: 42),
        () => runner,
      );
      expect(runner.commands.single, contains('kill 42;;'));
      expect(runner.closeCount, 1);
    });

    test('swallows a failing machine', () async {
      final runner = ScriptedAgentCommandRunner([StateError('unreachable')]);
      expect(
        await reapMoshServer(
          const MoshServerHandle(port: 60001, pid: 42),
          () => runner,
        ),
        isFalse,
      );
      expect(runner.closeCount, 1);
    });

    test('opens no channel when the server cannot be identified', () async {
      var opened = 0;
      await reapMoshServer(
        const MoshServerHandle(port: 60001, portArgument: '60001:60999'),
        () {
          opened += 1;
          return ScriptedAgentCommandRunner([_ok]);
        },
      );
      expect(opened, 0);
    });
  });

  test('the bootstrap gives mosh-server a 24-hour idle timeout and a '
      'SIGUSR1 that spares connected servers', () {
    final command = MoshTerminalRepository.bootstrapCommand(
      buildHost('m').copyWith(useMosh: true),
    );
    expect(
      command,
      startsWith(
        'MOSH_SERVER_NETWORK_TMOUT=86400 MOSH_SERVER_SIGNAL_TMOUT=3600 ',
      ),
    );
    expect(command, contains('mosh-server new'));
  });

  test('the bootstrap first ends the abandoned servers', () {
    final host = buildHost('m').copyWith(useMosh: true);
    const abandoned = [MoshServerHandle(port: 60001, pid: 7)];
    expect(
      MoshTerminalRepository.bootstrapCommand(host, abandoned: abandoned),
      '${killAllCommand(abandoned)}'
      '${MoshTerminalRepository.bootstrapCommand(host)}',
    );
  });

  test('security-key hosts get no cleanup channel', () {
    final repository = MoshTerminalRepository(
      NoopVerifier(),
      cleanupRunner: (_) => ScriptedAgentCommandRunner([_ok]),
    );
    final host = buildHost('m').copyWith(useMosh: true);
    expect(repository.cleanupRunnerFor(host), isNotNull);
    expect(
      repository.cleanupRunnerFor(
        host.copyWith(authMethod: SshAuthMethod.hardwareKey),
      ),
      isNull,
    );
    expect(
      MoshTerminalRepository(NoopVerifier()).cleanupRunnerFor(host),
      isNull,
    );
  });

  group('starting mosh-server over the side connection', () {
    final host = buildHost('m').copyWith(useMosh: true);

    test('needs no SSH connection of its own', () async {
      final runner = ScriptedAgentCommandRunner([
        const AgentCommandResult(
          stdout: 'MOSH CONNECT 60001 AAAAAAAAAAAAAAAAAAAAAA\n',
          stderr: '[mosh-server detached, pid = 1142291]\n',
          exitCode: 0,
        ),
      ]);
      final repository = MoshTerminalRepository(
        NoopVerifier(),
        cleanupRunner: (_) => runner,
      );

      final started = await repository.bootstrapOnSideChannel(host);

      final server = started!.server;
      expect(server.port, 60001);
      expect(server.host, host.host);
      expect(MoshServerHandle.parsePid(server.rawOutput), 1142291);
      expect(
        runner.commands.single,
        MoshTerminalRepository.bootstrapCommand(host),
      );
      await Future<void>.delayed(Duration.zero);
      expect(runner.closeCount, 1);
    });

    test('Mosh goes to the address the side connection reached', () async {
      // A name's first address may be one SSH fell back from (an IPv6 one
      // without a route): Mosh must use the one that answered.
      final runner = _AddressedRunner(InternetAddress('192.0.2.7'));
      final repository = MoshTerminalRepository(
        NoopVerifier(),
        cleanupRunner: (_) => runner,
      );

      final started = await repository.bootstrapOnSideChannel(host);

      expect(started?.address, InternetAddress('192.0.2.7'));
      expect(
        runner.timeouts.single,
        MoshTerminalRepository.sideChannelBootstrapTimeout,
      );
    });

    test(
      'leaves a changed host key to the terminal\'s own connection',
      () async {
        final repository = MoshTerminalRepository(
          NoopVerifier(),
          cleanupRunner: (_) => ScriptedAgentCommandRunner([
            const ConnectionFailure(
              'Could not reach m.',
              'host key mismatch',
              kind: ConnectionProblemKind.hostKey,
            ),
          ]),
        );
        expect(await repository.bootstrapOnSideChannel(host), isNull);
      },
    );

    test('falls back on output it cannot read', () async {
      final repository = MoshTerminalRepository(
        NoopVerifier(),
        cleanupRunner: (_) => ScriptedAgentCommandRunner([
          const AgentCommandResult(
            stdout: '',
            stderr: 'mosh-server: command not found',
            exitCode: 127,
          ),
        ]),
      );
      expect(await repository.bootstrapOnSideChannel(host), isNull);
    });

    test('does not try an unreachable machine twice', () async {
      final repository = MoshTerminalRepository(
        NoopVerifier(),
        cleanupRunner: (_) => ScriptedAgentCommandRunner([
          const ConnectionFailure(
            'Could not reach m.',
            'No route to host',
            kind: ConnectionProblemKind.unreachable,
          ),
        ]),
      );
      await expectLater(
        repository.bootstrapOnSideChannel(host),
        throwsA(isA<ConnectionFailure>()),
      );
    });

    test('security-key hosts and repositories without one skip it', () async {
      final repository = MoshTerminalRepository(
        NoopVerifier(),
        cleanupRunner: (_) => fail('no side channel for a security key'),
      );
      expect(
        await repository.bootstrapOnSideChannel(
          host.copyWith(authMethod: SshAuthMethod.hardwareKey),
        ),
        isNull,
      );
      expect(
        await MoshTerminalRepository(
          NoopVerifier(),
        ).bootstrapOnSideChannel(host),
        isNull,
      );
    });
  });

  group('closing a Mosh session', () {
    setUp(HerdrKeymapCache.instance.clear);
    tearDown(HerdrKeymapCache.instance.clear);

    SavedHost mosh(ConnectTarget? target, {bool useMosh = true}) {
      final host = buildHost('m').copyWith(useMosh: useMosh);
      return target == null ? host : target.apply(host);
    }

    Future<TrackableTerminalSession> closeSession(
      WidgetTester tester,
      SavedHost host,
    ) async {
      final repository = _Repository();
      final workspace = TerminalWorkspaceController(repository);
      addTearDown(workspace.dispose);
      final session = workspace.open(host);
      await tester.runAsync(session.connect);
      await tester.runAsync(() => workspace.close(session));
      await tester.runAsync(pumpEventQueue);
      return repository.sessions.single;
    }

    const herdr = ConnectTarget.herdr(workspaceId: 'w1');

    // The transport close is what ends the server (MoshTerminalSession
    // asks it to); these are typed first so the remote side ends cleanly.
    testWidgets('a Herdr session is detached, then closed', (tester) async {
      HerdrKeymapCache.instance.put('m', HerdrKeymap.hostDefaults);
      final remote = await closeSession(tester, mosh(herdr));
      expect(remote.sent.last, [0x02, 0x71]);
      expect(remote.closeCount, 1);
    });

    testWidgets('Herdr before its keymap is read: nothing typed', (
      tester,
    ) async {
      final remote = await closeSession(tester, mosh(herdr));
      expect(remote.sent, isEmpty);
      expect(remote.closeCount, 1);
    });

    testWidgets('a plain shell gets Ctrl-D, then is closed', (tester) async {
      final remote = await closeSession(tester, mosh(null));
      expect(remote.sent.single, [0x04]);
      expect(remote.closeCount, 1);
    });

    testWidgets('closed while connecting: the late session is closed too', (
      tester,
    ) async {
      final gate = Completer<void>();
      final repository = _GatedRepository(gate.future);
      final workspace = TerminalWorkspaceController(repository);
      addTearDown(workspace.dispose);
      final session = workspace.open(mosh(herdr));
      final connecting = session.connect();
      await tester.runAsync(() => workspace.close(session));
      gate.complete();
      await tester.runAsync(() => connecting);
      expect(repository.session.closeCount, 1);
    });

    testWidgets('quitting disconnects every session at once', (tester) async {
      final repository = _Repository();
      final workspace = TerminalWorkspaceController(repository);
      addTearDown(workspace.dispose);
      for (final id in ['a', 'b']) {
        final session = workspace.open(buildHost(id).copyWith(useMosh: true));
        await tester.runAsync(session.connect);
      }
      await tester.runAsync(workspace.disconnectAll);
      expect([for (final s in repository.sessions) s.closeCount], [1, 1]);
      expect(workspace.sessions, hasLength(2));
    });
  });
}

/// Connects once [gate] opens.
class _GatedRepository implements SshTerminalRepository {
  _GatedRepository(this.gate);

  final Future<void> gate;
  final session = TrackableTerminalSession();

  @override
  Future<SshTerminalSession> connect(
    SavedHost host, {
    required int columns,
    required int rows,
  }) async {
    await gate;
    return session;
  }
}

/// A side connection that is up to [remoteAddress].
class _AddressedRunner implements AgentCommandRunner, AddressedCommandRunner {
  _AddressedRunner(this.remoteAddress);

  @override
  final InternetAddress remoteAddress;
  final timeouts = <Duration>[];

  @override
  Future<AgentCommandResult> run(
    String command, {
    required Duration timeout,
  }) async {
    timeouts.add(timeout);
    return const AgentCommandResult(
      stdout: 'MOSH CONNECT 60001 AAAAAAAAAAAAAAAAAAAAAA\n',
      stderr: '',
      exitCode: 0,
    );
  }

  @override
  Future<void> close() async {}
}
