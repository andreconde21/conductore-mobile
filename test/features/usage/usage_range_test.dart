import 'dart:convert';
import 'dart:ui';

import 'package:conduit/features/usage/data/usage_preferences.dart';
import 'package:conduit/features/usage/domain/usage_explorer.dart';
import 'package:conduit/features/usage/domain/usage_range.dart';
import 'package:conduit/features/usage/domain/usage_report.dart';
import 'package:flutter_test/flutter_test.dart';

import 'usage_fakes.dart';

UsageRow row(
  String date, {
  String project = 'api',
  String model = 'opus',
  String machine = 'box',
  int output = 100,
  double? cost = 1,
  int? hour,
  String? account,
  String? session,
  UsageAgent agent = UsageAgent.claude,
}) => UsageRow(
  date: date,
  project: project,
  model: model,
  machine: machine,
  agent: agent,
  hour: hour,
  account: account,
  session: session,
  totals: UsageTotals(output: output, input: 10, costUsd: cost),
);

void main() {
  group('ranges', () {
    // 2026-09-25 is a Friday.
    UsageDateRange resolve(
      UsageRangePreset preset, {
      String today = '2026-09-25',
      int firstWeekday = DateTime.monday,
      UsageDateRange? custom,
    }) => resolveUsageRange(
      preset,
      today: today,
      firstWeekday: firstWeekday,
      custom: custom,
    );

    test('today, yesterday, 7 and 30 days end today', () {
      expect(
        resolve(UsageRangePreset.today),
        const UsageDateRange('2026-09-25', '2026-09-25'),
      );
      expect(
        resolve(UsageRangePreset.yesterday),
        const UsageDateRange('2026-09-24', '2026-09-24'),
      );
      expect(resolve(UsageRangePreset.last7).from, '2026-09-19');
      expect(resolve(UsageRangePreset.last7).length, 7);
      expect(resolve(UsageRangePreset.last30).from, '2026-08-27');
      expect(resolve(UsageRangePreset.last30).length, 30);
      // Across a year boundary.
      expect(
        resolve(UsageRangePreset.last7, today: '2027-01-03').from,
        '2026-12-28',
      );
    });

    test('this week starts on Monday, or Sunday where that is the custom', () {
      final week = resolve(UsageRangePreset.thisWeek);
      expect(week.from, '2026-09-21');
      expect(week.to, '2026-09-25');
      expect(week.end, '2026-09-27');
      expect(week.length, 5);
      expect(week.shownDays, hasLength(7));
      final sunday = resolve(
        UsageRangePreset.thisWeek,
        firstWeekday: DateTime.sunday,
      );
      expect(sunday.from, '2026-09-20');
      expect(sunday.end, '2026-09-26');
      // On the first day of the week the week is that day.
      final monday = resolve(UsageRangePreset.thisWeek, today: '2026-09-21');
      expect(monday.from, '2026-09-21');
      expect(monday.length, 1);
      expect(firstWeekdayFor(const Locale('pt', 'PT')), DateTime.monday);
      expect(firstWeekdayFor(const Locale('en', 'US')), DateTime.sunday);
      expect(firstWeekdayFor(const Locale('pt', 'BR')), DateTime.sunday);
      expect(firstWeekdayFor(const Locale('en')), DateTime.monday);
      expect(firstWeekdayFor(null), DateTime.monday);
    });

    test('this month runs to its last day; February and leap years', () {
      final month = resolve(UsageRangePreset.thisMonth);
      expect(month.from, '2026-09-01');
      expect(month.to, '2026-09-25');
      expect(month.end, '2026-09-30');
      expect(
        resolve(UsageRangePreset.thisMonth, today: '2028-02-10').end,
        '2028-02-29',
      );
      expect(
        resolve(UsageRangePreset.thisMonth, today: '2027-02-10').end,
        '2027-02-28',
      );
    });

    test('custom ranges are clamped to today', () {
      final custom = resolve(
        UsageRangePreset.custom,
        custom: const UsageDateRange('2026-09-20', '2026-10-02'),
      );
      expect(custom, const UsageDateRange('2026-09-20', '2026-09-25'));
      expect(
        resolve(
          UsageRangePreset.custom,
          custom: const UsageDateRange('2026-10-01', '2026-10-02'),
        ),
        const UsageDateRange('2026-09-25', '2026-09-25'),
      );
    });

    test('the previous period: as long, just before; months by the day', () {
      expect(
        previousUsageRange(
          UsageRangePreset.last7,
          resolve(UsageRangePreset.last7),
        ),
        const UsageDateRange('2026-09-12', '2026-09-18'),
      );
      expect(
        previousUsageRange(
          UsageRangePreset.today,
          resolve(UsageRangePreset.today),
        ),
        const UsageDateRange('2026-09-24', '2026-09-24'),
      );
      // Monday to Friday of the week before.
      expect(
        previousUsageRange(
          UsageRangePreset.thisWeek,
          resolve(UsageRangePreset.thisWeek),
        ),
        const UsageDateRange('2026-09-14', '2026-09-18'),
      );
      // September 1–25 against August 1–25.
      expect(
        previousUsageRange(
          UsageRangePreset.thisMonth,
          resolve(UsageRangePreset.thisMonth),
        ),
        const UsageDateRange('2026-08-01', '2026-08-25'),
      );
      // March 1–31 against all of February, not into March.
      expect(
        previousUsageRange(
          UsageRangePreset.thisMonth,
          resolve(UsageRangePreset.thisMonth, today: '2027-03-31'),
        ),
        const UsageDateRange('2027-02-01', '2027-02-28'),
      );
      // January against December.
      expect(
        previousUsageRange(
          UsageRangePreset.thisMonth,
          resolve(UsageRangePreset.thisMonth, today: '2027-01-05'),
        ),
        const UsageDateRange('2026-12-01', '2026-12-05'),
      );
    });

    test('date arithmetic ignores daylight saving', () {
      // Europe's clocks go back on 2026-10-25.
      expect(addUsageDays('2026-10-24', 1), '2026-10-25');
      expect(addUsageDays('2026-10-25', 1), '2026-10-26');
      expect(usageDaysBetween('2026-10-20', '2026-10-30'), 10);
      expect(usageDaysBetween('2026-03-25', '2026-04-05'), 11);
      expect(formatUsageRange(resolve(UsageRangePreset.last7)), '19–25 Sep');
      expect(
        formatUsageRange(const UsageDateRange('2026-09-29', '2026-10-05')),
        '29 Sep – 5 Oct',
      );
      expect(
        formatUsageRange(const UsageDateRange('2026-12-29', '2027-01-04')),
        '29 Dec 2026 – 4 Jan 2027',
      );
      expect(formatUsageDay('2026-09-25'), 'Fri 25 Sep');
    });
  });

  group('explorer maths', () {
    test('comparison: percent change, nothing before is new', () {
      expect(const UsageComparison(current: 118, previous: 100).label, '+18%');
      expect(const UsageComparison(current: 96, previous: 100).label, '−4%');
      expect(const UsageComparison(current: 5, previous: 0).label, 'new');
      expect(const UsageComparison(current: 0, previous: 0).label, '±0%');
      expect(
        const UsageComparison(current: 150, previous: 100).percent,
        closeTo(50, 1e-9),
      );
    });

    test('filters narrow every view; tapping twice removes the chip', () {
      final rows = [
        row('2026-09-24'),
        row('2026-09-25', project: 'web', output: 50, account: 'work'),
        row('2026-09-25', machine: 'mac', output: 20),
      ];
      var filter = UsageFilter.none.toggle(UsageDimension.project, 'api');
      expect(filter.chips, [(UsageDimension.project, 'api')]);
      var slice = UsageSlice(rows, filter: filter);
      expect(slice.total.output, 120);
      filter = filter.toggle(UsageDimension.machine, 'mac');
      expect(UsageSlice(rows, filter: filter).total.output, 20);
      filter = filter
          .toggle(UsageDimension.machine, 'mac')
          .toggle(UsageDimension.project, 'api');
      expect(filter.isEmpty, isTrue);
      // Accounts: rows before the companion saw one are "not attributed".
      slice = UsageSlice(
        rows,
        filter: UsageFilter.none.toggle(UsageDimension.account, 'work'),
      );
      expect(slice.total.output, 50);
      expect(UsageSlice(rows).valuesOf(UsageDimension.account), [
        kUsageNoAccount,
        'work',
      ]);
      // Sessions are not a filter.
      expect(
        UsageFilter.none.toggle(UsageDimension.session, 'abc').isEmpty,
        isTrue,
      );
    });

    test('days fill the range with empty and future days; hours add up', () {
      final slice = UsageSlice([
        row('2026-09-24', hour: 9),
        row('2026-09-24', output: 50, hour: 9, project: 'web'),
        row('2026-09-24', output: 10, hour: 23),
        row('2026-09-25', output: 7),
      ]);
      final days = slice.days(
        const UsageDateRange('2026-09-23', '2026-09-25', end: '2026-09-27'),
      );
      expect(days.map((d) => d.date), [
        '2026-09-23',
        '2026-09-24',
        '2026-09-25',
        '2026-09-26',
        '2026-09-27',
      ]);
      expect(days.map((d) => d.totals.output), [0, 160, 7, 0, 0]);
      final hours = slice.hours('2026-09-24');
      expect(hours, hasLength(24));
      expect(hours[9].output, 150);
      expect(hours[23].output, 10);
      // Groups: largest first in the measure asked for.
      final byProject = slice.groupBy(
        UsageDimension.project,
        metric: UsageMetric.tokens,
      );
      expect(byProject.first.label, 'api');
      expect(byProject.first.totals.output, 117);
    });

    test('CSV: one line per row, quoted where needed, estimate marked', () {
      final csv = usageRowsCsv([
        row('2026-09-24', project: 'my, "app"', hour: 9, account: 'work'),
      ]);
      final lines = const LineSplitter().convert(csv);
      expect(lines.first, contains('cost_usd_api_estimate'));
      expect(
        lines[1],
        '2026-09-24,9,box,Claude,work,"my, ""app""",opus,10,100,0,0,110,0,'
        '1.000000',
      );
    });

    test('weekly markers: where the window began and resets, local time', () {
      final weekly = UsageLimit(
        label: '7d',
        usedPct: 40,
        // 14:30 UTC = 15:30 in Lisbon (summer time, +60).
        resetsAt: DateTime.utc(2026, 9, 24, 14, 30),
      );
      const week = UsageDateRange(
        '2026-09-21',
        '2026-09-25',
        end: '2026-09-27',
      );
      final markers = usageWeeklyMarkers(weekly, week, utcOffsetMinutes: 60);
      expect(markers, hasLength(1));
      expect(markers.single.date, '2026-09-24');
      expect(markers.single.upcoming, isTrue);
      expect(markers.single.fraction, closeTo((15 * 60 + 30) / 1440, 1e-9));
      expect(markers.single.label, 'Weekly limit resets Thu 15:30');
      final twoWeeks = usageWeeklyMarkers(
        weekly,
        const UsageDateRange('2026-09-12', '2026-09-25'),
        utcOffsetMinutes: 60,
      );
      expect(twoWeeks.map((m) => m.upcoming), [false, true]);
      expect(twoWeeks.first.date, '2026-09-17');
      expect(usageWeeklyMarkers(null, week, utcOffsetMinutes: 0), isEmpty);
    });

    test('the command: a range, one day with hours, and the fallback', () {
      expect(companionUsageArguments(), 'usage --days 7');
      expect(
        companionUsageArguments(days: 31, from: '2026-09-12', to: '2026-09-25'),
        'usage --days 31 --from 2026-09-12 --to 2026-09-25',
      );
      expect(
        companionUsageArguments(
          days: 31,
          from: '2026-09-24',
          to: '2026-09-24',
          hourly: true,
          sessions: true,
        ),
        'usage --days 31 --day 2026-09-24 --hourly --sessions',
      );
    });

    test('replies with hours, sessions and accounts parse; older ones too', () {
      final report = parseUsageReport(
        jsonEncode({
          ...usageReplyJson(
            rows: [
              {...usageRow('2026-09-25'), 'hour': 14, 'account': 'work'},
            ],
          ),
          'to': '2026-09-25',
          'hourly': true,
          'detailFrom': '2026-08-26',
          'historyFrom': '2026-07-26',
          'utcOffsetMin': 60,
          'scan': {'partial': false, 'rebuilding': true},
        }),
      )!;
      expect(report.supportsRanges, isTrue);
      expect(report.hourly, isTrue);
      expect(report.rebuilding, isTrue);
      expect(report.utcOffsetMinutes, 60);
      expect(report.claude.rows.single.hour, 14);
      expect(report.claude.rows.single.account, 'work');
      final old = parseUsageReport(jsonEncode(usageReplyJson()))!;
      expect(old.supportsRanges, isFalse);
      expect(old.hourly, isFalse);
      expect(old.claude.bySession, isEmpty);
    });

    test('the explorer range and measure are remembered', () {
      const prefs = UsagePreferences(
        explorerRange: UsageRangePreset.custom,
        explorerCustom: UsageDateRange('2026-09-01', '2026-09-10'),
        explorerMetric: UsageMetric.cost,
      );
      final back = UsagePreferences.fromJson(
        jsonDecode(jsonEncode(prefs.toJson())),
      );
      expect(back.explorerRange, UsageRangePreset.custom);
      expect(back.explorerCustom, prefs.explorerCustom);
      expect(back.explorerMetric, UsageMetric.cost);
      expect(
        UsagePreferences.fromJson(const {}).explorerRange,
        UsageRangePreset.last7,
      );
    });
  });
}
