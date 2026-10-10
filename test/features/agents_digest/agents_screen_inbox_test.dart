import 'package:conduit/features/agent_attention/data/conductore_host_attention_provider.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/agents_digest/presentation/agents_dashboard.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:conduit/features/usage/presentation/usage_controller.dart';
import 'package:conduit/features/usage/presentation/usage_widgets.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';
import '../usage/usage_fakes.dart';

/// What the Agents screen took over from the terminal's old Agents sheet
/// (its Inbox and Usage tabs): live cards updated in place, hiding, the
/// machine on each card, the Usage tab, and the sheet's bottom inset.

typedef Harness = ({
  AgentAttentionController controller,
  List<AgentInfo> opened,
  List<AgentInfo> chats,
});

/// Two minutes after the scripted agents' times: they are "Done since".
final _now = DateTime.fromMillisecondsSinceEpoch(1790000120000);

void main() {
  SavedHost monitoredHost(String id) => buildHost(id).copyWith(
    agentAttentionEnabled: true,
    agentMonitor: AgentMonitorKind.companion,
  );

  AgentCommandResult status(List<String> agents, {int seq = 1}) =>
      AgentCommandResult(
        stdout: '{"version":1,"seq":$seq,"agents":[${agents.join(',')}]}',
        stderr: '',
        exitCode: 0,
      );

  String agentJson(
    String id, {
    String state = 'working',
    String cwd = '/home/a/api',
    String? message,
    String? usage,
    int updatedAt = 1790000000000,
  }) =>
      '{"sessionId":"$id","cwd":"$cwd","state":"$state","updatedAt":'
      '$updatedAt,"pending":[]'
      '${message == null ? '' : ',"lastMessage":"$message"'}'
      '${usage == null ? '' : ',"usage":$usage'}}';

  /// Pumps the screen for one scripted runner per host id.
  Future<Harness> pumpPanel(
    WidgetTester tester,
    Map<String, List<Object>> scripts, {
    UsageController? usage,
  }) async {
    final workspace = TerminalWorkspaceController(FreshTerminalRepository());
    final runners = {
      for (final MapEntry(:key, :value) in scripts.entries)
        key: ScriptedAgentCommandRunner(value),
    };
    final controller = AgentAttentionController(
      workspace: workspace,
      runnerFactory: (host) => runners[host.id]!,
      provider: const ConductoreHostAttentionProvider(),
      pollInterval: const Duration(days: 1),
    );
    controller.setLongPoll(false);
    final digest = monitorOnlyDigest(clock: () => _now);
    addTearDown(digest.dispose);
    addTearDown(controller.dispose);
    addTearDown(workspace.dispose);
    for (final id in scripts.keys) {
      final session = workspace.open(monitoredHost(id));
      await tester.runAsync(session.connect);
    }
    await tester.runAsync(pumpEventQueue);
    final opened = <AgentInfo>[];
    final chats = <AgentInfo>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: _withUsage(
            usage,
            AgentsDashboardView(
              controller: digest,
              attention: controller,
              tabs: true,
              now: () => _now,
              onOpenTerminal: (host, agent) => opened.add(agent),
              onOpenChat: (host, agent) => chats.add(agent),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return (controller: controller, opened: opened, chats: chats);
  }

  Future<void> pollAgain(
    WidgetTester tester,
    AgentAttentionController controller,
    String hostId,
  ) async {
    await tester.runAsync(() => controller.pollNow(hostId));
    await tester.pump();
  }

  const card = ValueKey('digest-card-s-1');

  testWidgets('a new event updates the existing card in place', (tester) async {
    final harness = await pumpPanel(tester, {
      'h': [
        status([agentJson('s-1', message: 'Reading the tests.')]),
        status([
          agentJson(
            's-1',
            state: 'ended',
            message: 'All green.',
            updatedAt: 1790000060000,
          ),
        ], seq: 2),
      ],
    });
    expect(find.byKey(card), findsOneWidget);
    expect(find.byKey(const ValueKey('digest-section-working')), findsOne);
    expect(find.text('Reading the tests.'), findsOneWidget);

    await pollAgain(tester, harness.controller, 'h');

    expect(find.byKey(card), findsOneWidget);
    expect(find.text('Reading the tests.'), findsNothing);
    expect(find.text('All green.'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);
    expect(find.byKey(const ValueKey('digest-section-working')), findsNothing);
    expect(find.byKey(const ValueKey('digest-section-done')), findsOne);
  });

  testWidgets('a tap opens the chat, a long-press the terminal', (
    tester,
  ) async {
    final harness = await pumpPanel(tester, {
      'h': [
        status([agentJson('s-1')]),
      ],
    });
    await tester.tap(find.byKey(card));
    expect(harness.chats.single.id, 's-1');
    expect(harness.opened, isEmpty);

    await tester.longPress(find.byKey(card));
    expect(harness.opened.single.id, 's-1');
    // No separate Chat or Terminal buttons on the card (CON-107).
    expect(find.text('Chat'), findsNothing);
    expect(find.text('Terminal'), findsNothing);
  });

  testWidgets('swiping a done agent left hides it until it changes', (
    tester,
  ) async {
    final done = status([
      agentJson('s-1', state: 'ended', message: 'All green.'),
    ]);
    final harness = await pumpPanel(tester, {
      'h': [
        done,
        done,
        status([
          agentJson('s-1', message: 'Starting over.', updatedAt: 1790000090000),
        ], seq: 3),
      ],
    });

    await tester.drag(find.byKey(card), const Offset(-600, 0));
    await tester.pumpAndSettle();
    expect(find.byKey(card), findsNothing);
    expect(find.text('Show 1 hidden'), findsOneWidget);
    expect(find.textContaining('Nothing new'), findsOneWidget);

    // An unchanged poll keeps it hidden.
    await pollAgain(tester, harness.controller, 'h');
    expect(find.byKey(card), findsNothing);

    // The agent changing brings it back.
    await pollAgain(tester, harness.controller, 'h');
    expect(find.byKey(card), findsOneWidget);
    expect(find.text('Starting over.'), findsOneWidget);
    expect(find.text('Show 1 hidden'), findsNothing);
  });

  testWidgets('working cards cannot be hidden; hidden cards can return', (
    tester,
  ) async {
    await pumpPanel(tester, {
      'h': [
        status([
          agentJson('s-1'),
          agentJson('s-2', state: 'ended', cwd: '/w/web'),
        ]),
      ],
    });
    await tester.drag(find.byKey(card), const Offset(-600, 0));
    await tester.pumpAndSettle();
    expect(find.byKey(card), findsOneWidget);

    const web = ValueKey('digest-card-s-2');
    await tester.drag(find.byKey(web), const Offset(-600, 0));
    await tester.pumpAndSettle();
    expect(find.byKey(web), findsNothing);

    await tester.tap(find.text('Show 1 hidden'));
    await tester.pump();
    expect(find.byKey(web), findsOneWidget);
  });

  testWidgets('the badge counts exactly the cards under Needs you: a turn '
      'that only finished counts in neither', (tester) async {
    final harness = await pumpPanel(tester, {
      'h': [
        status([
          // Finished its turn: Done, no badge.
          agentJson('s-1', state: 'waiting_input', message: 'All green.'),
          // Asks in its last line.
          agentJson(
            's-2',
            state: 'waiting_input',
            cwd: '/w/web',
            message: 'Should I deploy?',
          ),
          // Asks with AskUserQuestion.
          '{"sessionId":"s-3","cwd":"/w/etl","state":"waiting_input",'
              '"updatedAt":1790000000000,"pending":[],'
              '"lastEvent":"PreToolUse","lastToolName":"AskUserQuestion"}',
          agentJson('s-4', cwd: '/w/docs'),
        ]),
      ],
    });
    expect(harness.controller.attentionCount, 2);
    final needsYou = find.byKey(const ValueKey('digest-section-needsYou'));
    expect(
      find.descendant(of: needsYou, matching: find.text('2')),
      findsOneWidget,
    );
    expect(find.text('Asks you'), findsNWidgets(2));
    // The tab's badge says the same.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('agents-tabs')),
        matching: find.text('2'),
      ),
      findsOneWidget,
    );
    expect(find.text('Done'), findsOneWidget);
  });

  group('desktop right-click', () {
    const desktops = TargetPlatformVariant({
      TargetPlatform.linux,
      TargetPlatform.windows,
      TargetPlatform.macOS,
    });
    final done = status([agentJson('s-1', state: 'ended')]);

    testWidgets('offers Mute and Hide, which do what swiping does', (
      tester,
    ) async {
      final harness = await pumpPanel(tester, {
        'h': [done],
      });
      await tester.tap(find.byKey(card), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('digest-menu-Mute notifications')),
      );
      await tester.pumpAndSettle();
      expect(harness.controller.isAgentMuted('h', 's-1'), isTrue);

      await tester.tap(find.byKey(card), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('digest-menu-Unmute notifications')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('digest-menu-Hide')));
      await tester.pumpAndSettle();
      expect(find.byKey(card), findsNothing);
      expect(find.text('Show 1 hidden'), findsOneWidget);
    }, variant: desktops);

    testWidgets('phones keep swipe only: no menu', (tester) async {
      await pumpPanel(tester, {
        'h': [done],
      });
      await tester.tap(find.byKey(card), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('digest-menu-Hide')), findsNothing);
      expect(find.byType(Dismissible), findsOneWidget);
    });
  });

  testWidgets('with several machines, every card names its machine', (
    tester,
  ) async {
    await pumpPanel(tester, {
      'a': [
        status([agentJson('s-1')]),
      ],
      'b': [
        status([agentJson('s-2', cwd: '/srv/web')]),
      ],
    });
    expect(find.textContaining('· Host a'), findsOneWidget);
    expect(find.textContaining('· Host b'), findsOneWidget);
  });

  group('usage', () {
    const usage =
        '{"contextUsedPct":42,"contextTokens":85000,"windowLabel":"200k",'
        '"limits":[{"label":"5h","usedPct":23.5}]}';

    testWidgets('a card shows its context; the Usage tab the details', (
      tester,
    ) async {
      await pumpPanel(tester, {
        'h': [
          status([
            agentJson('s-1', usage: usage),
            agentJson('s-2', cwd: '/w/web'),
          ]),
        ],
      });
      // Only the reporting agent's card names its context.
      expect(find.text('context 42%'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('digest-fact-context-s-2')),
        findsNothing,
      );

      await tester.tap(find.text('Usage'));
      await tester.pump();

      expect(find.text('42%'), findsOneWidget);
      expect(find.text('85k tokens of 200k'), findsOneWidget);
      expect(find.text('5h limit'), findsOneWidget);
      expect(find.text('24%'), findsOneWidget);
      expect(find.text('Not reported'), findsOneWidget);
      // The cards are on the Agents tab only.
      expect(find.byKey(card), findsNothing);
    });

    testWidgets('with the companion usage, the tab shows the breakdown and '
        'leaves the limit bars to it', (tester) async {
      final source = FakeUsageSource(
        [usageHost('h', name: 'Dev')],
        {
          'h': FakeUsageRunner(
            () => FakeUsageRunner.ok(
              usageReplyJson(
                limits: [
                  {'label': '5h', 'usedPct': 23.5},
                ],
                rows: [usageRow('2026-09-25')],
              ),
            ),
          ),
        },
      );
      final usageController = UsageController(
        source: source,
        observeLifecycle: false,
      );
      addTearDown(usageController.dispose);
      await pumpPanel(tester, {
        'h': [
          status([agentJson('s-1', usage: usage)]),
        ],
      }, usage: usageController);
      await tester.tap(find.text('Usage'));
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const ValueKey('usage-breakdown')), findsOneWidget);
      expect(find.text('Claude · 5-hour'), findsOneWidget);
      expect(find.text('5h limit'), findsNothing);
      expect(find.text('85k tokens of 200k'), findsOneWidget);
    });

    testWidgets('explains the source when nothing reports usage', (
      tester,
    ) async {
      await pumpPanel(tester, {
        'h': [
          status([agentJson('s-1')]),
        ],
      });
      await tester.tap(find.text('Usage'));
      await tester.pump();
      expect(find.textContaining("Claude Code's status line"), findsOneWidget);
      expect(find.text('Not reported'), findsOneWidget);
    });
  });

  testWidgets('the sheet keeps its end above a three-button navigation bar', (
    tester,
  ) async {
    // Galaxy M53-like: 1080x2400 at 2.625, 48dp three-button bar.
    const dpr = 2.625;
    const navBar = 48.0;
    tester.view
      ..physicalSize = const Size(1080, 2400)
      ..devicePixelRatio = dpr
      ..viewPadding = const FakeViewPadding(bottom: navBar * dpr)
      ..padding = const FakeViewPadding(bottom: navBar * dpr);
    addTearDown(tester.view.reset);

    final workspace = TerminalWorkspaceController(FreshTerminalRepository());
    final runner = ScriptedAgentCommandRunner([
      status([
        for (var i = 0; i < 12; i++)
          agentJson(
            's-$i',
            cwd: '/w/project-$i',
            message: 'Line one of the summary.',
          ),
      ]),
    ]);
    final controller = AgentAttentionController(
      workspace: workspace,
      runnerFactory: (_) => runner,
      provider: const ConductoreHostAttentionProvider(),
      pollInterval: const Duration(days: 1),
    );
    controller.setLongPoll(false);
    final digest = monitorOnlyDigest(clock: () => _now);
    addTearDown(digest.dispose);
    addTearDown(controller.dispose);
    addTearDown(workspace.dispose);
    await tester.runAsync(workspace.open(monitoredHost('h')).connect);
    await tester.runAsync(pumpEventQueue);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showAgentsSheet(
                  context: context,
                  controller: digest,
                  attention: controller,
                  onOpenTerminal: (_, _) {},
                  onOpenChat: (_, _) {},
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Expand the sheet, then scroll to the very end.
    for (var i = 0; i < 6; i++) {
      await tester.drag(find.byType(ListView), const Offset(0, -1200));
      await tester.pumpAndSettle();
    }

    const screenHeight = 2400 / dpr;
    final lastControl = tester.getRect(find.byTooltip('Refresh Host h'));
    expect(lastControl.bottom, lessThanOrEqualTo(screenHeight - navBar));
    final lastCard = tester.getRect(
      find.byKey(const ValueKey('digest-card-s-11')),
    );
    expect(lastCard.bottom, lessThanOrEqualTo(screenHeight - navBar));
  });
}

Widget _withUsage(UsageController? usage, Widget child) =>
    usage == null ? child : UsageScope(controller: usage, child: child);
