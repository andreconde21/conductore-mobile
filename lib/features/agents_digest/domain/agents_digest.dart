import 'dart:convert';

import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/domain/agent_kinds.dart';

/// The dashboard's sections, in display order.
enum DigestSection {
  needsYou('Needs you'),
  stuck('Stuck'),
  working('Working'),
  done('Done since'),

  /// Nothing happened in the window (idle, waiting for a new prompt).
  quiet('Quiet');

  const DigestSection(this.label);

  final String label;
}

/// What an agent waits for.
enum DigestAttention {
  /// A permission request (from the phone or in the terminal).
  permission,

  /// An answer: it asked something.
  question;

  static DigestAttention? parse(Object? raw) => switch (raw) {
    'permission' => DigestAttention.permission,
    'question' => DigestAttention.question,
    _ => null,
  };
}

/// The time window the dashboard counts from.
enum DigestWindow {
  sinceLastCheck('Since last check'),
  twoHours('Last 2 hours'),
  today('Today');

  const DigestWindow(this.label);

  final String label;

  static DigestWindow parse(Object? raw) => DigestWindow.values.firstWhere(
    (window) => window.name == raw,
    orElse: () => DigestWindow.sinceLastCheck,
  );

  /// The start of the window at [now]. Since the last check: [lastSeen],
  /// or two hours back before the first check.
  DateTime since(DateTime now, DateTime? lastSeen) => switch (this) {
    DigestWindow.sinceLastCheck =>
      lastSeen ?? now.subtract(const Duration(hours: 2)),
    DigestWindow.twoHours => now.subtract(const Duration(hours: 2)),
    DigestWindow.today => DateTime(now.year, now.month, now.day),
  };
}

/// One stuck rule that fired, with its short reason ("`npm test` failed 3
/// times").
class DigestStuckFlag {
  const DigestStuckFlag(this.rule, this.reason);

  final String rule;
  final String reason;

  @override
  bool operator ==(Object other) =>
      other is DigestStuckFlag && other.rule == rule && other.reason == reason;

  @override
  int get hashCode => Object.hash(rule, reason);
}

/// What an agent did in the window, as the companion counted it (free:
/// no Claude). Every count is 0 when unknown.
class DigestFacts {
  const DigestFacts({
    this.turns = 0,
    this.files = const [],
    this.filesEdited = 0,
    this.linesAdded = 0,
    this.linesRemoved = 0,
    this.commands = 0,
    this.failedCommands = 0,
    this.testRuns = 0,
    this.testsPassed = 0,
    this.testsFailed = 0,
    this.lastTestPassed,
    this.waitingPermission = Duration.zero,
    this.waitingInput = Duration.zero,
    this.tokens,
    this.outputTokens,
    this.costUsd,
    this.partial = false,
  });

  final int turns;

  /// Edited files, relative to the agent's directory (at most 12).
  final List<String> files;
  final int filesEdited;
  final int linesAdded;
  final int linesRemoved;
  final int commands;
  final int failedCommands;
  final int testRuns;
  final int testsPassed;
  final int testsFailed;

  /// Whether the last test run passed; null without one.
  final bool? lastTestPassed;
  final Duration waitingPermission;
  final Duration waitingInput;

  /// Tokens in the window (every kind), and output alone; null unknown.
  final int? tokens;
  final int? outputTokens;

  /// Estimated at API list prices.
  final double? costUsd;

  /// The window starts before what the companion still has.
  final bool partial;

