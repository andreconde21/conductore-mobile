import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:flutter/foundation.dart';

/// The companion capability that carries risk labels, approval rules,
/// time-boxed trust, "approve all safe" and the auto-approved log.
const smartApprovalsCapability = 'smart-approvals';

/// Where an approval rule applies.
enum ApprovalScopeKind {
  /// One agent session; the rule goes when the session ends.
  session,

  /// Any session working inside a repository (or folder).
  repo,

  /// Every session on the machine.
  any;

  String get label => switch (this) {
    ApprovalScopeKind.session => 'This session',
    ApprovalScopeKind.repo => 'This repo',
    ApprovalScopeKind.any => 'All repos',
  };

  static ApprovalScopeKind? parse(Object? raw) => switch (raw) {
    'session' => ApprovalScopeKind.session,
    'repo' || 'path' || 'workspace' => ApprovalScopeKind.repo,
    'any' => ApprovalScopeKind.any,
    _ => null,
  };
}

/// A rule's scope: a session id, a repo path, or everywhere.
@immutable
class ApprovalScope {
  const ApprovalScope.any()
    : kind = ApprovalScopeKind.any,
      path = null,
      sessionId = null,
      label = null;

  const ApprovalScope.repo(String this.path)
    : kind = ApprovalScopeKind.repo,
      sessionId = null,
      label = null;

  const ApprovalScope.session(String this.sessionId, {this.label})
    : kind = ApprovalScopeKind.session,
      path = null;

  /// Just the kind, for a trust: the companion takes the repo and session
  /// from the request it trusts.
  const ApprovalScope.ofKind(this.kind)
    : path = null,
      sessionId = null,
      label = null;

  const ApprovalScope._(this.kind, this.path, this.sessionId, this.label);

  final ApprovalScopeKind kind;
  final String? path;
  final String? sessionId;

  /// The agent's name, for a session scope.
  final String? label;

  static ApprovalScope parse(Object? raw) {
    if (raw is! Map) {
      return const ApprovalScope.any();
    }
    final kind = ApprovalScopeKind.parse(raw['kind']) ?? ApprovalScopeKind.any;
    String? text(Object? value) =>
        value is String && value.trim().isNotEmpty ? value.trim() : null;
    return ApprovalScope._(
      kind,
      text(raw['path']),
      text(raw['sessionId']),
      text(raw['label']),
    );
  }

  /// "in app", "session reviewer", "everywhere".
  String describe() => switch (kind) {
    ApprovalScopeKind.any => 'all repos',
    ApprovalScopeKind.repo => 'in ${_basename(path) ?? 'a repo'}',
    ApprovalScopeKind.session =>
      'in session ${label ?? _shortId(sessionId) ?? '?'}',
  };

  @override
  bool operator ==(Object other) =>
      other is ApprovalScope &&
      other.kind == kind &&
      other.path == path &&
      other.sessionId == sessionId &&
      other.label == label;

  @override
  int get hashCode => Object.hash(kind, path, sessionId, label);
}

/// How long a new rule lasts.
@immutable
class TrustDuration {
  const TrustDuration.minutes(int this.minutes) : untilSessionEnd = false;

  const TrustDuration.untilSessionEnd()
    : minutes = null,
      untilSessionEnd = true;

  /// Until revoked (a rule saved from "Always").
  const TrustDuration.forever() : minutes = null, untilSessionEnd = false;

  final int? minutes;
  final bool untilSessionEnd;

  bool get isForever => minutes == null && !untilSessionEnd;

  /// The choices the approval sheet offers, shortest first.
  static const choices = [
    TrustDuration.minutes(15),
    TrustDuration.minutes(60),
    TrustDuration.untilSessionEnd(),
    TrustDuration.forever(),
  ];

  String get label {
    final m = minutes;
    if (m != null) {
      return m % 60 == 0 ? '${m ~/ 60} h' : '$m min';
    }
    return untilSessionEnd ? 'Until session ends' : 'Always';
  }

  @override
  bool operator ==(Object other) =>
      other is TrustDuration &&
      other.minutes == minutes &&
      other.untilSessionEnd == untilSessionEnd;

  @override
  int get hashCode => Object.hash(minutes, untilSessionEnd);
}

