import 'dart:async';

import 'package:conduit/features/agent_attention/data/conductore_host_attention_provider.dart';
import 'package:conduit/features/agent_attention/data/herdr_attention_provider.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/agent_attention/domain/agent_permission_actions.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/agent_attention/presentation/agent_permission_action_listener.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

class _QueueSource implements AgentPermissionActionSource {
  final List<AgentPermissionAction> queue = [];
  bool Function()? listener;

  @override
  Future<List<AgentPermissionAction>> consumeActions() async {
    final taken = List.of(queue);
    queue.clear();
    return taken;
  }

  @override
  void setListener(bool Function()? listener) => this.listener = listener;
}

void main() {
  const tap = AgentPermissionAction(
    notificationId: 'agent:h:s-1',
    hostId: 'h',
    requestId: 'req-1',
    agentId: 's-1',
    verdict: 'allow',
  );

  Future<
    (
      _QueueSource,
      ScriptedAgentCommandRunner,
      RecordingAgentNotifier,
      Completer<void>,
    )
  >
  pump(
    WidgetTester tester, {
    List<AgentPermissionAction> queued = const [],
  }) async {
    final source = _QueueSource()..queue.addAll(queued);
    final runner = ScriptedAgentCommandRunner([
      const AgentCommandResult(stdout: '{"ok":true}', stderr: '', exitCode: 0),
    ]);
    final notifier = RecordingAgentNotifier();
    final workspace = TerminalWorkspaceController(FreshTerminalRepository());
    final controller = AgentAttentionController(
      workspace: workspace,
      runnerFactory: (_) => runner,
      provider: const HerdrAttentionProvider(),
      companionProvider: const ConductoreHostAttentionProvider(),
      notifier: notifier,
      pollInterval: const Duration(days: 1),
    );
    addTearDown(controller.dispose);
    addTearDown(workspace.dispose);
    final hostsLoaded = Completer<void>();
    final host = buildHost('h');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentPermissionActionListener(
            source: source,
            agentAttention: controller,
            findHost: (hostId) async {
              await hostsLoaded.future;
              return hostId == host.id ? host : null;
            },
            child: const SizedBox(),
          ),
        ),
      ),
    );
    return (source, runner, notifier, hostsLoaded);
  }

  testWidgets('a tap queued before start completes once hosts are loaded', (
    tester,
  ) async {
    final (_, runner, notifier, hostsLoaded) = await pump(
      tester,
      queued: const [tap],
    );
    await tester.runAsync(pumpEventQueue);
    // Still waiting for the saved hosts: nothing sent, nothing failed.
    expect(runner.commands, isEmpty);
    expect(notifier.shown, isEmpty);

    hostsLoaded.complete();
    await tester.runAsync(pumpEventQueue);
    await tester.pump();

    expect(runner.commands.single, contains('decide req-1 allow'));
    expect(runner.closeCount, 1);
    expect(notifier.agentCancelled, ['agent:h:s-1']);
    expect(find.text('Allowed the permission request on Host h.'), findsOne);
  });

  testWidgets('a ping while mounted drains the queue and says so', (
    tester,
  ) async {
    final (source, runner, notifier, hostsLoaded) = await pump(tester);
    hostsLoaded.complete();
    source.queue.add(tap);

    expect(source.listener?.call(), isTrue);
    await tester.runAsync(pumpEventQueue);
    await tester.pump();
    expect(runner.commands.single, contains('decide req-1 allow'));
    expect(notifier.agentCancelled, ['agent:h:s-1']);

    // Unmounted (e.g. the app locked): the platform is told nobody listens.
    await tester.pumpWidget(const SizedBox());
    expect(source.listener, isNull);
  });
}
