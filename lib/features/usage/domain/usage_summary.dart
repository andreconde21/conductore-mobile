import 'package:conduit/features/usage/domain/usage_report.dart';

/// Use of a limit at or above this is shown in the warning colour.
const kUsageWarningPct = 80.0;

/// At or above this, in the danger colour.
const kUsageCriticalPct = 95.0;

enum UsageLevel { normal, warning, critical }

/// How close [percent] is to a limit.
UsageLevel usageLevelFor(double percent) {
  if (percent >= kUsageCriticalPct) {
    return UsageLevel.critical;
  }
  if (percent >= kUsageWarningPct) {
    return UsageLevel.warning;
  }
  return UsageLevel.normal;
}

/// What the app knows about one machine's usage.
class MachineUsage {
  const MachineUsage({
    required this.hostId,
    required this.hostName,
    this.report,
    this.liveLimits = const [],
    this.error,
    this.needsUpdate = false,
    this.fetchedAt,
  });

  final String hostId;
  final String hostName;

  /// The last `usage` reply, kept while a newer one is fetched.
  final UsageReport? report;

  /// Claude limits from the agent monitor's statusline reports, often
  /// newer than [report] (it polls every 15 s, in the background too).
  final List<UsageLimit> liveLimits;

  /// The last fetch failed (the report, if any, is older).
  final String? error;

  /// The companion is missing or older than 0.6.0 (no `usage` command).
  final bool needsUpdate;
  final DateTime? fetchedAt;

  /// The live login's limits: the companion's and the agent monitor's
  /// reports, of the account the newest one is for ([currentLoginLimits]).
  List<UsageLimit> get claudeLimits =>
      currentLoginLimits([report?.claude.limits ?? const [], liveLimits]);

  List<UsageLimit> get codexLimits => report?.codex.limits ?? const [];

  /// Every Claude account cswap manages here; empty without cswap (and
  /// from companions before it).
  List<UsageAccount> get accounts => report?.claude.accounts ?? const [];

  /// The companion found cswap and lists accounts: it can switch them.
  bool get canSwitchAccounts =>
      (report?.claude.cswap ?? false) && accounts.isNotEmpty;

  MachineUsage copyWith({
    String? hostName,
    UsageReport? report,
    List<UsageLimit>? liveLimits,
    String? error,
    bool clearError = false,
    bool? needsUpdate,
    DateTime? fetchedAt,
  }) => MachineUsage(
    hostId: hostId,
    hostName: hostName ?? this.hostName,
    report: report ?? this.report,
    liveLimits: liveLimits ?? this.liveLimits,
    error: clearError ? null : (error ?? this.error),
    needsUpdate: needsUpdate ?? this.needsUpdate,
    fetchedAt: fetchedAt ?? this.fetchedAt,
  );
}

/// One machine's view of a [UsageAccountSummary].
class UsageAccountPlacement {
  const UsageAccountPlacement({
    required this.hostId,
    required this.hostName,
    required this.account,
    this.canSwitch = false,
  });

  final String hostId;
  final String hostName;
  final UsageAccount account;

  /// The machine's companion can run `cswap switch`.
  final bool canSwitch;
}

/// One Claude account across machines, merged by its label: the freshest
/// windows any machine reported, and where it is active.
class UsageAccountSummary {
  const UsageAccountSummary({
    required this.label,
    required this.placements,
    this.fiveHour,
    this.weekly,
  });

  final String label;
  final UsageLimit? fiveHour;
  final UsageLimit? weekly;
  final List<UsageAccountPlacement> placements;

  /// New Claude sessions use it on at least one machine.
  bool get active => placements.any((p) => p.account.active);

  /// Held out of rotation wherever it is configured.
  bool get disabled => placements.every((p) => p.account.disabled);

  /// No machine has a fresh measurement.
  bool get stale => placements.every((p) => p.account.stale);

  /// Machines it is active on.
  List<String> get activeOn => [
    for (final p in placements)
      if (p.account.active) p.hostName,
  ];

  /// Not managed by cswap on any machine: the live login cswap names, never
  /// `cswap add`ed.
  bool get unmanaged => placements.every((p) => !p.account.managed);

  /// [unmanaged], and the sessions' limits confirm it is none of cswap's
  /// accounts. Otherwise it is only "the current login".
  bool get notInCswap =>
      unmanaged && placements.any((p) => p.account.inCswap == false);

  /// cswap lost its login wherever it is configured: "Needs re-login".
  bool get needsLogin => placements.every((p) => p.account.needsLogin);

  /// Running sessions use it on at least one machine.
  bool get live => placements.any((p) => p.account.live);

  /// Machines where it can be made the active account.
  List<UsageAccountPlacement> get switchTargets => [
    for (final p in placements)
      if (p.canSwitch &&
          p.account.managed &&
          !p.account.active &&
          !p.account.disabled)
        p,
  ];

  /// When the windows were measured (the newest machine's).
  DateTime? get usageAt {
    DateTime? newest;
    for (final p in placements) {
      final at = p.account.usageAt;
      if (at != null && (newest == null || at.isAfter(newest))) {
        newest = at;
      }
    }
    return newest;
  }

