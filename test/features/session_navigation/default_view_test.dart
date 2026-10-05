import 'package:conduit/core/theme/theme_controller.dart';
import 'package:conduit/features/agent_attention/data/conductore_host_attention_provider.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_page.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/session_navigation/domain/session_view_preferences.dart';
import 'package:conduit/features/session_navigation/presentation/session_view_controller.dart';
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

/// Opening a session honours "Open Claude sessions in" and the session's
/// own choice: Chat View only for a pane running Claude.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  WakelockPlusPlatformInterface.instance = _NoopWakelock();

  AgentCommandResult ok(String stdout) =>
      AgentCommandResult(stdout: stdout, stderr: '', exitCode: 0);

  String status({String kind = 'claude'}) =>
      '{"version":1,"seq":2,"agents":[{"sessionId":"a","name":"a",'
      '"cwd":"/home/a/p","state":"working","kind":"$kind","pending":[]}]}';

  SavedHost companion(String id) => buildHost(id).copyWith(
    agentAttentionEnabled: true,
    agentMonitor: AgentMonitorKind.companion,
  );

  late ThemeController themeController;

  setUp(() async {
    themeController = ThemeController(InMemoryThemePreferences());
    await themeController.load();
  });

  /// Two monitored sessions, "Host one" then "Host two" (active).
  Future<(TerminalWorkspaceController, SessionViewController)> pumpPage(
    WidgetTester tester, {
    SessionView defaultView = SessionView.terminal,
    Map<String, SessionView> overrides = const {},
    String kind = 'claude',
  }) async {
    final workspace = TerminalWorkspaceController(
      ImmediateTerminalRepository(TrackableTerminalSession()),
    );
    final attention = AgentAttentionController(
      workspace: workspace,
      runnerFactory: (_) =>
          ScriptedAgentCommandRunner([ok(status(kind: kind))]),
      provider: const ConductoreHostAttentionProvider(),
      pollInterval: const Duration(days: 1),
    );
    attention.setLongPoll(false);
    final views = SessionViewController(
      InMemorySessionViewPreferencesRepository(
        SessionViewPreferences(defaultView: defaultView, overrides: overrides),
      ),
    );
    await views.load();
    addTearDown(views.dispose);
    addTearDown(attention.dispose);
    addTearDown(workspace.dispose);
    for (final id in ['one', 'two']) {
      final session = workspace.open(companion(id));
      await tester.runAsync(session.connect);
    }
    await tester.runAsync(pumpEventQueue);
    await tester.pumpWidget(
      SessionViewScope(
        controller: views,
        child: MaterialApp(
          home: TerminalPage(
            workspace: workspace,
            themeController: themeController,
            sftpRepository: NoNetworkSftpRepository(),
            agentAttention: attention,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    return (workspace, views);
  }

  Future<void> tapTab(WidgetTester tester, String label) async {
    await tester.tap(find.text(label));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('the terminal by default', (tester) async {
    final (workspace, _) = await pumpPage(tester);
    await tapTab(tester, 'Host one');
    expect(workspace.activeSession!.host.id, 'one');
    expect(find.byType(ChatViewPage), findsNothing);
  });

  testWidgets('Chat View when the default is Chat View', (tester) async {
    await pumpPage(tester, defaultView: SessionView.chat);
    await tapTab(tester, 'Host one');
    expect(find.byType(ChatViewPage), findsOneWidget);
  });

  testWidgets('a session set to Terminal ignores the Chat View default', (
    tester,
  ) async {
    await pumpPage(
      tester,
      defaultView: SessionView.chat,
      overrides: {'one': SessionView.terminal},
    );
    await tapTab(tester, 'Host one');
    expect(find.byType(ChatViewPage), findsNothing);
  });

  testWidgets('a session set to Chat View opens it on a Terminal default', (
    tester,
  ) async {
    await pumpPage(tester, overrides: {'one': SessionView.chat});
    await tapTab(tester, 'Host one');
    expect(find.byType(ChatViewPage), findsOneWidget);
  });

  testWidgets('a pane running another agent opens the terminal', (
    tester,
  ) async {
    await pumpPage(tester, defaultView: SessionView.chat, kind: 'codex');
    await tapTab(tester, 'Host one');
    expect(find.byType(ChatViewPage), findsNothing);
  });

  testWidgets('long-press on a tab sets the session\'s own view', (
    tester,
  ) async {
    final (_, views) = await pumpPage(tester);
    await tester.longPress(find.text('Host one'));
    await tester.pumpAndSettle();
    expect(find.text('Always open in Chat View'), findsOneWidget);
    await tester.tap(find.text('Always open in Chat View'));
    await tester.pumpAndSettle();
    expect(views.overrideFor('one'), SessionView.chat);
    expect(views.overrideFor('two'), isNull);

    await tester.longPress(find.text('Host one'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use default (Terminal)'));
    await tester.pumpAndSettle();
    expect(views.overrideFor('one'), isNull);
  });
}
