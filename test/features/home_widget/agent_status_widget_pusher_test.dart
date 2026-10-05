import 'dart:async';

import 'package:conduit/features/agent_attention/data/herdr_attention_provider.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/agent_attention/domain/launcher_prompt.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/agents_digest/data/digest_preferences.dart';
import 'package:conduit/features/agents_digest/domain/agents_digest.dart';
import 'package:conduit/features/agents_digest/presentation/digest_controller.dart';
import 'package:conduit/features/home_widget/domain/agent_status_snapshot.dart';
import 'package:conduit/features/home_widget/presentation/agent_status_widget_pusher.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:conduit/features/usage/domain/usage_report.dart';
import 'package:conduit/features/usage/presentation/usage_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';
import '../agents_digest/digest_fakes.dart';
import '../usage/usage_fakes.dart';
import 'fake_agent_status_widget_channel.dart';

void main() {
  const debounce = Duration(milliseconds: 500);

  (ChangeNotifier, FakeAgentStatusWidgetChannel, AgentStatusWidgetPusher)
  build() {
    final source = ChangeNotifier();
    final channel = FakeAgentStatusWidgetChannel();
    var revision = 0;
    final pusher = AgentStatusWidgetPusher(
      source: source,
      snapshot: () => AgentStatusSnapshot(
        monitoring: true,
        attentionCount: revision++,
        agents: const [],
        updatedAt: DateTime.utc(2026),
      ),
      channel: channel,
    );
    addTearDown(pusher.dispose);
    return (source, channel, pusher);
  }

  testWidgets('pushes the launcher prompts first, and only when changed', (
    tester,
  ) async {
    final source = ChangeNotifier();
    final channel = FakeAgentStatusWidgetChannel();
    var prompts = const [
      LauncherPrompt(
        hostId: 'h',
        agentId: 's-1',
        requestId: 'reply',
        question: 'Which branch?',
        replyVerdict: 'reply',
      ),
    ];
    var revision = 0;
    final pusher = AgentStatusWidgetPusher(
      source: source,
      snapshot: () => AgentStatusSnapshot(
        monitoring: true,
        attentionCount: revision++,
        agents: const [],
        updatedAt: DateTime.utc(2026),
      ),
      launcherPrompts: () => prompts,
      channel: channel,
    );
    addTearDown(pusher.dispose);
    pusher.start();
    await tester.pump();
    expect(channel.pushedPrompts.single, prompts);
    expect(channel.pushed, hasLength(1));

    // Same prompts: the snapshot goes, the prompts do not.
    source.notifyListeners();
    await tester.pump(debounce);
    expect(channel.pushed, hasLength(2));
    expect(channel.pushedPrompts, hasLength(1));

    prompts = const [];
    source.notifyListeners();
    await tester.pump(debounce);
    expect(channel.pushedPrompts.last, isEmpty);
  });

  testWidgets('pushes once on start', (tester) async {
    final (_, channel, pusher) = build();
    pusher.start();
    await tester.pump();
    expect(channel.pushed, hasLength(1));

    // Starting twice does not double-subscribe or re-push.
    pusher.start();
    await tester.pump(debounce * 2);
    expect(channel.pushed, hasLength(1));
  });

  testWidgets('coalesces a burst of changes into one push after the window', (
    tester,
  ) async {
    final (source, channel, pusher) = build();
    pusher.start();
    await tester.pump();
    channel.pushed.clear();

    source.notifyListeners();
    source.notifyListeners();
    await tester.pump(const Duration(milliseconds: 200));
    source.notifyListeners();
    expect(channel.pushed, isEmpty);

    await tester.pump(const Duration(milliseconds: 300));
    expect(channel.pushed, hasLength(1));

    // The window is closed; a new change opens a new one.
    source.notifyListeners();
    await tester.pump(debounce);
    expect(channel.pushed, hasLength(2));
    expect(
      channel.pushed.last.attentionCount,
      greaterThan(channel.pushed.first.attentionCount),
    );
  });

  testWidgets('skips snapshots that differ only by their time', (tester) async {
    final source = ChangeNotifier();
    final channel = FakeAgentStatusWidgetChannel();
    var now = DateTime.utc(2026, 9, 27, 10);
    var count = 0;
    final pusher = AgentStatusWidgetPusher(
      source: source,
      snapshot: () => AgentStatusSnapshot(
        monitoring: true,
        attentionCount: count,
        agents: const [],
        updatedAt: now,
      ),
      channel: channel,
    );
    addTearDown(pusher.dispose);
    pusher.start();
    await tester.pump();
    expect(channel.pushed, hasLength(1));

    // A title spinner re-notifying every half second changes nothing.
    for (var i = 0; i < 10; i++) {
      now = now.add(const Duration(seconds: 1));
      source.notifyListeners();
      await tester.pump(debounce);
    }
    expect(channel.pushed, hasLength(1));

    // A real change goes out at once.
    count = 1;
    source.notifyListeners();
    await tester.pump(debounce);
    expect(channel.pushed, hasLength(2));

    // And the shown time still refreshes once it is a minute old.
    now = now.add(AgentStatusWidgetPusher.unchangedRefresh);
    source.notifyListeners();
    await tester.pump(debounce);
    expect(channel.pushed, hasLength(3));
  });

  testWidgets('a change during an in-flight push causes exactly one more', (
    tester,
  ) async {
    final (source, channel, pusher) = build();
    channel.pushGate = Completer<void>();
    pusher.start();
    await tester.pump();
    expect(channel.pushed, hasLength(1));

    source.notifyListeners();
    await tester.pump(debounce);
    source.notifyListeners();
    await tester.pump(debounce);
    // Still blocked on the first push; nothing overlaps.
    expect(channel.pushed, hasLength(1));

    final gate = channel.pushGate!;
    channel.pushGate = null;
    gate.complete();
    await tester.pump();
    expect(channel.pushed, hasLength(2));
    await tester.pump(debounce);
    expect(channel.pushed, hasLength(2));
  });

  testWidgets('stops pushing after dispose', (tester) async {
    final (source, channel, pusher) = build();
    pusher.start();
    await tester.pump();
    source.notifyListeners();
    pusher.dispose();
    await tester.pump(debounce * 2);
    expect(channel.pushed, hasLength(1));
  });

  testWidgets('survives a throwing channel', (tester) async {
    final source = ChangeNotifier();
    final pusher = AgentStatusWidgetPusher(
      source: source,
      snapshot: () => AgentStatusSnapshot.empty(DateTime.utc(2026)),
      channel: _ThrowingChannel(),
    );
    addTearDown(pusher.dispose);
    pusher.start();
    await tester.pump();
    source.notifyListeners();
    await tester.pump(debounce);
    // No unhandled error surfaced to the test binding.
  });

  test('snapshotOf reflects the monitored hosts and their agents', () async {
    final workspace = TerminalWorkspaceController(
      ImmediateTerminalRepository(TrackableTerminalSession()),
    );
    final runner = ScriptedAgentCommandRunner([
      const AgentCommandResult(
        stdout:
            '[{"name": "builder", "state": "blocked"},'
            ' {"name": "tester", "state": "working"}]',
        stderr: '',
        exitCode: 0,
      ),
    ]);
    final controller = AgentAttentionController(
      workspace: workspace,
      runnerFactory: (_) => runner,
      provider: const HerdrAttentionProvider(),
      pollInterval: const Duration(days: 1),
    );
    addTearDown(controller.dispose);
    addTearDown(workspace.dispose);

    expect(AgentStatusWidgetPusher.snapshotOf(controller).monitoring, isFalse);

    await workspace
        .open(buildHost('h').copyWith(agentAttentionEnabled: true, name: 'Dev'))
        .connect();
    await pumpEventQueue();

    final snapshot = AgentStatusWidgetPusher.snapshotOf(controller);
    expect(snapshot.monitoring, isTrue);
    expect(snapshot.attentionCount, 1);
    expect(snapshot.agents.first.name, 'builder');
    expect(snapshot.agents.first.host, 'Dev');
    expect(snapshot.agents.first.state, AgentAttentionState.needsInput);
    expect(snapshot.agents.last.name, 'tester');
  });

  test('the widget limits are the 5h and weekly rings, 0 after a reset', () {
    final now = DateTime.utc(2026, 9, 25, 12);
    final limits = AgentStatusWidgetPusher.widgetLimits([
      UsageLimit(
        label: '5h',
        usedPct: 82.6,
        resetsAt: now.add(const Duration(hours: 1)),
      ),
      UsageLimit(
        label: '7d',
        usedPct: 40,
        resetsAt: now.subtract(const Duration(minutes: 1)),
      ),
      const UsageLimit(label: 'spend', usedPct: 10),
    ], now);
    expect(limits.map((l) => (l.label, l.usedPct, l.level)), [
      ('5h', 83, 'warning'),
      ('7d', 0, 'normal'),
    ]);
  });

  testWidgets('with usage, the snapshot carries the limits and a usage '
      'change pushes', (tester) async {
    final workspace = TerminalWorkspaceController(
      ImmediateTerminalRepository(TrackableTerminalSession()),
    );
    final attention = AgentAttentionController(
      workspace: workspace,
      runnerFactory: (_) => ScriptedAgentCommandRunner(const []),
      provider: const HerdrAttentionProvider(),
      pollInterval: const Duration(days: 1),
    );
    final source = FakeUsageSource([usageHost('box')], {});
    final usage = UsageController(source: source, observeLifecycle: false);
    final channel = FakeAgentStatusWidgetChannel();
    final pusher = AgentStatusWidgetPusher.forController(
      attention,
      usage: usage,
      channel: channel,
      debounce: const Duration(milliseconds: 10),
    )..start();
    addTearDown(() {
      pusher.dispose();
      usage.dispose();
      attention.dispose();
      workspace.dispose();
    });
    await tester.pump();
    expect(channel.pushed.last.limits, isEmpty);

    source
      ..live['box'] = [
        UsageLimit(
          label: '5h',
          usedPct: 96,
          resetsAt: DateTime.now().add(const Duration(hours: 2)),
        ),
      ]
      ..changed();
    await tester.pump(const Duration(milliseconds: 20));
    final limit = channel.pushed.last.limits.single;
    expect(limit.label, '5h');
    expect(limit.usedPct, 96);
    expect(limit.level, 'critical');
  });

  testWidgets('the "as of" of the cached facts refreshes at most once a '
      'minute; a new count goes out at once', (tester) async {
    final source = ChangeNotifier();
    final channel = FakeAgentStatusWidgetChannel();
    var now = DateTime.utc(2026, 9, 27, 10);
    var factsAt = now;
    var stuck = 1;
    final pusher = AgentStatusWidgetPusher(
      source: source,
      snapshot: () => AgentStatusSnapshot.build(
        hosts: const [],
        monitoring: true,
        now: now,
        dashboard: AgentStatusDashboard(
          needsYou: 0,
          working: 1,
          stuck: stuck,
          done: 2,
          factsAt: factsAt,
        ),
      ),
      channel: channel,
    );
    addTearDown(pusher.dispose);
    pusher.start();
    await tester.pump();
    expect(channel.pushed, hasLength(1));

    // The dashboard re-fetching the same facts every 20 s moves only the
    // "as of": held back.
    for (var i = 0; i < 2; i++) {
      now = now.add(const Duration(seconds: 20));
      factsAt = now;
      source.notifyListeners();
      await tester.pump(debounce);
    }
    expect(channel.pushed, hasLength(1));

    // A minute on, the newer "as of" goes out.
    now = now.add(const Duration(seconds: 20));
    factsAt = now;
    source.notifyListeners();
    await tester.pump(debounce);
    expect(channel.pushed, hasLength(2));
    expect(channel.pushed.last.dashboard!.factsAt, factsAt);

    // A changed count never waits.
    stuck = 2;
    source.notifyListeners();
    await tester.pump(debounce);
    expect(channel.pushed, hasLength(3));
    expect(channel.pushed.last.dashboard!.stuck, 2);

    // And an identical snapshot is skipped.
    source.notifyListeners();
    await tester.pump(debounce);
    expect(channel.pushed, hasLength(3));
  });

  test('contentOf ignores only the update time and the "as of"', () {
    AgentStatusSnapshot at(DateTime time, {int done = 2}) =>
        AgentStatusSnapshot.build(
          hosts: const [],
          monitoring: true,
          now: time,
          dashboard: AgentStatusDashboard(
            needsYou: 0,
            working: 0,
            done: done,
            factsAt: time,
          ),
        );
    final a = DateTime.utc(2026, 9, 27, 10);
    final b = a.add(const Duration(minutes: 3));
    expect(
      AgentStatusWidgetPusher.contentOf(at(a)),
      AgentStatusWidgetPusher.contentOf(at(b)),
    );
    expect(
      AgentStatusWidgetPusher.contentOf(at(a)),
      isNot(AgentStatusWidgetPusher.contentOf(at(a, done: 3))),
    );
  });

  testWidgets('reads the dashboard\'s cached digest without ever asking a '
      'machine, and never for summaries', (tester) async {
    final workspace = TerminalWorkspaceController(
      ImmediateTerminalRepository(TrackableTerminalSession()),
    );
    final attention = AgentAttentionController(
      workspace: workspace,
      runnerFactory: (_) => ScriptedAgentCommandRunner(const []),
      provider: const HerdrAttentionProvider(),
      pollInterval: const Duration(days: 1),
    );
    final runner = FakeDigestRunner(
      facts: digestReplyJson([
        digestAgentJson(
          'web',
          state: 'working',
          stuck: [
            {'rule': 'tests', 'reason': 'npm test failed 3 times'},
          ],
          summaryPending: true,
        ),
        digestAgentJson('doc'),
      ]),
    );
    final digestSource = FakeDigestSource(
      [digestHost('box', name: 'Box')],
      {'box': runner},
    );
    final fetchedAt = DateTime.utc(2026, 9, 27, 14);
    final digest = DigestController(
      source: digestSource,
      preferences: MemoryDigestPreferencesStore(),
      clock: () => fetchedAt,
      observeLifecycle: false,
    );
    final channel = FakeAgentStatusWidgetChannel();
    final pusher = AgentStatusWidgetPusher.forController(
      attention,
      digest: digest,
      channel: channel,
      debounce: const Duration(milliseconds: 10),
    )..start();
    addTearDown(() {
      pusher.dispose();
      digest.dispose();
      attention.dispose();
      workspace.dispose();
    });
    await tester.pump(const Duration(minutes: 5));
    // Nothing cached: stuck and done unknown, and nobody was asked.
    expect(runner.commands, isEmpty);
    expect(AgentStatusWidgetPusher.cachedDigest(digest), isNull);
    expect(
      AgentStatusWidgetPusher.snapshotOf(attention, digest: digest).dashboard,
      isNull, // nothing monitored
    );

    // The user opens the dashboard once (facts, and the summaries the
    // opened view asks for).
    final detach = digest.attachView();
    await tester.pump();
    await tester.pump();
    detach();
    await tester.pump();
    final asked = runner.commands.length;
    final summarised = runner.summaryCommands.length;

    final cached = AgentStatusWidgetPusher.cachedDigest(digest)!;
    expect(cached.at, fetchedAt);
    expect(cached.overview.section(DigestSection.stuck).single.name, 'web');

    // Pushes keep reading the cache; the machine is never asked again.
    for (var i = 0; i < 3; i++) {
      digest.notifyListeners();
      await tester.pump(const Duration(minutes: 2));
    }
    expect(runner.commands, hasLength(asked));
    expect(runner.summaryCommands, hasLength(summarised));
  });
}

class _ThrowingChannel extends FakeAgentStatusWidgetChannel {
  @override
  Future<void> push(AgentStatusSnapshot snapshot) async {
    throw StateError('native side is gone');
  }
}
