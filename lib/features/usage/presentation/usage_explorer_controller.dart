import 'dart:async';

import 'package:conduit/features/usage/domain/usage_explorer.dart';
import 'package:conduit/features/usage/domain/usage_range.dart';
import 'package:conduit/features/usage/domain/usage_report.dart';
import 'package:conduit/features/usage/presentation/usage_controller.dart';
import 'package:flutter/foundation.dart';

/// The companion keeps 31 days of detail: an older companion (no ranges)
/// is asked for all of them, and filtered here.
const _legacyDays = 31;

/// The usage explorer's state: the range (remembered per device), the
/// measure, the filters, the day open in detail, and the machines'
/// answers for them.
///
/// One `usage` call per machine covers the range and the period before it
/// (`--from <previous from> --to <to>`, with `--days 31` for companions
/// before ranges, which ignore the rest); a day in detail is one more call
/// (`--day D --hourly --sessions`), except for a one-day range, whose call
/// asks for hours and sessions itself. Answers are refreshed every
/// [refreshEvery] while [start]ed, sooner while a machine is still
/// counting.
class UsageExplorerController extends ChangeNotifier {
  UsageExplorerController({
    required this.usage,
    this.firstWeekday = DateTime.monday,
    this.refreshEvery = const Duration(seconds: 60),
    this.partialEvery = const Duration(seconds: 5),
  }) : _preset = usage.preferences.explorerRange,
       _custom = usage.preferences.explorerCustom,
       _metric = usage.preferences.explorerMetric {
    usage.addListener(_onUsageChanged);
  }

  final UsageController usage;

  /// The weekday "This week" starts on.
  final int firstWeekday;
  final Duration refreshEvery;
  final Duration partialEvery;

  UsageRangePreset _preset;
  UsageDateRange? _custom;
  UsageMetric _metric;
  bool _split = false;
  UsageFilter _filter = UsageFilter.none;
  String? _selectedDay;

  String? _rangeKey;
  List<UsageQueryResult> _range = const [];
  bool _rangeLoading = false;
  String? _dayKey;
  List<UsageQueryResult> _day = const [];
  bool _dayLoading = false;

  bool _started = false;
  bool _disposed = false;
  Timer? _timer;

  UsageRangePreset get preset => _preset;
  UsageMetric get metric => _metric;

  /// Input, output and cache shown apart.
  bool get split => _split;
  UsageFilter get filter => _filter;

  /// The picked custom range (also while another preset is chosen).
  UsageDateRange? get custom => _custom;

  /// The range on the machines' today.
  UsageDateRange get range => resolveUsageRange(
    _preset,
    today: usage.today,
    firstWeekday: firstWeekday,
    custom: _custom,
  );

  /// What [range] is compared with.
  UsageDateRange get previous => previousUsageRange(_preset, range);

  /// The day tapped in the chart (null: none open).
  String? get selectedDay => _selectedDay;

  /// The day whose hours and sessions are shown: the tapped one, or the
  /// range's only day.
  String? get detailDay {
    final r = range;
    return _selectedDay ?? (r.isSingleDay ? r.from : null);
  }

  bool get loading => _rangeLoading && _range.isEmpty;
  bool get refreshing => _rangeLoading || _dayLoading;
  bool get dayLoading => _dayLoading && _dayRowsSource.isEmpty;

  List<UsageQueryResult> get results => _range;

  /// Machines whose companion has no `usage` at all.
  List<String> get needsUpdate => [
    for (final r in _range)
      if (r.needsUpdate) r.hostName,
  ];

  /// Machines that did not answer: (name, error).
  List<(String, String)> get errors => [
    for (final r in _range)
      if (r.report == null && !r.needsUpdate) (r.hostName, r.error ?? '?'),
  ];

  /// Machines whose companion predates ranges and hours (a 31-day window,
  /// daily rows only), by id.
  List<String> get legacyHosts => {
    for (final r in [..._range, ..._day])
      if (r.report case final report? when !report.supportsRanges) r.hostId,
  }.toList();

  /// Machines whose companion re-reads its transcripts after an upgrade.
  List<String> get rebuilding => {
    for (final r in [..._range, ..._day])
      if (r.report?.rebuilding ?? false) r.hostName,
  }.toList();

  /// Still counting older transcripts somewhere.
  bool get partial => _range.any((r) => r.report?.partial ?? false);

  String? get pricingAsOf =>
      _range.map((r) => r.report?.pricingAsOf).nonNulls.firstOrNull;

  // --- rows ---------------------------------------------------------------