  static DigestFacts fromJson(Object? raw) {
    if (raw is! Map) return const DigestFacts();
    int n(String key) => raw[key] is num ? (raw[key] as num).toInt() : 0;
    Duration ms(String key) => Duration(milliseconds: n(key));
    final files = raw['files'];
    final lastTest = raw['lastTest'];
    final tokens = raw['tokens'];
    final cost = raw['costUsd'];
    return DigestFacts(
      turns: n('turns'),
      files: [
        if (files is List)
          for (final file in files)
            if (file is String && file.isNotEmpty) file,
      ],
      filesEdited: n('filesEdited'),
      linesAdded: n('linesAdded'),
      linesRemoved: n('linesRemoved'),
      commands: n('commands'),
      failedCommands: n('failedCommands'),
      testRuns: n('testRuns'),
      testsPassed: n('testsPassed'),
      testsFailed: n('testsFailed'),
      lastTestPassed: lastTest is Map && lastTest['ok'] is bool
          ? lastTest['ok'] as bool
          : null,
      waitingPermission: ms('waitingPermissionMs'),
      waitingInput: ms('waitingInputMs'),
      tokens: tokens is Map && tokens['total'] is num
          ? (tokens['total'] as num).toInt()
          : null,
      outputTokens: tokens is Map && tokens['output'] is num
          ? (tokens['output'] as num).toInt()
          : null,
      costUsd: cost is num ? cost.toDouble() : null,
      partial: raw['partial'] == true,
    );
  }

  bool get isEmpty =>
      turns == 0 &&
      filesEdited == 0 &&
      testRuns == 0 &&
      failedCommands == 0 &&
      (tokens ?? 0) == 0;
}

/// One pending request as the digest lists it (the live one, with its
/// full input, comes from the agent monitor for the actions).
class DigestPending {
  const DigestPending({
    required this.id,
    required this.toolName,
    required this.summary,
    this.risk,
  });

  final String id;
  final String toolName;
  final String summary;
  final PermissionRisk? risk;
}

/// One agent on the dashboard.
class DigestAgent {
  const DigestAgent({
    required this.hostId,
    required this.hostName,
    required this.sessionId,
    required this.name,
    required this.state,
    this.attention,
    this.project,
    this.live = true,
    this.lastActivityAt,
    this.headline,
    this.stuck = const [],
    this.pending = const [],
    this.facts = const DigestFacts(),
    this.summary,
    this.summaryFresh = false,
    this.summaryPending = false,
    this.lastError,
    this.fromStatus = false,
    this.kind = defaultAgentKind,
  });

  /// The monitored session host it belongs to, and the machine's name.
  final String hostId;
  final String hostName;
  final String sessionId;
  final String name;

  /// The agent CLI (`claude`, `codex`, ...); companions only name it for
  /// agents other than Claude Code.
  final String kind;

  /// The companion's state: `working`, `waiting_input`, `needs_permission`
  /// or `ended`.
  final String state;
  final DigestAttention? attention;
  final String? project;

  /// False: the companion only remembers it (it ended); nothing can be sent.
  final bool live;
  final DateTime? lastActivityAt;

  /// The first line of its last message.
  final String? headline;
  final List<DigestStuckFlag> stuck;
  final List<DigestPending> pending;
  final DigestFacts facts;

  /// Claude's one- or two-sentence summary, when there is one.
  final String? summary;

  /// The summary covers everything the agent did.
  final bool summaryFresh;

  /// A summary run would (re)write it.
  final bool summaryPending;

  /// The API error the last turn ended on (`rate_limit`, `overloaded`).
  final String? lastError;

  /// Built from the monitor's status (a companion without `digest`).
  final bool fromStatus;

  String get key => '$hostId/$sessionId';

  bool get working => state == 'working';
  bool get ended => state == 'ended';

  DigestSection sectionSince(DateTime since) {
    if (attention != null) return DigestSection.needsYou;
    if (stuck.isNotEmpty) return DigestSection.stuck;
    if (working) return DigestSection.working;
    final at = lastActivityAt;
    if (at != null && !at.isBefore(since)) return DigestSection.done;
    return DigestSection.quiet;
  }

