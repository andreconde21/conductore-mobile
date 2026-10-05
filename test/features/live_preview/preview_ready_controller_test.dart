import 'package:conduit/core/app_failure.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/live_preview/presentation/preview_ready_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

AgentCommandResult _ok(String stdout) =>
    AgentCommandResult(stdout: stdout, stderr: '', exitCode: 0);

String _ports(int seq, [List<String> entries = const []]) =>
    '{"seq":$seq,"source":"ss","cached":false,"ports":[${entries.join(',')}]}';

String _port(int port, int seq, {String label = 'vite'}) =>
    '{"port":$port,"process":"node","label":"$label","cwd":"/app","seq":$seq}';

const _ss1 = 'LISTEN 0 511 127.0.0.1:3000 0.0.0.0:*\n';
const _ss2 =
    'LISTEN 0 511 127.0.0.1:3000 0.0.0.0:*\n'
    'LISTEN 0 511 127.0.0.1:5173 0.0.0.0:* users:(("node",pid=9,fd=3))\n'
    'LISTEN 0 128 0.0.0.0:22 0.0.0.0:*\n';

void main() {
  test(
    'companion: the first reply is the baseline, later ones offer',
    () async {
      final runner = ScriptedAgentCommandRunner([
        _ok(_ports(4, [_port(3000, 4)])),
        _ok(_ports(5, [_port(5173, 5)])),
      ]);
      final controller = PreviewReadyController(runnerFactory: () => runner);
      await controller.poll();
      expect(controller.source, PreviewPortSource.companion);
      expect(controller.offer, isNull);
      expect(runner.commands.single, contains('conductore-hostd ports'));
      await controller.poll();
      expect(runner.commands.last, contains('ports --since 4'));
      expect(controller.offer?.chipText, 'Preview ready · :5173 · vite');
      expect(controller.offer?.cwd, '/app');
      controller.dispose();
    },
  );

  test('falls back to ss when the companion is missing or too old', () async {
    final runner = ScriptedAgentCommandRunner([
      const AgentCommandResult(
        stdout: '',
        stderr: 'conductore-hostd: not found',
        exitCode: 127,
      ),
      _ok(_ss1),
      _ok(_ss2),
    ]);
    final controller = PreviewReadyController(runnerFactory: () => runner);
    await controller.poll();
    expect(controller.source, PreviewPortSource.ss);
    expect(controller.offer, isNull);
    await controller.poll();
    expect(runner.commands.last, startsWith('ss -ltnpH'));
    expect(controller.offer?.port, 5173);
    expect(controller.offer?.label, 'node');
    controller.dispose();
  });

  test('an old companion ("unknown command") also falls back', () async {
    final runner = ScriptedAgentCommandRunner([
      const AgentCommandResult(
        stdout: '{"error":"unknown command ports"}',
        stderr: '',
        exitCode: 1,
      ),
      _ok(_ss1),
    ]);
    final controller = PreviewReadyController(runnerFactory: () => runner);
    await controller.poll();
    expect(controller.source, PreviewPortSource.ss);
    controller.dispose();
  });

  test('a dismissed port is not offered again in this session', () async {
    final runner = ScriptedAgentCommandRunner([
      _ok(_ports(1)),
      _ok(_ports(2, [_port(5173, 2)])),
      _ok(_ports(3, [_port(5173, 3)])),
      _ok(_ports(4, [_port(4321, 4, label: 'astro')])),
    ]);
    final controller = PreviewReadyController(runnerFactory: () => runner);
    await controller.poll();
    await controller.poll();
    expect(controller.offer?.port, 5173);
    controller.dismiss();
    expect(controller.offer, isNull);
    expect(controller.handledPorts, {5173});
    // The server restarts: still dismissed.
    await controller.poll();
    expect(controller.offer, isNull);
    await controller.poll();
    expect(controller.offer?.port, 4321);
    controller.markOpened();
    expect(controller.handledPorts, {5173, 4321});
    controller.dispose();
  });

  test('connection failures are retried on the next poll', () async {
    final runner = ScriptedAgentCommandRunner([
      const AppFailure('Could not reach box.'),
      _ok(_ports(1)),
    ]);
    final controller = PreviewReadyController(runnerFactory: () => runner);
    await controller.poll();
    expect(controller.source, PreviewPortSource.unknown);
    await controller.poll();
    expect(controller.source, PreviewPortSource.companion);
    controller.dispose();
  });

  test('screen URLs offer once per appearance and merge with ports', () {
    final controller = PreviewReadyController(
      runnerFactory: () => ScriptedAgentCommandRunner([_ok(_ports(1))]),
    );
    controller.scanScreen([
      '  VITE v5.0.0',
      '  ➜  Local:   http://localhost:5173/x',
    ]);
    expect(controller.offer?.port, 5173);
    expect(controller.offer?.path, '/x');
    expect(controller.offer?.label, 'vite');
    controller.dismiss();
    controller.scanScreen(['Local: http://localhost:5173/x']);
    expect(controller.offer, isNull);
    controller.scanScreen(['Local: http://localhost:4000/']);
    expect(controller.offer?.port, 4000);
    controller.dispose();
  });

  test('markPreviewing hides the offer for the port Live preview shows', () {
    final controller = PreviewReadyController(
      runnerFactory: () => ScriptedAgentCommandRunner([_ok(_ports(1))]),
    );
    controller.scanScreen(['Local: http://localhost:5173/']);
    controller.markPreviewing(5173);
    expect(controller.offer, isNull);
    controller.dispose();
  });

  testWidgets(
    'polls only in the foreground and closes its connection when hidden',
    (tester) async {
      final runner = ScriptedAgentCommandRunner([_ok(_ports(1))]);
      final screen = ChangeNotifier();
      var rows = <String>[];
      final controller = PreviewReadyController(
        runnerFactory: () => runner,
        canPoll: () => true,
      )..attachScreen(screen, () => rows);
      await tester.pump(const Duration(seconds: 20));
      expect(runner.commands, isEmpty);

      controller.setForeground(true);
      await tester.pump(const Duration(seconds: 1));
      expect(runner.commands, isEmpty);
      await tester.pump(PreviewReadyController.defaultStartDelay);
      expect(runner.commands, hasLength(1));
      await tester.pump(const Duration(seconds: 5));
      expect(runner.commands, hasLength(2));
      // Nothing new: the next gap doubles (CON-089).
      await tester.pump(const Duration(seconds: 5));
      expect(runner.commands, hasLength(2));
      await tester.pump(const Duration(seconds: 5));
      expect(runner.commands, hasLength(3));

      rows = ['Local: http://localhost:8000/'];
      screen.notifyListeners();
      await tester.pump(const Duration(seconds: 1));
      expect(controller.offer?.port, 8000);

      controller.setForeground(false);
      await tester.pump();
      expect(runner.closeCount, 1);
      await tester.pump(const Duration(seconds: 30));
      expect(runner.commands, hasLength(3));
      controller.dispose();
      screen.dispose();
    },
  );

  testWidgets('backs off to 30 s and stops while a port is offered '
      '(CON-089)', (tester) async {
    final runner = ScriptedAgentCommandRunner([_ok(_ports(1))]);
    final controller = PreviewReadyController(
      runnerFactory: () => runner,
      canPoll: () => true,
    )..setForeground(true);
    // Polls at 2, 7, 17, 37, 67, 97 s.
    await tester.pump(const Duration(seconds: 2));
    for (final gap in [5, 10, 20, 30, 30]) {
      await tester.pump(Duration(seconds: gap));
    }
    expect(runner.commands, hasLength(6));

    controller.scanScreen(['Local: http://localhost:5173/']);
    expect(controller.offer?.port, 5173);
    await tester.pump(const Duration(seconds: 30));
    expect(runner.commands, hasLength(6), reason: 'a port was found');
    expect(controller.pollScheduled, isFalse);

    controller.dismiss();
    await tester.pump(const Duration(seconds: 30));
    expect(runner.commands, hasLength(7));
    controller.dispose();
  });

  test('skips polls while the session is disconnected', () async {
    final runner = ScriptedAgentCommandRunner([_ok(_ports(1))]);
    final controller = PreviewReadyController(
      runnerFactory: () => runner,
      canPoll: () => false,
    );
    await controller.poll();
    expect(runner.commands, isEmpty);
    controller.dispose();
  });
}
