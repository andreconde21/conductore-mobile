import 'package:conduit/features/agent_attention/data/conductore_host_attention_provider.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_sheet.dart';
import 'package:conduit/features/agent_attention/presentation/widgets/agent_inbox_widgets.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:conduit/features/usage/presentation/usage_controller.dart';
import 'package:conduit/features/usage/presentation/usage_widgets.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';
import '../usage/usage_fakes.dart';

typedef Harness = ({
  AgentAttentionController controller,
  List<AgentInfo> opened,
  List<AgentInfo> chats,
});

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

  /// Pumps the panel for one scripted runner per host id.
  Future<Harness> pumpPanel(
    WidgetTester tester,
    Map<String, List<Object>> scripts, {
    bool withChat = false,
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
            AgentAttentionSheet(
              controller: controller,
              onOpenAgent: (host, agent) => opened.add(agent),
              onOpenChat: withChat ? (host, agent) => chats.add(agent) : null,
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

  testWidgets('a new event updates the existing row in place', (tester) async {
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
    final row = find.byKey(const ValueKey('agent-row-h/s-1'));
    expect(row, findsOneWidget);
    expect(find.text('WORKING  1'), findsOneWidget);
    expect(find.text('Reading the tests.'), findsOneWidget);

    await pollAgain(tester, harness.controller, 'h');

    expect(row, findsOneWidget);
    expect(find.text('api'), findsOneWidget);
    expect(find.text('Reading the tests.'), findsNothing);
    expect(find.text('All green.'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);
    expect(find.text('WORKING  1'), findsNothing);
    expect(find.text('DONE & IDLE  1'), findsOneWidget);
  });

  testWidgets('tapping a row opens that agent', (tester) async {
    final harness = await pumpPanel(tester, {
      'h': [
        status([agentJson('s-1')]),
      ],
    });
    await tester.tap(find.text('api'));
    expect(harness.opened.single.id, 's-1');
  });

  testWidgets('swiping a finished agent hides it until it changes', (
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

    await tester.drag(find.text('api'), const Offset(-600, 0));
    await tester.pumpAndSettle();
    expect(find.text('api'), findsNothing);
    expect(find.text('Show 1 hidden'), findsOneWidget);
    expect(find.textContaining('Nothing new'), findsOneWidget);

    // An unchanged poll keeps it hidden.
    await pollAgain(tester, harness.controller, 'h');
    expect(find.text('api'), findsNothing);

    // The agent changing brings it back.
    await pollAgain(tester, harness.controller, 'h');
    expect(find.text('api'), findsOneWidget);
    expect(find.text('Starting over.'), findsOneWidget);
    expect(find.text('Show 1 hidden'), findsNothing);
  });

  testWidgets('working rows are not dismissible; hidden rows can return', (
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
    expect(find.byType(Dismissible), findsOneWidget);

    await tester.drag(find.text('web'), const Offset(600, 0));
    await tester.pumpAndSettle();
    expect(find.text('web'), findsNothing);

    await tester.tap(find.text('Show 1 hidden'));
    await tester.pump();
    expect(find.text('web'), findsOneWidget);
  });

  group('desktop hide (no swipe needed)', () {
    const desktops = TargetPlatformVariant({
      TargetPlatform.linux,
      TargetPlatform.windows,
      TargetPlatform.macOS,
    });
    final done = status([agentJson('s-1', state: 'ended')]);
    const hide = ValueKey('agent-row-hide-h/s-1');

    testWidgets('hovering a finished row shows Hide, which hides it', (
      tester,
    ) async {
      await pumpPanel(tester, {
        'h': [done],
      });
      expect(find.byKey(hide), findsNothing);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(find.text('api')));
      await tester.pump();
      expect(find.byKey(hide), findsOneWidget);
      expect(tester.widget<IconButton>(find.byKey(hide)).tooltip, 'Hide');
      await tester.tap(find.byKey(hide));
      await tester.pumpAndSettle();
      expect(find.text('api'), findsNothing);
      expect(find.text('Show 1 hidden'), findsOneWidget);
    }, variant: desktops);

    testWidgets('right-click offers Open and Hide', (tester) async {
      final harness = await pumpPanel(tester, {
        'h': [done],
      });
      await tester.tap(find.text('api'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('agent-row-menu-Open')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('agent-row-menu-Open')));
      await tester.pumpAndSettle();
      expect(harness.opened.single.id, 's-1');

      await tester.tap(find.text('api'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('agent-row-menu-Hide')));
      await tester.pumpAndSettle();
      expect(find.text('api'), findsNothing);
    }, variant: desktops);

    testWidgets('phones keep swipe only: no Hide button, no menu', (
      tester,
    ) async {
      await pumpPanel(tester, {
        'h': [done],
      });
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(find.text('api')));
      await tester.pump();
      expect(find.byKey(hide), findsNothing);
      await tester.tap(find.text('api'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('agent-row-menu-Open')), findsNothing);
      expect(find.byType(Dismissible), findsOneWidget);
    });
  });

  testWidgets('groups by host and project with several machines', (
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
    expect(find.text('Host a / api'), findsOneWidget);
    expect(find.text('Host b / web'), findsOneWidget);
    // The group header names the machine, so the row does not repeat it.
    expect(find.text('Host a'), findsNothing);
  });

  testWidgets('renders the Chat button only with a chat callback', (
    tester,
  ) async {
    final script = {
      'h': <Object>[
        status([agentJson('s-1')]),
      ],
    };
    await pumpPanel(tester, script);
    expect(find.text('Chat'), findsNothing);

    final harness = await pumpPanel(tester, script, withChat: true);
    await tester.tap(find.text('Chat'));
    expect(harness.chats.single.id, 's-1');
    expect(harness.opened, isEmpty);
  });

  group('usage', () {
    const usage =
        '{"contextUsedPct":42,"contextTokens":85000,"windowLabel":"200k",'
        '"limits":[{"label":"5h","usedPct":23.5}]}';

    testWidgets('shows a ring when reported and Not reported otherwise', (
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
      // The inbox row carries a small ring for the reporting agent only.
      expect(find.byType(ContextRing), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (widget) => widget is ContextRing && widget.percent == 42,
        ),
        findsOneWidget,
      );

      await tester.tap(find.text('Usage'));
      await tester.pump();

      expect(find.text('42%'), findsOneWidget);
      expect(find.text('85k tokens of 200k'), findsOneWidget);
      expect(find.text('5h limit'), findsOneWidget);
      expect(find.text('24%'), findsOneWidget);
      expect(find.text('Not reported'), findsOneWidget);
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
      expect(find.byType(ContextRing), findsNothing);
    });
  });

  testWidgets('keeps the last row above a three-button navigation bar', (
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
                onPressed: () => showAgentAttentionSheet(
                  context: context,
                  controller: controller,
                  onOpenAgent: (_, _) {},
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
    // Equal times sort by name: project-9 is the last row.
    final lastRow = tester.getRect(
      find.byKey(const ValueKey('agent-row-h/s-9')),
    );
    expect(lastRow.bottom, lessThanOrEqualTo(screenHeight - navBar));
  });
}

Widget _withUsage(UsageController? usage, Widget child) =>
    usage == null ? child : UsageScope(controller: usage, child: child);
