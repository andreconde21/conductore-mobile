import 'dart:async';

import 'package:conduit/core/app_failure.dart';
import 'package:conduit/features/agent_attention/data/shared_command_runners.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

/// One fake SSH connection: commands wait for [release] when [hold] is set.
class _Connection
    implements StdinAgentCommandRunner, ReconnectingCommandRunner {
  _Connection(this.host);

  final String host;
  final List<String> commands = [];
  int closeCount = 0;
  int drops = 0;
  Completer<void>? hold;

  @override
  Future<AgentCommandResult> run(
    String command, {
    required Duration timeout,
  }) async {
    commands.add(command);
    await hold?.future;
    return AgentCommandResult(stdout: '$host:$command', stderr: '');
  }

  @override
  Future<AgentCommandResult> runWithStdin(
    String command, {
    required String stdin,
    required Duration timeout,
    Future<void>? cancel,
  }) => run('$command<$stdin', timeout: timeout);

  @override
  Future<void> dropConnection() async => drops += 1;

  @override
  Future<void> close() async => closeCount += 1;
}

void main() {
  const timeout = Duration(seconds: 10);

  (SharedCommandRunners, List<_Connection>) makePool({Stream<void>? network}) {
    final opened = <_Connection>[];
    final pool = SharedCommandRunners((host) {
      final connection = _Connection(host.id);
      opened.add(connection);
      return connection;
    }, networkChanges: network);
    return (pool, opened);
  }

  test('runners of one machine share its connection', () async {
    final (pool, opened) = makePool();
    final monitor = pool.lease(buildHost('a'));
    final board = pool.lease(buildHost('a').copyWith(name: 'Renamed'));
    final other = pool.lease(buildHost('b'));
    await monitor.run('status', timeout: timeout);
    await board.run('tmux ls', timeout: timeout);
    await other.run('status', timeout: timeout);
    expect(opened.map((c) => c.host), ['a', 'b']);
    expect(opened.first.commands, ['status', 'tmux ls']);
    // A changed login is another connection.
    pool.lease(buildHost('a').copyWith(password: 'new'));
    expect(opened, hasLength(3));
  });

  test('a closed runner fails alone; the connection lingers after the '
      'last one, then closes', () {
    fakeAsync((async) {
      final (pool, opened) = makePool();
      final chat = pool.lease(buildHost('a'));
      final monitor = pool.lease(buildHost('a'));
      unawaited(monitor.close());
      async.flushMicrotasks();
      expect(
        () => monitor.run('status', timeout: timeout),
        throwsA(isA<AppFailure>()),
      );
      // The chat keeps its channel when the monitor stops.
      expect(chat.run('transcript', timeout: timeout), completes);
      async.flushMicrotasks();
      unawaited(chat.close());
      async.elapse(const Duration(seconds: 20));
      expect(opened.single.closeCount, 0);
      // Reopened within the linger: the same connection.
      final again = pool.lease(buildHost('a'));
      async.elapse(const Duration(minutes: 1));
      expect(opened, hasLength(1));
      expect(opened.single.closeCount, 0);
      unawaited(again.close());
      async.elapse(pool.linger);
      expect(opened.single.closeCount, 1);
      expect(pool.connectionCount, 0);
    });
  });

  test('at most maxChannels commands run at once; a wait past the '
      'timeout fails without dropping the connection', () {
    fakeAsync((async) {
      final (pool, opened) = makePool();
      final runner = pool.lease(buildHost('a'));
      runner.run('first', timeout: timeout);
      final connection = opened.single..hold = Completer<void>();
      for (var i = 1; i < pool.maxChannels; i++) {
        unawaited(runner.run('long $i', timeout: timeout));
      }
      async.flushMicrotasks();
      Object? error;
      unawaited(
        runner.run('queued', timeout: const Duration(seconds: 2)).catchError((
          Object e,
        ) {
          error = e;
          return const AgentCommandResult(stdout: '', stderr: '');
        }),
      );
      var ran = false;
      unawaited(runner.run('next', timeout: timeout).then((_) => ran = true));
      async.elapse(const Duration(seconds: 3));
      expect(error, isA<AppFailure>());
      expect(connection.commands, isNot(contains('queued')));
      expect(ran, isFalse);
      connection.hold!.complete();
      async.flushMicrotasks();
      expect(ran, isTrue);
      expect(connection.drops, 0);
    });
  });

  test('a network change drops the sockets so they reconnect', () async {
    final network = StreamController<void>();
    final (pool, opened) = makePool(network: network.stream);
    await pool.lease(buildHost('a')).run('status', timeout: timeout);
    network.add(null);
    await pumpEventQueue();
    expect(opened.single.drops, 1);
    await network.close();
    await pool.dispose();
    expect(opened.single.closeCount, 1);
  });

  test('stdin commands go through the shared connection', () async {
    final (pool, opened) = makePool();
    final result = await pool
        .lease(buildHost('a').copyWith(authMethod: SshAuthMethod.password))
        .runWithStdin('send', stdin: 'hi', timeout: timeout);
    expect(result.stdout, 'a:send<hi');
    expect(opened, hasLength(1));
  });
}
