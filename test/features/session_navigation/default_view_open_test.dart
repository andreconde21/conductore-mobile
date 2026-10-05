import 'package:conduit/core/presentation/terminal_route.dart';
import 'package:conduit/core/theme/theme_controller.dart';
import 'package:conduit/features/agent_attention/data/conductore_host_attention_provider.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/app_lock/presentation/app_lock_controller.dart';
import 'package:conduit/features/backup/data/app_backup_service.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_page.dart';
import 'package:conduit/features/hosts/domain/home_preferences.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/hosts/presentation/home_board_controller.dart';
import 'package:conduit/features/hosts/presentation/hosts_controller.dart';
import 'package:conduit/features/hosts/presentation/hosts_page.dart';
import 'package:conduit/features/local_shell/presentation/local_shell_controller.dart';
import 'package:conduit/features/session_navigation/domain/session_view_preferences.dart';
import 'package:conduit/features/session_navigation/presentation/session_view_controller.dart';
import 'package:conduit/features/sessions/domain/connect_preferences.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/sessions/presentation/session_connect_flow.dart';
import 'package:conduit/features/terminal/presentation/host_key_prompt_coordinator.dart';
import 'package:conduit/features/terminal/presentation/terminal_page.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

import '../../support/test_doubles.dart';
import '../hosts/home_board_fakes.dart';

class _NoopWakelock extends WakelockPlusPlatformInterface {
  @override
  Future<void> toggle({required bool enable}) async {}

  @override
  Future<bool> get enabled async => false;
}

