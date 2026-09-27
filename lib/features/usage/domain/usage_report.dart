import 'dart:convert';
import 'dart:math' as math;

import 'package:conduit/features/agent_attention/domain/agent_attention.dart';

/// Which coding agent a number belongs to.
enum UsageAgent {
  claude('Claude'),
  codex('Codex');

  const UsageAgent(this.label);

  final String label;
}

/// One rate-limit window of an account (`5h`, `7d`, `spend`).
class UsageLimit {
  const UsageLimit({
    required this.label,
    required this.usedPct,
    this.resetsAt,
    this.expired = false,
  });

  final String label;

  /// 0 to 100 as last reported.
  final double usedPct;
  final DateTime? resetsAt;

  /// The window reset after the last report: its use is unknown, shown as
  /// 0 until the next report.
  final bool expired;

  bool get isFiveHour => label == '5h';
  bool get isWeekly => label == '7d';

  /// What to show: 0 once the window is over.
  double effectivePct(DateTime now) {
    final reset = resetsAt;
    if (expired || (reset != null && !reset.isAfter(now))) {
      return 0;
    }
    return usedPct.clamp(0, 100).toDouble();
  }

  /// A human name for the window.
  String get title => switch (label) {
    '5h' => '5-hour',
    '7d' => 'Weekly',
    'spend' => 'Spend',
    _ => label,
  };

  static UsageLimit? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final label = json['label'];
    final used = json['usedPct'];
    if (label is! String || used is! num) {
      return null;
    }
    final resets = json['resetsAt'];
    return UsageLimit(
      label: label,
      usedPct: used.toDouble(),
      resetsAt: resets is num
          ? DateTime.fromMillisecondsSinceEpoch(resets.toInt(), isUtc: true)
          : null,
      expired: json['expired'] == true,
    );
  }

  static UsageLimit fromAgent(AgentRateLimit limit) => UsageLimit(
    label: limit.label,
    usedPct: limit.usedPct,
    resetsAt: limit.resetsAt,
  );

  @override
  bool operator ==(Object other) =>
      other is UsageLimit &&
      other.label == label &&
      other.usedPct == usedPct &&
      other.resetsAt == resetsAt &&
      other.expired == expired;

  @override
  int get hashCode => Object.hash(label, usedPct, resetsAt, expired);

  @override
  String toString() => 'UsageLimit($label, $usedPct, $resetsAt)';
}

/// Of two reports for one window, the one for the later window wins, then
/// the higher use (it only grows within a window). Mirrors the companion.
UsageLimit fresherLimit(UsageLimit a, UsageLimit b) {
  final ra = a.resetsAt?.millisecondsSinceEpoch ?? 0;
  final rb = b.resetsAt?.millisecondsSinceEpoch ?? 0;
  if ((ra - rb).abs() > const Duration(minutes: 5).inMilliseconds) {
    return rb > ra ? b : a;
  }
  return b.usedPct > a.usedPct ? b : a;
}

/// The freshest report per window label across [lists], 5h then 7d first.
List<UsageLimit> mergeUsageLimits(Iterable<Iterable<UsageLimit>> lists) {
  final byLabel = <String, UsageLimit>{};
  for (final list in lists) {
    for (final limit in list) {
      final known = byLabel[limit.label];
      byLabel[limit.label] = known == null ? limit : fresherLimit(known, limit);
    }
  }
  int order(String label) => switch (label) {
    '5h' => 0,
    '7d' => 1,
    _ => 2,
  };
  return byLabel.values.toList()
    ..sort((a, b) => order(a.label).compareTo(order(b.label)));
}

/// Token counts and the estimated cost of some usage.
class UsageTotals {
  const UsageTotals({
    this.input = 0,
    this.output = 0,
    this.cacheWrite = 0,
    this.cacheRead = 0,
    this.messages = 0,
    this.costUsd,
  });

  static const zero = UsageTotals();

  /// Input without cache reads and writes.
  final int input;
  final int output;
  final int cacheWrite;
  final int cacheRead;
  final int messages;