/// What the phone asks the companion to save: a rule, where, how long.
@immutable
class ApprovalRuleDraft {
  const ApprovalRuleDraft({
    required this.rule,
    required this.scope,
    required this.duration,
  });

  /// Claude Code syntax: `Tool` or `Tool(pattern)`. Empty in a trust:
  /// the companion saves a rule for exactly the trusted call.
  final String rule;
  final ApprovalScope scope;
  final TrustDuration duration;
}

/// Whether [text] reads as a rule (`Tool` or `Tool(pattern)`), the same
/// check the companion makes.
bool isValidApprovalRule(String text) {
  final trimmed = text.trim();
  return trimmed.isNotEmpty &&
      trimmed.length <= 500 &&
      RegExp(r'^[A-Za-z][A-Za-z0-9_-]*(\([\s\S]*\))?$').hasMatch(trimmed);
}

/// One saved rule or time-boxed trust on a machine.
@immutable
class ApprovalRule {
  const ApprovalRule({
    required this.id,
    required this.rule,
    required this.scope,
    this.expiresAt,
    this.endsWithSession,
    this.source = 'cli',
    this.createdAt,
    this.hits = 0,
    this.lastUsedAt,
  });

  final String id;
  final String rule;
  final ApprovalScope scope;

  /// Null: until revoked (or until [endsWithSession] ends).
  final DateTime? expiresAt;
  final String? endsWithSession;

  /// `trust`, `always`, `cli` or `voice`.
  final String source;
  final DateTime? createdAt;
  final int hits;
  final DateTime? lastUsedAt;

  /// A trust that runs out by itself (a time or a session).
  bool get isTimeBoxed => expiresAt != null || endsWithSession != null;

  /// "12 min left", "until the session ends", "until revoked".
  String describeDuration({DateTime? now}) {
    final expires = expiresAt;
    if (expires != null) {
      final left = expires.difference((now ?? DateTime.now()).toUtc());
      if (left.isNegative) {
        return 'expired';
      }
      if (left.inMinutes < 1) {
        return 'under a minute left';
      }
      if (left.inMinutes < 60) {
        return '${left.inMinutes} min left';
      }
      final hours = left.inMinutes / 60;
      return hours < 24
          ? '${hours.toStringAsFixed(hours < 10 ? 1 : 0)} h left'
          : '${left.inDays} d left';
    }
    if (endsWithSession != null) {
      return 'until the session ends';
    }
    return 'until revoked';
  }

