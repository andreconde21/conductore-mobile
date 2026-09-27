import 'dart:convert';

import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agents_digest/domain/agents_digest.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';

/// One agent line as the home-screen widget and quick-settings tile show
/// it: display label, machine name and state only (the same lock-screen
/// safe subset the notifications use).
class AgentStatusEntry {
  const AgentStatusEntry({
    required this.name,
    required this.host,
    required this.state,
  });

  final String name;
  final String host;
  final AgentAttentionState state;

  Map<String, Object?> toJson() => {
    'name': name,
    'host': host,
    'state': state.name,
    'label': state.label,
  };

  static AgentStatusEntry fromJson(Map<String, Object?> json) {
    final stateName = json['state'] as String?;
    return AgentStatusEntry(
      name: json['name'] as String? ?? '',
      host: json['host'] as String? ?? '',
      state:
          AgentAttentionState.values
              .where((state) => state.name == stateName)
              .firstOrNull ??
          AgentAttentionState.unknown,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AgentStatusEntry &&
      other.name == name &&
      other.host == host &&
      other.state == state;

  @override
  int get hashCode => Object.hash(name, host, state);
}

/// One account limit window as the widget's ring shows it: `5h` or `7d`,
/// the share used (0 once the window reset) and whether it is at the
/// warning level (80 % and up).
class AgentStatusLimit {
  const AgentStatusLimit({
    required this.label,
    required this.usedPct,
    this.resetsAt,
  });

  final String label;

  /// 0 to 100, rounded.
  final int usedPct;
  final DateTime? resetsAt;

  /// Mirrors `kUsageWarningPct` / `kUsageCriticalPct` of the app.
  String get level => usedPct >= 95
      ? 'critical'
      : usedPct >= 80
      ? 'warning'
      : 'normal';

  Map<String, Object?> toJson() => {
    'label': label,
    'usedPct': usedPct,
    'level': level,
    if (resetsAt case final at?) 'resetsAt': at.toUtc().millisecondsSinceEpoch,
  };

  static AgentStatusLimit? fromJson(Object? json) {
    if (json is! Map || json['label'] is! String || json['usedPct'] is! num) {
      return null;
    }
    final resets = json['resetsAt'];
    return AgentStatusLimit(
      label: json['label'] as String,
      usedPct: (json['usedPct'] as num).round(),
      resetsAt: resets is int
          ? DateTime.fromMillisecondsSinceEpoch(resets, isUtc: true)
          : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AgentStatusLimit &&
      other.label == label &&
      other.usedPct == usedPct &&
      other.resetsAt == resetsAt;

  @override
  int get hashCode => Object.hash(label, usedPct, resetsAt);
}

/// What the native widget and tile render, pushed from Dart whenever the
/// agent dashboard changes.
///
/// Serialized as JSON so the Kotlin side can store it verbatim in
/// SharedPreferences and render it without the Flutter engine running.
class AgentStatusSnapshot {
  const AgentStatusSnapshot({
    required this.monitoring,
    required this.attentionCount,
    required this.agents,
    required this.updatedAt,
    this.limits = const [],
    this.dashboard,
    this.theme,
  });

  /// Payload format version; bump when the shape changes. 2: [limits].
  /// 3: [dashboard] and [theme]. The native side reads every version.
  static const version = 3;

  /// Most agents listed; the widget has room for four rows at most.
  static const maxAgents = 4;

  /// Whether at least one host is currently monitored. When false the
  /// widget shows its "open the app" placeholder instead of stale rows.
  final bool monitoring;

  /// Agents needing input or blocked, across all monitored hosts.
  final int attentionCount;

  /// Up to [maxAgents] entries, most urgent first.
  final List<AgentStatusEntry> agents;

  final DateTime updatedAt;

  /// Claude's 5-hour and weekly windows (the widget's rings), when known.
  final List<AgentStatusLimit> limits;

  /// The agents dashboard's counts and top lines; null while nothing is
  /// monitored (and in payloads before version 3).
  final AgentStatusDashboard? dashboard;

  /// The app theme's colours, so the widget matches the app; null keeps
  /// the widget's own Everforest.
  final AgentStatusTheme? theme;

  /// Builds the snapshot for every monitored host, sorting agents so the
  /// ones a human should look at come first.
  factory AgentStatusSnapshot.build({
    required Iterable<({String hostName, List<AgentInfo> agents})> hosts,
    required bool monitoring,
    required DateTime now,
    List<AgentStatusLimit> limits = const [],
    AgentStatusDashboard? dashboard,
    AgentStatusTheme? theme,
  }) {
    final entries = <AgentStatusEntry>[
      for (final host in hosts)
        for (final agent in host.agents)
          AgentStatusEntry(
            name: agent.name,
            host: host.hostName,
            state: agent.state,
          ),
    ];
    // Stable sort by urgency only, so the provider's own ordering breaks
    // ties (the list does not jump around between polls).
    final ranked = entries.indexed.toList()
      ..sort((a, b) {
        final byUrgency = _urgency(a.$2.state).compareTo(_urgency(b.$2.state));
        return byUrgency != 0 ? byUrgency : a.$1.compareTo(b.$1);
      });
    return AgentStatusSnapshot(
      monitoring: monitoring,
      attentionCount: entries
          .where((entry) => entry.state.needsAttention)
          .length,
      agents: [for (final (_, entry) in ranked.take(maxAgents)) entry],
      updatedAt: now,
      limits: limits,
      dashboard: monitoring ? dashboard : null,
      theme: theme,
    );
  }

  /// The snapshot pushed when nothing is monitored (app start, or after the
  /// last monitored session closes).
  factory AgentStatusSnapshot.empty(DateTime now) => AgentStatusSnapshot(
    monitoring: false,
    attentionCount: 0,
    agents: const [],
    updatedAt: now,
  );

  static int _urgency(AgentAttentionState state) => switch (state) {
    AgentAttentionState.needsInput => 0,
    AgentAttentionState.blocked => 1,
    AgentAttentionState.finished => 2,
    AgentAttentionState.working => 3,
    AgentAttentionState.idle => 4,
    AgentAttentionState.unknown => 5,
  };

  Map<String, Object?> toJson() => {
    'version': version,
    'monitoring': monitoring,
    'attentionCount': attentionCount,
    'updatedAt': updatedAt.toUtc().millisecondsSinceEpoch,
    'agents': [for (final agent in agents) agent.toJson()],
    'limits': [for (final limit in limits) limit.toJson()],
    if (dashboard case final dashboard?) 'dashboard': dashboard.toJson(),
    if (theme case final theme?) 'theme': theme.toJson(),
  };

  String encode() => jsonEncode(toJson());

  /// Reads every payload version: before 3 there is no dashboard or theme.
  static AgentStatusSnapshot fromJson(Map<String, Object?> json) {
    final agents = json['agents'];
    final limits = json['limits'];
    final payloadVersion = json['version'] is int ? json['version']! as int : 1;
    final v3 = payloadVersion >= 3;
    return AgentStatusSnapshot(
      monitoring: json['monitoring'] as bool? ?? false,
      attentionCount: json['attentionCount'] as int? ?? 0,
      agents: [
        if (agents is List)
          for (final agent in agents)
            if (agent is Map<String, Object?>) AgentStatusEntry.fromJson(agent),
      ],
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        json['updatedAt'] as int? ?? 0,
        isUtc: true,
      ),
      limits: [
        if (limits is List)
          for (final limit in limits) ?AgentStatusLimit.fromJson(limit),
      ],
      dashboard: v3 ? AgentStatusDashboard.fromJson(json['dashboard']) : null,
      theme: v3 ? AgentStatusTheme.fromJson(json['theme']) : null,
    );
  }

  static AgentStatusSnapshot decode(String source) =>
      fromJson(jsonDecode(source) as Map<String, Object?>);

  @override
  bool operator ==(Object other) =>
      other is AgentStatusSnapshot &&
      other.monitoring == monitoring &&
      other.attentionCount == attentionCount &&
      other.updatedAt == updatedAt &&
      _listEquals(other.agents, agents) &&
      _listEquals(other.limits, limits) &&
      other.dashboard == dashboard &&
      other.theme == theme;

  @override
  int get hashCode => Object.hash(
    monitoring,
    attentionCount,
    updatedAt,
    Object.hashAll(agents),
    Object.hashAll(limits),
    dashboard,
    theme,
  );

  static bool _listEquals<T>(List<T> a, List<T> b) {
    if (a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }
}

/// What a widget line is about.
enum AgentStatusLineKind { needsYou, stuck }

/// One "needs you" or "stuck" line of the widget: agent · machine ·
/// reason, each part capped, and the agent a tap on it opens.
class AgentStatusLine {
  const AgentStatusLine({
    required this.kind,
    required this.name,
    required this.host,
    required this.reason,
    required this.hostId,
    required this.agentId,
    this.workspace,
    this.tab,
    this.pane,
  });

  /// Builds a line with every shown part capped to what the widget fits.
  factory AgentStatusLine.capped({
    required AgentStatusLineKind kind,
    required String name,
    required String host,
    required String reason,
    required String hostId,
    required String agentId,
    String? workspace,
    String? tab,
    String? pane,
  }) => AgentStatusLine(
    kind: kind,
    name: _cap(name, maxName),
    host: _cap(host, maxHost),
    reason: _cap(reason.replaceAll('`', ''), maxReason),
    hostId: hostId,
    agentId: agentId,
    workspace: workspace,
    tab: tab,
    pane: pane,
  );

  static const maxName = 28;
  static const maxHost = 20;
  static const maxReason = 60;

  final AgentStatusLineKind kind;
  final String name;
  final String host;
  final String reason;

  /// Where a tap goes (the notification deep link's fields).
  final String hostId;
  final String agentId;
  final String? workspace;
  final String? tab;
  final String? pane;

  static String _cap(String text, int max) {
    final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length <= max ? flat : '${flat.substring(0, max - 1)}…';
  }

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'name': name,
    'host': host,
    'reason': reason,
    'hostId': hostId,
    'agentId': agentId,
    'workspace': ?workspace,
    'tab': ?tab,
    'pane': ?pane,
  };

  static AgentStatusLine? fromJson(Object? json) {
    if (json is! Map ||
        json['hostId'] is! String ||
        (json['hostId'] as String).isEmpty) {
      return null;
    }
    String text(String key) => json[key] is String ? json[key] as String : '';
    String? optional(String key) =>
        json[key] is String && (json[key] as String).isNotEmpty
        ? json[key] as String
        : null;
    return AgentStatusLine(
      kind: json['kind'] == AgentStatusLineKind.stuck.name
          ? AgentStatusLineKind.stuck
          : AgentStatusLineKind.needsYou,
      name: text('name'),
      host: text('host'),
      reason: text('reason'),
      hostId: text('hostId'),
      agentId: text('agentId'),
      workspace: optional('workspace'),
      tab: optional('tab'),
      pane: optional('pane'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AgentStatusLine &&
      other.kind == kind &&
      other.name == name &&
      other.host == host &&
      other.reason == reason &&
      other.hostId == hostId &&
      other.agentId == agentId &&
      other.workspace == workspace &&
      other.tab == tab &&
      other.pane == pane;

  @override
  int get hashCode => Object.hash(
    kind,
    name,
    host,
    reason,
    hostId,
    agentId,
    workspace,
    tab,
    pane,
  );
}

/// The agents dashboard's counts as the widget and tile show them.
///
/// Needs you and working are live: the agent monitor's state. Stuck and
/// done come from the dashboard's last `digest` answer, if one is cached
/// ([factsAt]); they are null when there is none. Building it never asks
/// a machine for anything, and never runs a summary.
class AgentStatusDashboard {
  const AgentStatusDashboard({
    required this.needsYou,
    required this.working,
    this.stuck,
    this.done,
    this.factsAt,
    this.lines = const [],
  });

  /// Most lines listed; the 4x2 widget has room for three.
  static const maxLines = 3;

  final int needsYou;
  final int working;

  /// Null: no digest cached yet.
  final int? stuck;

  /// Done (and quiet) since the last look at the dashboard; null: no
  /// digest cached yet.
  final int? done;

  /// When the oldest cached digest answer behind [stuck] and [done] was
  /// fetched ("as of").
  final DateTime? factsAt;

  /// Up to [maxLines], needing you first, then stuck.
  final List<AgentStatusLine> lines;

  /// Derives the counts from the monitor's [hosts] and, when given, the
  /// cached [digest] overview fetched at [factsAt].
  ///
  /// The sections follow the dashboard's precedence (needs you, stuck,
  /// working, done), so no agent counts twice: an agent the monitor sees
  /// needing you is not stuck, a stuck one is not working, and nothing
  /// the monitor sees needing you or working is done.
  factory AgentStatusDashboard.derive({
    required Iterable<
      ({String hostId, String hostName, List<AgentInfo> agents})
    >
    hosts,
    DigestOverview? digest,
    DateTime? factsAt,
  }) {
    String key(String hostId, String agentId) =>
        '${baseHostId(hostId)}/$agentId';
    final needs = <(String, AgentInfo, String)>[];
    final working = <String>{};
    final live = <String, (String, AgentInfo)>{};
    for (final host in hosts) {
      for (final agent in host.agents) {
        final id = key(host.hostId, agent.id);
        live[id] = (host.hostId, agent);
        if (agent.state.needsAttention) {
          needs.add((host.hostId, agent, host.hostName));
        } else if (agent.state == AgentAttentionState.working) {
          working.add(id);
        }
      }
    }
    // Waiting for a human answer before other blocks, provider order kept.
    needs.sort((a, b) => a.$2.state.index.compareTo(b.$2.state.index));
    final needKeys = {
      for (final (hostId, agent, _) in needs) key(hostId, agent.id),
    };

    final lines = <AgentStatusLine>[
      for (final (hostId, agent, hostName) in needs.take(maxLines))
        AgentStatusLine.capped(
          kind: AgentStatusLineKind.needsYou,
          name: agent.name,
          host: hostName,
          reason: _needsReason(agent),
          hostId: hostId,
          agentId: agent.id,
          workspace: agent.workspace,
          tab: agent.tab,
          pane: agent.pane,
        ),
    ];
    if (digest == null) {
      return AgentStatusDashboard(
        needsYou: needs.length,
        working: working.length,
        lines: lines,
      );
    }
    final stuck = [
      for (final agent in digest.agents)
        if (agent.stuck.isNotEmpty &&
            !needKeys.contains(key(agent.hostId, agent.sessionId)))
          agent,
    ];
    final stuckKeys = {
      for (final agent in stuck) key(agent.hostId, agent.sessionId),
    };
    for (final agent in stuck) {
      if (lines.length >= maxLines) break;
      final (hostId, info) =
          live[key(agent.hostId, agent.sessionId)] ?? (agent.hostId, null);
      lines.add(
        AgentStatusLine.capped(
          kind: AgentStatusLineKind.stuck,
          name: agent.name,
          host: agent.hostName,
          reason: agent.stuck.first.reason,
          hostId: hostId,
          agentId: agent.sessionId,
          workspace: info?.workspace,
          tab: info?.tab,
          pane: info?.pane,
        ),
      );
    }
    final done = [
      for (final section in const [DigestSection.done, DigestSection.quiet])
        for (final agent in digest.section(section))
          if (!needKeys.contains(key(agent.hostId, agent.sessionId)) &&
              !working.contains(key(agent.hostId, agent.sessionId)))
            agent,
    ];
    return AgentStatusDashboard(
      needsYou: needs.length,
      working: working.difference(stuckKeys).length,
      stuck: stuck.length,
      done: done.length,
      factsAt: factsAt,
      lines: lines,
    );
  }

  static String _needsReason(AgentInfo agent) {
    if (agent.pendingRequests.firstOrNull case final request?) {
      return 'approve ${request.toolName}';
    }
    return agent.state.label.toLowerCase();
  }

  Map<String, Object?> toJson() => {
    'needsYou': needsYou,
    'working': working,
    'stuck': ?stuck,
    'done': ?done,
    if (factsAt case final at?) 'factsAt': at.toUtc().millisecondsSinceEpoch,
    'lines': [for (final line in lines) line.toJson()],
  };

  static AgentStatusDashboard? fromJson(Object? json) {
    if (json is! Map) return null;
    int? count(String key) =>
        json[key] is num ? (json[key] as num).toInt() : null;
    final lines = json['lines'];
    final factsAt = json['factsAt'];
    return AgentStatusDashboard(
      needsYou: count('needsYou') ?? 0,
      working: count('working') ?? 0,
      stuck: count('stuck'),
      done: count('done'),
      factsAt: factsAt is int
          ? DateTime.fromMillisecondsSinceEpoch(factsAt, isUtc: true)
          : null,
      lines: [
        if (lines is List)
          for (final line in lines.take(maxLines))
            ?AgentStatusLine.fromJson(line),
      ],
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AgentStatusDashboard &&
      other.needsYou == needsYou &&
      other.working == working &&
      other.stuck == stuck &&
      other.done == done &&
      other.factsAt == factsAt &&
      AgentStatusSnapshot._listEquals(other.lines, lines);

  @override
  int get hashCode => Object.hash(
    needsYou,
    working,
    stuck,
    done,
    factsAt,
    Object.hashAll(lines),
  );
}

/// The app theme's colours as ARGB, for the widget to match the app
/// (dark or light, whatever Omarchy theme; Everforest by default).
class AgentStatusTheme {
  const AgentStatusTheme({
    required this.dark,
    required this.surface,
    required this.onSurface,
    required this.muted,
    required this.border,
    required this.accent,
    required this.onAccent,
    required this.warning,
    required this.urgent,
  });

  /// The same roles the app chrome gives the palette.
  factory AgentStatusTheme.fromPalette(AppPalette palette) => AgentStatusTheme(
    dark: palette.isDark,
    surface: palette.canvas.toARGB32(),
    onSurface: palette.foreground.toARGB32(),
    muted: palette.mutedForeground.toARGB32(),
    border: palette.hairline.toARGB32(),
    accent: palette.accent.toARGB32(),
    onAccent: palette.onAccent.toARGB32(),
    warning: palette.warning.toARGB32(),
    urgent: palette.danger.toARGB32(),
  );

  final bool dark;
  final int surface;
  final int onSurface;
  final int muted;
  final int border;
  final int accent;
  final int onAccent;
  final int warning;
  final int urgent;

  Map<String, Object?> toJson() => {
    'dark': dark,
    'surface': surface,
    'onSurface': onSurface,
    'muted': muted,
    'border': border,
    'accent': accent,
    'onAccent': onAccent,
    'warning': warning,
    'urgent': urgent,
  };

  static AgentStatusTheme? fromJson(Object? json) {
    if (json is! Map) return null;
    const keys = [
      'surface',
      'onSurface',
      'muted',
      'border',
      'accent',
      'onAccent',
      'warning',
      'urgent',
    ];
    if (keys.any((key) => json[key] is! int)) return null;
    int color(String key) => json[key]! as int;
    return AgentStatusTheme(
      dark: json['dark'] != false,
      surface: color('surface'),
      onSurface: color('onSurface'),
      muted: color('muted'),
      border: color('border'),
      accent: color('accent'),
      onAccent: color('onAccent'),
      warning: color('warning'),
      urgent: color('urgent'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AgentStatusTheme &&
      other.dark == dark &&
      other.surface == surface &&
      other.onSurface == onSurface &&
      other.muted == muted &&
      other.border == border &&
      other.accent == accent &&
      other.onAccent == onAccent &&
      other.warning == warning &&
      other.urgent == urgent;

  @override
  int get hashCode => Object.hash(
    dark,
    surface,
    onSurface,
    muted,
    border,
    accent,
    onAccent,
    warning,
    urgent,
  );
}
