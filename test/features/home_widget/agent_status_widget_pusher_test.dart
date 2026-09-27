import 'dart:async';

import 'package:conduit/features/agent_attention/data/herdr_attention_provider.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/home_widget/domain/agent_status_snapshot.dart';
import 'package:conduit/features/home_widget/presentation/agent_status_widget_pusher.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:conduit/features/usage/domain/usage_report.dart';
import 'package:conduit/features/usage/presentation/usage_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';
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
}

class _ThrowingChannel extends FakeAgentStatusWidgetChannel {
  @override
  Future<void> push(AgentStatusSnapshot snapshot) async {
    throw StateError('native side is gone');
  }
}
