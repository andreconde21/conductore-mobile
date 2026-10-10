import 'package:conduit/features/agent_attention/data/herdr_attention_provider.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/agents_digest/presentation/agents_dashboard.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

void main() {
  SavedHost monitoredHost(String id) =>
      buildHost(id).copyWith(agentAttentionEnabled: true);

  Future<
    (
      AgentAttentionController,
      ScriptedAgentCommandRunner,
      List<AgentInfo>,
      List<AgentInfo>,
    )
  >
  pumpSheet(
    WidgetTester tester,
    List<Object> script, {
    bool connect = true,
  }) async {
    final workspace = TerminalWorkspaceController(
      ImmediateTerminalRepository(TrackableTerminalSession()),
    );
    final runner = ScriptedAgentCommandRunner(script);
    final controller = AgentAttentionController(
      workspace: workspace,
      runnerFactory: (_) => runner,
      provider: const HerdrAttentionProvider(),
      pollInterval: const Duration(days: 1),
    );
    addTearDown(controller.dispose);
    addTearDown(workspace.dispose);
    if (connect) {
      final session = workspace.open(monitoredHost('h'));
      await tester.runAsync(session.connect);
      await tester.runAsync(pumpEventQueue);
    }
    final opened = <AgentInfo>[];
    final chats = <AgentInfo>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentsDashboardView(
            attention: controller,
            tabs: true,
            onOpenTerminal: (host, agent) => opened.add(agent),
            onOpenChat: (host, agent) => chats.add(agent),
          ),
        ),
      ),
    );
    await tester.pump();
    return (controller, runner, opened, chats);
  }

  testWidgets('shows an empty state when nothing is monitored', (tester) async {
    await pumpSheet(tester, [], connect: false);
    expect(find.textContaining('No machine reports agents'), findsOneWidget);
  });

  testWidgets('shows agents with states, kind, and machine', (tester) async {
    await pumpSheet(tester, [
      const AgentCommandResult(
        stdout:
            '[{"name": "builder", "kind": "claude-code", "state": "working",'
            ' "workspace_id": "w1", "tab_id": "w1:t2"},'
            ' {"name": "reviewer", "state": "blocked"}]',
        stderr: '',
        exitCode: 0,
      ),
    ]);

    expect(find.textContaining('builder'), findsOneWidget);
    expect(find.text('Working'), findsOneWidget);
    // The card names the machine; the Machines section the provider.
    expect(find.textContaining('· Host h'), findsNWidgets(2));
    expect(find.textContaining('reviewer'), findsOneWidget);
    // Herdr saw it waiting: it needs the user.
    expect(find.text('Asks you'), findsOneWidget);
    expect(find.text('NEEDS YOU'), findsOneWidget);
  });

  testWidgets('swipe a card to the right to mute its notifications', (
    tester,
  ) async {
    final (controller, _, _, _) = await pumpSheet(tester, [
      const AgentCommandResult(
        stdout: '[{"name": "builder", "state": "working"}]',
        stderr: '',
        exitCode: 0,
      ),
    ]);
    final agent = controller.statusFor('h')!.agents.single;
    final card = find.byKey(ValueKey('digest-card-${agent.id}'));

    await tester.drag(card, const Offset(500, 0));
    await tester.pumpAndSettle();
    expect(controller.isAgentMuted('h', agent.id), isTrue);
    // The card stays, marked muted.
    expect(card, findsOneWidget);
    expect(find.byKey(ValueKey('digest-muted-${agent.id}')), findsOneWidget);

    await tester.drag(card, const Offset(500, 0));
    await tester.pumpAndSettle();
    expect(controller.isAgentMuted('h', agent.id), isFalse);
    expect(find.byKey(ValueKey('digest-muted-${agent.id}')), findsNothing);
  });

  testWidgets('swipe a done card to the left to hide it until it changes', (
    tester,
  ) async {
    final (controller, _, _, _) = await pumpSheet(tester, [
      const AgentCommandResult(
        stdout:
            '[{"name": "builder", "state": "working"},'
            ' {"name": "lint", "state": "done"}]',
        stderr: '',
        exitCode: 0,
      ),
    ]);
    // Done long ago: under the collapsed Quiet section.
    await tester.tap(find.byKey(const ValueKey('digest-section-quiet')));
    await tester.pumpAndSettle();
    final lint = controller.statusFor('h')!.agents.last;
    final card = find.byKey(ValueKey('digest-card-${lint.id}'));
    expect(card, findsOneWidget);

    await tester.drag(card, const Offset(-500, 0));
    await tester.pumpAndSettle();
    expect(card, findsNothing);
    await tester.tap(find.byKey(const ValueKey('agents-show-hidden')));
    await tester.pumpAndSettle();
    expect(card, findsOneWidget);

    // A working agent cannot be hidden: swiping left does nothing.
    final builder = controller.statusFor('h')!.agents.first;
    final working = find.byKey(ValueKey('digest-card-${builder.id}'));
    await tester.drag(working, const Offset(-500, 0));
    await tester.pumpAndSettle();
    expect(working, findsOneWidget);
  });

  testWidgets('shows the no-agents empty state', (tester) async {
    await pumpSheet(tester, [
      const AgentCommandResult(stdout: '[]', stderr: '', exitCode: 0),
    ]);
    expect(find.textContaining('No agents in this window'), findsOneWidget);
  });

  testWidgets('shows the provider-unavailable state', (tester) async {
    await pumpSheet(tester, [
      const AgentCommandResult(
        stdout: '',
        stderr: 'sh: herdr: command not found',
        exitCode: 127,
      ),
    ]);
    expect(find.textContaining('not installed'), findsOneWidget);
  });

  testWidgets('shows the error state', (tester) async {
    await pumpSheet(tester, [StateError('connection reset')]);
    expect(find.textContaining('Could not read agent state'), findsOneWidget);
  });

  testWidgets('tapping an agent opens its terminal', (tester) async {
    final (_, _, opened, chats) = await pumpSheet(tester, [
      const AgentCommandResult(
        stdout: '[{"name": "builder", "state": "blocked"}]',
        stderr: '',
        exitCode: 0,
      ),
    ]);

    await tester.tap(find.textContaining('builder'));
    await tester.pump();

    expect(opened, hasLength(1));
    expect(opened.single.name, 'builder');
    expect(chats, isEmpty);
  });

  testWidgets('on a Herdr machine the long-press still tries the chat, and '
      'a waiting agent offers no Answer (no companion to send it)', (
    tester,
  ) async {
    final (_, _, opened, chats) = await pumpSheet(tester, [
      const AgentCommandResult(
        stdout:
            '[{"name": "builder", "kind": "claude-code", "state": "blocked",'
            ' "workspace_id": "w1", "tab_id": "w1:t2"}]',
        stderr: '',
        exitCode: 0,
      ),
    ]);
    expect(find.text('Asks you'), findsOneWidget);
    expect(find.text('Answer'), findsNothing);

    await tester.longPress(find.textContaining('builder'));
    expect(chats.single.name, 'builder');
    expect(opened, isEmpty);
  });

  testWidgets('the Usage tab keeps the machines\' status', (tester) async {
    final (controller, _, _, _) = await pumpSheet(tester, [
      const AgentCommandResult(stdout: '[]', stderr: '', exitCode: 0),
    ]);
    await tester.tap(find.text('Usage'));
    await tester.pump();
    expect(find.text('MACHINES'), findsOneWidget);
    expect(find.byTooltip('Refresh Host h'), findsOneWidget);
    expect(controller.monitoredHosts, hasLength(1));
  });
}