  /// What the card says when there is no summary: the facts in words, then
  /// the last message.
  String get factsLine {
    final f = facts;
    final parts = <String>[
      if (f.filesEdited > 0)
        '${f.filesEdited} ${f.filesEdited == 1 ? 'file' : 'files'} edited',
      if (f.testRuns > 0)
        f.lastTestPassed == false ? 'tests failing' : 'tests passing',
      if (f.failedCommands > 0 && f.testsFailed < f.failedCommands)
        '${f.failedCommands - f.testsFailed} failed '
            '${f.failedCommands - f.testsFailed == 1 ? 'command' : 'commands'}',
    ];
    final head = headline?.trim();
    final lead = parts.isEmpty ? '' : '${_capitalize(parts.join(', '))}.';
    if (head == null || head.isEmpty) {
      if (lead.isNotEmpty) return lead;
      return switch (state) {
        'working' => 'Working.',
        'ended' => 'Ended.',
        _ => 'Nothing new.',
      };
    }
    return lead.isEmpty ? head : '$lead $head';
  }

  /// The line to show: the summary, else [factsLine].
  String get line => summary ?? factsLine;
}

String _capitalize(String s) =>
    s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

/// What one summary run cost.
class DigestSummaryRun {
  const DigestSummaryRun({
    this.enabled = false,
    this.pending = 0,
    this.done = 0,
    this.calls = 0,
    this.tokens = 0,
    this.costUsd = 0,
    this.error,
  });

  final bool enabled;
  final int pending;
  final int done;
  final int calls;
  final int tokens;
  final double costUsd;

  /// `claude-missing`, `not-logged-in`, `timeout`, `busy`, `failed`.
  final String? error;
}

/// One machine's `digest` answer.
class DigestReport {
  const DigestReport({
    required this.agents,
    this.generatedAt,
    this.since,
    this.activity = true,
    this.summaries = const DigestSummaryRun(),
    this.tokensToday = 0,
    this.costTodayUsd = 0,
    this.fromStatus = false,
  });

  final List<DigestAgent> agents;
  final DateTime? generatedAt;
  final DateTime? since;

  /// False: the companion's daemon has no activity log yet (older daemon
  /// still running): only state facts.
  final bool activity;
  final DigestSummaryRun summaries;

  /// Tokens and cost of the companion's summary calls today.
  final int tokensToday;
  final double costTodayUsd;

  /// Built from `status` (a companion without `digest`).
  final bool fromStatus;

  bool get hasPendingSummaries => agents.any((agent) => agent.summaryPending);
}

DateTime? _time(Object? raw) => raw is num && raw > 0
    ? DateTime.fromMillisecondsSinceEpoch(raw.toInt(), isUtc: true)
    : null;

String? _text(Object? raw) =>
    raw is String && raw.trim().isNotEmpty ? raw.trim() : null;

/// Parses `conductore-hostd digest` stdout; null when it is not a digest
/// (an older companion answers `unknown command`).
DigestReport? parseDigestReport(
  String stdout, {
  required String hostId,
  required String hostName,
}) {
  final text = stdout.trim();
  if (text.isEmpty) return null;
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
  final agents = decoded['agents'];
  final run = decoded['summaries'];
  final today = decoded['summaryUsageToday'];
  int tokensOf(Object? raw) => raw is Map && raw['tokens'] is Map
      ? ((raw['tokens'] as Map)['total'] as num? ?? 0).toInt()
      : 0;
  double costOf(Object? raw) => raw is Map && raw['costUsd'] is num
      ? (raw['costUsd'] as num).toDouble()
      : 0;
  return DigestReport(
    generatedAt: _time(decoded['generatedAt']),
    since: _time(decoded['since']),
    activity: decoded['activity'] != false,
    summaries: run is Map
        ? DigestSummaryRun(
            enabled: run['enabled'] == true,
            pending: (run['pending'] as num? ?? 0).toInt(),
            done: (run['done'] as num? ?? 0).toInt(),
            calls: (run['calls'] as num? ?? 0).toInt(),
            tokens: tokensOf(run),
            costUsd: costOf(run),
            error: _text(run['error']),
          )
        : const DigestSummaryRun(),
    tokensToday: tokensOf(today),
    costTodayUsd: costOf(today),
    agents: [
      if (agents is List)
        for (final raw in agents)
          ?_parseAgent(raw, hostId: hostId, hostName: hostName),
    ],
  );
}

