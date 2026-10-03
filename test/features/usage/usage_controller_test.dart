import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/usage/data/usage_preferences.dart';
import 'package:conduit/features/usage/domain/usage_alert.dart';
import 'package:conduit/features/usage/domain/usage_report.dart';
import 'package:conduit/features/usage/presentation/usage_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'usage_fakes.dart';

void main() {
  late DateTime now;
  late FakeUsageRunner runner;
  late FakeUsageSource source;
  late FakeUsageNotifier notifier;
  late MemoryUsagePreferencesStore store;

  final resets = DateTime.utc(2026, 9, 25, 15);

  UsageController build({
    Duration interval = const Duration(seconds: 60),
    bool autoDispose = true,
  }) {
    final controller = UsageController(
      source: source,
      preferences: store,
      notifier: notifier,
      interval: interval,
      clock: () => now,
      observeLifecycle: false,
    );
    if (autoDispose) {
      addTearDown(controller.dispose);
    }
    return controller;
  }

  setUp(() {
    now = DateTime.utc(2026, 9, 25, 12);
    runner = FakeUsageRunner(
      () => FakeUsageRunner.ok(
        usageReplyJson(rows: [usageRow('2026-09-25', costUsd: 2)]),
      ),
    );
    source = FakeUsageSource([usageHost('box', name: 'Box')], {'box': runner});
    notifier = FakeUsageNotifier();
    store = MemoryUsagePreferencesStore();
  });

  testWidgets('asks nothing until a view shows usage', (tester) async {
    final controller = build();
    await tester.pump(const Duration(minutes: 5));
    expect(runner.commands, isEmpty);
    expect(controller.summary.machines.single.hostName, 'Box');
    expect(controller.summary.machines.single.report, isNull);

    final detach = controller.attachView();
    await tester.pump();
    expect(runner.commands, hasLength(1));
    expect(runner.commands.single, contains('usage --days 7'));
    expect(controller.summary.today.costUsd, 2);
    detach();
  });

  testWidgets('polls every interval while visible, reuses a fresh reply', (
    tester,
  ) async {
    final controller = build();
    final detach = controller.attachView();
    await tester.pump();
    expect(runner.commands, hasLength(1));

    now = now.add(const Duration(seconds: 60));
    await tester.pump(const Duration(seconds: 60));
    expect(runner.commands, hasLength(2));

    // Hidden: no polls.
    detach();
    now = now.add(const Duration(minutes: 5));
    await tester.pump(const Duration(minutes: 5));
    expect(runner.commands, hasLength(2));

    // Shown again 10 s after a poll would still be cached; after 5 min the
    // reply is stale and is fetched at once.
    final again = controller.attachView();
    await tester.pump();
    expect(runner.commands, hasLength(3));
    again();

    now = now.add(const Duration(seconds: 10));
    final third = controller.attachView();
    await tester.pump();
    expect(runner.commands, hasLength(3));
    third();
  });

  testWidgets('a partial scan is polled again soon', (tester) async {
    var partial = true;
    runner.reply = () => FakeUsageRunner.ok(usageReplyJson(partial: partial));
    final controller = build();
    final detach = controller.attachView();
    await tester.pump();
    expect(controller.summary.machines.single.report!.partial, isTrue);
    partial = false;
    now = now.add(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 5));
    expect(runner.commands, hasLength(2));
    expect(controller.summary.machines.single.report!.partial, isFalse);
    now = now.add(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 5));
    expect(runner.commands, hasLength(2));
    detach();
  });

  testWidgets('pauses in the background', (tester) async {
    final controller = build();
    final detach = controller.attachView();
    await tester.pump();
    controller.setAppActive(false);
    now = now.add(const Duration(minutes: 3));
    await tester.pump(const Duration(minutes: 3));
    expect(runner.commands, hasLength(1));
    controller.setAppActive(true);
    await tester.pump();
    expect(runner.commands, hasLength(2));
    detach();
  });

  testWidgets('an older companion is marked for an update and left alone', (
    tester,
  ) async {
    runner.reply = () => const AgentCommandResult(
      stdout: '{"error":"unknown command usage"}',
      stderr: '',
      exitCode: 1,
    );
    final controller = build();
    final detach = controller.attachView();
    await tester.pump();
    final machine = controller.summary.machines.single;
    expect(machine.needsUpdate, isTrue);
    expect(machine.error, isNull);
    now = now.add(const Duration(minutes: 2));
    await tester.pump(const Duration(minutes: 2));
    expect(runner.commands, hasLength(1));
    detach();
  });

  testWidgets('a failure keeps the last reply and reports the error', (
    tester,
  ) async {
    final controller = build();
    final detach = controller.attachView();
    await tester.pump();
    runner.reply = () => throw StateError('connection lost');
    await controller.refresh();
    final machine = controller.summary.machines.single;
    expect(machine.report, isNotNull);
    expect(machine.error, contains('connection lost'));
    detach();
  });

  testWidgets('closes runners it owns', (tester) async {
    source.owned = true;
    final controller = build();
    final detach = controller.attachView();
    await tester.pump();
    expect(runner.closed, 1);
    detach();
  });

  testWidgets('follows the source: new machines are asked at once', (
    tester,
  ) async {
    final other = FakeUsageRunner(
      () => FakeUsageRunner.ok(usageReplyJson(machine: 'other')),
    );
    final controller = build();
    final detach = controller.attachView();
    await tester.pump();
    source
      ..hosts = [...source.hosts, usageHost('other')]
      ..runners['other'] = other
      ..changed();
    await tester.pump();
    expect(other.commands, hasLength(1));
    expect(controller.summary.machines, hasLength(2));
    source
      ..hosts = [usageHost('other')]
      ..changed();
    expect(controller.summary.machines.single.hostId, 'other');
    detach();
  });

  testWidgets('the 80 % alert fires once per window, only when enabled', (
    tester,
  ) async {
    final controller = build(autoDispose: false);
    await tester.pump();
    source
      ..live['box'] = [UsageLimit(label: '5h', usedPct: 85, resetsAt: resets)]
      ..changed();
    await tester.pump();
    expect(notifier.shown, isEmpty, reason: 'off by default');

    await controller.setAlertEnabled(true);
    await tester.pump();
    expect(notifier.shown, hasLength(1));
    expect(notifier.shown.single.id, UsageAlert.notificationId);
    expect(
      notifier.shown.single.body,
      '85% of your 5-hour window used, resets at ${formatClockTime(resets)}.',
    );
    expect(store.value.alertedWindow, resets);

    // More reports of the same window: quiet.
    source
      ..live['box'] = [UsageLimit(label: '5h', usedPct: 92, resetsAt: resets)]
      ..changed();
    await tester.pump();
    expect(notifier.shown, hasLength(1));

    // A restart remembers the window.
    controller.dispose();
    final restarted = build();
    await tester.pump();
    expect(restarted.preferences.alertedWindow, resets);
    expect(notifier.shown, hasLength(1));

    // The next window alerts again.
    final next = resets.add(const Duration(hours: 5));
    now = resets.add(const Duration(hours: 4));
    source
      ..live['box'] = [UsageLimit(label: '5h', usedPct: 80, resetsAt: next)]
      ..changed();
    await tester.pump();
    expect(notifier.shown, hasLength(2));
  });

  testWidgets('limits merge the monitor reports with the usage reply', (
    tester,
  ) async {
    runner.reply = () => FakeUsageRunner.ok(
      usageReplyJson(
        limits: [
          {
            'label': '5h',
            'usedPct': 40,
            'resetsAt': resets.millisecondsSinceEpoch,
          },
          {'label': '7d', 'usedPct': 12},
        ],
      ),
    );
    source.live['box'] = [
      UsageLimit(label: '5h', usedPct: 44, resetsAt: resets),
    ];
    final controller = build();
    final detach = controller.attachView();
    await tester.pump();
    expect(controller.summary.fiveHour!.usedPct, 44);
    expect(controller.summary.weekly!.usedPct, 12);
    detach();
  });

  // CON-067: the numbers on a usage screen just opened, or pulled to
  // refresh, were up to a minute old in the app and another minute in the
  // companion's cswap cache.
  testWidgets('a usage screen opening asks at once, cswap included', (
    tester,
  ) async {
    final controller = build();
    final bar = controller.attachView();
    await tester.pump();
    expect(runner.commands, hasLength(1));
    expect(runner.commands.single, isNot(contains('--fresh')));
    // A reply seconds old: the bar alone would wait for the interval.
    now = now.add(const Duration(seconds: 5));
    final screen = controller.attachView(refresh: true);
    await tester.pump();
    expect(runner.commands, hasLength(2));
    expect(runner.commands.last, contains('--fresh'));
    await controller.refresh();
    expect(runner.commands, hasLength(3));
    expect(runner.commands.last, contains('--fresh'));
    // The regular poll stays cached.
    now = now.add(const Duration(seconds: 60));
    await tester.pump(const Duration(seconds: 60));
    expect(runner.commands, hasLength(4));
    expect(runner.commands.last, isNot(contains('--fresh')));
    screen();
    bar();
  });

  testWidgets('limits follow the newest report, not a later window of '
      'another account', (tester) async {
    final at = now.subtract(const Duration(minutes: 1));
    runner.reply = () => FakeUsageRunner.ok(
      usageReplyJson(
        limits: [
          {
            'label': '7d',
            'usedPct': 99,
            'resetsAt': resets
                .add(const Duration(days: 4))
                .millisecondsSinceEpoch,
            'at': now.subtract(const Duration(hours: 9)).millisecondsSinceEpoch,
          },
        ],
      ),
    );
    source.live['box'] = [
      UsageLimit(
        label: '7d',
        usedPct: 52,
        resetsAt: resets.add(const Duration(days: 2)),
        reportedAt: at,
      ),
    ];
    final controller = build();
    final detach = controller.attachView();
    await tester.pump();
    expect(controller.summary.weekly!.usedPct, 52);
    expect(controller.summary.weekly!.reportedAt, at);
    detach();
  });

  testWidgets('remembers the collapsed bar', (tester) async {
    final controller = build();
    await tester.pump();
    await controller.setBarCollapsed(true);
    expect(store.value.barCollapsed, isTrue);
    expect(controller.preferences.barCollapsed, isTrue);
    expect(
      UsagePreferences.fromJson(store.value.toJson()).barCollapsed,
      isTrue,
    );
  });
}