  /// The fuller of its two windows, 0 to 100; null when neither is known.
  double? usedPct(DateTime now) {
    final values = [?fiveHour?.effectivePct(now), ?weekly?.effectivePct(now)];
    return values.isEmpty ? null : values.reduce((a, b) => a > b ? a : b);
  }
}

/// How the Usage tab groups rows.
enum UsageGrouping {
  machine('Machine'),
  project('Project'),
  model('Model'),
  agent('Agent');

  const UsageGrouping(this.label);

  final String label;
}

/// One line of a grouped breakdown.
class UsageGroup {
  const UsageGroup(this.label, this.totals);

  final String label;
  final UsageTotals totals;
}

/// Totals of one day, for the bar chart.
class UsageDay {
  const UsageDay(this.date, this.totals);

  /// `YYYY-MM-DD`.
  final String date;
  final UsageTotals totals;
}

/// Usage across every machine: what the bar, the tab and the widget show.
class UsageSummary {
  const UsageSummary(this.machines);

  static const empty = UsageSummary([]);

  final List<MachineUsage> machines;

  Iterable<UsageReport> get _reports => [
    for (final machine in machines) ?machine.report,
  ];

  /// Whether any machine has answered `usage` or reported limits.
  bool get hasData =>
      machines.any((m) => m.report != null || m.liveLimits.isNotEmpty);

  /// The Claude limit windows of the account in use: the machine that
  /// reported last decides which ([currentLoginLimits]).
  List<UsageLimit> get claudeLimits =>
      currentLoginLimits([for (final m in machines) m.claudeLimits]);

  List<UsageLimit> get codexLimits =>
      mergeUsageLimits([for (final m in machines) m.codexLimits]);

  UsageLimit? get fiveHour =>
      claudeLimits.where((limit) => limit.isFiveHour).firstOrNull;

  UsageLimit? get weekly =>
      claudeLimits.where((limit) => limit.isWeekly).firstOrNull;

  bool get codexPresent => _reports.any((report) => report.codex.present);

  /// Every cswap account across machines, merged by label, active ones
  /// first. Empty without cswap.
  List<UsageAccountSummary> get accounts {
    final byLabel = <String, List<UsageAccountPlacement>>{};
    // cswap has no windows for a login it does not manage; the machine's
    // statusline limits are that live login's.
    final liveLimits = <UsageAccountPlacement, List<UsageLimit>>{};
    for (final machine in machines) {
      for (final account in machine.accounts) {
        final placement = UsageAccountPlacement(
          hostId: machine.hostId,
          hostName: machine.hostName,
          account: account,
          canSwitch: machine.canSwitchAccounts,
        );
        // Not when the sessions run on one of cswap's accounts: the
        // machine's limits are that account's then.
        if (!account.managed &&
            account.active &&
            !machine.accounts.any((a) => a.managed && a.live)) {
          liveLimits[placement] = machine.claudeLimits;
        }
        (byLabel[account.label] ??= []).add(placement);
      }
    }
    UsageLimit? window(UsageAccountPlacement p, {required bool weekly}) =>
        (weekly ? p.account.weekly : p.account.fiveHour) ??
        liveLimits[p]
            ?.where((l) => weekly ? l.isWeekly : l.isFiveHour)
            .firstOrNull;
    final merged = [
      for (final MapEntry(key: label, value: placements) in byLabel.entries)
        UsageAccountSummary(
          label: label,
          placements: placements,
          fiveHour: _freshest([
            for (final p in placements) ?window(p, weekly: false),
          ]),
          weekly: _freshest([
            for (final p in placements) ?window(p, weekly: true),
          ]),
        ),
    ];
    // Stable: active first, otherwise in the machines' slot order.
    final active = merged.where((a) => a.active);
    final rest = merged.where((a) => !a.active);
    return [...active, ...rest];
  }

  static UsageLimit? _freshest(List<UsageLimit> limits) =>
      limits.isEmpty ? null : limits.reduce(fresherLimit);

  /// Accounts no machine uses right now (the home bar's "+N accounts").
  int get otherAccountCount => accounts.where((a) => !a.active).length;

  /// Another account with clearly more headroom than the active one, once
  /// the active one is at least half used: what "Switch to best" would
  /// likely pick. Null otherwise.
  UsageAccountSummary? bestAccount(DateTime now) {
    final all = accounts;
    double? activeUsed;
    for (final account in all.where((a) => a.active)) {
      final used = account.usedPct(now);
      if (used != null && (activeUsed == null || used > activeUsed)) {
        activeUsed = used;
      }
    }
    activeUsed ??= [
      ?fiveHour?.effectivePct(now),
      ?weekly?.effectivePct(now),
    ].fold<double?>(null, (m, v) => m == null || v > m ? v : m);
    if (activeUsed == null || activeUsed < 50) {
      return null;
    }
    UsageAccountSummary? best;
    double? bestUsed;
    for (final account in all) {
      final used = account.usedPct(now);
      if (account.active || account.disabled || used == null) {
        continue;
      }
      if (bestUsed == null || used < bestUsed) {
        best = account;
        bestUsed = used;
      }
    }
    return bestUsed != null && bestUsed + 10 <= activeUsed ? best : null;
  }