DigestAgent? _parseAgent(
  Object? raw, {
  required String hostId,
  required String hostName,
}) {
  if (raw is! Map) return null;
  final sessionId = _text(raw['sessionId']);
  if (sessionId == null) return null;
  final stuck = raw['stuck'];
  final pending = raw['pending'];
  final summary = raw['summary'];
  final lastError = raw['lastError'];
  final kind = _text(raw['kind']) ?? defaultAgentKind;
  return DigestAgent(
    hostId: hostId,
    hostName: hostName,
    sessionId: sessionId,
    kind: kind,
    name:
        _text(raw['name']) ??
        _text(raw['project']) ??
        '${agentKindLabel(kind)} session',
    state: _text(raw['state']) ?? 'working',
    attention: DigestAttention.parse(raw['attention']),
    project: _text(raw['project']),
    live: raw['live'] != false,
    lastActivityAt: _time(raw['lastActivityAt']),
    headline: _text(raw['headline']),
    stuck: [
      if (stuck is List)
        for (final flag in stuck)
          if (flag is Map && _text(flag['reason']) != null)
            DigestStuckFlag(_text(flag['rule']) ?? '', _text(flag['reason'])!),
    ],
    pending: [
      if (pending is List)
        for (final p in pending)
          if (p is Map && _text(p['id']) != null)
            DigestPending(
              id: _text(p['id'])!,
              toolName: _text(p['toolName']) ?? 'tool',
              summary: _text(p['summary']) ?? '',
              risk: PermissionRisk.parse(p['risk']),
            ),
    ],
    facts: DigestFacts.fromJson(raw['facts']),
    summary: summary is Map ? _text(summary['text']) : null,
    summaryFresh: summary is Map && summary['fresh'] == true,
    summaryPending: raw['summaryPending'] == true,
    lastError: lastError is Map ? _text(lastError['type']) : null,
  );
}

/// A digest from the agent monitor's status alone, for a companion
/// without `digest`: states, approvals and last messages; no counts, no
/// stuck flags, no summaries.
DigestReport digestFromStatus({
  required String hostId,
  required String hostName,
  required List<AgentInfo> agents,
}) {
  return DigestReport(
    fromStatus: true,
    activity: false,
    agents: [
      for (final agent in agents)
        DigestAgent(
          hostId: hostId,
          hostName: hostName,
          sessionId: agent.id,
          name: agent.name,
          kind: agent.kind.isEmpty ? defaultAgentKind : agent.kind,
          project: agent.projectLabel,
          fromStatus: true,
          state: switch (agent.state) {
            AgentAttentionState.working => 'working',
            AgentAttentionState.finished => 'ended',
            _ when agent.pendingRequests.isNotEmpty => 'needs_permission',
            _ => 'waiting_input',
          },
          attention: agent.pendingRequests.isNotEmpty
              ? DigestAttention.permission
              : agent.state.needsAttention && _asks(agent.lastMessage)
              ? DigestAttention.question
              : null,
          lastActivityAt: agent.stateChangedAt,
          headline: _firstLine(agent.lastMessage),
          pending: [
            for (final request in agent.pendingRequests)
              DigestPending(
                id: request.id,
                toolName: request.toolName,
                summary: request.summary,
                risk: request.risk,
              ),
          ],
        ),
    ],
  );
}

bool _asks(String? message) {
  final lines = (message ?? '')
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty);
  return lines.isNotEmpty && RegExp(r'''\?[\s*_)"'`]*$''').hasMatch(lines.last);
}

