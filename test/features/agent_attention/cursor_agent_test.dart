import 'dart:io';

import 'package:conduit/features/agent_attention/data/conductore_host_attention_provider.dart';
import 'package:conduit/features/agent_attention/data/herdr_attention_provider.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/agent_attention/domain/agent_kinds.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_sheet.dart';
import 'package:conduit/features/agent_attention/presentation/widgets/approval_widgets.dart';
import 'package:conduit/features/chat_view/domain/chat_items.dart';
import 'package:conduit/features/chat_view/domain/chat_transcript.dart';
import 'package:conduit/features/chat_view/domain/neutral_chat_items.dart';
import 'package:conduit/features/chat_view/presentation/widgets/chat_thread_items.dart';
import 'package:conduit/features/companion_setup/domain/companion_status.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/session_navigation/domain/session_view_preferences.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

/// Cursor CLI agents (CON-073) in the dashboard, the approvals sheet,
/// notifications and Chat View. Cursor's hooks cannot allow a command, so
/// its permission prompts reach the phone watch-only (`answerable:
/// false`). `adapters` is what the companion reports
/// (host/lib/adapters capabilityMap()).
void main() {
  const adapters =
      '"adapters":{"claude":{"label":"Claude Code","events":"hooks",'
      '"approvals":"hook","always":true,"questions":true,"plans":true,'
      '"chat":"entries","send":"pane","interrupt":"pane","liveUsage":true,'
      '"limits":true,"history":true,"brain":true,"brainSchema":true,'
      '"accounts":"cswap","facts":"full","undo":true},"cursor":{"label":'
      '"Cursor","events":"hooks","approvals":"observe","always":false,'
      '"questions":false,"plans":false,"chat":"items","send":"pane",'
      '"interrupt":"pane","liveUsage":false,"limits":false,"history":false,'
      '"brain":false,"brainSchema":false,"accounts":null,"facts":"partial",'
      '"undo":true,"launch":"cursor-agent"}}';

  AgentCommandResult ok(String stdout) =>
      AgentCommandResult(stdout: stdout, stderr: '', exitCode: 0);

  AgentCommandResult status(String state, {String pending = '', int seq = 1}) =>
      ok(
        '{"version":1,"seq":$seq,"source":"daemon","agents":[{"sessionId":'
        '"c-1","kind":"cursor","name":"proj","cwd":"/w/proj","state":'
        '"$state","pending":[$pending]}],$adapters}',
      );
  // What the companion reports for Cursor's "Run this command?".
  const watched =
      '{"id":"req-1","toolName":"Bash","toolKind":"bash","answerable":false,'
      '"summary":"echo hello-from-cursor","toolInput":{"command":'
      '"echo hello-from-cursor"},"risk":{"level":"low","reason":"Read-only"},'
      '"batchable":true,"suggestedRules":["Bash(echo *)"]}';

  test('Cursor is named, watch-only, and its doctor checks are optional', () {
    final catalog = AgentKindCatalog.fromJson({
      'cursor': {
        'label': 'Cursor',
        'approvals': 'observe',
        'chat': 'items',
        'send': 'pane',
      },
    })!;
    final kind = catalog.of('cursor');
    expect(kind.answersApprovals, isFalse);
    expect(otherAgentKindName('cursor'), 'Cursor');
    const agent = AgentInfo(
      id: 'c-1',
      name: 'proj',
      project: 'proj',
      state: AgentAttentionState.working,
      kind: 'cursor',
    );
    expect(supportsChatView(agent, catalog), isTrue);
    expect(
      const CompanionDoctorCheck(
        name: 'cursor hooks',
        ok: false,
        detail: 'missing',
      ).optional,
      isTrue,
    );
  });

  test('a request with answerable false is watch-only: no batch, no trust', () {
    final parsed = ConductoreHostAttentionProvider.parseSnapshot(
      '{"version":1,"seq":1,"source":"daemon","agents":[{"sessionId":'
      '"c-1","kind":"cursor","name":"proj","state":"needs_permission",'
      '"pending":[$watched]}]}',
    );
    final request = parsed.agents.single.pendingRequests.single;
    expect(request.terminalOnly, isTrue);
    expect(request.batchable, isFalse);
    expect(request.trustable, isFalse);
    // Claude Code's requests never carry the flag.
    final claudeRequest = watched.replaceFirst('"answerable":false,', '');
    final claude = ConductoreHostAttentionProvider.parseSnapshot(
      '{"version":1,"seq":1,"source":"daemon","agents":[{"sessionId":'
      '"s-1","name":"api","state":"needs_permission","pending":'
      '[$claudeRequest]}]}',
    );
    expect(claude.agents.single.pendingRequests.single.terminalOnly, isFalse);
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
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentAttentionSheet(
            controller: controller,
            onOpenAgent: (host, agent) {},
          ),
        ),
      ),
    );
    await tester.pump();
    return (controller, runner);
  }

  testWidgets('a Cursor request shows with its badge and says to answer it '
      'in the terminal, with no buttons', (tester) async {
    final (controller, runner) = await pumpSheet(tester, [
      status('needs_permission', pending: watched),
    ]);
    final agent = controller.statusFor('h')!.agents.single;
    expect(agent.kind, 'cursor');
    expect(controller.agentKinds('h').of('cursor').label, 'Cursor');
    expect(find.text('CU'), findsWidgets);
    expect(find.text('echo hello-from-cursor'), findsOneWidget);
    expect(find.byType(TerminalOnlyNote), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Allow'), findsNothing);
    expect(find.widgetWithText(OutlinedButton, 'Deny'), findsNothing);
    expect(find.text('Trust…'), findsNothing);
    expect(runner.commands, hasLength(1));
  });

  test('a Cursor agent waiting in its terminal notifies, without an Allow '
      'action', () async {
    final workspace = TerminalWorkspaceController(FreshTerminalRepository());
    final notifier = RecordingAgentNotifier();
    final controller = AgentAttentionController(
      workspace: workspace,
      runnerFactory: (_) => ScriptedAgentCommandRunner([
        ok('{"version":"0.1.0"}'),
        status('working'),
        status('needs_permission', pending: watched, seq: 2),
      ]),
      provider: const HerdrAttentionProvider(),
      companionProvider: const ConductoreHostAttentionProvider(),
      notifier: notifier,
      pollInterval: const Duration(days: 1),
    );
    controller.setAppForeground(false);
    addTearDown(controller.dispose);
    addTearDown(workspace.dispose);
    await workspace
        .open(buildHost('h').copyWith(agentAttentionEnabled: true))
        .connect();
    await pumpEventQueue();
    await controller.pollNow('h');

    final post = notifier.alerts.single;
    expect(post.title, contains('(Cursor)'));
    expect(
      post.text,
      'Approve Bash in the terminal: echo hello-from-cursor · Low risk',
    );
    expect(post.action, isNull);
  });

  testWidgets('Chat View shows a watch-only request without buttons', (
    tester,
  ) async {
    const request = PendingPermissionRequest(
      id: 'req-1',
      toolName: 'Bash',
      summary: 'echo hello-from-cursor',
      terminalOnly: true,
    );
    final decided = <PermissionVerdict>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatApprovalCard(
            request: request,
            busy: false,
            onDecide: decided.add,
            onTrust: () {},
          ),
        ),
      ),
    );
    expect(find.text('Bash is waiting for approval'), findsOneWidget);
    expect(find.byType(TerminalOnlyNote), findsOneWidget);
    expect(find.text('Allow'), findsNothing);
    expect(find.text('Trust…'), findsNothing);
  });

  test('the real Cursor chat page parses as neutral items', () {
    // What the companion's Cursor adapter reads from a real Cursor
    // 2026.10.01 session (host/test/cursor-adapter.test.js keeps it so).
    final raw = File(
      'test/fixtures/agent_adapters/cursor_chat_page.json',
    ).readAsStringSync();
    final page = TranscriptParser.parsePage(raw);
    expect(page.isNeutral, isTrue);
    expect(page.cursor, 'L7');
    expect(page.startCursor, isNull);
    final items = NeutralChatItems.parse(page.neutralItems!);
    expect(items.map((i) => i.runtimeType), [
      ChatUserMessage,
      ChatAssistantText,
      ChatToolCall,
      ChatAssistantText,
      ChatUserMessage,
      ChatAssistantText,
      ChatToolCall,
      ChatAssistantText,
    ]);
    expect((items.first as ChatUserMessage).text, 'run the echo command');
    final shell = items[2] as ChatToolCall;
    expect(shell.name, 'Shell');
    expect(shell.result?.isError, isFalse);
  });
}