  /// Account names crash reports must never carry (telemetry scrubber).
  Iterable<String> get accountTerms sync* {
    for (final machine in machines) {
      for (final account in machine.accounts) {
        yield account.label;
        if (account.alias case final alias?) yield alias;
      }
    }
  }

  /// Today on each machine, every agent.
  UsageTotals get today {
    var total = UsageTotals.zero;
    for (final report in _reports) {
      for (final section in report.agents) {
        total = total + section.today;
      }
    }
    return total;
  }

  UsageTotals todayFor(UsageAgent agent) {
    var total = UsageTotals.zero;
    for (final report in _reports) {
      total =
          total +
          switch (agent) {
            UsageAgent.claude => report.claude,
            UsageAgent.codex => report.codex,
            UsageAgent.opencode => report.opencode,
            UsageAgent.gemini => report.gemini,
          }.today;
    }
    return total;
  }

  UsageTotals get range {
    var total = UsageTotals.zero;
    for (final report in _reports) {
      for (final section in report.agents) {
        total = total + section.range;
      }
    }
    return total;
  }

  /// Every row, with its machine's name.
  List<UsageRow> get rows => [
    for (final machine in machines)
      if (machine.report case final report?)
        for (final section in report.agents)
          for (final row in section.rows) row.withMachine(machine.hostName),
  ];

  /// Rows of [agent] (all agents when null) summed by [grouping], largest
  /// first (by cost, then tokens).
  List<UsageGroup> groupBy(UsageGrouping grouping, {UsageAgent? agent}) {
    final sums = <String, UsageTotals>{};
    for (final row in rows) {
      if (agent != null && row.agent != agent) {
        continue;
      }
      final key = switch (grouping) {
        UsageGrouping.machine => row.machine,
        UsageGrouping.project => row.project,
        UsageGrouping.model => row.model,
        UsageGrouping.agent => row.agent.label,
      };
      sums[key] = (sums[key] ?? UsageTotals.zero) + row.totals;
    }
    return [for (final e in sums.entries) UsageGroup(e.key, e.value)]..sort((
      a,
      b,
    ) {
      final byCost = (b.totals.costUsd ?? 0).compareTo(a.totals.costUsd ?? 0);
      return byCost != 0 ? byCost : b.totals.tokens.compareTo(a.totals.tokens);
    });
  }

  /// One entry per day from the earliest report's first day to the latest
  /// report's today, empty days included.
  List<UsageDay> days({UsageAgent? agent}) {
    final reports = _reports.toList();
    if (reports.isEmpty) {
      return const [];
    }
    var first = reports.first.from;
    var last = reports.first.today;
    for (final report in reports) {
      if (report.from.isNotEmpty && report.from.compareTo(first) < 0) {
        first = report.from;
      }
      if (report.today.compareTo(last) > 0) {
        last = report.today;
      }
    }
    final sums = <String, UsageTotals>{};
    for (final row in rows) {
      if (agent != null && row.agent != agent) {
        continue;
      }
      sums[row.date] = (sums[row.date] ?? UsageTotals.zero) + row.totals;
    }
    final start = DateTime.tryParse(first);
    final end = DateTime.tryParse(last);
    if (start == null || end == null) {
      return const [];
    }
    return [
      for (
        var day = DateTime.utc(start.year, start.month, start.day);
        !day.isAfter(DateTime.utc(end.year, end.month, end.day));
        day = day.add(const Duration(days: 1))
      )
        UsageDay(_date(day), sums[_date(day)] ?? UsageTotals.zero),
    ];
  }

  static String _date(DateTime day) =>
      '${day.year.toString().padLeft(4, '0')}-'
      '${day.month.toString().padLeft(2, '0')}-'
      '${day.day.toString().padLeft(2, '0')}';

  /// The pricing note and date of the newest report.
  String? get pricingAsOf =>
      _reports.map((r) => r.pricingAsOf).nonNulls.firstOrNull;
}

/// `1.2M`, `850k`, `12`.
String formatUsageTokens(int tokens) {
  if (tokens >= 1000000000) {
    return '${_trim(tokens / 1000000000)}B';
  }
  if (tokens >= 1000000) {
    return '${_trim(tokens / 1000000)}M';
  }
  if (tokens >= 1000) {
    return '${(tokens / 1000).round()}k';
  }
  return '$tokens';
}

String _trim(double value) =>
    value >= 100 ? value.round().toString() : value.toStringAsFixed(1);

/// `$12.40`, `$0.03`, `<$0.01`, `—` without a price.
String formatUsageCost(double? usd) {
  if (usd == null) {
    return '—';
  }
  if (usd > 0 && usd < 0.01) {
    return r'<$0.01';
  }
  if (usd >= 1000) {
    return '\$${usd.round()}';
  }
  return '\$${usd.toStringAsFixed(2)}';
}
