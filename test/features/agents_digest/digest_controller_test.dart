import 'package:conduit/core/telemetry/telemetry_events.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/agents_digest/data/digest_preferences.dart';
import 'package:conduit/features/agents_digest/domain/agents_digest.dart';
import 'package:conduit/features/agents_digest/presentation/digest_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'digest_fakes.dart';

void main() {
  late DateTime now;
  late FakeDigestRunner runner;
  late FakeDigestSource source;
  late MemoryDigestPreferencesStore store;

  DigestController build({String language = 'en'}) {
    final controller = DigestController(
      source: source,
      preferences: store,
      language: () => language,
      clock: () => now,
      observeLifecycle: false,
    );
    addTearDown(controller.dispose);
    return controller;
  }

  setUp(() {
    now = digestNow;
    runner = FakeDigestRunner(
      facts: digestReplyJson([
        digestAgentJson('api', summaryPending: true),
        digestAgentJson('web', summary: 'Old summary.'),
      ]),
      summaries: digestReplyJson([
        digestAgentJson('api', summary: 'New summary.'),
        digestAgentJson('web', summary: 'Old summary.'),
      ], tokensToday: 5000),
    );
    source = FakeDigestSource(
      [digestHost('box', name: 'Box')],
      {'box': runner},
    );
    store = MemoryDigestPreferencesStore();
  });

  testWidgets('asks nothing until a view opens; then facts, then summaries', (
    tester,
  ) async {
    final controller = build();
    await tester.pump(const Duration(minutes: 5));
    expect(runner.commands, isEmpty);

    final detach = controller.attachView();
    await tester.pump();
    await tester.pump();
    expect(runner.commands, hasLength(2));
    final [facts, summaries] = runner.commands;
    expect(facts, contains('digest --since '));
    expect(facts, isNot(contains('--summaries')));
    expect(facts, contains('--lang en'));
    expect(summaries, contains('--summaries'));
    // The window starts two hours back before the first check.
    final since = now.subtract(const Duration(hours: 2)).millisecondsSinceEpoch;
    expect(facts, contains('--since $since'));
    expect(controller.overview.agents.map((a) => a.summary), [
      'New summary.',
      'Old summary.',
    ]);
    expect(controller.summaryUsageToday.tokens, 5000);
    detach();
  });

  testWidgets("an older companion's digest takes the agent's Herdr "
      'workspace label from the monitor (CON-116)', (tester) async {
    runner = FakeDigestRunner(
      facts: digestReplyJson([
        digestAgentJson('api', name: 'root'),
        digestAgentJson('web', name: 'web'),
      ]),
    );
    source = FakeDigestSource([digestHost('box')], {'box': runner});
    source.live['box'] = const [
      AgentInfo(
        id: 'api',
        name: 'Infrastructure',
        state: AgentAttentionState.needsInput,
        workspace: 'w4',
        workspaceLabel: 'Infrastructure',
      ),
      AgentInfo(id: 'web', name: 'web', state: AgentAttentionState.idle),
    ];
    final controller = build();
    final detach = controller.attachView();
    await tester.pump();
    await tester.pump();
    expect(controller.overview.agents.map((a) => a.name).toSet(), {
      'Infrastructure',
      'web',
    });
    detach();
  });

  testWidgets('keeps the facts fresh with no view while asked, for the '
      'stuck alerts', (tester) async {
    runner = FakeDigestRunner(
      facts: digestReplyJson([
        digestAgentJson(
          'api',
          state: 'working',
          stuck: [
            {'rule': 'repeating', 'reason': 'Ran `npm test` 6 times'},
          ],
        ),
      ]),
    );
    source = FakeDigestSource([digestHost('box')], {'box': runner});
    final controller = build();
    controller.keepFactsFresh(true);
    await tester.pump(controller.freshFactsInterval);
    await tester.pump();
    expect(runner.commands, hasLength(1));
    expect(runner.commands.single, isNot(contains('--summaries')));
    expect(controller.cachedStuckFor('box', 'api'), 'Ran `npm test` 6 times');
    expect(controller.cachedStuckFor('box', 'web'), isNull);

    // Fresh enough: the next tick asks again only once the interval passed.
    now = now.add(controller.freshFactsInterval);
    await tester.pump(controller.freshFactsInterval);
    await tester.pump();
    expect(runner.commands, hasLength(2));

    controller.keepFactsFresh(false);
    await tester.pump(controller.freshFactsInterval * 3);
    expect(runner.commands, hasLength(2));
  });

  testWidgets('polls facts while visible, never summaries; stops when hidden', (
    tester,
  ) async {
    final controller = build();
    final detach = controller.attachView();
    await tester.pump();
    await tester.pump();
    expect(runner.summaryCommands, hasLength(1));

    now = now.add(const Duration(seconds: 60));
    await tester.pump(const Duration(seconds: 60));
    expect(runner.commands, hasLength(3));
    expect(runner.summaryCommands, hasLength(1), reason: 'polls are facts');

    detach();
    now = now.add(const Duration(minutes: 10));
    await tester.pump(const Duration(minutes: 10));
    expect(runner.commands, hasLength(3));
  });

  testWidgets('summaries off: facts only', (tester) async {
    store.value = const DigestPreferences(summariesEnabled: false);
    final controller = build();
    final detach = controller.attachView();
    await tester.pump();
    await tester.pump();
    expect(runner.commands, hasLength(1));
    expect(runner.summaryCommands, isEmpty);
    expect(controller.overview.agents.first.summaryPending, isTrue);
    detach();
  });

  testWidgets('no pending summaries: no summary call', (tester) async {
    runner.facts = digestReplyJson([digestAgentJson('api', summary: 'Same.')]);
    final controller = build();
    final detach = controller.attachView();
    await tester.pump();
    await tester.pump();
    expect(runner.summaryCommands, isEmpty);
    expect(controller.isSummarizing, isFalse);
    detach();
  });

  testWidgets('closing counts as a look: the next open starts there', (
    tester,
  ) async {
    final controller = build();
    final opened = now;
    final detach = controller.attachView();
    await tester.pump();
    await tester.pump();
    now = now.add(const Duration(minutes: 3));
    detach();
    await tester.pump();
    expect(store.value.lastSeen, opened);

    now = now.add(const Duration(hours: 1));
    final again = controller.attachView();
    await tester.pump();
    expect(controller.since, opened);
    expect(
      runner.commands.last,
      contains('--since ${opened.millisecondsSinceEpoch}'),
    );
    again();
  });

  testWidgets('mark all seen and the window menu choose the start', (
    tester,
  ) async {
    final controller = build();
    final detach = controller.attachView();
    await tester.pump();
    await tester.pump();
    await controller.markAllSeen();
    expect(controller.since, now);
    expect(store.value.lastSeen, now);
    expect(
      runner.commands.last,
      contains('--since ${now.millisecondsSinceEpoch}'),
    );
    await controller.setWindow(DigestWindow.today);
    final local = now.toLocal();
    expect(controller.since, DateTime(local.year, local.month, local.day));
    expect(store.value.window, DigestWindow.today);
    detach();
  });

  testWidgets('thresholds and language go to the companion', (tester) async {
    store.value = const DigestPreferences(
      thresholds: DigestThresholds(approvalMinutes: 15),
    );
    final controller = build(language: 'pt-PT');
    final detach = controller.attachView();
    await tester.pump();
    expect(runner.commands.first, contains('--lang pt'));
    expect(runner.commands.first, contains('--stuck-approval-min 15'));
    detach();
  });

  testWidgets('an older companion: status facts and an update hint', (
    tester,
  ) async {
    runner.raw = const AgentCommandResult(
      stdout: '{"error":"unknown command digest"}',
      stderr: '',
      exitCode: 1,
    );
    source.live['box'] = [
      const AgentInfo(
        id: 's1',
        name: 'api',
        state: AgentAttentionState.needsInput,
        pendingRequests: [
          PendingPermissionRequest(id: 'r', toolName: 'Bash', summary: 'ls'),
        ],
      ),
    ];
    final controller = build();
    final detach = controller.attachView();
    await tester.pump();
    await tester.pump();
    expect(controller.outdated.single.hostName, 'Box');
    final agent = controller.overview.agents.single;
    expect(agent.fromStatus, isTrue);
    expect(agent.attention, DigestAttention.permission);
    expect(runner.summaryCommands, isEmpty);

    // The monitor's next status shows up without asking the companion.
    source.live['box'] = [
      const AgentInfo(
        id: 's1',
        name: 'api',
        state: AgentAttentionState.working,
      ),
    ];
    source.changed();
    expect(controller.overview.agents.single.state, 'working');
    // Not asked again for a while.
    final asked = runner.commands.length;
    now = now.add(const Duration(minutes: 2));
    await tester.pump(const Duration(minutes: 2));
    expect(runner.commands, hasLength(asked));
    detach();
  });

  testWidgets('a failure keeps the last report and says why', (tester) async {
    final controller = build();
    final detach = controller.attachView();
    await tester.pump();
    await tester.pump();
    runner.raw = const AgentCommandResult(
      stdout: '',
      stderr: 'ssh: connection reset',
      exitCode: 255,
    );
    await controller.refresh();
    final machine = controller.machines.single;
    expect(machine.error, 'ssh: connection reset');
    expect(machine.report!.agents, hasLength(2));
    detach();
  });

  testWidgets('catch me up asks now and speaks the overview', (tester) async {
    final controller = build();
    late String spoken;
    await tester.runAsync(() async {
      spoken = await controller.catchUp('en');
    });
    expect(runner.summaryCommands, hasLength(1));
    expect(spoken, startsWith('0 need you, 0 stuck, 0 working, 2 done.'));
  });

  test('digest_opened carries no content', () {
    const event = TelemetryEvent.digestOpened();
    expect(event.name, 'digest_opened');
    expect(event.screen, TelemetryScreen.home);
    expect(event.props, isEmpty);
  });
}