  static ApprovalRule? parse(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final id = raw['id'];
    final rule = raw['rule'];
    if (id is! String || id.isEmpty || rule is! String || rule.isEmpty) {
      return null;
    }
    final ends = raw['endsWithSession'];
    final source = raw['source'];
    final hits = raw['hits'];
    return ApprovalRule(
      id: id,
      rule: rule,
      scope: ApprovalScope.parse(raw['scope']),
      expiresAt: _millis(raw['expiresAt']),
      endsWithSession: ends is String && ends.isNotEmpty ? ends : null,
      source: source is String && source.isNotEmpty ? source : 'cli',
      createdAt: _millis(raw['createdAt']),
      hits: hits is num ? hits.toInt() : 0,
      lastUsedAt: _millis(raw['lastUsedAt']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ApprovalRule &&
      other.id == id &&
      other.rule == rule &&
      other.scope == scope &&
      other.expiresAt == expiresAt &&
      other.endsWithSession == endsWithSession &&
      other.source == source &&
      other.hits == hits &&
      other.lastUsedAt == lastUsedAt;

  @override
  int get hashCode => Object.hash(
    id,
    rule,
    scope,
    expiresAt,
    endsWithSession,
    source,
    hits,
    lastUsedAt,
  );
}

/// One request a rule answered on the host, for the inbox's audit list.
@immutable
class AutoApprovedEntry {
  const AutoApprovedEntry({
    required this.at,
    required this.toolName,
    required this.summary,
    required this.ruleId,
    required this.rule,
    this.requestId,
    this.sessionId,
    this.agent,
    this.cwd,
    this.risk,
    this.scope = const ApprovalScope.any(),
  });

  final DateTime at;
  final String toolName;
  final String summary;
  final String ruleId;
  final String rule;
  final String? requestId;
  final String? sessionId;

  /// The agent's name when it was answered.
  final String? agent;
  final String? cwd;
  final PermissionRisk? risk;
  final ApprovalScope scope;

  static AutoApprovedEntry? parse(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final at = _millis(raw['at']);
    final ruleId = raw['ruleId'];
    final rule = raw['rule'];
    if (at == null || ruleId is! String || rule is! String) {
      return null;
    }
    String? text(Object? value) =>
        value is String && value.trim().isNotEmpty ? value.trim() : null;
    final toolName = text(raw['toolName']) ?? 'tool';
    return AutoApprovedEntry(
      at: at,
      toolName: toolName,
      summary: text(raw['summary']) ?? toolName,
      ruleId: ruleId,
      rule: rule,
      requestId: text(raw['requestId']),
      sessionId: text(raw['sessionId']),
      agent: text(raw['agent']),
      cwd: text(raw['cwd']),
      risk: PermissionRisk.parse(raw['risk']),
      scope: ApprovalScope.parse(raw['scope']),
    );
  }
}

/// A machine's rules and what they answered (`conductore-hostd approvals`).
@immutable
class ApprovalsSnapshot {
  const ApprovalsSnapshot({
    this.rules = const [],
    this.autoApproved = const [],
    this.fetchedAt,
  });

  final List<ApprovalRule> rules;

  /// Newest first, last 24 hours.
  final List<AutoApprovedEntry> autoApproved;
  final DateTime? fetchedAt;

  ApprovalRule? ruleById(String id) =>
      rules.where((rule) => rule.id == id).firstOrNull;

  ApprovalsSnapshot copyWith({
    List<ApprovalRule>? rules,
    List<AutoApprovedEntry>? autoApproved,
  }) => ApprovalsSnapshot(
    rules: rules ?? this.rules,
    autoApproved: autoApproved ?? this.autoApproved,
    fetchedAt: fetchedAt,
  );
}

/// What "Approve all safe" did: approved request ids, and the ones it
/// left alone with why (not low risk, expired, unknown).
@immutable
class BatchApprovalResult {
  const BatchApprovalResult({
    this.approved = const [],
    this.skipped = const [],
  });

  final List<String> approved;
  final List<({String id, String reason})> skipped;

  BatchApprovalResult merge(BatchApprovalResult other) => BatchApprovalResult(
    approved: [...approved, ...other.approved],
    skipped: [...skipped, ...other.skipped],
  );
}

/// What a trust did: the saved rule and the requests it allowed (the one
/// it came from first).
@immutable
class TrustResult {
  const TrustResult({required this.rule, this.approved = const []});

  final ApprovalRule rule;
  final List<String> approved;
}

/// A provider whose host can keep approval rules and answer requests by
/// itself (the Conductore companion with [smartApprovalsCapability]).
/// Commands are shell command lines for the provider's runner; the parse
/// methods read their stdout and throw on an `{"error"}` reply.
abstract interface class SmartApprovalsProvider {
  String approveLowCommand(List<String> requestIds);

  String trustCommand(
    PendingPermissionRequest request,
    ApprovalRuleDraft draft, {
    String source = 'trust',
  });

  String approvalsCommand();

  String addRuleCommand(ApprovalRuleDraft draft, {String source = 'cli'});

  String editRuleCommand(String ruleId, ApprovalRuleDraft draft);

  String removeRuleCommand(String ruleId);

  ApprovalsSnapshot parseApprovals(String stdout);

  BatchApprovalResult parseBatch(String stdout);

  TrustResult parseTrust(String stdout);

  /// The rule a `rules add` / `rules edit` reply carries, with the waiting
  /// requests it answered.
  TrustResult parseRuleReply(String stdout);
}

DateTime? _millis(Object? value) {
  if (value is! num || value <= 0) {
    return null;
  }
  return DateTime.fromMillisecondsSinceEpoch(value.toInt(), isUtc: true);
}

String? _basename(String? path) {
  if (path == null) {
    return null;
  }
  final parts = path.split('/').where((part) => part.isNotEmpty);
  return parts.isEmpty ? path : parts.last;
}

String? _shortId(String? id) =>
    id == null ? null : (id.length > 8 ? id.substring(0, 8) : id);