String? _firstLine(String? message) {
  for (final line in (message ?? '').split('\n')) {
    final plain = line.replaceAll(RegExp(r'^[#>*\-\s]+|[*_`]+'), '').trim();
    if (plain.isNotEmpty) {
      return plain.length > 160 ? '${plain.substring(0, 159)}…' : plain;
    }
  }
  return null;
}

/// Every machine's agents, sorted into sections.
class DigestOverview {
  DigestOverview(List<DigestAgent> agents, {required this.since})
    : agents = List.unmodifiable(agents) {
    for (final agent in this.agents) {
      _sections.putIfAbsent(agent.sectionSince(since), () => []).add(agent);
    }
    for (final list in _sections.values) {
      list.sort((a, b) {
        final at = a.lastActivityAt;
        final bt = b.lastActivityAt;
        if (at == null || bt == null) return at == null ? 1 : -1;
        return bt.compareTo(at);
      });
    }
  }

  final DateTime since;
  final List<DigestAgent> agents;
  final Map<DigestSection, List<DigestAgent>> _sections = {};

  List<DigestAgent> section(DigestSection section) =>
      _sections[section] ?? const [];

  int count(DigestSection section) => section == DigestSection.done
      // "Done" in the header counts the quiet ones too.
      ? this.section(DigestSection.done).length +
            this.section(DigestSection.quiet).length
      : this.section(section).length;

  bool get isEmpty => agents.isEmpty;
}

/// "catch me up" / "põe-me a par": the counts, then who needs the user
/// and who is stuck, briefly (at most three of each).
String catchUpSpeech(DigestOverview overview, String languageCode) {
  final pt = languageCode.startsWith('pt');
  if (overview.isEmpty) {
    return pt ? 'Não há agentes a correr.' : 'No agents are running.';
  }
  final needs = overview.section(DigestSection.needsYou);
  final stuck = overview.section(DigestSection.stuck);
  final working = overview.count(DigestSection.working);
  final done = overview.count(DigestSection.done);
  String plural(int n, String one, String many) => n == 1 ? one : many;
  final counts = pt
      ? [
          '${needs.length} ${plural(needs.length, 'precisa', 'precisam')} de ti',
          '${stuck.length} ${plural(stuck.length, 'parado', 'parados')}',
          '$working a trabalhar',
          '$done ${plural(done, 'terminado', 'terminados')}',
        ]
      : [
          '${needs.length} ${plural(needs.length, 'needs', 'need')} you',
          '${stuck.length} stuck',
          '$working working',
          '$done done',
        ];
  final out = StringBuffer('${counts.join(', ')}.');
  String brief(DigestAgent agent, String what) {
    final text = what.trim();
    final sentence = RegExp(r'^.*?[.!?](\s|$)').firstMatch(text)?.group(0);
    final short = (sentence ?? text).trim();
    return '${agent.name}: ${short.length > 180 ? '${short.substring(0, 179)}…' : short}';
  }

  void list(
    List<DigestAgent> agents,
    String title,
    String Function(DigestAgent) what,
  ) {
    if (agents.isEmpty) return;
    out.write(' $title ');
    final shown = agents.take(3).map((agent) => brief(agent, what(agent)));
    out.write(shown.join(' '));
    if (agents.length > 3) {
      out.write(
        pt
            ? ' E mais ${agents.length - 3}.'
            : ' And ${agents.length - 3} more.',
      );
    }
    if (!out.toString().endsWith('.') &&
        !out.toString().endsWith('?') &&
        !out.toString().endsWith('…')) {
      out.write('.');
    }
  }

  list(needs, pt ? 'Precisam de ti:' : 'Needs you:', (agent) {
    final request = agent.pending.firstOrNull;
    if (agent.summary == null && request != null) {
      return pt
          ? 'quer aprovação para ${request.toolName}.'
          : 'wants approval for ${request.toolName}.';
    }
    return agent.line;
  });
  list(stuck, pt ? 'Parados:' : 'Stuck:', (agent) => agent.stuck.first.reason);
  return out.toString();
}
