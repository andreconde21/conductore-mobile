import 'package:conduit/core/app_failure.dart';
import 'package:conduit/features/agent_attention/data/herdr_attention_provider.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/chat_view/data/attention_host_runner.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_controller.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

/// Like SshAgentCommandRunner: unusable once closed.
class _ClosableRunner implements AgentCommandRunner {
  bool closed = false;
  int runs = 0;
  @override
  Future<AgentCommandResult> run(
    String command, {
    required Duration timeout,
  }) async {
    if (closed) throw const AppFailure('This connection is closed.');
    runs += 1;
    return const AgentCommandResult(stdout: '[]', stderr: '', exitCode: 0);
  }

  @override
  Future<void> close() async => closed = true;
}

void main() {
  test(
    'a chat open across a reconnect uses the new monitor connection',
    () async {
      final workspace = TerminalWorkspaceController(
        CompletingTerminalRepository(),
      );
      final runners = <_ClosableRunner>[];
      final attention = AgentAttentionController(
        workspace: workspace,
        runnerFactory: (_) => runners.last,
        provider: const HerdrAttentionProvider(),
        pollInterval: const Duration(days: 1),
      );
      runners.add(_ClosableRunner());
      final host = buildHost('h').copyWith(agentAttentionEnabled: true);
      final session = workspace.open(host);
      await session.connect();
      await pumpEventQueue();
      expect(attention.isMonitoring(host.id), isTrue);

      final runner = AttentionHostRunner(attention, session.host);
      final chat = ChatViewController(
        runner: runner,
        ownsRunner: true,
        sessionId: 's1',
        pollInterval: const Duration(days: 1),
      );

      // Network blip: the session drops and is reconnected.
      await session.disconnect();
      expect(runners.first.closed, isTrue);
      runners.add(_ClosableRunner());
      await session.connect();
      await pumpEventQueue();

      chat.setVisible(true);
      await chat.refresh();
      // The fake answers an empty list, which the chat rejects as a
      // transcript; what matters is that it reached the new connection.
      expect(chat.error, isNot(contains('closed')));
      expect(runners.last.runs, greaterThan(0));

      chat.dispose();
      await pumpEventQueue();
      // The monitor's connection is not the chat's to close.
      expect(runners.last.closed, isFalse);
      attention.dispose();
      workspace.dispose();
    },
  );

  test(
    'an unmonitored host gets one connection, closed with the runner',
    () async {
      final workspace = TerminalWorkspaceController(
        CompletingTerminalRepository(),
      );
      var created = 0;
      final own = _ClosableRunner();
      final attention = AgentAttentionController(
        workspace: workspace,
        runnerFactory: (_) {
          created += 1;
          return own;
        },
        provider: const HerdrAttentionProvider(),
        pollInterval: const Duration(days: 1),
      );
      final runner = AttentionHostRunner(attention, buildHost('h'));
      await runner.run('true', timeout: const Duration(seconds: 1));
      await runner.run('true', timeout: const Duration(seconds: 1));
      expect(created, 1);
      await runner.close();
      expect(own.closed, isTrue);
      attention.dispose();
      workspace.dispose();
    },
  );
}
