import 'package:flutter/foundation.dart';

/// The agent kind of companion records without one (older companions,
/// hooks registered before agent adapters): Claude Code.
const defaultAgentKind = 'claude';

/// What one agent kind supports, as the companion reports it per kind
/// (`status` → `adapters.<kind>`, host/lib/adapters/types.js). The UI
/// hides what a kind lacks instead of offering an action that cannot work.
@immutable
class AgentKindCapabilities {
  const AgentKindCapabilities({
    required this.kind,
    this.label,
    this.approvals = 'none',
    this.always = false,
    this.questions = false,
    this.plans = false,
    this.chat,
    this.send,
    this.interrupt,
    this.liveUsage = false,
    this.limits = false,
    this.history = false,
    this.brain = false,
    this.accounts,
    this.setup = const [],
    this.launch,
  });

  /// Claude Code as companions before agent adapters behaved: everything
  /// the app offers today.
  static const claudeCode = AgentKindCapabilities(
    kind: defaultAgentKind,
    label: 'Claude Code',
    approvals: 'hook',
    always: true,
    questions: true,
    plans: true,
    chat: 'entries',
    send: 'pane',
    interrupt: 'pane',
    liveUsage: true,
    limits: true,
    history: true,
    brain: true,
    accounts: 'cswap',
  );

  /// One `adapters` entry; unknown or malformed fields keep their
  /// conservative defaults (the feature stays hidden).
  factory AgentKindCapabilities.fromJson(
    String kind,
    Map<Object?, Object?> raw,
  ) {
    String? text(Object? value) =>
        value is String && value.isNotEmpty ? value : null;
    bool flag(Object? value) => value == true;
    return AgentKindCapabilities(
      kind: kind,
      label: text(raw['label']),
      approvals: text(raw['approvals']) ?? 'none',
      always: flag(raw['always']),
      questions: flag(raw['questions']),
      plans: flag(raw['plans']),
      chat: text(raw['chat']),
      send: text(raw['send']),
      interrupt: text(raw['interrupt']),
      liveUsage: flag(raw['liveUsage']),
      limits: flag(raw['limits']),
      history: flag(raw['history']),
      brain: flag(raw['brain']),
      accounts: text(raw['accounts']),
      setup: [
        if (raw['setup'] case final List<Object?> steps)
          for (final step in steps)
            if (step is String && step.isNotEmpty) step,
      ],
      launch: switch (text(raw['launch'])) {
        final String command when launchCommandPattern.hasMatch(command) =>
          command,
        _ => null,
      },
    );
  }

  /// What a [launch] command may be: one plain word, typed into a pane.
  static final launchCommandPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$');

  final String kind;

  /// The agent's name for people (`Claude Code`, `Codex`), when reported.
  final String? label;

  /// How permission prompts reach the phone: `hook` and `server` can be
  /// answered here, `observe` only watched, `none` not seen.
  final String approvals;

  /// A native "always allow" (else Always becomes a Conductore rule).
  final bool always;
  final bool questions;
  final bool plans;

  /// The transcript format `transcript` returns (`entries`: Claude Code's
  /// own, `items`: the neutral one), or null without a chat view.
  final String? chat;

  /// How a prompt or an interrupt reaches the agent (`pane`, `server`), or
  /// null when it cannot.
  final String? send;
  final String? interrupt;
  final bool liveUsage;
  final bool limits;
  final bool history;
  final bool brain;

  /// `cswap` (switchable accounts), `show` (the active one only) or null.
  final String? accounts;

  /// Manual steps the user must take once (e.g. `trust-hooks`).
  final List<String> setup;

  /// The command that starts this agent in a terminal, when the companion
  /// reports one (else [knownAgentKinds] has it).
  final String? launch;

  /// Whether the phone can answer this kind's permission prompts.
  bool get answersApprovals => approvals == 'hook' || approvals == 'server';

  @override
  bool operator ==(Object other) =>
      other is AgentKindCapabilities &&
      other.kind == kind &&
      other.label == label &&
      other.approvals == approvals &&
      other.always == always &&
      other.questions == questions &&
      other.plans == plans &&
      other.chat == chat &&
      other.send == send &&
      other.interrupt == interrupt &&
      other.liveUsage == liveUsage &&
      other.limits == limits &&
      other.history == history &&
      other.brain == brain &&
      other.accounts == accounts &&
      listEquals(other.setup, setup) &&
      other.launch == launch;

  @override
  int get hashCode => Object.hash(
    kind,
    label,
    approvals,
    always,
    questions,
    plans,
    chat,
    send,
    interrupt,
    liveUsage,
    limits,
    history,
    brain,
    accounts,
    Object.hashAll(setup),
    launch,
  );
}

