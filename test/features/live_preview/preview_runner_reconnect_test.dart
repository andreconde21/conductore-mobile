import 'package:conduit/core/app_failure.dart';
import 'package:conduit/core/theme/theme_controller.dart';
import 'package:conduit/features/agent_attention/data/herdr_attention_provider.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
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

/// Like SshAgentCommandRunner: unusable once closed.
class _ClosableRunner implements AgentCommandRunner {
  bool closed = false;
  final List<String> commands = [];

  @override
  Future<AgentCommandResult> run(
    String command, {
    required Duration timeout,
  }) async {
    if (closed) throw const AppFailure('This connection is closed.');
    commands.add(command);
    return AgentCommandResult(
      stdout: command.contains('ports') ? '{"seq":1,"ports":[]}' : '[]',
      stderr: '',
      exitCode: 0,
    );
  }

  @override
  Future<void> close() async => closed = true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  WakelockPlusPlatformInterface.instance = _NoopWakelock();

  testWidgets('the preview port polls follow the monitor across a reconnect', (
    tester,
  ) async {
    final workspace = TerminalWorkspaceController(
      CompletingTerminalRepository(),
    );
    addTearDown(workspace.dispose);
    final runners = <_ClosableRunner>[_ClosableRunner()];
    final attention = AgentAttentionController(
      workspace: workspace,
      runnerFactory: (_) => runners.last,
      provider: const HerdrAttentionProvider(),
      pollInterval: const Duration(days: 1),
    );
    addTearDown(attention.dispose);
    final host = buildHost('h').copyWith(agentAttentionEnabled: true);
    final session = workspace.open(host);
    await tester.runAsync(session.connect);
    await tester.pump();
    expect(attention.isMonitoring(host.id), isTrue);

    await tester.pumpWidget(
      MaterialApp(
        home: TerminalPage(
          workspace: workspace,
          themeController: ThemeController(InMemoryThemePreferences()),
          sftpRepository: NoNetworkSftpRepository(),
          hostKeyVerifier: NoopVerifier(),
          agentAttention: attention,
        ),
      ),
    );
    await tester.pump(PreviewReadyController.defaultStartDelay);
    await tester.pump();
    bool polledPorts(_ClosableRunner r) =>
        r.commands.any((c) => c.contains('conductore-hostd ports'));
    expect(polledPorts(runners.first), isTrue);

    // Network blip: the monitor closes its connection and makes a new one.
    await tester.runAsync(session.disconnect);
    expect(runners.first.closed, isTrue);
    runners.add(_ClosableRunner());
    await tester.runAsync(session.connect);
    await tester.pump();

    await tester.pump(PreviewReadyController.defaultInterval);
    await tester.pump();
    expect(polledPorts(runners.last), isTrue);
    // The monitor's connection is not the preview's to close.
    expect(runners.last.closed, isFalse);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 300));
  });
}