  /// Null when no model of it has a price.
  final double? costUsd;

  int get tokens => input + output + cacheWrite + cacheRead;

  UsageTotals operator +(UsageTotals other) => UsageTotals(
    input: input + other.input,
    output: output + other.output,
    cacheWrite: cacheWrite + other.cacheWrite,
    cacheRead: cacheRead + other.cacheRead,
    messages: messages + other.messages,
    costUsd: costUsd == null && other.costUsd == null
        ? null
        : (costUsd ?? 0) + (other.costUsd ?? 0),
  );

  static UsageTotals fromJson(Object? json) {
    if (json is! Map) {
      return zero;
    }
    int count(String key) => switch (json[key]) {
      final num value => value.toInt(),
      _ => 0,
    };
    final cost = json['costUsd'];
    return UsageTotals(
      input: count('input'),
      output: count('output'),
      cacheWrite: count('cacheWrite'),
      cacheRead: count('cacheRead'),
      messages: count('messages'),
      costUsd: cost is num ? cost.toDouble() : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is UsageTotals &&
      other.input == input &&
      other.output == output &&
      other.cacheWrite == cacheWrite &&
      other.cacheRead == cacheRead &&
      other.messages == messages &&
      other.costUsd == costUsd;

  @override
  int get hashCode =>
      Object.hash(input, output, cacheWrite, cacheRead, messages, costUsd);
}

/// One day, project and model of one agent on one machine.
class UsageRow {
  const UsageRow({
    required this.date,
    required this.project,
    required this.model,
    required this.totals,
    this.agent = UsageAgent.claude,
    this.machine = '',
  });

  /// `YYYY-MM-DD` in the machine's time zone.
  final String date;
  final String project;
  final String model;
  final UsageTotals totals;
  final UsageAgent agent;

  /// Display name of the machine (filled in by the controller).
  final String machine;

  UsageRow withMachine(String name) => UsageRow(
    date: date,
    project: project,
    model: model,
    totals: totals,
    agent: agent,
    machine: name,
  );

  static UsageRow? fromJson(Object? json, UsageAgent agent) {
    if (json is! Map) {
      return null;
    }
    final date = json['date'];
    if (date is! String) {
      return null;
    }
    final project = json['project'];
    final model = json['model'];
    return UsageRow(
      date: date,
      project: project is String ? project : '(unknown)',
      model: model is String ? model : 'unknown',
      totals: UsageTotals.fromJson(json),
      agent: agent,
    );
  }
}

/// Context use of one live session.
class UsageSession {
  const UsageSession({
    required this.sessionId,
    this.name,
    this.project,
    this.contextUsedPct,
    this.contextTokens,
    this.windowLabel,
  });

  final String sessionId;
  final String? name;
  final String? project;
  final double? contextUsedPct;
  final int? contextTokens;
  final String? windowLabel;

  static UsageSession? fromJson(Object? json) {
    if (json is! Map || json['sessionId'] is! String) {
      return null;
    }
    String? text(String key) =>
        json[key] is String ? json[key] as String : null;
    final pct = json['contextUsedPct'];
    final tokens = json['contextTokens'];
    return UsageSession(
      sessionId: json['sessionId'] as String,
      name: text('name'),
      project: text('project'),
      contextUsedPct: pct is num ? pct.toDouble() : null,
      contextTokens: tokens is num ? tokens.toInt() : null,
      windowLabel: text('windowLabel'),
    );
  }
}

/// One Claude account cswap (claude-swap) manages on a machine: its 5-hour
/// and weekly windows. The companion sends the alias, else a masked email,
/// as [label]; never the email itself.
class UsageAccount {
  const UsageAccount({
    required this.slot,
    required this.label,
    this.alias,
    this.active = false,
    this.disabled = false,
    this.stale = false,
    this.status,
    this.fiveHour,
    this.weekly,
    this.perModel = const [],
    this.usageAt,
  });

  /// cswap's account number on that machine (`cswap switch <slot>`).
  final int slot;
  final String label;
  final String? alias;

  /// The account new Claude sessions on the machine use.
  final bool active;

  /// Held out of cswap's rotation.
  final bool disabled;

  /// No fresh measurement: the windows are the last good ones.
  final bool stale;

  /// cswap's `usageStatus` (`ok`, `unavailable`, `token_expired`, …).
  final String? status;
  final UsageLimit? fiveHour;
  final UsageLimit? weekly;

  /// Per-model weekly windows (label = model name).
  final List<UsageLimit> perModel;

  /// When the windows were measured.
  final DateTime? usageAt;

  /// The fuller of its two windows, 0 to 100; null when neither is known.
  double? usedPct(DateTime now) {
    final values = [?fiveHour?.effectivePct(now), ?weekly?.effectivePct(now)];
    return values.isEmpty ? null : values.reduce(math.max);
  }

  static UsageAccount? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final slot = json['slot'];
    final label = json['label'];
    if (slot is! num || label is! String || label.isEmpty) {
      return null;
    }
    UsageLimit? window(String key) {
      final limits = json['limits'];
      if (limits is! Map) {
        return null;
      }
      return UsageLimit.fromJson(
        limits[key] is Map ? {...limits[key] as Map, 'label': key} : null,
      );
    }

    final alias = json['alias'];
    final status = json['status'];
    final usageAt = json['usageAt'];
    return UsageAccount(
      slot: slot.toInt(),
      label: label,
      alias: alias is String && alias.isNotEmpty ? alias : null,
      active: json['active'] == true,
      disabled: json['disabled'] == true,
      stale: json['stale'] == true,
      status: status is String ? status : null,
      fiveHour: window('5h'),
      weekly: window('7d'),
      perModel: [
        if (json['perModel'] case final List<Object?> models)
          for (final model in models)
            if (model is Map && model['model'] is String)
              ?UsageLimit.fromJson({...model, 'label': model['model']}),
      ],
      usageAt: usageAt is num
          ? DateTime.fromMillisecondsSinceEpoch(usageAt.toInt(), isUtc: true)
          : null,
    );
  }
}

/// One agent's section of a report.
class UsageSection {
  const UsageSection({
    required this.agent,
    required this.present,
    this.limits = const [],
    this.sessions = const [],
    this.today = UsageTotals.zero,
    this.range = UsageTotals.zero,
    this.rows = const [],
    this.accounts = const [],
    this.cswap = false,
  });