/// Every agent kind one companion reported, with the fallbacks for kinds
/// it did not: without a report (an older companion) Claude Code keeps
/// everything it has today and any other kind gets nothing.
@immutable
class AgentKindCatalog {
  const AgentKindCatalog(this.kinds);

  /// What a companion without `adapters` implies.
  static const legacy = AgentKindCatalog({});

  /// Parses `status` → `adapters`; null when it is missing or malformed.
  static AgentKindCatalog? fromJson(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    return AgentKindCatalog({
      for (final entry in raw.entries)
        if (entry.key case final String kind when kind.isNotEmpty)
          if (entry.value case final Map<Object?, Object?> value)
            kind: AgentKindCapabilities.fromJson(kind, value),
    });
  }

  final Map<String, AgentKindCapabilities> kinds;

  /// What [kind] supports (an empty kind is Claude Code).
  AgentKindCapabilities of(String kind) {
    final key = normalizeAgentKind(kind);
    return kinds[key] ??
        (key == defaultAgentKind
            ? AgentKindCapabilities.claudeCode
            : AgentKindCapabilities(kind: key));
  }

  @override
  bool operator ==(Object other) =>
      other is AgentKindCatalog && mapEquals(other.kinds, kinds);

  @override
  int get hashCode => Object.hashAllUnordered(
    kinds.entries.map((entry) => Object.hash(entry.key, entry.value)),
  );
}

/// The registry id of a reported kind: lower case, Herdr's `claude-code`
/// style names folded onto `claude`, empty as Claude Code.
String normalizeAgentKind(String kind) {
  final key = kind.trim().toLowerCase();
  if (key.isEmpty || key.startsWith('claude')) return defaultAgentKind;
  return key;
}

/// An agent kind the app knows by name: its label for people and the
/// command that starts it in a terminal.
@immutable
class KnownAgentKind {
  const KnownAgentKind(this.kind, this.label, this.command);

  final String kind;
  final String label;
  final String command;
}

/// The agents the app can name and start without a companion telling it
/// (an older companion, or none). A companion's `adapters` map adds to and
/// overrides this ([agentLaunchCandidates]).
const knownAgentKinds = [
  KnownAgentKind(defaultAgentKind, 'Claude Code', 'claude'),
  KnownAgentKind('codex', 'Codex', 'codex'),
  KnownAgentKind('opencode', 'OpenCode', 'opencode'),
  KnownAgentKind('gemini', 'Gemini CLI', 'gemini'),
  KnownAgentKind('cursor', 'Cursor', 'cursor-agent'),
];

/// The name people know [kind] by (`Claude Code`, `Codex`): what the
/// companion reported in [catalog], else [knownAgentKinds], else the id.
String agentKindLabel(String kind, [AgentKindCatalog? catalog]) {
  final key = normalizeAgentKind(kind);
  final reported = catalog?.kinds[key]?.label;
  if (reported != null) return reported;
  for (final known in knownAgentKinds) {
    if (known.kind == key) return known.label;
  }
  return key;
}

/// A person's name for an agent kind other than Claude Code (`Codex`), for
/// texts that must say which agent it is; null for Claude Code.
String? otherAgentKindName(String kind) {
  final key = normalizeAgentKind(kind);
  if (key == defaultAgentKind) return null;
  return agentKindLabel(key);
}

/// The agents a new workspace could start on a machine whose companion
/// reported [catalog]: every [knownAgentKinds] entry (with the reported
/// label and command when there is one) and every other reported kind
/// that names its [AgentKindCapabilities.launch] command. Whether each is
/// installed there is a separate check (its command on PATH).
List<KnownAgentKind> agentLaunchCandidates([AgentKindCatalog? catalog]) {
  final reported = catalog?.kinds ?? const <String, AgentKindCapabilities>{};
  return [
    for (final known in knownAgentKinds)
      KnownAgentKind(
        known.kind,
        reported[known.kind]?.label ?? known.label,
        reported[known.kind]?.launch ?? known.command,
      ),
    for (final entry in reported.entries)
      if (entry.value.launch case final String command
          when !knownAgentKinds.any((known) => known.kind == entry.key))
        KnownAgentKind(entry.key, entry.value.label ?? entry.key, command),
  ];
}

/// Transcript formats the Chat View renders: Claude Code's `entries`, and
/// `items` (the neutral format, `NeutralChatItems`, paged by the
/// companion's opaque cursor: `NeutralChatWindow`).
const renderableChatFormats = {'entries', 'items'};
