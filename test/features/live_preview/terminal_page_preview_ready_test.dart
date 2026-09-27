import 'dart:async';

import 'package:conduit/core/theme/theme_controller.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/live_preview/presentation/preview_ready_controller.dart';
import 'package:conduit/features/terminal/presentation/terminal_page.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

import '../../support/test_doubles.dart';

class _NoopWakelock extends WakelockPlusPlatformInterface {
  @override
  Future<void> toggle({required bool enable}) async {}

  @override
  Future<bool> get enabled async => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  WakelockPlusPlatformInterface.instance = _NoopWakelock();

  testWidgets('a dev server URL on screen shows the chip over the terminal; '
      'dismissing hides it', (tester) async {
    final workspace = TerminalWorkspaceController(
      ImmediateTerminalRepository(TrackableTerminalSession()),
    );
    addTearDown(workspace.dispose);
    final themeController = ThemeController(InMemoryThemePreferences());
    final session = workspace.open(buildHost('a'));
    await tester.runAsync(session.connect);
    workspace.activate(session);
    final runner = ScriptedAgentCommandRunner([
      const AgentCommandResult(
        stdout: '{"seq":3,"ports":[]}',
        stderr: '',
        exitCode: 0,
      ),
    ]);
    PreviewReadyController? watcher;

    await tester.pumpWidget(
      MaterialApp(
        home: TerminalPage(
          workspace: workspace,
          themeController: themeController,
          sftpRepository: NoNetworkSftpRepository(),
          previewWatcherFactory: (session) =>
              watcher = PreviewReadyController(runnerFactory: () => runner),
        ),
      ),
    );
    await tester.pump();
    expect(watcher?.isForeground, isTrue);
    await tester.pump(PreviewReadyController.defaultStartDelay);
    expect(runner.commands.single, contains('conductore-hostd ports'));
    expect(find.byKey(const ValueKey('preview-ready-chip')), findsNothing);

    session.terminal.write(
      '\r\n  VITE v5.4.2  ready in 300 ms\r\n\r\n'
      '  ➜  Local:   http://localhost:5173/\r\n',
    );
    await tester.pump(PreviewReadyController.defaultScreenDebounce);
    await tester.pump();
    expect(find.text('Preview ready · :5173 · vite'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('preview-ready-dismiss')));
    await tester.pump();
    expect(find.byKey(const ValueKey('preview-ready-chip')), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('a route on top pauses the port polls', (tester) async {
    final workspace = TerminalWorkspaceController(
      ImmediateTerminalRepository(TrackableTerminalSession()),
    );
    addTearDown(workspace.dispose);
    final session = workspace.open(buildHost('a'));
    await tester.runAsync(session.connect);
    workspace.activate(session);
    PreviewReadyController? watcher;
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: TerminalPage(
          workspace: workspace,
          themeController: ThemeController(InMemoryThemePreferences()),
          sftpRepository: NoNetworkSftpRepository(),
          previewWatcherFactory: (session) => watcher = PreviewReadyController(
            runnerFactory: () => ScriptedAgentCommandRunner([
              const AgentCommandResult(stdout: '', stderr: '', exitCode: 0),
            ]),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(watcher?.isForeground, isTrue);
    unawaited(
      navigator.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const Scaffold()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(watcher?.isForeground, isFalse);
    navigator.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(watcher?.isForeground, isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 300));
  });
}
