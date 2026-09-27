import 'dart:convert';

import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/sftp/domain/file_export.dart';
import 'package:conduit/features/usage/data/usage_preferences.dart';
import 'package:conduit/features/usage/domain/usage_explorer.dart';
import 'package:conduit/features/usage/domain/usage_range.dart';
import 'package:conduit/features/usage/presentation/usage_controller.dart';
import 'package:conduit/features/usage/presentation/usage_explorer_controller.dart';
import 'package:conduit/features/usage/presentation/usage_explorer_view.dart';
import 'package:conduit/features/usage/presentation/usage_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'usage_fakes.dart';

const today = '2026-09-25';

/// Daily rows from 2026-08-26 (31 days): api every day (1,100 tokens,
/// $1), and web on the 24th (600 tokens, $2, account "work").
List<Map<String, Object?>> dataset() => [
  for (var i = 0; i < 31; i++) usageRow(addUsageDays(today, -i)),
  {
    ...usageRow('2026-09-24', project: 'web', output: 500, costUsd: 2),
    'account': 'work',
  },
];

/// What a companion with ranges answers to [command].
AgentCommandResult newCompanion(String command) {
  String? flag(String name) =>
      RegExp('--$name (\\S+)').firstMatch(command)?.group(1);
  final day = flag('day');
  final to = day ?? flag('to') ?? today;
  final from = day ?? flag('from') ?? addUsageDays(to, -6);
  final hourly = command.contains('--hourly');
  final rows = [
    for (final row in dataset())
      if ((row['date']! as String).compareTo(from) >= 0 &&
          (row['date']! as String).compareTo(to) <= 0)
        if (hourly)
          for (final hour in [9, 14])
            {
              ...row,
              'hour': hour,
              'output': (row['output']! as int) ~/ 2,
              'input': (row['input']! as int) ~/ 2,
              'costUsd': (row['costUsd']! as num) / 2,
            }
        else
          row,
  ];
  final json = usageReplyJson(
    from: from,
    rows: rows,
    limits: [
      {
        'label': '7d',
        'usedPct': 40,
        'resetsAt': DateTime.utc(2026, 9, 24, 14, 30).millisecondsSinceEpoch,
      },
    ],
  );
  (json['claude']! as Map<String, Object?>)['bySession'] = [
    if (command.contains('--sessions'))
      for (final row in rows.where((r) => r['hour'] != 14))
        {...row, 'session': 'sess${row['project']}'},
  ];
  return FakeUsageRunner.ok({
    ...json,
    'to': to,
    'hourly': hourly,
    'utcOffsetMin': 60,
  });
}

/// A companion before ranges: 31 days of daily rows whatever is asked.
AgentCommandResult oldCompanion(String command) => FakeUsageRunner.ok(
  usageReplyJson(from: addUsageDays(today, -30), rows: dataset()),
);

class FakeExport implements FileExport {
  String? name;
  Uint8List? bytes;

  @override
  Future<String?> save(String fileName, Uint8List bytes) async {
    name = fileName;
    this.bytes = bytes;
    return '/tmp/$fileName';
  }
}

