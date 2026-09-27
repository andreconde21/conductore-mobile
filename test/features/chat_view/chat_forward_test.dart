import 'dart:async';

import 'package:conduit/features/agent_attention/data/conductore_host_attention_provider.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/chat_view/presentation/chat_forward.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_page.dart';
import 'package:conduit/features/chat_view/presentation/widgets/chat_thread_items.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

/// Records what `send` typed (sends pass the text on stdin).
class _Runner extends ScriptedAgentCommandRunner
    implements StdinAgentCommandRunner {
  _Runner(super.script);

  final List<(String, String)> sent = [];

  @override
  Future<AgentCommandResult> runWithStdin(
    String command, {
    required String stdin,
    required Duration timeout,
    Future<void>? cancel,
  }) async {
    sent.add((command, stdin));
    return ok('{}');
  }
}

AgentCommandResult ok(String stdout) =>
    AgentCommandResult(stdout: stdout, stderr: '', exitCode: 0);

/// "Send to another agent": which sessions are offered, and the default
/// send, which opens the target's chat and sends there.
void main() {
  final status = ok(
    '{"version":1,"seq":2,"agents":['
    '{"sessionId":"s-1","name":"api","state":"working","kind":"claude",'
    '"pending":[]},'
    '{"sessionId":"s-2","name":"web","state":"idle","kind":"claude",'
    '"pending":[]},'
    '{"sessionId":"s-3","name":"cx","state":"idle","kind":"codex",'
    '"pending":[]}]}',
  );
  final runners = <_Runner>[];

  Future<(AgentAttentionController, SavedHost)> monitor(
    WidgetTester tester,
  ) async {
    runners.clear();
    final workspace = TerminalWorkspaceController(
      ImmediateTerminalRepository(TrackableTerminalSession()),
    );
    final controller = AgentAttentionController(
      workspace: workspace,
      runnerFactory: (_) {
        final runner = _Runner([status]);
        runners.add(runner);
        return runner;
      },
      provider: const ConductoreHostAttentionProvider(),
      pollInterval: const Duration(days: 1),
    );
    controller.setAppForeground(false);
    addTearDown(controller.dispose);
    addTearDown(workspace.dispose);
    final session = workspace.open(
      buildHost('h').copyWith(
        agentAttentionEnabled: true,
        agentMonitor: AgentMonitorKind.companion,
      ),
    );
    await tester.runAsync(session.connect);
    await tester.runAsync(pumpEventQueue);
    return (controller, controller.monitoredHosts.single);
  }

  testWidgets('offers the other Claude sessions, not this one', (tester) async {
    final (attention, host) = await monitor(tester);
    final targets = chatForwardTargets(
      attention,
      sessionId: 's-1',
      hostId: host.id,
    );
    expect([for (final t in targets) t.agent.id], ['s-2']);
  });

  testWidgets('the default send opens the target chat and sends there', (
    tester,
  ) async {
    final (attention, host) = await monitor(tester);
    final target = chatForwardTargets(
      attention,
      sessionId: 's-1',
      hostId: host.id,
    ).single;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => unawaited(
              forwardToAgentChat(
                context,
                attention,
                target,
                'From api on h:\n> hello',
              ),
            ),
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    for (var i = 0; i < 6; i += 1) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    addTearDown(() => tester.pumpWidget(const SizedBox()));
    expect(find.byType(ChatViewPage), findsOneWidget);
    // The prompt shows as that chat's pending bubble.
    expect(find.byType(ChatOutgoingBubble), findsOneWidget);
    final sent = [for (final r in runners) ...r.sent];
    expect(sent, hasLength(1));
    expect(sent.single.$1, contains('s-2'));
    expect(sent.single.$2, contains('From api on h:\n> hello'));
  });
}