  static List<UsageRow> _rowsOf(
    Iterable<UsageQueryResult> results, {
    bool sessions = false,
  }) => [
    for (final result in results)
      if (result.report case final report?)
        for (final section in report.agents)
          for (final row in sessions ? section.bySession : section.rows)
            row.withMachine(result.hostName),
  ];

  List<UsageRow> _within(UsageDateRange r) => [
    for (final row in _rowsOf(_range))
      if (r.contains(row.date)) row,
  ];

  /// The range, filtered.
  UsageSlice get current => UsageSlice(_within(range), filter: _filter);

  /// The period before, filtered.
  UsageSlice get previousSlice =>
      UsageSlice(_within(previous), filter: _filter);

  /// Every row of the range, unfiltered (the filter picker's values).
  UsageSlice get unfiltered => UsageSlice(_within(range));

  /// Whether every machine that answered reaches back to the period
  /// before: companions keep 62 days (31 before ranges), and only since
  /// they were installed.
  bool get canCompare {
    final from = previous.from;
    final reports = [for (final r in _range) ?r.report];
    return reports.isNotEmpty &&
        reports.every((report) {
          final earliest = report.supportsRanges
              ? report.from
              : addUsageDays(report.today, -(_legacyDays - 1));
          return earliest.compareTo(from) <= 0;
        });
  }

  /// The range against the period before, in [metric]; null when the
  /// machines do not reach back that far.
  UsageComparison? get comparison => canCompare
      ? UsageComparison(
          current: usageMetricValue(current.total, _metric),
          previous: usageMetricValue(previousSlice.total, _metric),
        )
      : null;

  /// [metric] per day that has passed in the range.
  double get averagePerDay =>
      usageMetricValue(current.total, _metric) / range.length;

  List<UsageQueryResult> get _dayRowsSource {
    final day = detailDay;
    if (day == null) {
      return const [];
    }
    return _dayKey == _dayArguments(day) ? _day : const [];
  }

  /// Rows of [detailDay], filtered: per hour where the companion has
  /// hours, else the range's daily rows.
  UsageSlice get daySlice {
    final day = detailDay;
    if (day == null) {
      return UsageSlice(const []);
    }
    final source = _dayRowsSource.isNotEmpty ? _dayRowsSource : _range;
    return UsageSlice([
      for (final row in _rowsOf(source))
        if (row.date == day) row,
    ], filter: _filter);
  }

  /// Per-session rows of [detailDay], filtered.
  UsageSlice get daySessions {
    final day = detailDay;
    final source = _dayRowsSource.isNotEmpty ? _dayRowsSource : _range;
    return UsageSlice([
      for (final row in _rowsOf(source, sessions: true))
        if (row.date == day) row,
    ], filter: _filter);
  }

  /// Whether [detailDay]'s answers carry hours.
  bool get dayHasHours {
    final source = _dayRowsSource.isNotEmpty ? _dayRowsSource : _range;
    return source.any((r) => r.report?.hourly ?? false);
  }

  /// Machines that answered [detailDay] without hours because their
  /// companion is too old (not while it is re-reading), by id.
  List<String> get dayWithoutHours {
    final source = _dayRowsSource.isNotEmpty ? _dayRowsSource : _range;
    return [
      for (final r in source)
        if (r.report case final report?
            when !report.hourly && !report.rebuilding)
          r.hostId,
    ];
  }

  /// The range's rows (filtered) as CSV.
  String csv() {
    final rows = [...current.rows]
      ..sort((a, b) {
        final byDate = a.date.compareTo(b.date);
        return byDate != 0 ? byDate : a.machine.compareTo(b.machine);
      });
    return usageRowsCsv(rows);
  }

  /// `usage-2026-09-19_2026-09-25.csv`.
  String get csvFileName {
    final r = range;
    return r.from == r.to
        ? 'usage-${r.from}.csv'
        : 'usage-${r.from}_${r.to}.csv';
  }

  // --- changes ------------------------------------------------------------

  /// Begins fetching; call once the view is shown.
  void start() {
    if (_started || _disposed) {
      return;
    }
    _started = true;
    unawaited(_fetchAll());
  }

  /// Stops refreshing (the view is gone); [start] resumes.
  void stop() {
    _started = false;
    _timer?.cancel();
    _timer = null;
  }

  /// Pull to refresh, the refresh button: the range and also the limits
  /// and accounts above it.
  Future<void> refresh() async {
    await Future.wait([_fetchAll(force: true), usage.refresh()]);
  }

  void setPreset(UsageRangePreset preset, {UsageDateRange? custom}) {
    if (preset == _preset && custom == null) {
      return;
    }
    _preset = preset;
    if (custom != null) {
      _custom = custom;
    }
    _selectedDay = null;
    unawaited(usage.setExplorerPreferences(range: preset, custom: custom));
    _changed();
    unawaited(_fetchAll());
  }