void main() {
  final now = DateTime.utc(2026, 9, 25, 12);
  late FakeUsageRunner runner;
  late FakeUsageSource source;
  late MemoryUsagePreferencesStore store;
  late AgentCommandResult Function(String) companion;

  setUp(() {
    companion = newCompanion;
    runner = FakeUsageRunner(() => companion(runner.commands.last));
    source = FakeUsageSource([usageHost('box', name: 'Box')], {'box': runner});
    store = MemoryUsagePreferencesStore();
  });

  UsageController usage() {
    final c = UsageController(
      source: source,
      preferences: store,
      clock: () => now,
      observeLifecycle: false,
    );
    addTearDown(c.dispose);
    return c;
  }

  Future<void> phone(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(500, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: child));
    await tester.pump();
    await tester.pump();
  }

  Future<void> desktop(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(1400, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
    await tester.pump();
    await tester.pump();
  }

  String text(WidgetTester tester, String key) =>
      tester.widget<Text>(find.byKey(ValueKey(key))).data!;

  group('controller', () {
    testWidgets('one call covers the range and the period before', (
      tester,
    ) async {
      final u = usage();
      final explorer = UsageExplorerController(usage: u)..start();
      addTearDown(explorer.dispose);
      await tester.pump();
      expect(
        runner.commands.where(
          (c) => c.contains('--from 2026-09-12 --to 2026-09-25'),
        ),
        hasLength(1),
      );
      // 19–25 Sep: 7 × 1,100 + 600 tokens; 12–18: 7 × 1,100.
      expect(explorer.current.total.tokens, 8300);
      expect(explorer.previousSlice.total.tokens, 7700);
      expect(explorer.comparison!.label, '+8%');
      expect(explorer.averagePerDay, closeTo(8300 / 7, 1e-9));
      explorer.setMetric(UsageMetric.cost);
      expect(explorer.comparison!.label, '+29%');
      expect(store.value.explorerMetric, UsageMetric.cost);
      explorer.stop();
    });

    testWidgets('an older companion: 31 daily days, filtered here', (
      tester,
    ) async {
      companion = oldCompanion;
      final u = usage();
      final explorer = UsageExplorerController(usage: u)..start();
      addTearDown(explorer.dispose);
      await tester.pump();
      expect(explorer.legacyHosts, ['box']);
      expect(explorer.current.total.tokens, 8300);
      expect(explorer.comparison, isNotNull);
      // 30 days needs 60: not there.
      explorer.setPreset(UsageRangePreset.last30);
      await tester.pump();
      expect(explorer.current.rows, hasLength(31));
      expect(explorer.comparison, isNull);
      // A day has no hours.
      explorer
        ..setPreset(UsageRangePreset.last7)
        ..selectDay('2026-09-24');
      await tester.pump();
      expect(explorer.daySlice.total.tokens, 1700);
      expect(explorer.dayHasHours, isFalse);
      expect(explorer.dayWithoutHours, ['box']);
      explorer.stop();
    });

    testWidgets('a one-day range asks for hours; days step the range', (
      tester,
    ) async {
      final u = usage();
      final explorer = UsageExplorerController(usage: u)..start();
      addTearDown(explorer.dispose);
      explorer.setPreset(UsageRangePreset.today);
      await tester.pump();
      expect(
        runner.commands.last,
        contains(
          'usage --days 31 --from 2026-09-24 --to 2026-09-25 --hourly --sessions',
        ),
      );
      expect(explorer.detailDay, today);
      expect(explorer.dayHasHours, isTrue);
      expect(explorer.daySlice.hours(today)[9].output, 500);
      expect(explorer.canStep(1), isFalse);
      expect(explorer.stepDay(-1), isTrue);
      expect(explorer.preset, UsageRangePreset.yesterday);
      expect(explorer.stepDay(-1), isTrue);
      expect(explorer.preset, UsageRangePreset.custom);
      expect(explorer.range.from, '2026-09-23');
      explorer.stop();
    });
  });

  group('phone', () {
    testWidgets('tap a day: its hours and breakdowns, arrows and swipes', (
      tester,
    ) async {
      final u = usage();
      await phone(tester, UsageExplorerPage(usage: u, now: now));
      expect(text(tester, 'usage-explorer-total'), '8k tokens');
      expect(text(tester, 'usage-explorer-delta'), 'vs previous period +8%');
      expect(
        find.byKey(const ValueKey('usage-explorer-average')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey('usage-explorer-day-2026-09-24')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('usage-day-page')), findsOneWidget);
      expect(text(tester, 'usage-day-title'), 'Thu 24 Sep');
      expect(
        runner.commands.last,
        contains('--day 2026-09-24 --hourly --sessions'),
      );
      expect(find.byKey(const ValueKey('usage-hour-chart')), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const ValueKey('usage-hour-9'))).height,
        greaterThan(0),
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('usage-hour-3'))).height,
        0,
      );
      expect(
        find.byKey(const ValueKey('usage-section-session')),
        findsOneWidget,
      );
      expect(find.text('web · sessweb'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('usage-section-account')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('usage-day-previous')));
      await tester.pumpAndSettle();
      expect(text(tester, 'usage-day-title'), 'Wed 23 Sep');
      await tester.fling(
        find.byKey(const ValueKey('usage-day-title')),
        const Offset(-300, 0),
        1000,
      );
      await tester.pumpAndSettle();
      expect(text(tester, 'usage-day-title'), 'Thu 24 Sep');

      // Back: the range again.
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('usage-day-page')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a row filters everything; the chip removes it', (
      tester,
    ) async {
      final u = usage();
      await phone(tester, UsageExplorerPage(usage: u, now: now));
      await tester.tap(find.byKey(const ValueKey('usage-row-project-web')));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('usage-filter-project-web')),
        findsOneWidget,
      );
      expect(text(tester, 'usage-explorer-total'), '600 tokens');
      expect(text(tester, 'usage-explorer-delta'), 'vs previous period new');
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('usage-filter-project-web')),
          matching: find.byType(Icon),
        ),
      );
      await tester.pump();
      expect(text(tester, 'usage-explorer-total'), '8k tokens');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('tokens or cost, the split, and the remembered range', (
      tester,
    ) async {
      // Portugal: weeks start on Monday (the test default, en-US, on
      // Sunday).
      tester.platformDispatcher.localeTestValue = const Locale('pt', 'PT');
      addTearDown(tester.platformDispatcher.clearLocaleTestValue);
      final u = usage();
      await phone(tester, UsageExplorerPage(usage: u, now: now));
      expect(
        find.byKey(const ValueKey('usage-explorer-estimate')),
        findsNothing,
      );
      await tester.tap(find.text('Cost'));
      await tester.pump();
      expect(text(tester, 'usage-explorer-total'), r'$9.00');
      expect(
        find.byKey(const ValueKey('usage-explorer-estimate')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('usage-split')));
      await tester.pump();
      expect(find.byKey(const ValueKey('usage-split-legend')), findsOneWidget);
      expect(find.text('Output 8k'), findsOneWidget);

      await tester.ensureVisible(
        find.byKey(const ValueKey('usage-range-thisWeek')),
      );
      await tester.tap(find.byKey(const ValueKey('usage-range-thisWeek')));
      await tester.pump();
      await tester.pump();
      expect(store.value.explorerRange, UsageRangePreset.thisWeek);
      expect(
        runner.commands.last,
        contains('--from 2026-09-14 --to 2026-09-25'),
      );
      // The week shows through Sunday, and where the weekly window resets.
      expect(
        find.byKey(const ValueKey('usage-explorer-day-2026-09-27')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('usage-weekly-marker-reset')),
        findsOneWidget,
      );
      // It reset yesterday (the test's now is Friday noon).
      expect(find.text('Weekly limit reset Thu 15:30'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());

      // Opening again starts on the week, in cost.
      await phone(tester, UsageExplorerPage(usage: u, now: now));
      expect(text(tester, 'usage-explorer-total'), r'$7.00');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('an older companion: daily numbers and the update note', (
      tester,
    ) async {
      companion = oldCompanion;
      final updates = <String>[];
      final u = usage();
      await phone(
        tester,
        UsageExplorerPage(usage: u, now: now, onUpdateCompanion: updates.add),
      );
      expect(text(tester, 'usage-explorer-total'), '8k tokens');
      await tester.tap(
        find.byKey(const ValueKey('usage-explorer-day-2026-09-24')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('usage-hour-chart')), findsNothing);
      expect(
        find.textContaining('Update agent hooks for hourly detail'),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(TextButton, 'Update agent hooks'));
      expect(updates, ['box']);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('CSV of the range and filters', (tester) async {
      final u = usage();
      final export = FakeExport();
      await phone(
        tester,
        UsageExplorerPage(usage: u, now: now, fileExport: export),
      );
      await tester.tap(find.byKey(const ValueKey('usage-row-project-web')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('usage-explorer-export')));
      await tester.pump();
      expect(export.name, 'usage-2026-09-19_2026-09-25.csv');
      final lines = const LineSplitter().convert(utf8.decode(export.bytes!));
      expect(lines, hasLength(2));
      expect(lines.last, startsWith('2026-09-24,,Box,Claude,work,web,'));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the home bar opens the explorer', (tester) async {
      final u = usage();
      await phone(
        tester,
        Scaffold(
          body: UsageHomeBar(controller: u, now: now),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('usage-today')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('usage-explorer-page')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('desktop', () {
    testWidgets('wide: breakdowns side by side, the day in a column', (
      tester,
    ) async {
      final u = usage();
      await desktop(tester, UsageExplorerView(usage: u, now: now));
      expect(find.byKey(const ValueKey('usage-explorer-grid')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('usage-section-project')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('usage-section-model')), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('usage-explorer-day-2026-09-24')),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('usage-day-panel')), findsOneWidget);
      expect(find.byKey(const ValueKey('usage-day-page')), findsNothing);
      expect(text(tester, 'usage-day-title'), 'Thu 24 Sep');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(text(tester, 'usage-day-title'), 'Fri 25 Sep');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byKey(const ValueKey('usage-day-panel')), findsNothing);
      // The filter picker is a dialog, not a bottom sheet.
      await tester.tap(find.byKey(const ValueKey('usage-filter-add')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('usage-filter-picker')), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('usage-filter-option-project-web')),
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('usage-filter-project-web')),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a scope opener shows the explorer elsewhere', (tester) async {
      final u = usage();
      String? opened;
      await desktop(
        tester,
        UsageScope(
          controller: u,
          openExplorer: ({String? day}) => opened = day ?? 'range',
          child: UsageBreakdown(controller: u, now: now),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('usage-explore')));
      expect(opened, 'range');
      await tester.tap(find.byKey(const ValueKey('usage-day-2026-09-24')));
      expect(opened, '2026-09-24');
      await tester.pumpWidget(const SizedBox());
    });
  });
}
