import 'package:conduit/features/agent_attention/data/conductore_host_attention_provider.dart';
import 'package:conduit/features/agent_attention/data/herdr_attention_provider.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/agent_attention/domain/agent_kinds.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/agents_digest/presentation/agents_dashboard.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/session_navigation/domain/session_view_preferences.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

/// OpenCode agents (CON-069) in the dashboard, the approvals sheet and
/// notifications. `adapters` is the companion's capability map as it
/// reports it (host/lib/adapters capabilityMap()).
void main() {
  const adapters =
      '"adapters":{"claude":{"label":"Claude Code","events":"hooks",'
      '"approvals":"hook","always":true,"questions":true,"plans":true,'
      '"chat":"entries","send":"pane","interrupt":"pane","liveUsage":true,'
      '"limits":true,"history":true,"brain":true,"brainSchema":true,'
      '"accounts":"cswap","facts":"full","undo":true},"opencode":{"label":'
      '"OpenCode","events":"plugin","approvals":"hook","always":true,'
      '"questions":true,"plans":false,"chat":"items","send":"pane",'
      '"interrupt":"pane","liveUsage":false,"limits":false,"history":true,'
      '"brain":true,"brainSchema":false,"accounts":null,"facts":"partial",'
      '"undo":false}}';

  AgentCommandResult ok(String stdout) =>
      AgentCommandResult(stdout: stdout, stderr: '', exitCode: 0);

  AgentCommandResult status(String state, {String pending = '', int seq = 1}) =>
      ok(
        '{"version":1,"seq":$seq,"source":"daemon","agents":[{"sessionId":'
        '"ses_1","kind":"opencode","name":"proj","cwd":"/w/proj","state":'
        '"$state","pending":[$pending]}],$adapters}',
      );
  const bash =
      '{"id":"req-1","toolName":"Bash","toolKind":"bash","summary":'
      '"echo hello","toolInput":{"command":"echo hello"}}';

  test('the capability map gives OpenCode approvals, questions and chat', () {
    final catalog = AgentKindCatalog.fromJson({
      'opencode': {
        'label': 'OpenCode',
        'approvals': 'hook',
        'questions': true,
        'chat': 'items',
        'send': 'pane',
        'history': true,
      },
    })!;
    final kind = catalog.of('opencode');
    expect(kind.label, 'OpenCode');
    expect(kind.answersApprovals, isTrue);
    expect(kind.questions, isTrue);
    expect(kind.limits, isFalse);
    const agent = AgentInfo(
      id: 'ses_1',
      name: 'proj',
      project: 'proj',
      state: AgentAttentionState.working,
      kind: 'opencode',
    );
    expect(supportsChatView(agent, catalog), isTrue);
    // An older companion without the map: no Chat View for OpenCode.
    expect(supportsChatView(agent), isFalse);
  });

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
    final session = workspace.open(
      buildHost('h').copyWith(
        agentAttentionEnabled: true,
        agentMonitor: AgentMonitorKind.companion,
      ),
    );
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

  testWidgets('an OpenCode request shows with its badge and is answered '
      'from the phone', (tester) async {
    final (controller, runner) = await pumpSheet(tester, [
      status('needs_permission', pending: bash),
      ok('{"ok":true}'),
      status('working', seq: 2),
    ]);
    final agent = controller.statusFor('h')!.agents.single;
    expect(agent.kind, 'opencode');
    expect(controller.agentKinds('h').of('opencode').label, 'OpenCode');
    expect(find.text('OC'), findsWidgets);
    expect(find.text('echo hello'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Allow'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Deny'), findsOneWidget);

    await tester.tap(find.text('Allow'));
    await tester.runAsync(pumpEventQueue);
    await tester.pump();
    expect(runner.commands[1], contains('conductore-hostd decide req-1 allow'));
    expect(find.text('Allow'), findsNothing);
  });

  test(
    'an OpenCode agent that needs approval notifies like Claude Code',
    () async {
      final workspace = TerminalWorkspaceController(FreshTerminalRepository());
      final notifier = RecordingAgentNotifier();
      final controller = AgentAttentionController(
        workspace: workspace,
        runnerFactory: (_) => ScriptedAgentCommandRunner([
          ok('{"version":"0.1.0"}'),
          status('working'),
          status('needs_permission', pending: bash, seq: 2),
        ]),
        provider: const HerdrAttentionProvider(),
        companionProvider: const ConductoreHostAttentionProvider(),
        notifier: notifier,
        pollInterval: const Duration(days: 1),
      );
      controller.setLongPoll(false);
      addTearDown(controller.dispose);
      addTearDown(workspace.dispose);
      await workspace
          .open(buildHost('h').copyWith(agentAttentionEnabled: true))
          .connect();
      await pumpEventQueue();
      await controller.pollNow('h');

      final post = notifier.alerts.single;
      expect(post.text, 'Approve Bash: echo hello');
      expect(post.action?.requestId, 'req-1');
    },
  );
}