  void setMetric(UsageMetric metric) {
    if (metric == _metric) {
      return;
    }
    _metric = metric;
    unawaited(usage.setExplorerPreferences(metric: metric));
    _changed();
  }

  void setSplit(bool split) {
    if (split == _split) {
      return;
    }
    _split = split;
    _changed();
  }

  /// Adds or removes one filter chip.
  void toggleFilter(UsageDimension dimension, String value) {
    final next = _filter.toggle(dimension, value);
    if (next == _filter) {
      return;
    }
    _filter = next;
    _changed();
  }

  void clearFilter() {
    if (_filter.isEmpty) {
      return;
    }
    _filter = UsageFilter.none;
    _changed();
  }

  /// Opens [date] in detail (null closes it).
  void selectDay(String? date) {
    if (date == _selectedDay) {
      return;
    }
    _selectedDay = date;
    _changed();
    unawaited(_fetchDay());
  }

  /// The day before (-1) or after (+1) the one in detail, within the
  /// range's days that have passed. Returns whether it moved.
  bool stepDay(int delta) {
    final day = detailDay;
    if (day == null) {
      return false;
    }
    final next = addUsageDays(day, delta);
    final r = range;
    if (r.isSingleDay) {
      // A one-day range steps the range itself: Today ← Yesterday.
      if (next.compareTo(usage.today) > 0) {
        return false;
      }
      final preset = next == usage.today
          ? UsageRangePreset.today
          : next == addUsageDays(usage.today, -1)
          ? UsageRangePreset.yesterday
          : UsageRangePreset.custom;
      setPreset(
        preset,
        custom: preset == UsageRangePreset.custom
            ? UsageDateRange(next, next)
            : null,
      );
      return true;
    }
    if (!r.contains(next)) {
      return false;
    }
    selectDay(next);
    return true;
  }

  bool canStep(int delta) {
    final day = detailDay;
    if (day == null) {
      return false;
    }
    final next = addUsageDays(day, delta);
    final r = range;
    if (r.isSingleDay) {
      return next.compareTo(usage.today) <= 0;
    }
    return r.contains(next);
  }

  // --- fetching -----------------------------------------------------------

  String _rangeArguments() {
    final r = range;
    return companionUsageArguments(
      days: _legacyDays,
      from: previous.from,
      to: r.to,
      hourly: r.isSingleDay,
      sessions: r.isSingleDay,
    );
  }

  static String _dayArguments(String day) => companionUsageArguments(
    days: _legacyDays,
    from: day,
    to: day,
    hourly: true,
    sessions: true,
  );

  void _onUsageChanged() {
    // The machines' today moved (or a first report arrived): the range
    // is another one.
    if (_started && !_disposed && _rangeKey != _rangeArguments()) {
      unawaited(_fetchAll());
    }
  }

  Future<void> _fetchAll({bool force = false}) async {
    if (_disposed) {
      return;
    }
    _timer?.cancel();
    _timer = null;
    await Future.wait([_fetchRange(force: force), _fetchDay(force: force)]);
    if (_disposed || !_started) {
      return;
    }
    // Of two overlapping fetches, the last one's timer wins.
    _timer?.cancel();
    _timer = Timer(partial ? partialEvery : refreshEvery, () {
      _timer = null;
      unawaited(_fetchAll(force: true));
    });
  }

  Future<void> _fetchRange({bool force = false}) async {
    final key = _rangeArguments();
    if (!force && key == _rangeKey && (_range.isNotEmpty || _rangeLoading)) {
      return;
    }
    if (key != _rangeKey) {
      _range = const [];
    }
    _rangeKey = key;
    _rangeLoading = true;
    _changed();
    final results = await usage.query(key);
    if (_disposed || key != _rangeKey) {
      return;
    }
    _range = results;
    _rangeLoading = false;
    _changed();
  }

  Future<void> _fetchDay({bool force = false}) async {
    final day = _selectedDay;
    // A one-day range's own answer has the hours.
    if (day == null || range.isSingleDay) {
      return;
    }
    final key = _dayArguments(day);
    if (!force && key == _dayKey && (_day.isNotEmpty || _dayLoading)) {
      return;
    }
    if (key != _dayKey) {
      _day = const [];
    }
    _dayKey = key;
    _dayLoading = true;
    _changed();
    final results = await usage.query(key);
    if (_disposed || key != _dayKey) {
      return;
    }
    _day = results;
    _dayLoading = false;
    _changed();
  }

  void _changed() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    usage.removeListener(_onUsageChanged);
    super.dispose();
  }
}
