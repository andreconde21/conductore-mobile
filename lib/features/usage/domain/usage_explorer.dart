import 'package:conduit/features/usage/domain/usage_range.dart';
import 'package:conduit/features/usage/domain/usage_report.dart';
import 'package:conduit/features/usage/domain/usage_summary.dart';

/// What the explorer's numbers and bars measure.
enum UsageMetric {
  tokens('Tokens'),
  cost('Cost');

  const UsageMetric(this.label);

  final String label;

  static UsageMetric? byName(Object? name) {
    for (final metric in values) {
      if (metric.name == name) {
        return metric;
      }
    }
    return null;
  }
}

/// [totals] in [metric]: tokens, or the estimated cost (0 without a price).
double usageMetricValue(UsageTotals totals, UsageMetric metric) =>
    switch (metric) {
      UsageMetric.tokens => totals.tokens.toDouble(),
      UsageMetric.cost => totals.costUsd ?? 0,
    };

/// `1.2M tokens`, `$4.20`.
String formatUsageMetric(UsageTotals totals, UsageMetric metric) =>
    switch (metric) {
      UsageMetric.tokens => '${formatUsageTokens(totals.tokens)} tokens',
      UsageMetric.cost => formatUsageCost(totals.costUsd),
    };

/// A value of [metric] alone: `1.2M`, `$4.20`.
String formatUsageMetricValue(double value, UsageMetric metric) =>
    switch (metric) {
      UsageMetric.tokens => formatUsageTokens(value.round()),
      UsageMetric.cost => formatUsageCost(value),
    };

/// What rows can be broken down and filtered by.
enum UsageDimension {
  project('Project', 'Projects'),
  model('Model', 'Models'),
  session('Session', 'Sessions'),
  machine('Machine', 'Machines'),
  account('Account', 'Accounts'),
  agent('Agent', 'Agents');

  const UsageDimension(this.label, this.plural);

  final String label;
  final String plural;

  /// Session rows come apart from the others (`bySession`): filtering by a
  /// session would leave the day and hour charts meaningless.
  bool get filterable => this != UsageDimension.session;
}

/// A row's value for [dimension]; null when the row does not have one (a
/// session of a row that is not per session). Rows without an account
/// have [kUsageNoAccount].
String? usageRowValue(UsageRow row, UsageDimension dimension) =>
    switch (dimension) {
      UsageDimension.project => row.project,
      UsageDimension.model => row.model,
      UsageDimension.session => row.session,
      UsageDimension.machine => row.machine,
      UsageDimension.account => row.account ?? kUsageNoAccount,
      UsageDimension.agent => row.agent.label,
    };

/// The account of usage from before the companion saw which one was
/// active (or without cswap).
const kUsageNoAccount = 'Not attributed';

/// The chips that narrow the whole explorer: rows match when, for every
/// dimension with values, their value is one of them.
class UsageFilter {
  const UsageFilter([this.values = const {}]);

  static const none = UsageFilter();

  final Map<UsageDimension, Set<String>> values;

  bool get isEmpty => values.values.every((set) => set.isEmpty);

  bool has(UsageDimension dimension, String value) =>
      values[dimension]?.contains(value) ?? false;

  /// Every (dimension, value) chip, in dimension order.
  List<(UsageDimension, String)> get chips => [
    for (final dimension in UsageDimension.values)
      for (final value in values[dimension] ?? const <String>{})
        (dimension, value),
  ];

  bool matches(UsageRow row) {
    for (final MapEntry(key: dimension, value: allowed) in values.entries) {
      if (allowed.isEmpty) {
        continue;
      }
      final value = usageRowValue(row, dimension);
      if (value == null || !allowed.contains(value)) {
        return false;
      }
    }
    return true;
  }

  /// Adds [value] when absent, else removes it.
  UsageFilter toggle(UsageDimension dimension, String value) {
    if (!dimension.filterable) {
      return this;
    }
    final next = {
      for (final e in values.entries) e.key: {...e.value},
    };
    final set = next[dimension] ??= {};
    if (!set.remove(value)) {
      set.add(value);
    }
    if (set.isEmpty) {
      next.remove(dimension);
    }
    return UsageFilter(next);
  }

  UsageFilter clear() => none;

  @override
  bool operator ==(Object other) =>
      other is UsageFilter &&
      other.chips.length == chips.length &&
      chips.every((c) => other.has(c.$1, c.$2));

  @override
  int get hashCode => Object.hashAllUnordered(chips);
}

/// The change from [previous] to [current]: `+18%`. Null percent when the
/// previous period had nothing (and the current one something).
class UsageComparison {
  const UsageComparison({required this.current, required this.previous});

  final double current;
  final double previous;

  double? get percent {
    if (previous == 0) {
      return current == 0 ? 0 : null;
    }
    return (current - previous) / previous * 100;
  }

  /// `+18%`, `−4%`, `±0%`, `new`.
  String get label {
    final pct = percent;
    if (pct == null) {
      return 'new';
    }
    final rounded = pct.round();
    if (rounded == 0) {
      return '±0%';
    }
    return rounded > 0 ? '+$rounded%' : '−${-rounded}%';
  }
}

