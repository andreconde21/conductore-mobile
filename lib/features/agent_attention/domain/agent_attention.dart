import 'package:conduit/features/agent_attention/domain/agent_kinds.dart';
import 'package:conduit/features/agent_attention/domain/agent_naming.dart';
import 'package:flutter/foundation.dart';

/// The attention-relevant state of one remote agent, normalized across
/// providers.
enum AgentAttentionState {
  /// Actively producing output or running tools.
  working,

  /// Waiting on a human answer or approval.
  needsInput,

  /// Blocked for another reason a provider distinguishes from input.
  blocked,

  /// Completed background work that has not been reviewed yet.
  finished,

  /// Ready for input with nothing pending.
  idle,

  /// Present, but the provider cannot classify it confidently.
  unknown,
}

extension AgentAttentionStateDetails on AgentAttentionState {
  String get label => switch (this) {
    AgentAttentionState.working => 'Working',
    AgentAttentionState.needsInput => 'Needs input',
    AgentAttentionState.blocked => 'Blocked',
    AgentAttentionState.finished => 'Finished',
    AgentAttentionState.idle => 'Idle',
    AgentAttentionState.unknown => 'Unknown',
  };

  /// Whether this state means a human should look at the agent now.
  bool get needsAttention =>
      this == AgentAttentionState.needsInput ||
      this == AgentAttentionState.blocked;
}

/// What a human answers to a pending permission request.
enum PermissionVerdict { allow, deny, always }

extension PermissionVerdictDetails on PermissionVerdict {
  /// The verdict as the host companion's `decide` command spells it.
  String get wireName => name;

  String get label => switch (this) {
    PermissionVerdict.allow => 'Allow',
    PermissionVerdict.deny => 'Deny',
    PermissionVerdict.always => 'Always',
  };
}

/// How much damage a permission request could do, as the companion rates
/// it (`host/lib/risk.js`).
enum PermissionRiskLevel {
  /// Read-only tools and commands, tests and linters.
  low,

  /// Edits in the repo, installs, builds, anything unknown.
  medium,

  /// Recursive deletes, force pushes, `curl | sh`, sudo, writes outside
  /// the repo, secrets, network to unknown hosts. Always asks.
  high;

  String get label => switch (this) {
    PermissionRiskLevel.low => 'Low risk',
    PermissionRiskLevel.medium => 'Medium risk',
    PermissionRiskLevel.high => 'High risk',
  };

  static PermissionRiskLevel? parse(Object? raw) => switch (raw) {
    'low' => PermissionRiskLevel.low,
    'medium' => PermissionRiskLevel.medium,
    'high' => PermissionRiskLevel.high,
    _ => null,
  };
}

/// A risk label with its one-line reason ("Deletes recursively: dist").
class PermissionRisk {
  const PermissionRisk(this.level, this.reason);

  final PermissionRiskLevel level;
  final String reason;