  final UsageAgent agent;

  /// Whether the agent is installed on the machine.
  final bool present;
  final List<UsageLimit> limits;
  final List<UsageSession> sessions;
  final UsageTotals today;
  final UsageTotals range;
  final List<UsageRow> rows;

  /// Claude only: every account cswap manages on the machine. Empty
  /// without cswap and from companions before it.
  final List<UsageAccount> accounts;

  /// Claude only: the companion found cswap, so it can switch accounts.
  final bool cswap;

  static UsageSection fromJson(Object? json, UsageAgent agent) {
    if (json is! Map) {
      return UsageSection(agent: agent, present: false);
    }
    List<T> list<T>(String key, T? Function(Object?) parse) => [
      if (json[key] case final List<Object?> items)
        for (final item in items)
          if (parse(item) case final T value) value,
    ];
    return UsageSection(
      agent: agent,
      present: json['present'] == true,
      limits: list('limits', UsageLimit.fromJson),
      sessions: list('sessions', UsageSession.fromJson),
      today: UsageTotals.fromJson(json['today']),
      range: UsageTotals.fromJson(json['range']),
      rows: list('rows', (item) => UsageRow.fromJson(item, agent)),
      accounts: list('accounts', UsageAccount.fromJson),
      cswap: json['cswap'] is Map && (json['cswap'] as Map)['present'] == true,
    );
  }
}

/// One `conductore-hostd usage` reply.
class UsageReport {
  const UsageReport({
    required this.machine,
    required this.today,
    required this.from,
    required this.claude,
    required this.codex,
    this.generatedAt,
    this.companionVersion,
    this.pricingAsOf,
    this.pricingNote,
    this.unpricedModels = const [],
    this.partial = false,
  });

