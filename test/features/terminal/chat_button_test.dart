import 'package:conduit/core/presentation/terminal_route.dart';
import 'package:conduit/core/theme/terminal_pill_items.dart';
import 'package:conduit/core/theme/theme_controller.dart';
import 'package:conduit/features/agent_attention/data/conductore_host_attention_provider.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_launcher.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_page.dart';
import 'package:conduit/features/companion_setup/presentation/companion_setup_controller.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/terminal/presentation/terminal_page.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:conduit_vt/conduit_vt.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

import '../../support/test_doubles.dart';
import '../chat_view/live_status_fixture.dart';
import '../companion_setup/companion_fakes.dart' as fakes;
import '../voice/fake_speech_recognizer.dart';

/// The floating pill's Chat button: Chat View for a Claude session the
/// companion knows, else the inline composer, which must take over at once.
class _NoopWakelock extends WakelockPlusPlatformInterface {
  @override
  Future<void> toggle({required bool enable}) async {}

  @override
  Future<bool> get enabled async => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The page toggles the wakelock; runAsync below would reach the real
  // (absent) platform channel.
  WakelockPlusPlatformInterface.instance = _NoopWakelock();

  AgentCommandResult ok(String stdout) =>
      AgentCommandResult(stdout: stdout, stderr: '', exitCode: 0);

  String agent(String id, {String extra = '', String state = 'working'}) =>
      '{"sessionId":"$id","name":"$id","cwd":"/home/a/$id",'
      '"state":"$state","pending":[]$extra}';

  String status(List<String> agents) =>
      '{"version":1,"seq":2,"agents":[${agents.join(',')}]}';

  SavedHost companion(SavedHost host) => host.copyWith(
    agentAttentionEnabled: true,
    agentMonitor: AgentMonitorKind.companion,
  );

  late ThemeController themeController;

  setUp(() async {
    themeController = ThemeController(InMemoryThemePreferences());
    await themeController.load();
  });

  Future<(AgentAttentionController, TerminalWorkspaceController)> monitor(
    WidgetTester tester,
    SavedHost host,
    String statusJson,
  ) async {
    final workspace = TerminalWorkspaceController(
      ImmediateTerminalRepository(TrackableTerminalSession()),
    );
    final controller = AgentAttentionController(
      workspace: workspace,
      runnerFactory: (_) => ScriptedAgentCommandRunner([ok(statusJson)]),
      provider: const ConductoreHostAttentionProvider(),
      pollInterval: const Duration(days: 1),
    );
    controller.setAppForeground(false);
    addTearDown(controller.dispose);
    addTearDown(workspace.dispose);
    final session = workspace.open(host);
    await tester.runAsync(session.connect);
    await tester.runAsync(pumpEventQueue);
    return (controller, workspace);
  }

  group('chatAgentForSession', () {
    testWidgets('the only live agent on the host', (tester) async {
      final host = companion(buildHost('h'));
      final (controller, _) = await monitor(
        tester,
        host,
        status([agent('a'), agent('old', state: 'ended')]),
      );
      expect(chatAgentForSession(controller, host)?.id, 'a');
    });

    testWidgets('the agent in the session\'s own tmux session', (tester) async {
      final host = companion(
        const ConnectTarget.tmux('work').apply(buildHost('h')),
      );
      final (controller, _) = await monitor(
        tester,
        host,
        status([
          agent('a', extra: ',"tmux":{"session":"other","window":0}'),
          agent('b', extra: ',"tmux":{"session":"work","window":1}'),
        ]),
      );
      expect(chatAgentForSession(controller, host)?.id, 'b');
    });

    testWidgets('the agent in the session\'s Herdr tab', (tester) async {
      final host = companion(
        const ConnectTarget.herdr(
          workspaceId: 'w1',
          tabId: 'w1:t2',
        ).apply(buildHost('h')),
      );
      final (controller, _) = await monitor(
        tester,
        host,
        status([
          agent(
            'a',
            extra:
                ',"herdr":{"workspaceId":"w1","tabId":"w1:t1",'
                '"paneId":"w1:p1"}',
          ),
          agent(
            'b',
            extra:
                ',"herdr":{"workspaceId":"w1","tabId":"w1:t2",'
                '"paneId":"w1:p2"}',
          ),
        ]),
      );
      expect(chatAgentForSession(controller, host)?.id, 'b');
    });

    testWidgets('null when several agents and none matches', (tester) async {
      final host = companion(buildHost('h'));
      final (controller, _) = await monitor(
        tester,
        host,
        status([agent('a'), agent('b')]),
      );
      expect(chatAgentForSession(controller, host), isNull);
    });

    testWidgets('null without agent monitoring', (tester) async {
      final host = buildHost('h');
      final (controller, _) = await monitor(tester, host, status([agent('a')]));
      expect(chatAgentForSession(controller, host), isNull);
    });
  });

