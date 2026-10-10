import 'package:conduit/core/connection_problem.dart';
import 'package:conduit/features/agent_attention/data/conductore_host_attention_provider.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/agents_digest/presentation/agents_dashboard.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_launcher.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_page.dart';
import 'package:conduit/features/companion_setup/presentation/companion_setup_controller.dart';
import 'package:conduit/features/companion_setup/presentation/companion_setup_page.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/hosts/presentation/host_form_page.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';
import '../companion_setup/companion_fakes.dart';

/// Chat View is decided by the companion on the machine, not by the
/// "Monitor coding agents" setting (André: companion 0.3.0 running, yet
/// "Chat view needs the companion").
void main() {
  // Monitoring OFF: the setting that used to gate Chat View.
  final host = buildHost('h');
  late MatchingRunner runner;
  late List<String> persisted;
  var stopped = false;

  // Tears the UI and the monitor down inside the test, so their poll and
  // chat timers are gone before the pending-timer check.
  Future<void> stop(
    WidgetTester tester,
    AgentAttentionController attention,
  ) async {
    await tester.pumpWidget(const SizedBox());
    attention.dispose();
    stopped = true;
    await tester.pump(const Duration(days: 2));
  }

  Map<String, Object> companionWith(List<Map<String, Object?>> agents) => {
    ...healthyResponses(),
    'conductore-hostd status': ok(statusJson(agents: agents)),
  };

  Future<(AgentAttentionController, TerminalWorkspaceController)> start(
    WidgetTester tester,
    Map<String, Object> responses,
  ) async {
    runner = MatchingRunner(responses);
    persisted = [];
    stopped = false;
    final workspace = TerminalWorkspaceController(
      ImmediateTerminalRepository(TrackableTerminalSession()),
    );
    final controller = AgentAttentionController(
      workspace: workspace,
      runnerFactory: (_) => runner,
      provider: const ConductoreHostAttentionProvider(),
      pollInterval: const Duration(days: 1),
      persistMonitoringEnabled: (id) async => persisted.add(id),
    );
    controller.setLongPoll(false);
    addTearDown(() {
      if (!stopped) controller.dispose();
    });
    addTearDown(workspace.dispose);
    final session = workspace.open(host);
    await tester.runAsync(session.connect);
    await tester.runAsync(pumpEventQueue);
    return (controller, workspace);
  }

  Future<ChatViewAccess> check(
    WidgetTester tester,
    AgentAttentionController attention, {
    CompanionSetupController? companion,
  }) async {
    final access = await tester.runAsync(
      () => checkChatViewAccess(
        attention: attention,
        host: host,
        companion: companion,
      ),
    );
    return access!;
  }

  final now = DateTime.now();

  group('checkChatViewAccess with monitoring off', () {
    testWidgets('a working companion is enough; sessions come from status', (
      tester,
    ) async {
      final (attention, _) = await start(
        tester,
        companionWith([
          agent('s-1', updatedAt: now),
          agent('s-old', updatedAt: now, state: 'ended'),
        ]),
      );
      expect(attention.isMonitoring(host.id), isFalse);

      final access = await check(tester, attention);

      expect(access.ready, isTrue);
      expect(access.monitored, isFalse);
      expect(access.agents.map((agent) => agent.id), ['s-1']);
      expect(runner.ran('conductore-hostd version'), isTrue);
    });

    testWidgets('uses the Agent hooks screen\'s cached check', (tester) async {
      final (attention, _) = await start(
        tester,
        companionWith([agent('s-1', updatedAt: now)]),
      );
      final companion = CompanionSetupController(
        runnerFactory: (_) => runner,
        sftpRepository: NoNetworkSftpRepository(),
        loadBundle: () async => fakeBundle(),
      );
      addTearDown(companion.dispose);
      await tester.runAsync(() => companion.refresh(host));
      runner.commands.clear();

      final access = await check(tester, attention, companion: companion);

      expect(access.ready, isTrue);
      // No second probe: only the session list was fetched.
      expect(runner.ran('conductore-hostd version'), isFalse);
      expect(runner.ran('conductore-hostd status'), isTrue);
    });

    testWidgets('not installed says so', (tester) async {
      final (attention, _) = await start(tester, {
        'conductore-hostd version': notFound,
      });

      final access = await check(tester, attention);

      expect(access.ready, isFalse);
      expect(access.title, 'Chat view needs the companion');
      expect(access.problem, contains('was not found on Host h'));
    });

    testWidgets('missing hooks never claim the companion is missing', (
      tester,
    ) async {
      final (attention, _) = await start(tester, {
        ...healthyResponses(),
        'conductore-hostd doctor': ok(doctorJson(hooks: false)),
      });

      final access = await check(tester, attention);

      expect(access.ready, isFalse);
      expect(access.title, 'Claude Code hooks are not registered');
      expect(access.problem, contains('is installed on Host h'));
      expect(access.problem, isNot(contains('not found')));
      expect(access.problem, isNot(contains('install.sh')));
    });

    testWidgets('an old companion asks for an update', (tester) async {
      final (attention, _) = await start(tester, {
        ...healthyResponses(),
        'conductore-hostd version': ok(versionJson(version: '0.1.0')),
      });

      final access = await check(tester, attention);

      expect(access.title, 'The companion needs an update');
      expect(access.problem, contains('0.1.0'));
    });

    testWidgets('a failed check says the check failed', (tester) async {
      final (attention, _) = await start(tester, {
        'conductore-hostd version': Exception('connection reset'),
      });

      final access = await check(tester, attention);

      expect(access.title, 'Could not check the companion');
      expect(access.problem, contains('connection reset'));
      expect(access.canSetUp, isFalse);
    });
  });

  group('an unreachable machine', () {
    testWidgets('says the machine was not reached, not the companion', (
      tester,
    ) async {
      final (attention, _) = await start(tester, {
        'conductore-hostd version': const ConnectionFailure(
          'Could not reach Host h.',
          'SocketException: No route to host (OS Error: No route to host, '
              'errno = 113)',
          kind: ConnectionProblemKind.unreachable,
        ),
      });

      final access = await check(tester, attention);

      expect(access.ready, isFalse);
      expect(access.title, "Can't reach Host h");
      expect(
        access.problem,
        "Your device couldn't connect to 192.168.1.1. Check your network.",
      );
      expect(access.detail, contains('No route to host'));
      expect(access.canSetUp, isFalse);
    });

    testWidgets('the dialog keeps the technical reason behind Details', (
      tester,
    ) async {
      const access = ChatViewAccess.blocked(
        title: "Can't reach Host h",
        problem: 'Check your network.',
        detail: 'SocketException: errno = 113',
        canSetUp: false,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showChatViewUnavailable(context, host: host, access: access),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text("Can't reach Host h"), findsOneWidget);
      expect(find.textContaining('errno = 113'), findsNothing);
      await tester.tap(find.text('Details'));
      await tester.pumpAndSettle();
      expect(find.textContaining('errno = 113'), findsOneWidget);
    });
  });

  group('turning monitoring on', () {
    testWidgets('enableMonitoring starts the monitor and saves the setting', (
      tester,
    ) async {
      final (attention, _) = await start(
        tester,
        companionWith([agent('s-1', updatedAt: now)]),
      );
      expect(attention.unmonitoredHosts.map((h) => h.id), ['h']);

      await tester.runAsync(() => attention.enableMonitoring(host));

      expect(persisted, ['h']);
      expect(attention.monitoringEnabled(host), isTrue);
      expect(attention.isMonitoring(host.id), isTrue);
      expect(attention.unmonitoredHosts, isEmpty);
    });

    testWidgets('Chat View opens and offers a one-tap Turn on', (tester) async {
      final (attention, _) = await start(
        tester,
        companionWith([agent('s-1', updatedAt: now)]),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                final access = await checkChatViewAccessWithProgress(
                  context,
                  attention: attention,
                  host: host,
                );
                if (access == null || !context.mounted) return;
                await openChatView(
                  context: context,
                  attention: attention,
                  host: host,
                  agent: access.agents.single,
                  onOpenTerminal: () {},
                );
              },
              child: const Text('go'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('go'));
      for (var i = 0; i < 5; i += 1) {
        await tester.runAsync(pumpEventQueue);
        await tester.pump(const Duration(milliseconds: 200));
      }

      expect(find.text('Chat view needs the companion'), findsNothing);
      expect(find.byType(ChatViewPage), findsOneWidget);
      final banner = find.byKey(const ValueKey('chat-enable-monitoring'));
      expect(banner, findsOneWidget);

      await tester.tap(
        find.descendant(of: banner, matching: find.text('Turn on')),
      );
      await tester.pump();
      expect(persisted, ['h']);
      expect(banner, findsNothing);
      await stop(tester, attention);
    });

    testWidgets('the dialog names the failed condition', (tester) async {
      final (attention, _) = await start(tester, {
        ...healthyResponses(),
        'conductore-hostd doctor': ok(doctorJson(hooks: false)),
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                final access = await checkChatViewAccessWithProgress(
                  context,
                  attention: attention,
                  host: host,
                );
                if (access == null || !context.mounted) return;
                await showChatViewUnavailable(
                  context,
                  host: host,
                  access: access,
                );
              },
              child: const Text('go'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('go'));
      for (var i = 0; i < 5; i += 1) {
        await tester.runAsync(pumpEventQueue);
        await tester.pump(const Duration(milliseconds: 200));
      }

      expect(find.text('Claude Code hooks are not registered'), findsOneWidget);
      expect(find.text('Chat view needs the companion'), findsNothing);
    });

    testWidgets('the Agents panel offers Turn on for connected machines', (
      tester,
    ) async {
      final (attention, _) = await start(tester, healthyResponses());
      final digest = monitorOnlyDigest();
      addTearDown(digest.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AgentsDashboardView(
              controller: digest,
              attention: attention,
              tabs: true,
              onOpenTerminal: (host, agent) {},
              onOpenChat: (host, agent) {},
            ),
          ),
        ),
      );
      await tester.pump();
      final card = find.byKey(const ValueKey('agents-monitoring-off-h'));
      expect(card, findsOneWidget);

      await tester.tap(
        find.descendant(of: card, matching: find.text('Turn on')),
      );
      await tester.runAsync(pumpEventQueue);
      await tester.pump();
      expect(persisted, ['h']);
      expect(attention.isMonitoring(host.id), isTrue);
      await stop(tester, attention);
    });

    testWidgets('Agent hooks shows the banner when active and off', (
      tester,
    ) async {
      final (attention, _) = await start(tester, healthyResponses());
      final companion = CompanionSetupController(
        runnerFactory: (_) => runner,
        sftpRepository: NoNetworkSftpRepository(),
        loadBundle: () async => fakeBundle(),
      );
      addTearDown(companion.dispose);
      await tester.runAsync(() => companion.refresh(host));
      await tester.pumpWidget(
        CompanionSetupScope(
          controller: companion,
          agentAttention: attention,
          child: MaterialApp(
            home: CompanionSetupPage(host: host, controller: companion),
          ),
        ),
      );
      await tester.pump();
      final banner = find.byKey(const ValueKey('companion-monitoring-off'));
      expect(banner, findsOneWidget);

      await tester.tap(
        find.descendant(of: banner, matching: find.text('Turn on')),
      );
      await tester.runAsync(pumpEventQueue);
      await tester.pump();
      expect(persisted, ['h']);
      expect(banner, findsNothing);
      await stop(tester, attention);
    });
  });

  testWidgets('a new machine starts with agent monitoring on', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: HostFormPage()));
    final toggle = find.widgetWithText(SwitchListTile, 'Monitor coding agents');
    await tester.scrollUntilVisible(
      toggle,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
  });

  test('saved machines keep their stored setting', () {
    expect(buildHost('x').agentAttentionEnabled, isFalse);
    expect(
      SavedHost.fromJson(buildHost('x').toJson()).agentAttentionEnabled,
      isFalse,
    );
  });
}