  /// Parses the companion's `{"level", "reason"}`; null when absent or
  /// malformed (an older companion).
  static PermissionRisk? parse(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final level = PermissionRiskLevel.parse(raw['level']);
    if (level == null) {
      return null;
    }
    final reason = raw['reason'];
    return PermissionRisk(
      level,
      reason is String && reason.trim().isNotEmpty ? reason.trim() : '',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PermissionRisk && other.level == level && other.reason == reason;

  @override
  int get hashCode => Object.hash(level, reason);
}

/// The smart-approval fields of one pending request, as the companion
/// reports them (all absent from an older companion).
typedef PendingApprovalInfo = ({
  PermissionRisk? risk,
  bool batchable,
  List<String> suggestedRules,
  String? repo,
});

/// Reads [PendingApprovalInfo] from one `pending[]` entry.
PendingApprovalInfo parsePendingApprovalInfo(Map<Object?, Object?> entry) {
  final risk = PermissionRisk.parse(entry['risk']);
  final rules = entry['suggestedRules'];
  final repo = entry['repo'];
  return (
    risk: risk,
    // Only a low rating may go into a batch, whatever the flag says.
    batchable:
        entry['batchable'] == true && risk?.level == PermissionRiskLevel.low,
    suggestedRules: [
      if (rules is List)
        for (final rule in rules)
          if (rule is String && rule.trim().isNotEmpty) rule.trim(),
    ],
    repo: repo is String && repo.startsWith('/') ? repo : null,
  );
}

/// One option of a [PendingQuestion].
@immutable
class PendingQuestionOption {
  const PendingQuestionOption({required this.label, this.description});

  final String label;
  final String? description;

  @override
  bool operator ==(Object other) =>
      other is PendingQuestionOption &&
      other.label == label &&
      other.description == description;

  @override
  int get hashCode => Object.hash(label, description);
}

/// One question of a pending AskUserQuestion, as the companion reports it
/// (`pending[].questions`, capability `question-answers`). The answer is
/// keyed by [question], exactly as asked.
@immutable
class PendingQuestion {
  const PendingQuestion({
    required this.question,
    this.header,
    this.kind = 'choice',
    this.multiSelect = false,
    this.options = const [],
    this.description,
    this.placeholder,
    this.unit,
  });

  final String question;
  final String? header;

  /// `choice` (options), `text` (free text) or `number`; Claude Code may
  /// add kinds, which take free text here.
  final String kind;
  final bool multiSelect;
  final List<PendingQuestionOption> options;
  final String? description;
  final String? placeholder;
  final String? unit;

  /// Parses one `questions[]` entry; null when it has no question text.
  static PendingQuestion? parse(Object? raw) {
    if (raw is! Map) return null;
    final question = raw['question'];
    if (question is! String || question.isEmpty) return null;
    String? text(Object? value) =>
        value is String && value.trim().isNotEmpty ? value.trim() : null;
    final options = raw['options'];
    return PendingQuestion(
      question: question,
      header: text(raw['header']),
      kind: text(raw['kind']) ?? 'choice',
      multiSelect: raw['multiSelect'] == true,
      options: [
        if (options is List)
          for (final option in options)
            if (option is Map && text(option['label']) != null)
              PendingQuestionOption(
                label: option['label'] as String,
                description: text(option['description']),
              ),
      ],
      description: text(raw['description']),
      placeholder: text(raw['placeholder']),
      unit: text(raw['unit']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PendingQuestion &&
      other.question == question &&
      other.header == header &&
      other.kind == kind &&
      other.multiSelect == multiSelect &&
      listEquals(other.options, options) &&
      other.description == description &&
      other.placeholder == placeholder &&
      other.unit == unit;

  @override
  int get hashCode => Object.hash(
    question,
    header,
    kind,
    multiSelect,
    Object.hashAll(options),
    description,
    placeholder,
    unit,
  );
}

/// The `questions` of one `pending[]` entry (empty when absent).
List<PendingQuestion> parsePendingQuestions(Object? raw) => [
  if (raw is List)
    for (final question in raw) ?PendingQuestion.parse(question),
];

/// One tool call an agent is waiting to have approved, as reported by a
/// provider that can relay permission prompts (the Conductore host
/// companion). Herdr agents never carry these.
class PendingPermissionRequest {
  const PendingPermissionRequest({
    required this.id,
    required this.toolName,
    required this.summary,
    this.toolInput = '',
    this.createdAt,
    this.risk,
    this.batchable = false,
    this.suggestedRules = const [],
    this.repo,
    this.questions = const [],
    this.answers,
    this.terminalOnly = false,
    this.expired = false,
  });

  /// The Claude Code tool that asks the user questions.
  static const questionTool = 'AskUserQuestion';

  /// The Claude Code tool that asks the user to approve a plan.
  static const planTool = 'ExitPlanMode';

  /// Provider-issued request id, passed back verbatim with the decision.
  final String id;

  final String toolName;

  /// One-line human description of the call (e.g. the shell command).
  final String summary;

  /// The full tool input, pretty-printed, capped at [maxToolInputLength].
  final String toolInput;

  final DateTime? createdAt;

  /// The companion's risk rating; null from an older companion.
  final PermissionRisk? risk;

  /// Whether "Approve all safe" may include it (low risk only).
  final bool batchable;

  /// Approval rules that would cover it, most specific first
  /// (Claude Code syntax, e.g. `Bash(npm test *)`).
  final List<String> suggestedRules;

  /// The git work tree the agent works in (a rule's "this repo" scope).
  final String? repo;

  /// The questions of an AskUserQuestion request; empty for other tools
  /// and from a companion without `question-answers`.
  final List<PendingQuestion> questions;

  /// What the user picked, question -> answer: set on the copy handed to
  /// `decide` ([withAnswers]); never reported by the companion.
  final Map<String, String>? answers;

  /// The agent's own prompt answers it; the phone can only show it (the
  /// companion's `answerable: false`, e.g. Gemini CLI). No Allow, Deny,
  /// Always or Trust.
  final bool terminalOnly;

  /// The phone's wait for it is over (the companion's `expired`, CON-096):
  /// Claude Code's own dialog still asks in the terminal, so it is
  /// [terminalOnly]; a companion with `terminal-answers` types the answer
  /// there.
  final bool expired;

  /// A question Claude asked (AskUserQuestion). Claude Code ignores a plain
  /// Allow for it: it takes answers ([withAnswers]) or a Deny.
  bool get isQuestion => toolName == questionTool;

  /// A plan to approve: the user's to answer every time (no rule, no trust).
  bool get isPlan => toolName == planTool;

  /// Whether the phone can answer this question (the companion sent its
  /// questions, so it takes `decide <id> answer`).
  bool get answerable => isQuestion && questions.isNotEmpty;

  /// Whether a trust or rule may answer requests like this one (high risk
  /// always asks, and so do a question and a plan).
  bool get trustable =>
      !isQuestion &&
      !isPlan &&
      !terminalOnly &&
      risk != null &&
      risk!.level != PermissionRiskLevel.high;

  /// This request with the user's [answers], for `decide`.
  PendingPermissionRequest withAnswers(Map<String, String> answers) =>
      PendingPermissionRequest(
        id: id,
        toolName: toolName,
        summary: summary,
        toolInput: toolInput,
        createdAt: createdAt,
        risk: risk,
        batchable: batchable,
        suggestedRules: suggestedRules,
        repo: repo,
        questions: questions,
        answers: Map.unmodifiable(answers),
        terminalOnly: terminalOnly,
        expired: expired,
      );

  /// Longest tool input kept on the phone; anything beyond is truncated
  /// with a marker so a huge file write cannot bloat the dashboard.
  static const maxToolInputLength = 4000;

  @override
  bool operator ==(Object other) {
    return other is PendingPermissionRequest &&
        other.id == id &&
        other.toolName == toolName &&
        other.summary == summary &&
        other.toolInput == toolInput &&
        other.createdAt == createdAt &&
        other.risk == risk &&
        other.batchable == batchable &&
        listEquals(other.suggestedRules, suggestedRules) &&
        other.repo == repo &&
        listEquals(other.questions, questions) &&
        mapEquals(other.answers, answers) &&
        other.terminalOnly == terminalOnly &&
        other.expired == expired;
  }

  @override
  int get hashCode => Object.hash(
    id,
    toolName,
    summary,
    toolInput,
    createdAt,
    risk,
    batchable,
    Object.hashAll(suggestedRules),
    repo,
    Object.hashAll(questions),
    terminalOnly,
    expired,
  );
}

/// One remote agent as reported by a provider.
class AgentInfo {
  const AgentInfo({
    required this.id,
    required this.name,
    required this.state,
    this.kind = '',
    this.workspace,
    this.tab,
    this.pane,
    this.stateChangedAt,
    this.stateSequence,
    this.pendingRequests = const [],
    this.lastMessage,
    this.project,
    this.usage,
    this.lastAutoApprovedAt,
    this.permissionMode,
    this.lastEvent,
    this.lastToolName,
    this.lastError,
    this.workspaceLabel,
    this.herdrServer,
  });

  /// Stable identity across polls (provider-specific; e.g. pane id or a
  /// unique live agent name). Used to deduplicate notifications.
  final String id;

  /// Safe display label.
  final String name;

  final AgentAttentionState state;

  /// Provider-reported agent kind (e.g. which CLI runs in the pane).
  final String kind;

  final String? workspace;
  final String? tab;
  final String? pane;

  /// When the agent entered [state], if the provider reports it.
  final DateTime? stateChangedAt;

  /// Monotonic state-transition sequence, if the provider reports one.
  final int? stateSequence;

  /// Permission prompts waiting on a human, oldest first. Empty for
  /// providers that cannot relay them.
  final List<PendingPermissionRequest> pendingRequests;

  /// The agent's latest message, when the provider reports one (the last
  /// assistant text, a notification, or a question it asked). Capped by
  /// the provider; shown in the dashboard and notification bodies.
  final String? lastMessage;

  /// Provider-reported project label (e.g. the git repository name), when
  /// it knows one. See [projectLabel] for the fallback the inbox uses.
  final String? project;

  /// Context and rate-limit usage, when the provider reports it (the
  /// companion's optional `usage` field). Null means "not reported".
  final AgentUsage? usage;

  /// When an approval rule last answered one of this agent's requests on
  /// the host (the companion's `lastAutoApprovedAt`).
  final DateTime? lastAutoApprovedAt;

  /// Claude Code's permission mode (`default`, `plan`, `acceptEdits`,
  /// `auto`, `bypassPermissions`), when the companion recorded it from a
  /// hook event. Talkbawt never types link content into an agent that acts
  /// without asking.
  final String? permissionMode;

  /// The companion's last hook event (`Stop`, `PreToolUse`, ...), when it
  /// reports one: tells a turn that ended from a question.
  final String? lastEvent;

  /// The tool of the agent's last tool event (what it is running now while
  /// it works), when the companion reports it.
  final String? lastToolName;

  /// The API error its last turn ended on (`rate_limit`, `overloaded`), as
  /// the companion reports it until the next prompt.
  final String? lastError;

  /// The label of the agent's Herdr workspace (what Herdr and sheprd call
  /// it, CON-116), when the companion or the app's live view knows it.
  final String? workspaceLabel;

  /// The Herdr server whose workspace [workspace] is (`herdr`,
  /// `herdr@<session>`), when the provider can tell.
  final String? herdrServer;

  /// What the app calls this agent's project: its Herdr [workspaceLabel],
  /// else its [repoLabel]. The inbox groups by it.
  String? get projectLabel {
    final label = workspaceLabel?.trim();
    if (label != null && label.isNotEmpty) {
      return label;
    }
    return repoLabel;
  }

  /// The repository the agent works in: the provider's [project], else
  /// the basename of a path-like [workspace] (the companion puts the
  /// agent's cwd there). Herdr's opaque workspace ids are not projects, so
  /// those agents have none. Usage rows and layout rules match on it.
  String? get repoLabel {
    final explicit = project?.trim();
    if (explicit != null && explicit.isNotEmpty) {
      return explicit;
    }
    final raw = workspace?.trim();
    if (raw == null || !raw.contains('/')) {
      return null;
    }
    return projectFromPath(raw) ?? raw;
  }

  /// A copy with [pendingRequests] and optionally [state] replaced.
  AgentInfo copyWith({
    AgentAttentionState? state,
    List<PendingPermissionRequest>? pendingRequests,
  }) {
    return AgentInfo(
      id: id,
      name: name,
      state: state ?? this.state,
      kind: kind,
      workspace: workspace,
      tab: tab,
      pane: pane,
      stateChangedAt: stateChangedAt,
      stateSequence: stateSequence,
      pendingRequests: pendingRequests ?? this.pendingRequests,
      lastMessage: lastMessage,
      project: project,
      usage: usage,
      lastAutoApprovedAt: lastAutoApprovedAt,
      permissionMode: permissionMode,
      lastEvent: lastEvent,
      lastToolName: lastToolName,
      lastError: lastError,
      workspaceLabel: workspaceLabel,
      herdrServer: herdrServer,
    );
  }

  /// A copy named after its Herdr workspace [label] (CON-116), name
  /// included: what newer companions send, for the older ones.
  AgentInfo withWorkspaceLabel(String label) {
    return AgentInfo(
      id: id,
      name: label,
      state: state,
      kind: kind,
      workspace: workspace,
      tab: tab,
      pane: pane,
      stateChangedAt: stateChangedAt,
      stateSequence: stateSequence,
      pendingRequests: pendingRequests,
      lastMessage: lastMessage,
      project: project,
      usage: usage,
      lastAutoApprovedAt: lastAutoApprovedAt,
      permissionMode: permissionMode,
      lastEvent: lastEvent,
      lastToolName: lastToolName,
      lastError: lastError,
      workspaceLabel: label,
      herdrServer: herdrServer,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is AgentInfo &&
        other.id == id &&
        other.name == name &&
        other.state == state &&
        other.kind == kind &&
        other.workspace == workspace &&
        other.tab == tab &&
        other.pane == pane &&
        other.stateChangedAt == stateChangedAt &&
        other.stateSequence == stateSequence &&
        other.lastMessage == lastMessage &&
        other.project == project &&
        other.usage == usage &&
        other.lastAutoApprovedAt == lastAutoApprovedAt &&
        other.permissionMode == permissionMode &&
        other.lastEvent == lastEvent &&
        other.lastToolName == lastToolName &&
        other.lastError == lastError &&
        other.workspaceLabel == workspaceLabel &&
        other.herdrServer == herdrServer &&
        _sameRequests(other.pendingRequests, pendingRequests);
  }

  static bool _sameRequests(
    List<PendingPermissionRequest> a,
    List<PendingPermissionRequest> b,
  ) {
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

  @override
  int get hashCode => Object.hash(
    id,
    name,
    state,
    kind,
    workspace,
    tab,
    pane,
    stateChangedAt,
    stateSequence,
    lastMessage,
    project,
    usage,
    lastAutoApprovedAt,
    permissionMode,
    Object.hash(
      lastEvent,
      lastToolName,
      lastError,
      workspaceLabel,
      herdrServer,
    ),
    Object.hashAll(pendingRequests),
  );
}

/// How much of an agent's budget is used, as far as the provider knows.
/// Every field is optional: a provider reports what it can see (Claude
/// Code's statusline input carries all of it; hooks carry none).
class AgentUsage {
  const AgentUsage({
    this.contextUsedPct,
    this.contextTokens,
    this.windowLabel,
    this.limits = const [],
    this.reportedAt,
  });

  /// When the statusline reported this (companion 1.3.1+): an idle
  /// session's limits are as old as its last report.
  final DateTime? reportedAt;

  /// Share of the context window in use, 0 to 100.
  final double? contextUsedPct;

  /// Tokens currently in the context window.
  final int? contextTokens;

  /// Human label for the context window (e.g. `200k`, `1M`).
  final String? windowLabel;

  /// Account rate-limit windows (e.g. the 5-hour and 7-day windows).
  final List<AgentRateLimit> limits;

  bool get isEmpty =>
      contextUsedPct == null && contextTokens == null && limits.isEmpty;

  @override
  bool operator ==(Object other) {
    if (other is! AgentUsage ||
        other.contextUsedPct != contextUsedPct ||
        other.contextTokens != contextTokens ||
        other.windowLabel != windowLabel ||
        other.reportedAt != reportedAt ||
        other.limits.length != limits.length) {
      return false;
    }
    for (var i = 0; i < limits.length; i++) {
      if (other.limits[i] != limits[i]) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    contextUsedPct,
    contextTokens,
    windowLabel,
    reportedAt,
    Object.hashAll(limits),
  );
}

/// One rate-limit window (e.g. `5h` at 23.5 %, resetting at [resetsAt]).
class AgentRateLimit {
  const AgentRateLimit({
    required this.label,
    required this.usedPct,
    this.resetsAt,
  });

  final String label;

  /// 0 to 100 (a spend limit may exceed 100).
  final double usedPct;
  final DateTime? resetsAt;

  @override
  bool operator ==(Object other) =>
      other is AgentRateLimit &&
      other.label == label &&
      other.usedPct == usedPct &&
      other.resetsAt == resetsAt;

  @override
  int get hashCode => Object.hash(label, usedPct, resetsAt);
}

/// The companion capability behind Review mode and "Undo this turn": per
/// turn git snapshots and the `turns`, `diff`, `undo` and `redo` commands
/// (`host/README.md`, "Turn snapshots").
const snapshotsCapability = 'snapshots';

/// One poll's worth of agent information for a host.
class AgentAttentionSnapshot {
  const AgentAttentionSnapshot({
    required this.agents,
    this.sequence,
    this.capabilities,
    this.kinds,
  });

  final List<AgentInfo> agents;

  /// Features the provider reported (the companion's `capabilities`, e.g.
  /// `smart-approvals`); null when it reports none (older versions).
  final Set<String>? capabilities;

  /// What each agent kind supports (the companion's `adapters`); null when
  /// the provider reports none (older companions, Herdr).
  final AgentKindCatalog? kinds;

  /// Monotonic snapshot sequence, when the provider numbers its snapshots
  /// (used to resume a change stream and to drop stale results).
  final int? sequence;
}

/// One change reported by a provider's change stream.
class AgentChange {
  const AgentChange({
    required this.sequence,
    required this.agentId,
    required this.agent,
  });

  /// The provider's sequence number for this change.
  final int sequence;

  final String agentId;

  /// The agent's complete new record, or null when it was removed.
  final AgentInfo? agent;
}

/// What one long-poll returned: either a full [snapshot] (the provider
/// could not serve the changes since the requested sequence) followed by
/// any [changes], or just [changes] to apply on top of the known state.
class AgentChangeBatch {
  const AgentChangeBatch({this.snapshot, this.changes = const []});

  final AgentAttentionSnapshot? snapshot;

  /// In sequence order.
  final List<AgentChange> changes;

  bool get isEmpty => snapshot == null && changes.isEmpty;
}