/// "Open Claude sessions in: Chat View" from every way a workspace,
/// session or agent is opened on the phone's home: an open session's
/// tile, a dormant Herdr workspace or tmux session (which first has to
/// connect and report its agents), the quick switcher, a notification
/// tap. Chat View opens for the Claude session of that place, never
/// another one, and the terminal stays when there is none.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  WakelockPlusPlatformInterface.instance = _NoopWakelock();

  AgentCommandResult ok(String stdout) =>
      AgentCommandResult(stdout: stdout, stderr: '', exitCode: 0);

  String herdrAgent(
    String id,
    String workspace,
    String pane, {
    String kind = 'claude',
    int updatedAt = 1790000000000,
  }) =>
      '{"sessionId":"$id","name":"$id","cwd":"/home/a/$id",'
      '"state":"working","kind":"$kind","pending":[],'
      '"updatedAt":$updatedAt,'
      '"herdr":{"workspaceId":"$workspace","tabId":"$workspace:t1",'
      '"paneId":"$pane"}}';

  String tmuxAgent(String id, String session) =>
      '{"sessionId":"$id","name":"$id","cwd":"/home/a/$id",'
      '"state":"working","kind":"claude","pending":[],'
      '"tmux":{"session":"$session","window":1}}';

  String status(List<String> agents) =>
      '{"version":1,"seq":2,"agents":[${agents.join(',')}]}';

  /// Infrastructure (w1) runs two Claude sessions, the second one worked
  /// in last; TheCalendar (w2) one; tmux "main" one.
  final everywhere = status([
    herdrAgent('infra-old', 'w1', 'w1:p1'),
    herdrAgent('infra-new', 'w1', 'w1:p2', updatedAt: 1790000900000),
    herdrAgent('calendar', 'w2', 'w2:p1'),
    tmuxAgent('tmux-main', 'main'),
  ]);

  final machine = buildHost('a').copyWith(
    lastConnectedAt: DateTime.utc(2026),
    agentAttentionEnabled: true,
    agentMonitor: AgentMonitorKind.companion,
  );

  late ThemeController themeController;
  late TerminalWorkspaceController workspace;
  late AgentAttentionController attention;
  late SessionConnectFlow flow;

  setUp(() async {
    themeController = ThemeController(InMemoryThemePreferences());
    await themeController.load();
  });

  Future<void> pumpHome(
    WidgetTester tester, {
    List<Object>? script,
    SavedHost? host,
    SessionView defaultView = SessionView.chat,
  }) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.6;
    addTearDown(tester.view.reset);
    final saved = host ?? machine;
    final hostsController = HostsController(
      FakeHostsRepository()..persisted = [saved],
    );
    workspace = TerminalWorkspaceController(
      ImmediateTerminalRepository(TrackableTerminalSession()),
    );
    addTearDown(workspace.dispose);
    attention = AgentAttentionController(
      workspace: workspace,
      runnerFactory: (_) =>
          ScriptedAgentCommandRunner(script ?? [ok(everywhere)]),
      provider: const ConductoreHostAttentionProvider(),
      pollInterval: const Duration(days: 1),
    );
    attention.setLongPoll(false);
    final runner = HerdrFakeRunner(tmuxSessions: TmuxFixtures.sessions);
    final boards = HomeBoards(
      runnerFactory: (_) => runner,
      pollInterval: const Duration(days: 1),
    );
    addTearDown(boards.dispose);
    flow = SessionConnectFlow(
      hostsController: hostsController,
      workspace: workspace,
      runnerFactory: (_) => runner,
      preferences: InMemoryConnectPreferencesRepository(),
    );
    final views = SessionViewController(
      InMemorySessionViewPreferencesRepository(
        SessionViewPreferences(defaultView: defaultView),
      ),
    );
    await views.load();
    addTearDown(views.dispose);
    final verifier = NoopVerifier();
    await tester.pumpWidget(
      SessionViewScope(
        controller: views,
        child: MaterialApp(
          home: HostsPage(
            hostsController: hostsController,
            lockController: AppLockController(AlwaysAuthenticates()),
            terminalRepository: NoNetworkTerminalRepository(),
            workspaceController: workspace,
            localShellController: LocalShellController(),
            themeController: themeController,
            hostKeyVerifier: verifier,
            promptCoordinator: HostKeyPromptCoordinator(),
            sftpRepository: NoNetworkSftpRepository(),
            sftpBookmarksRepository: InMemorySftpBookmarks(),
            agentAttention: attention,
            backupService: AppBackupService(
              hostsController: hostsController,
              themeController: themeController,
              hostKeyVerifier: verifier,
            ),
            fileExport: RecordingFileExport(),
            homeBoards: boards,
            homePreferences: InMemoryHomePreferencesRepository(),
            connectFlow: flow,
            previewRefreshInterval: const Duration(days: 1),
          ),
        ),
      ),
    );
    for (var i = 0; i < 4; i += 1) {
      await tester.pump();
    }
  }

  /// Lets a new session connect and its agent monitor report.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 3; i += 1) {
      await tester.runAsync(pumpEventQueue);
      for (var j = 0; j < 4; j += 1) {
        await tester.pump(const Duration(milliseconds: 200));
      }
    }
  }

  Future<void> tearDownHome(WidgetTester tester) async {
    await flow.herdr.dispose();
    await tester.pumpWidget(const SizedBox());
    // Stops the agent monitors' timers.
    attention.dispose();
    await tester.pump(const Duration(minutes: 1));
  }

  NavigatorState navigator(WidgetTester tester) =>
      tester.state<NavigatorState>(find.byType(Navigator).first);

  /// The agent the Chat View on top shows, or null when none is on top.
  String? chatAgent(WidgetTester tester) {
    final top = topRouteOf(navigator(tester));
    return top == null ? null : chatRouteTarget(top)?.agentId;
  }

  testWidgets('an open workspace\'s tile: Chat View for its Claude session, '
      'the one worked in last of several', (tester) async {
    await pumpHome(tester);
    final session = workspace.open(
      const ConnectTarget.herdr(workspaceId: 'w1').apply(machine),
    );
    await tester.runAsync(session.connect);
    await settle(tester);
    expect(attention.statusFor(session.host.id)?.agents, hasLength(4));

    await tester.tap(find.byKey(ValueKey('home-session-${session.host.id}')));
    await settle(tester);

    expect(find.byType(ChatViewPage), findsOneWidget);
    expect(chatAgent(tester), 'infra-new');
    await tearDownHome(tester);
  });

  testWidgets('a restored session that has not reconnected yet: Chat View '
      'once it has', (tester) async {
    await pumpHome(tester);
    final session = workspace.open(
      const ConnectTarget.herdr(workspaceId: 'w2').apply(machine),
    );
    await tester.pump();
    expect(session.isConnected, isFalse);

    await tester.tap(find.byKey(ValueKey('home-session-${session.host.id}')));
    await settle(tester);

    expect(session.isConnected, isTrue);
    expect(chatAgent(tester), 'calendar');
    await tearDownHome(tester);
  });

  testWidgets('a dormant Herdr workspace: Chat View once it has connected '
      'and its agent is known; back goes home', (tester) async {
    await pumpHome(tester);
    expect(workspace.sessions, isEmpty);
    final tile = find.byKey(const ValueKey('other-herdr-a-w2'));
    await tester.scrollUntilVisible(tile, 200);

    await tester.tap(tile);
    await tester.pump();
    // Not connected yet: nothing to show in Chat View so far.
    expect(find.byType(ChatViewPage), findsNothing);
    await settle(tester);

    final session = workspace.activeSession!;
    expect(session.host.id, startsWith('a#herdr:w2'));
    expect(session.isConnected, isTrue);
    expect(find.byType(ChatViewPage), findsOneWidget);
    expect(chatAgent(tester), 'calendar');

    // Back leaves the terminal under it too.
    await navigator(tester).maybePop();
    await settle(tester);
    expect(find.byType(ChatViewPage), findsNothing);
    expect(find.byType(TerminalPage), findsNothing);
    await tearDownHome(tester);
  });

  testWidgets('a dormant tmux session: Chat View for the Claude session in '
      'it', (tester) async {
    await pumpHome(tester);
    final tile = find.byKey(const ValueKey('other-tmux-a-main'));
    await tester.scrollUntilVisible(tile, 200);

    await tester.tap(tile);
    await settle(tester);

    expect(workspace.activeSession!.host.id, 'a#tmux:main');
    expect(chatAgent(tester), 'tmux-main');
    await tearDownHome(tester);
  });

  testWidgets('a pane picked from a dormant workspace: that pane\'s Claude '
      'session', (tester) async {
    await pumpHome(tester);
    final tile = find.byKey(const ValueKey('other-herdr-a-w1'));
    await tester.scrollUntilVisible(tile, 200);

    await tester.longPress(tile);
    await tester.pumpAndSettle();
    // Herdr's pane w1:p1 is also the companion's infra-old.
    await tester.tap(find.byKey(const ValueKey('pane-w1:p1')));
    await settle(tester);

    expect(chatAgent(tester), 'infra-old');
    await tearDownHome(tester);
  });

  testWidgets('the quick switcher\'s workspace opens in Chat View', (
    tester,
  ) async {
    await pumpHome(tester);

    await tester.tap(find.byTooltip('Switch sessions'));
    await settle(tester);
    await tester.tap(
      find.byKey(const ValueKey('switcher-workspace-a-herdr-w2')),
    );
    await settle(tester);

    expect(workspace.activeSession!.host.id, startsWith('a#herdr:w2'));
    expect(chatAgent(tester), 'calendar');
    await tearDownHome(tester);
  });

  testWidgets('a notification tap opens that agent in Chat View', (
    tester,
  ) async {
    await pumpHome(tester);

    await flow.openAgent(
      machine,
      const AgentInfo(
        id: 'infra-old',
        name: 'infra-old',
        state: AgentAttentionState.working,
        kind: 'claude',
        workspace: 'w1',
        tab: 'w1:t1',
        pane: 'w1:p1',
      ),
      preferredView: true,
    );
    await settle(tester);

    expect(workspace.activeSession!.host.id, startsWith('a#herdr:w1'));
    // Its own agent, not the workspace's most recent one.
    expect(chatAgent(tester), 'infra-old');
    await tearDownHome(tester);
  });

  testWidgets('a workspace without a Claude session stays in the terminal', (
    tester,
  ) async {
    await pumpHome(
      tester,
      script: [
        ok(
          status([
            herdrAgent('infra', 'w1', 'w1:p1'),
            herdrAgent('e2e', 'w2', 'w2:p1', kind: 'codex'),
          ]),
        ),
      ],
    );
    final tile = find.byKey(const ValueKey('other-herdr-a-w2'));
    await tester.scrollUntilVisible(tile, 200);

    await tester.tap(tile);
    await settle(tester);
    await tester.pump(const Duration(seconds: 20));

    expect(find.byType(TerminalPage), findsOneWidget);
    expect(find.byType(ChatViewPage), findsNothing);
    await tearDownHome(tester);
  });

  testWidgets('a machine without the companion stays in the terminal', (
    tester,
  ) async {
    await pumpHome(
      tester,
      host: machine.copyWith(agentAttentionEnabled: false),
    );
    final tile = find.byKey(const ValueKey('other-herdr-a-w2'));
    await tester.scrollUntilVisible(tile, 200);

    await tester.tap(tile);
    await settle(tester);

    expect(find.byType(TerminalPage), findsOneWidget);
    expect(find.byType(ChatViewPage), findsNothing);
    await tearDownHome(tester);
  });

  testWidgets('left before the agent is known: no Chat View afterwards', (
    tester,
  ) async {
    // The first poll fails; the agent only shows on the next one.
    await pumpHome(tester, script: [StateError('not yet'), ok(everywhere)]);
    final tile = find.byKey(const ValueKey('other-herdr-a-w2'));
    await tester.scrollUntilVisible(tile, 200);
    await tester.tap(tile);
    await settle(tester);
    final session = workspace.activeSession!;
    expect(find.byType(ChatViewPage), findsNothing);

    await navigator(tester).maybePop();
    await settle(tester);
    expect(find.byType(TerminalPage), findsNothing);
    await tester.runAsync(() => attention.refresh(session.host.id));
    await settle(tester);

    expect(attention.statusFor(session.host.id)?.agents, hasLength(4));
    expect(find.byType(ChatViewPage), findsNothing);
    await tearDownHome(tester);
  });

  testWidgets('with the Terminal default nothing waits for agents', (
    tester,
  ) async {
    await pumpHome(tester, defaultView: SessionView.terminal);
    final tile = find.byKey(const ValueKey('other-herdr-a-w2'));
    await tester.scrollUntilVisible(tile, 200);

    await tester.tap(tile);
    await settle(tester);

    expect(find.byType(TerminalPage), findsOneWidget);
    expect(find.byType(ChatViewPage), findsNothing);
    await tearDownHome(tester);
  });
}
