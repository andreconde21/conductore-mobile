import 'package:conduit/features/agent_attention/data/conductore_host_attention_provider.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/agents_digest/presentation/agents_dashboard.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

void main() {
  SavedHost monitoredHost(String id) => buildHost(id).copyWith(
    agentAttentionEnabled: true,
    agentMonitor: AgentMonitorKind.companion,
  );

  AgentCommandResult ok(String stdout) =>
      AgentCommandResult(stdout: stdout, stderr: '', exitCode: 0);

  final pending = ok(
    '{"version":1,"seq":2,"agents":[{"sessionId":"s-1","name":"api",'
    '"cwd":"/home/a/api","state":"needs_permission","pending":[{"id":"req-1",'
    '"toolName":"Bash","summary":"rm -rf build","toolInput":{"command":'
    '"rm -rf build","description":"Clean the build dir"}}]}]}',
  );
  final working = ok(
    '{"version":1,"seq":3,"agents":[{"sessionId":"s-1","name":"api",'
    '"cwd":"/home/a/api","state":"working","pending":[]}]}',
  );

  Future<(AgentAttentionController, ScriptedAgentCommandRunner)> pumpSheet(
    WidgetTester tester,
    List<Object> script,
  ) async {
    final workspace = TerminalWorkspaceController(
      ImmediateTerminalRepository(TrackableTerminalSession()),
    );
    final runner = ScriptedAgentCommandRunner(script);
    final controller = AgentAttentionController(
      workspace: workspace,
      runnerFactory: (_) => runner,
      provider: const ConductoreHostAttentionProvider(),
      pollInterval: const Duration(days: 1),
    );
    controller.setLongPoll(false);
    addTearDown(controller.dispose);
    addTearDown(workspace.dispose);
    final session = workspace.open(monitoredHost('h'));
    await tester.runAsync(session.connect);
    await tester.runAsync(pumpEventQueue);
    final digest = monitorOnlyDigest();
    addTearDown(digest.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentsDashboardView(
            controller: digest,
            attention: controller,
            tabs: true,
            onOpenTerminal: (host, agent) {},
            onOpenChat: (host, agent) {},
          ),
        ),
      ),
    );
    await tester.pump();
    return (controller, runner);
  }

  testWidgets('shows the pending request with its buttons', (tester) async {
    await pumpSheet(tester, [pending]);

    expect(find.text('NEEDS YOU'), findsOneWidget);
    expect(find.text('Needs approval'), findsOneWidget);
    expect(find.textContaining('Conductore companion'), findsOneWidget);
    expect(find.text('Bash'), findsOneWidget);
    expect(find.text('rm -rf build'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Allow'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Deny'), findsOneWidget);
    expect(find.text('Always'), findsOneWidget);

    // The tool input is hidden until asked for.
    expect(find.textContaining('Clean the build dir'), findsNothing);
    await tester.tap(find.text('Tool input'));
    await tester.pump();
    expect(find.textContaining('Clean the build dir'), findsOneWidget);
    await tester.tap(find.text('Hide input'));
    await tester.pump();
    expect(find.textContaining('Clean the build dir'), findsNothing);
  });

  testWidgets('Allow sends the decision and removes the request', (
    tester,
  ) async {
    final (_, runner) = await pumpSheet(tester, [
      pending,
      ok('{"ok":true}'),
      working,
    ]);

    await tester.tap(find.text('Allow'));
    await tester.runAsync(pumpEventQueue);
    await tester.pump();

    expect(runner.commands[1], contains('conductore-hostd decide req-1 allow'));
    expect(find.text('Allow'), findsNothing);
    expect(find.text('Working'), findsOneWidget);
  });

  testWidgets('a failed decision shows a snackbar and keeps the buttons', (
    tester,
  ) async {
    await pumpSheet(tester, [
      pending,
      const AgentCommandResult(
        stdout: '{"error":"daemon not reachable"}',
        stderr: '',
        exitCode: 1,
      ),
    ]);

    await tester.tap(find.text('Deny'));
    await tester.runAsync(pumpEventQueue);
    await tester.pump();

    expect(find.textContaining('Could not deny Bash'), findsOneWidget);
    expect(find.text('Allow'), findsOneWidget);
  });

  final inTerminal = ok(
    '{"version":1,"seq":4,"agents":[{"sessionId":"s-1","name":"api",'
    '"cwd":"/home/a/api","state":"needs_permission","lastMessage":'
    '"Permission prompt is waiting in the terminal","pending":[]}]}',
  );

  testWidgets('a prompt the phone missed still needs you, without buttons', (
    tester,
  ) async {
    final (controller, _) = await pumpSheet(tester, [inTerminal]);
    // Still a prompt: it needs the user, and the badge counts it.
    expect(controller.attentionCount, 1);
    expect(find.text('NEEDS YOU'), findsOneWidget);
    expect(find.text('Needs approval'), findsOneWidget);
    expect(find.text('Answer'), findsNothing);

    expect(
      find.text('Permission prompt is waiting in the terminal'),
      findsOneWidget,
    );
    expect(find.text('Allow'), findsNothing);
  });

  testWidgets('an expired request explains itself and drops the buttons', (
    tester,
  ) async {
    await pumpSheet(tester, [
      pending,
      const AgentCommandResult(
        stdout: '{"error":"request expired; answer it in the terminal"}',
        stderr: '',
        exitCode: 1,
      ),
      inTerminal,
    ]);

    await tester.tap(find.text('Allow'));
    await tester.runAsync(pumpEventQueue);
    await tester.pump();

    expect(find.textContaining('answer it in the terminal'), findsWidgets);
    expect(find.text('Allow'), findsNothing);
    // Still at the prompt in the terminal.
    expect(find.text('Needs approval'), findsOneWidget);
  });
}