  group('on the terminal page', () {
    Future<void> pumpPage(
      WidgetTester tester,
      TerminalWorkspaceController workspace, {
      AgentAttentionController? attention,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: TerminalPage(
            workspace: workspace,
            themeController: themeController,
            sftpRepository: NoNetworkSftpRepository(),
            agentAttention: attention,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    // Lets the hint SnackBar time out so no timer outlives the test.
    Future<void> drainSnackBars(WidgetTester tester) async {
      for (var i = 0; i < 12; i += 1) {
        await tester.pump(const Duration(milliseconds: 500));
      }
    }

    final chatButton = find.byKey(const ValueKey('toolbar-chat'));
    const hint =
        'Chat opens Chat View for agent sessions. Long-press it for the '
        'composer.';

    testWidgets('a Claude session opens Chat View directly', (tester) async {
      final host = companion(buildHost('h'));
      final (controller, workspace) = await monitor(
        tester,
        host,
        status([agent('a')]),
      );
      await pumpPage(tester, workspace, attention: controller);

      await tester.tap(chatButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(ChatViewPage), findsOneWidget);
      expect(find.text(hint), findsOneWidget);
    });

    testWidgets('long-press opens the composer instead', (tester) async {
      final host = companion(buildHost('h'));
      final (controller, workspace) = await monitor(
        tester,
        host,
        status([agent('a')]),
      );
      await pumpPage(tester, workspace, attention: controller);

      await tester.longPress(chatButton);
      await tester.pump();

      expect(find.byType(ChatViewPage), findsNothing);
      expect(find.byTooltip('Close chat mode'), findsOneWidget);
      await drainSnackBars(tester);
    });

    testWidgets('without a Claude session the composer takes over at once', (
      tester,
    ) async {
      final remote = TrackableTerminalSession();
      final workspace = TerminalWorkspaceController(
        ImmediateTerminalRepository(remote),
      );
      addTearDown(workspace.dispose);
      final session = workspace.open(buildHost('plain'));
      await pumpPage(tester, workspace);
      final before = tester.getSize(find.byType(TerminalView)).height;
      // Let any start-up resize settle, then watch what the tap sends.
      await tester.pump(const Duration(seconds: 1));
      remote.resizes.clear();

      await tester.tap(chatButton);
      // One frame: no post-frame focus, no animation to wait for.
      await tester.pump();

      final field = find.byType(TextField);
      expect(field, findsOneWidget);
      final editable = tester.widget<EditableText>(
        find.descendant(of: field, matching: find.byType(EditableText)),
      );
      expect(editable.focusNode.hasPrimaryFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
      expect(tester.getSize(find.byType(TerminalView)).height, isNot(before));
      // The remote app hears about the new size in the same frame, so the
      // TUI redraws for the chat bar straight away.
      expect(remote.resizes, isNotEmpty);
      expect(remote.resizes.last, (
        session.terminal.viewWidth,
        session.terminal.viewHeight,
      ));
      expect(find.text(hint), findsOneWidget);
      await drainSnackBars(tester);
    });

    testWidgets('the Dictate pill button opens the chat line dictating', (
      tester,
    ) async {
      await themeController.setTerminalPillItems(const [
        TerminalPillItem.button(TerminalPillButton.chat),
        TerminalPillItem.button(TerminalPillButton.dictate),
      ]);
      final recognizer = FakeSpeechRecognizer();
      final workspace = TerminalWorkspaceController(
        ImmediateTerminalRepository(TrackableTerminalSession()),
      );
      addTearDown(workspace.dispose);
      workspace.open(buildHost('plain'));
      await tester.pumpWidget(
        MaterialApp(
          home: TerminalPage(
            workspace: workspace,
            themeController: themeController,
            sftpRepository: NoNetworkSftpRepository(),
            speechRecognizer: recognizer,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.byKey(const ValueKey('toolbar-dictate')));
      for (var i = 0; i < 6; i += 1) {
        await tester.pump();
      }

      expect(find.byTooltip('Close chat mode'), findsOneWidget);
      expect(recognizer.starts, hasLength(1));
      recognizer.say('git status');
      await tester.pump();
      expect(find.text('git status'), findsOneWidget);
      await drainSnackBars(tester);
    });

    testWidgets('the hint shows only once', (tester) async {
      final workspace = TerminalWorkspaceController(
        ImmediateTerminalRepository(TrackableTerminalSession()),
      );
      addTearDown(workspace.dispose);
      workspace.open(buildHost('plain'));
      await pumpPage(tester, workspace);

      await tester.tap(chatButton);
      await tester.pump();
      expect(themeController.chatButtonHintSeen, isTrue);
      await tester.tap(find.byTooltip('Close chat mode'));
      await tester.pump();
      ScaffoldMessenger.of(
        tester.element(find.byType(TerminalView)),
      ).removeCurrentSnackBar();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text(hint), findsNothing);

      await tester.tap(chatButton);
      await tester.pump();
      expect(find.text(hint), findsNothing);
      await drainSnackBars(tester);
    });

    String? openedSession(WidgetTester tester) {
      final pages = find.byType(ChatViewPage);
      if (pages.evaluate().isEmpty) return null;
      return tester.widget<ChatViewPage>(pages).controller.sessionId;
    }

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 5; i += 1) {
        await tester.runAsync(pumpEventQueue);
        await tester.pump(const Duration(milliseconds: 200));
      }
    }

    SavedHost herdrSession(String workspace) => companion(
      ConnectTarget.herdr(workspaceId: workspace).apply(buildHost('h')),
    );

    testWidgets('a Herdr workspace session opens its own Claude on a machine '
        'running several', (tester) async {
      final (controller, workspace) = await monitor(
        tester,
        herdrSession('w7'),
        liveHerdrStatusJson(),
      );
      await pumpPage(tester, workspace, attention: controller);

      await tester.tap(chatButton);
      await settle(tester);

      expect(openedSession(tester), 's-api');
      expect(find.byTooltip('Close chat mode'), findsNothing);
      await drainSnackBars(tester);
    });

    testWidgets('two Claudes in the workspace: asks which, then opens it', (
      tester,
    ) async {
      final (controller, workspace) = await monitor(
        tester,
        herdrSession('w5'),
        liveHerdrStatusJson(),
      );
      await pumpPage(tester, workspace, attention: controller);

      await tester.tap(chatButton);
      await settle(tester);
      expect(find.text('Open chat for…'), findsOneWidget);
      expect(find.byKey(const ValueKey('chat-agent-s-left')), findsOneWidget);
      expect(find.byKey(const ValueKey('chat-agent-s-api')), findsNothing);
      expect(find.byTooltip('Close chat mode'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('chat-agent-s-right')));
      await settle(tester);
      expect(openedSession(tester), 's-right');
      await drainSnackBars(tester);
    });

    testWidgets('no Claude session: the composer opens and says why', (
      tester,
    ) async {
      final (controller, workspace) = await monitor(
        tester,
        herdrSession('w7'),
        status([agent('old', state: 'ended')]),
      );
      await pumpPage(tester, workspace, attention: controller);

      await tester.tap(chatButton);
      await settle(tester);

      expect(find.byType(ChatViewPage), findsNothing);
      expect(find.byTooltip('Close chat mode'), findsOneWidget);
      expect(
        find.textContaining('No agent session is running on'),
        findsOneWidget,
      );
      await drainSnackBars(tester);
    });

    testWidgets('monitoring off: asks the companion directly and opens the '
        'session\'s own Claude', (tester) async {
      final runner = fakes.MatchingRunner({
        ...fakes.healthyResponses(),
        'conductore-hostd status': fakes.ok(liveHerdrStatusJson()),
      });
      final host = const ConnectTarget.herdr(
        workspaceId: 'w4',
      ).apply(buildHost('h'));
      final workspace = TerminalWorkspaceController(
        ImmediateTerminalRepository(TrackableTerminalSession()),
      );
      final attention = AgentAttentionController(
        workspace: workspace,
        runnerFactory: (_) => runner,
        provider: const ConductoreHostAttentionProvider(),
        pollInterval: const Duration(days: 1),
      );
      attention.setAppForeground(false);
      final session = workspace.open(host);
      await tester.runAsync(session.connect);
      expect(attention.isMonitoring(host.id), isFalse);
      await pumpPage(tester, workspace, attention: attention);

      await tester.tap(chatButton);
      await settle(tester);

      expect(runner.ran('conductore-hostd status'), isTrue);
      expect(openedSession(tester), 's-root');

      await tester.pumpWidget(const SizedBox());
      attention.dispose();
      workspace.dispose();
      await tester.pump(const Duration(days: 2));
    });

    testWidgets('a machine without the companion gets the composer and a '
        'note why', (tester) async {
      final runner = fakes.MatchingRunner({'conductore-hostd': fakes.notFound});
      final host = const ConnectTarget.herdr(
        workspaceId: 'w4',
      ).apply(buildHost('h'));
      final workspace = TerminalWorkspaceController(
        ImmediateTerminalRepository(TrackableTerminalSession()),
      );
      final attention = AgentAttentionController(
        workspace: workspace,
        runnerFactory: (_) => runner,
        provider: const ConductoreHostAttentionProvider(),
        pollInterval: const Duration(days: 1),
      );
      attention.setAppForeground(false);
      final session = workspace.open(host);
      await tester.runAsync(session.connect);
      await pumpPage(tester, workspace, attention: attention);

      await tester.tap(chatButton);
      await settle(tester);

      expect(find.byType(ChatViewPage), findsNothing);
      expect(find.byTooltip('Close chat mode'), findsOneWidget);
      expect(find.textContaining('No Conductore companion on'), findsOneWidget);

      await drainSnackBars(tester);
      await tester.pumpWidget(const SizedBox());
      attention.dispose();
      workspace.dispose();
      await tester.pump(const Duration(days: 2));
    });

    testWidgets('monitoring off but a working companion still opens Chat '
        'View', (tester) async {
      final runner = fakes.MatchingRunner({
        ...fakes.healthyResponses(),
        'conductore-hostd status': fakes.ok(
          fakes.statusJson(
            agents: [fakes.agent('s-1', updatedAt: DateTime.now())],
          ),
        ),
      });
      final host = buildHost('h');
      final workspace = TerminalWorkspaceController(
        ImmediateTerminalRepository(TrackableTerminalSession()),
      );
      final attention = AgentAttentionController(
        workspace: workspace,
        runnerFactory: (_) => runner,
        provider: const ConductoreHostAttentionProvider(),
        pollInterval: const Duration(days: 1),
      );
      attention.setAppForeground(false);
      final companion = CompanionSetupController(
        runnerFactory: (_) => runner,
        sftpRepository: NoNetworkSftpRepository(),
        loadBundle: () async => fakes.fakeBundle(),
      );
      final session = workspace.open(host);
      await tester.runAsync(session.connect);
      // What the Agent hooks chip already found out.
      await tester.runAsync(() => companion.refresh(host));
      expect(attention.isMonitoring(host.id), isFalse);

      await tester.pumpWidget(
        CompanionSetupScope(
          controller: companion,
          agentAttention: attention,
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

      await tester.tap(chatButton);
      for (var i = 0; i < 5; i += 1) {
        await tester.runAsync(pumpEventQueue);
        await tester.pump(const Duration(milliseconds: 200));
      }

      expect(find.byType(ChatViewPage), findsOneWidget);
      expect(find.byTooltip('Close chat mode'), findsNothing);

      await tester.pumpWidget(const SizedBox());
      attention.dispose();
      companion.dispose();
      workspace.dispose();
      await tester.pump(const Duration(days: 2));
    });
  });

  group('back from Chat View', () {
    const homeLabel = 'Home page';

    // Home with a button that pushes the terminal page as a terminal
    // route, the way the home page does.
    Future<void> pumpHome(
      WidgetTester tester,
      TerminalWorkspaceController workspace,
      AgentAttentionController attention,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Column(
                children: [
                  const Text(homeLabel),
                  TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        settings: terminalRouteSettings,
                        builder: (_) => TerminalPage(
                          workspace: workspace,
                          themeController: themeController,
                          sftpRepository: NoNetworkSftpRepository(),
                          agentAttention: attention,
                        ),
                      ),
                    ),
                    child: const Text('Open terminal'),
                  ),
                  TextButton(
                    onPressed: () => openChatView(
                      context: context,
                      attention: attention,
                      host: workspace.sessions.single.host,
                      agent: chatAgentForSession(
                        attention,
                        workspace.sessions.single.host,
                      )!,
                      onOpenTerminal: () {},
                    ),
                    child: const Text('Open chat'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    Future<void> settle(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
    }

    // Lets the Chat button hint SnackBar time out.
    Future<void> drain(WidgetTester tester) async {
      for (var i = 0; i < 12; i += 1) {
        await tester.pump(const Duration(milliseconds: 500));
      }
    }

    Future<void> openChatFromTerminal(WidgetTester tester) async {
      await tester.tap(find.text('Open terminal'));
      await settle(tester);
      expect(find.byType(TerminalPage), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('toolbar-chat')));
      await settle(tester);
      expect(find.byType(ChatViewPage), findsOneWidget);
    }

    testWidgets('opened from the terminal, back goes straight home', (
      tester,
    ) async {
      final host = companion(buildHost('h'));
      final (attention, workspace) = await monitor(
        tester,
        host,
        status([agent('a')]),
      );
      await pumpHome(tester, workspace, attention);
      await openChatFromTerminal(tester);

      await tester.binding.handlePopRoute();
      await settle(tester);

      expect(find.byType(ChatViewPage), findsNothing);
      expect(find.byType(TerminalPage), findsNothing);
      expect(find.text(homeLabel), findsOneWidget);
      // The session was not closed.
      expect(workspace.sessions, hasLength(1));
      await drain(tester);
    });

    testWidgets('the AppBar back arrow also goes home', (tester) async {
      final host = companion(buildHost('h'));
      final (attention, workspace) = await monitor(
        tester,
        host,
        status([agent('a')]),
      );
      await pumpHome(tester, workspace, attention);
      await openChatFromTerminal(tester);

      await tester.tap(find.byType(BackButton));
      await settle(tester);

      expect(find.byType(TerminalPage), findsNothing);
      expect(find.text(homeLabel), findsOneWidget);
      await drain(tester);
    });

    testWidgets('the Terminal button still switches to the terminal', (
      tester,
    ) async {
      final host = companion(buildHost('h'));
      final (attention, workspace) = await monitor(
        tester,
        host,
        status([agent('a')]),
      );
      await pumpHome(tester, workspace, attention);
      await openChatFromTerminal(tester);

      await tester.tap(find.text('Terminal'));
      await settle(tester);

      expect(find.byType(ChatViewPage), findsNothing);
      expect(find.byType(TerminalPage), findsOneWidget);
      await drain(tester);
    });

    testWidgets('opened from home, back returns home', (tester) async {
      final host = companion(buildHost('h'));
      final (attention, workspace) = await monitor(
        tester,
        host,
        status([agent('a')]),
      );
      await pumpHome(tester, workspace, attention);

      await tester.tap(find.text('Open chat'));
      await settle(tester);
      expect(find.byType(ChatViewPage), findsOneWidget);

      await tester.binding.handlePopRoute();
      await settle(tester);

      expect(find.byType(ChatViewPage), findsNothing);
      expect(find.text(homeLabel), findsOneWidget);
    });
  });
}
