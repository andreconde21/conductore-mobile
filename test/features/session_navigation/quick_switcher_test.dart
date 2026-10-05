import 'package:conduit/core/presentation/multiplexer_icon.dart';
import 'package:conduit/core/theme/theme_controller.dart';
import 'package:conduit/features/agent_attention/data/conductore_host_attention_provider.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_page.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/hosts/presentation/hosts_controller.dart';
import 'package:conduit/features/session_navigation/domain/session_view_preferences.dart';
import 'package:conduit/features/session_navigation/presentation/quick_switcher_actions.dart';
import 'package:conduit/features/session_navigation/presentation/quick_switcher_model.dart';
import 'package:conduit/features/session_navigation/presentation/session_view_controller.dart';
import 'package:conduit/features/sessions/domain/connect_preferences.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/sessions/presentation/session_connect_flow.dart';
import 'package:conduit/features/terminal/presentation/terminal_page.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:conduit/features/terminal/presentation/widgets/terminal_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

import '../../support/test_doubles.dart';

class _NoopWakelock extends WakelockPlusPlatformInterface {
  @override
  Future<void> toggle({required bool enable}) async {}

  @override
  Future<bool> get enabled async => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  WakelockPlusPlatformInterface.instance = _NoopWakelock();

  late ThemeController themeController;

  setUp(() async {
    themeController = ThemeController(InMemoryThemePreferences());
    await themeController.load();
  });

  final switcher = find.byKey(const ValueKey('quick-switcher'));
  final host = buildHost('a');

  SessionConnectFlow flowFor(
    TerminalWorkspaceController workspace,
    List<SavedHost> hosts,
  ) {
    final hostsController = HostsController(
      FakeHostsRepository()..persisted = hosts,
    );
    return SessionConnectFlow(
      hostsController: hostsController,
      workspace: workspace,
      runnerFactory: (_) => ScriptedAgentCommandRunner([
        const AgentCommandResult(stdout: '', stderr: '', exitCode: 0),
      ]),
      preferences: InMemoryConnectPreferencesRepository(),
    );
  }