  /// The host's name for itself.
  final String machine;

  /// `YYYY-MM-DD` on the machine.
  final String today;
  final String from;
  final UsageSection claude;
  final UsageSection codex;
  final DateTime? generatedAt;
  final String? companionVersion;
  final String? pricingAsOf;
  final String? pricingNote;
  final List<String> unpricedModels;

  /// The scan stopped at its per-call cap; the next call goes on.
  final bool partial;

  Iterable<UsageSection> get agents => [claude, codex];
}

/// A `conductore-hostd cswap-switch` reply.
class UsageAccountSwitchResult {
  const UsageAccountSwitchResult({
    required this.ok,
    this.switched = false,
    this.toLabel,
    this.error,
  });

  const UsageAccountSwitchResult.failed(String this.error)
    : ok = false,
      switched = false,
      toLabel = null;

  final bool ok;

  /// False when the account was already active.
  final bool switched;

  /// The account now active (alias or masked email).
  final String? toLabel;
  final String? error;

  /// One line for a snackbar.
  String get message {
    if (!ok) {
      return 'Could not switch: ${error ?? 'no reply'}';
    }
    final to = toLabel ?? 'the account';
    return switched
        ? 'New Claude sessions now use $to'
        : '$to was already the active account';
  }
}

/// Parses `conductore-hostd cswap-switch` output.
UsageAccountSwitchResult parseAccountSwitchResult(String stdout) {
  Object? decoded;
  final text = stdout.trim();
  try {
    decoded = text.isEmpty ? null : jsonDecode(text.split('\n').last);
  } on FormatException {
    decoded = null;
  }
  if (decoded is! Map) {
    return const UsageAccountSwitchResult.failed(
      'the companion on this machine cannot switch accounts',
    );
  }
  if (decoded['ok'] != true) {
    final error = decoded['error'];
    return UsageAccountSwitchResult.failed(
      error is String ? error : 'cswap failed',
    );
  }
  final to = decoded['to'];
  return UsageAccountSwitchResult(
    ok: true,
    switched: decoded['switched'] == true,
    toLabel: to is Map && to['label'] is String ? to['label'] as String : null,
  );
}

/// The command that asks for [days] of usage.
String companionUsageArguments({int days = 7}) => 'usage --days $days';

/// Parses `conductore-hostd usage` output. Null for anything that is not a
/// usage report (an older companion answers with an error).
UsageReport? parseUsageReport(String stdout) {
  final text = stdout.trim();
  if (text.isEmpty) {
    return null;
  }
  Object? decoded;
  try {
    decoded = jsonDecode(text.split('\n').last);
  } on FormatException {
    return null;
  }
  if (decoded is! Map ||
      decoded['schema'] is! num ||
      decoded['error'] != null) {
    return null;
  }
  String? text0(String key) =>
      decoded is Map && decoded[key] is String ? decoded[key] as String : null;
  final pricing = decoded['pricing'];
  final scan = decoded['scan'];
  final generated = decoded['generatedAt'];
  return UsageReport(
    machine: text0('machine') ?? '',
    today: text0('today') ?? '',
    from: text0('from') ?? '',
    claude: UsageSection.fromJson(decoded['claude'], UsageAgent.claude),
    codex: UsageSection.fromJson(decoded['codex'], UsageAgent.codex),
    generatedAt: generated is num
        ? DateTime.fromMillisecondsSinceEpoch(generated.toInt(), isUtc: true)
        : null,
    companionVersion: text0('version'),
    pricingAsOf: pricing is Map && pricing['asOf'] is String
        ? pricing['asOf'] as String
        : null,
    pricingNote: pricing is Map && pricing['note'] is String
        ? pricing['note'] as String
        : null,
    unpricedModels: [
      if (pricing is Map && pricing['unpriced'] is List)
        for (final model in pricing['unpriced'] as List)
          if (model is String) model,
    ],
    partial: scan is Map && scan['partial'] == true,
  );
}