/// The rows of one view (a range, or a day), filtered, and what the
/// explorer shows of them.
class UsageSlice {
  UsageSlice(Iterable<UsageRow> rows, {this.filter = UsageFilter.none})
    : rows = [
        for (final row in rows)
          if (filter.matches(row)) row,
      ];

  final UsageFilter filter;
  final List<UsageRow> rows;

  UsageTotals get total =>
      rows.fold(UsageTotals.zero, (sum, row) => sum + row.totals);

  /// Totals of [range]'s days (to its end: future days are zero).
  List<UsageDay> days(UsageDateRange range) {
    final sums = <String, UsageTotals>{};
    for (final row in rows) {
      sums[row.date] = (sums[row.date] ?? UsageTotals.zero) + row.totals;
    }
    return [
      for (final date in range.shownDays)
        UsageDay(date, sums[date] ?? UsageTotals.zero),
    ];
  }

  /// Totals of [date]'s 24 hours; rows without an hour are left out.
  List<UsageTotals> hours(String date) {
    final hours = List<UsageTotals>.filled(24, UsageTotals.zero);
    for (final row in rows) {
      final hour = row.hour;
      if (row.date == date && hour != null) {
        hours[hour] = hours[hour] + row.totals;
      }
    }
    return hours;
  }

  /// Rows summed by [dimension], largest first in [metric] (then the
  /// other measure). Rows without a value are left out.
  List<UsageGroup> groupBy(
    UsageDimension dimension, {
    UsageMetric metric = UsageMetric.cost,
  }) {
    final sums = <String, UsageTotals>{};
    for (final row in rows) {
      final key = usageRowValue(row, dimension);
      if (key != null) {
        sums[key] = (sums[key] ?? UsageTotals.zero) + row.totals;
      }
    }
    final other = metric == UsageMetric.cost
        ? UsageMetric.tokens
        : UsageMetric.cost;
    return [for (final e in sums.entries) UsageGroup(e.key, e.value)]
      ..sort((a, b) {
        final first = usageMetricValue(
          b.totals,
          metric,
        ).compareTo(usageMetricValue(a.totals, metric));
        return first != 0
            ? first
            : usageMetricValue(
                b.totals,
                other,
              ).compareTo(usageMetricValue(a.totals, other));
      });
  }

  /// Every value of [dimension] present, sorted.
  List<String> valuesOf(UsageDimension dimension) =>
      {for (final row in rows) ?usageRowValue(row, dimension)}.toList()..sort();
}

/// [rows] as CSV: one line per row, the estimate marked in the header.
String usageRowsCsv(Iterable<UsageRow> rows) {
  String cell(Object? value) {
    final text = value?.toString() ?? '';
    return RegExp(r'[",\n\r]').hasMatch(text)
        ? '"${text.replaceAll('"', '""')}"'
        : text;
  }

  final lines = [
    'date,hour,machine,agent,account,project,model,input,output,'
        'cache_write,cache_read,tokens,messages,cost_usd_api_estimate',
    for (final row in rows)
      [
        row.date,
        row.hour,
        row.machine,
        row.agent.label,
        row.account,
        row.project,
        row.model,
        row.totals.input,
        row.totals.output,
        row.totals.cacheWrite,
        row.totals.cacheRead,
        row.totals.tokens,
        row.totals.messages,
        row.totals.costUsd?.toStringAsFixed(6),
      ].map(cell).join(','),
  ];
  return '${lines.join('\n')}\n';
}

/// A point in a day chart: [date] and how far into it ([fraction], 0 to
/// 1), with what happens there.
class UsageChartMarker {
  const UsageChartMarker({
    required this.date,
    required this.fraction,
    required this.label,
    this.upcoming = false,
  });

  final String date;
  final double fraction;
  final String label;

  /// The weekly window resets here (else: the current window began).
  final bool upcoming;
}

/// Where the weekly limit window of [weekly] begins and resets within
/// [range], in the machine's local time ([utcOffsetMinutes]).
List<UsageChartMarker> usageWeeklyMarkers(
  UsageLimit? weekly,
  UsageDateRange range, {
  required int utcOffsetMinutes,
}) {
  final resets = weekly?.resetsAt;
  if (resets == null) {
    return const [];
  }
  String clock(DateTime local) =>
      '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
  final markers = <UsageChartMarker>[];
  for (final (at, upcoming) in [
    (resets.subtract(const Duration(days: 7)), false),
    (resets, true),
  ]) {
    // The instant's wall clock on the machine, as UTC fields.
    final local = at.toUtc().add(Duration(minutes: utcOffsetMinutes));
    final date = formatUsageDate(local);
    if (date.compareTo(range.from) < 0 || date.compareTo(range.end) > 0) {
      continue;
    }
    markers.add(
      UsageChartMarker(
        date: date,
        fraction: (local.hour * 60 + local.minute) / (24 * 60),
        label: upcoming
            ? 'Weekly limit resets ${usageWeekday(date)} ${clock(local)}'
            : 'Weekly window began ${usageWeekday(date)} ${clock(local)}',
        upcoming: upcoming,
      ),
    );
  }
  return markers;
}