  /// Two Herdr sessions on one machine, the second active, on a phone-sized
  /// screen.
  Future<(TerminalWorkspaceController, TrackableTerminalSession)> pumpTerminal(
    WidgetTester tester, {
    bool reduceMotion = false,
    SessionConnectFlow Function(TerminalWorkspaceController)? flow,
  }) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.6;
    addTearDown(tester.view.reset);
    final remote = TrackableTerminalSession();
    final workspace = TerminalWorkspaceController(
      ImmediateTerminalRepository(remote),
    );
    addTearDown(workspace.dispose);
    workspace
      ..open(
        const ConnectTarget.herdr(
          workspaceId: 'w1',
          label: 'Infrastructure',
        ).apply(host),
      )
      ..open(
        const ConnectTarget.herdr(
          workspaceId: 'w2',
          label: 'TheCalendar',
        ).apply(host),
      );
    final page = TerminalPage(
      workspace: workspace,
      themeController: themeController,
      sftpRepository: NoNetworkSftpRepository(),
      connectFlow: flow?.call(workspace),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: reduceMotion
            ? Builder(
                builder: (context) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(disableAnimations: true),
                  child: page,
                ),
              )
            : page,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    return (workspace, remote);
  }

  Future<void> swipeRow(WidgetTester tester, Offset by) async {
    final row = tester.getRect(find.byType(TerminalHeader));
    final gesture = await tester.startGesture(
      Offset(row.left + 90, row.center.dy),
    );
    for (var i = 0; i < 6; i += 1) {
      await gesture.moveBy(by / 6);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
  }

  Future<void> pressCtrlK(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
  }

  group('entry points', () {
    testWidgets('the Sessions button opens the switcher', (tester) async {
      await pumpTerminal(tester);
      await tester.tap(find.byTooltip('Sessions'));
      await tester.pumpAndSettle();

      expect(switcher, findsOneWidget);
      expect(find.text('OPEN SESSIONS'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('switcher-session-a#herdr:w1')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('switcher-session-a#herdr:w2')),
          matching: find.byType(MultiplexerIcon),
        ),
        findsOneWidget,
      );
    });

    testWidgets('swiping up on the top row opens it', (tester) async {
      await pumpTerminal(tester);
      await swipeRow(tester, const Offset(0, -150));
      await tester.pumpAndSettle();
      expect(switcher, findsOneWidget);
    });

    testWidgets('swiping down on the top row opens it too', (tester) async {
      await pumpTerminal(tester);
      await swipeRow(tester, const Offset(0, 150));
      await tester.pumpAndSettle();
      expect(switcher, findsOneWidget);
    });

    testWidgets('Ctrl+Shift+K opens it, focused on the search, and the session '
        'never gets the key', (tester) async {
      final (_, remote) = await pumpTerminal(tester);
      await tester.pump(const Duration(seconds: 1));
      remote.sent.clear();

      await pressCtrlK(tester);

      expect(switcher, findsOneWidget);
      final search = tester.widget<TextField>(
        find.byKey(const ValueKey('quick-switcher-search')),
      );
      expect(search.focusNode!.hasFocus, isTrue);
      expect(remote.sent.expand((bytes) => bytes), isNot(contains(0x0b)));
    });

    testWidgets('plain Ctrl+K stays with the terminal (kill to end of line)', (
      tester,
    ) async {
      final (_, remote) = await pumpTerminal(tester);
      await tester.pump(const Duration(seconds: 1));
      remote.sent.clear();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(switcher, findsNothing);
      expect(remote.sent.expand((bytes) => bytes), contains(0x0b));
    });
  });

  group('the top row', () {
    testWidgets('a horizontal swipe moves to the previous or next session', (
      tester,
    ) async {
      final (workspace, _) = await pumpTerminal(tester);
      expect(workspace.activeSession!.host.id, 'a#herdr:w2');

      await swipeRow(tester, const Offset(160, 0));
      await tester.pump(const Duration(milliseconds: 60));
      // Sliding in from the left.
      final slide = tester.widget<FractionalTranslation>(
        find
            .ancestor(
              of: find.byType(IndexedStack),
              matching: find.byType(FractionalTranslation),
            )
            .first,
      );
      expect(slide.translation.dx, lessThan(0));
      await tester.pumpAndSettle();
      expect(workspace.activeSession!.host.id, 'a#herdr:w1');

      // Nothing before the first session.
      await swipeRow(tester, const Offset(160, 0));
      await tester.pumpAndSettle();
      expect(workspace.activeSession!.host.id, 'a#herdr:w1');

      await swipeRow(tester, const Offset(-160, 0));
      await tester.pumpAndSettle();
      expect(workspace.activeSession!.host.id, 'a#herdr:w2');
      expect(switcher, findsNothing);
    });

    testWidgets('no slide with reduced motion', (tester) async {
      final (workspace, _) = await pumpTerminal(tester, reduceMotion: true);
      await swipeRow(tester, const Offset(160, 0));
      await tester.pump(const Duration(milliseconds: 60));
      final slide = tester.widget<FractionalTranslation>(
        find
            .ancestor(
              of: find.byType(IndexedStack),
              matching: find.byType(FractionalTranslation),
            )
            .first,
      );
      expect(slide.translation.dx, 0);
      expect(workspace.activeSession!.host.id, 'a#herdr:w1');
    });
  });

  group('in the switcher', () {
    testWidgets('tapping an open session shows it', (tester) async {
      final (workspace, _) = await pumpTerminal(tester);
      await tester.tap(find.byTooltip('Sessions'));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey('switcher-session-a#herdr:w1')),
      );
      await tester.pumpAndSettle();

      expect(switcher, findsNothing);
      expect(workspace.activeSession!.host.id, 'a#herdr:w1');
    });

    testWidgets('search narrows the list', (tester) async {
      await pumpTerminal(tester);
      await tester.tap(find.byTooltip('Sessions'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('quick-switcher-search')),
        'thecal',
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('switcher-session-a#herdr:w2')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('switcher-session-a#herdr:w1')),
        findsNothing,
      );

      await tester.enterText(
        find.byKey(const ValueKey('quick-switcher-search')),
        'zzz',
      );
      await tester.pump();
      expect(find.text('Nothing matches "zzz".'), findsOneWidget);
    });

    testWidgets('arrow keys and Enter open the highlighted row', (
      tester,
    ) async {
      final (workspace, _) = await pumpTerminal(tester);

      await pressCtrlK(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(switcher, findsNothing);
      expect(workspace.activeSession!.host.id, 'a#herdr:w1');

      await pressCtrlK(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(workspace.activeSession!.host.id, 'a#herdr:w2');
    });

    testWidgets('an agent needing input is listed first and opens at its '
        'session, in Chat View when that is the default', (tester) async {
      final companion = buildHost('c').copyWith(
        agentAttentionEnabled: true,
        agentMonitor: AgentMonitorKind.companion,
      );
      final workspace = TerminalWorkspaceController(
        ImmediateTerminalRepository(TrackableTerminalSession()),
      );
      final attention = AgentAttentionController(
        workspace: workspace,
        runnerFactory: (_) => ScriptedAgentCommandRunner([
          const AgentCommandResult(
            stdout:
                '{"version":1,"seq":2,"agents":[{"sessionId":"s1",'
                '"name":"s1","cwd":"/home/a/TheCalendar",'
                '"state":"waiting_input","pending":[]}]}',
            stderr: '',
            exitCode: 0,
          ),
        ]),
        provider: const ConductoreHostAttentionProvider(),
        pollInterval: const Duration(days: 1),
      );
      attention.setLongPoll(false);
      final views = SessionViewController(
        InMemorySessionViewPreferencesRepository(
          const SessionViewPreferences(defaultView: SessionView.chat),
        ),
      );
      await views.load();
      addTearDown(views.dispose);
      addTearDown(attention.dispose);
      addTearDown(workspace.dispose);
      await tester.runAsync(workspace.open(companion).connect);
      await tester.runAsync(workspace.open(buildHost('plain')).connect);
      await tester.runAsync(pumpEventQueue);
      final flow = flowFor(workspace, [companion, buildHost('plain')]);
      await tester.runAsync(flow.hostsController.load);

      await tester.pumpWidget(
        SessionViewScope(
          controller: views,
          child: MaterialApp(
            home: TerminalPage(
              workspace: workspace,
              themeController: themeController,
              sftpRepository: NoNetworkSftpRepository(),
              agentAttention: attention,
              connectFlow: flow,
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(workspace.activeSession!.host.id, 'plain');

      await tester.tap(find.byTooltip('Sessions'));
      await tester.pumpAndSettle();
      final needsYou = tester.getTopLeft(find.text('NEEDS YOU')).dy;
      final open = tester.getTopLeft(find.text('OPEN SESSIONS')).dy;
      expect(needsYou, lessThan(open));
      final row = find.byKey(const ValueKey('switcher-agent-c-s1'));
      expect(
        find.descendant(of: row, matching: find.textContaining('Host c')),
        findsOneWidget,
      );

      await tester.tap(row);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(workspace.activeSession!.host.id, 'c');
      expect(find.byType(ChatViewPage), findsOneWidget);
    });
  });

  group('open actions', () {
    Future<(TerminalWorkspaceController, SessionConnectFlow, BuildContext)>
    harness(WidgetTester tester) async {
      final workspace = TerminalWorkspaceController(
        ImmediateTerminalRepository(TrackableTerminalSession()),
      );
      addTearDown(workspace.dispose);
      workspace.open(const ConnectTarget.tmux('work').apply(host));
      final flow = flowFor(workspace, [host]);
      await tester.runAsync(flow.hostsController.load);
      await tester.pumpWidget(
        MaterialApp(home: Builder(builder: (context) => const SizedBox())),
      );
      return (workspace, flow, tester.element(find.byType(SizedBox)));
    }

    testWidgets('another tmux session opens in a new session', (tester) async {
      final (workspace, flow, context) = await harness(tester);
      var shown = 0;
      await tester.runAsync(
        () => openSwitcherItem(
          context,
          SwitcherWorkspaceItem(
            host: host,
            kind: MultiplexerKind.tmux,
            id: 'scratch',
            label: 'scratch',
          ),
          source: QuickSwitcherSource(workspace: workspace, connectFlow: flow),
          showTerminal: () => shown += 1,
        ),
      );
      expect(workspace.activeSession!.host.id, 'a#tmux:scratch');
      expect(workspace.sessions, hasLength(2));
      expect(shown, 1);
    });

    testWidgets('a tmux session already open is reused', (tester) async {
      final (workspace, flow, context) = await harness(tester);
      workspace.open(buildHost('other'));
      await tester.runAsync(
        () => openSwitcherItem(
          context,
          SwitcherWorkspaceItem(
            host: host,
            kind: MultiplexerKind.tmux,
            id: 'work',
            label: 'work',
          ),
          source: QuickSwitcherSource(workspace: workspace, connectFlow: flow),
          showTerminal: () {},
        ),
      );
      expect(workspace.activeSession!.host.id, 'a#tmux:work');
      expect(workspace.sessions, hasLength(2));
    });

    testWidgets('a recent target opens on its machine', (tester) async {
      final (workspace, flow, context) = await harness(tester);
      await tester.runAsync(
        () => openSwitcherItem(
          context,
          SwitcherRecentItem(
            host: host,
            target: const ConnectTarget.tmux('old'),
          ),
          source: QuickSwitcherSource(workspace: workspace, connectFlow: flow),
          showTerminal: () {},
        ),
      );
      expect(workspace.activeSession!.host.id, 'a#tmux:old');
    });

    testWidgets('recents come from the connect preferences', (tester) async {
      final (workspace, flow, _) = await harness(tester);
      await tester.runAsync(
        () => flow.preferences.save(
          'a',
          const ConnectPreferences().withChoice(
            const ConnectTarget.tmux('old'),
            remember: false,
          ),
        ),
      );
      final source = QuickSwitcherSource(
        workspace: workspace,
        connectFlow: flow,
      );
      final recents = (await tester.runAsync(source.loadRecents))!;
      expect(
        [for (final item in source.items(recents: recents)) item.key],
        ['session-a#tmux:work', 'recent-a-tmux:old'],
      );
    });
  });
}
