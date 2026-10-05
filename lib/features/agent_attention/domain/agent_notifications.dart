import 'dart:convert';

import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention_notifier.dart';
import 'package:conduit/features/agent_attention/domain/agent_kinds.dart';
import 'package:conduit/features/agent_attention/domain/agent_naming.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// What an agent's one notification is about.
enum AgentNeed {
  /// Permission requests wait for Allow / Deny.
  approval,

  /// The agent asked something and waits in the terminal.
  question,

  /// The agent stopped on something other than a question.
  error,

  /// The agents dashboard flags it: no progress, the same failure again
  /// and again, or a command it keeps repeating.
  stuck,

  /// The agent's turn ended.
  finished;

  /// Whether the agent waits on a human (everything but [finished]).
  bool get needsYou => this != AgentNeed.finished;

  /// The end of the title, after "api · VTM".
  String get verb => switch (this) {
    AgentNeed.approval => 'needs you',
    AgentNeed.question => 'is waiting for you',
    AgentNeed.error => 'hit an error',
    AgentNeed.stuck => 'looks stuck',
    AgentNeed.finished => 'finished',
  };
}

/// What this device notifies about agents (Settings › Agents ›
/// Notifications).
enum AgentNotificationMode {
  /// One ongoing, silent notification listing every agent, plus alerts for
  /// urgent things only (the default).
  ongoingAndUrgent('Ongoing + urgent'),

  /// One notification per agent for every need, finished turns included
  /// (the behaviour before CON-074).
  everything('Everything'),

  /// Alerts for urgent things only, no ongoing notification.
  urgentOnly('Urgent only');

  const AgentNotificationMode(this.label);

  final String label;

  /// Whether only urgent needs notify (finished turns only when opted in).
  bool get urgentOnlyAlerts => this != AgentNotificationMode.everything;

  /// Whether the ongoing status notification shows.
  bool get showsOngoing => this == AgentNotificationMode.ongoingAndUrgent;

  static AgentNotificationMode parse(Object? raw) =>
      AgentNotificationMode.values.firstWhere(
        (mode) => mode.name == raw,
        orElse: () => AgentNotificationMode.ongoingAndUrgent,
      );
}

/// The key a mute is kept under: the agent on its machine (any session of
/// the machine).
String agentMuteKey(String hostId, String agentId) =>
    '${baseHostId(hostId)}/$agentId';

/// Settings › Agents › Notifications, on this device only (never synced:
/// the phone may notify while the desktop stays quiet). Each machine's
/// [AgentNotifyLevel] still applies on top.
@immutable
class AgentNotificationPreferences {
  const AgentNotificationPreferences({
    this.approvals = true,
    this.questions = true,
    this.finished = true,
    this.errors = true,
    this.summaryOnly = false,
    this.quietUpdates = true,
    this.mode = AgentNotificationMode.ongoingAndUrgent,
    this.stuck = true,
    this.finishedAlerts = false,
    this.mutedAgents = const {},
  });

  /// Most mutes kept; the oldest go first (agents are sessions, which end).
  static const maxMutedAgents = 200;

  final bool approvals;
  final bool questions;

  /// "Notify when an agent finishes": a turn that ended.
  final bool finished;
  final bool errors;

  /// No Allow / Deny buttons: the notification only says what is pending.
  final bool summaryOnly;

  /// Another request for an agent that already needs you updates its
  /// notification silently; off, every new request alerts.
  final bool quietUpdates;

  final AgentNotificationMode mode;

  /// Alerts for agents the dashboard flags as stuck or looping (the urgent
  /// modes).
  final bool stuck;

  /// "Also alert when an agent finishes" in the urgent modes, where a
  /// finished turn otherwise only updates the ongoing notification.
  final bool finishedAlerts;

  /// Agents that never notify on this device ([agentMuteKey]).
  final Set<String> mutedAgents;

  bool isMuted(String hostId, String agentId) =>
      mutedAgents.contains(agentMuteKey(hostId, agentId));

  /// These preferences with [hostId]'s [agentId] muted or not.
  AgentNotificationPreferences withMuted(
    String hostId,
    String agentId, {
    required bool muted,
  }) {
    final key = agentMuteKey(hostId, agentId);
    final next = [
      for (final existing in mutedAgents)
        if (existing != key) existing,
      if (muted) key,
    ];
    final kept = next.length > maxMutedAgents
        ? next.sublist(next.length - maxMutedAgents)
        : next;
    return copyWith(mutedAgents: {...kept});
  }

  /// Whether [need] notifies at all.
  bool notifies(AgentNeed need) => switch (need) {
    AgentNeed.approval => approvals,
    AgentNeed.question => questions,
    AgentNeed.error => errors,
    AgentNeed.stuck => stuck && mode.urgentOnlyAlerts,
    AgentNeed.finished => mode.urgentOnlyAlerts ? finishedAlerts : finished,
  };

  AgentNotificationPreferences copyWith({
    bool? approvals,
    bool? questions,
    bool? finished,
    bool? errors,
    bool? summaryOnly,
    bool? quietUpdates,
    AgentNotificationMode? mode,
    bool? stuck,
    bool? finishedAlerts,
    Set<String>? mutedAgents,
  }) => AgentNotificationPreferences(
    approvals: approvals ?? this.approvals,
    questions: questions ?? this.questions,
    finished: finished ?? this.finished,
    errors: errors ?? this.errors,
    summaryOnly: summaryOnly ?? this.summaryOnly,
    quietUpdates: quietUpdates ?? this.quietUpdates,
    mode: mode ?? this.mode,
    stuck: stuck ?? this.stuck,
    finishedAlerts: finishedAlerts ?? this.finishedAlerts,
    mutedAgents: mutedAgents ?? this.mutedAgents,
  );

  Map<String, Object?> toJson() => {
    'approvals': approvals,
    'questions': questions,
    'finished': finished,
    'errors': errors,
    'summaryOnly': summaryOnly,
    'quietUpdates': quietUpdates,
    'mode': mode.name,
    'stuck': stuck,
    'finishedAlerts': finishedAlerts,
    'mutedAgents': [...mutedAgents],
  };

  static AgentNotificationPreferences fromJson(Object? json) {
    if (json is! Map) {
      return const AgentNotificationPreferences();
    }
    bool flag(String key, bool fallback) {
      final value = json[key];
      return value is bool ? value : fallback;
    }

    return AgentNotificationPreferences(
      approvals: flag('approvals', true),
      questions: flag('questions', true),
      finished: flag('finished', true),
      errors: flag('errors', true),
      summaryOnly: flag('summaryOnly', false),
      quietUpdates: flag('quietUpdates', true),
      mode: AgentNotificationMode.parse(json['mode']),
      stuck: flag('stuck', true),
      finishedAlerts: flag('finishedAlerts', false),
      mutedAgents: {
        if (json['mutedAgents'] case final List<Object?> muted)
          for (final key in muted)
            if (key is String && key.isNotEmpty) key,
      },
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AgentNotificationPreferences &&
      other.approvals == approvals &&
      other.questions == questions &&
      other.finished == finished &&
      other.errors == errors &&
      other.summaryOnly == summaryOnly &&
      other.quietUpdates == quietUpdates &&
      other.mode == mode &&
      other.stuck == stuck &&
      other.finishedAlerts == finishedAlerts &&
      setEquals(other.mutedAgents, mutedAgents);

  @override
  int get hashCode => Object.hash(
    approvals,
    questions,
    finished,
    errors,
    summaryOnly,
    quietUpdates,
    mode,
    stuck,
    finishedAlerts,
    Object.hashAllUnordered(mutedAgents),
  );
}

abstract class AgentNotificationPreferencesStore {
  Future<AgentNotificationPreferences> load();
  Future<void> save(AgentNotificationPreferences preferences);
}

/// In secure storage under its own key, outside every sync record.
class SecureAgentNotificationPreferencesStore
    implements AgentNotificationPreferencesStore {
  const SecureAgentNotificationPreferencesStore(this._storage);

  static const storageKey = 'agent_notification_preferences_v1';

  final FlutterSecureStorage _storage;

  @override
  Future<AgentNotificationPreferences> load() async {
    try {
      final raw = await _storage.read(key: storageKey);
      if (raw == null || raw.isEmpty) {
        return const AgentNotificationPreferences();
      }
      return AgentNotificationPreferences.fromJson(jsonDecode(raw));
    } on Object {
      return const AgentNotificationPreferences();
    }
  }

  @override
  Future<void> save(AgentNotificationPreferences preferences) =>
      _storage.write(key: storageKey, value: jsonEncode(preferences.toJson()));
}

/// For tests and platforms without secure storage.
class MemoryAgentNotificationPreferencesStore
    implements AgentNotificationPreferencesStore {
  MemoryAgentNotificationPreferencesStore([
    this.value = const AgentNotificationPreferences(),
  ]);

  AgentNotificationPreferences value;

  @override
  Future<AgentNotificationPreferences> load() async => value;

  @override
  Future<void> save(AgentNotificationPreferences preferences) async =>
      value = preferences;
}

/// The buttons of an agent's notification: they answer [requestId], the
/// first (most urgent) pending item.
@immutable
class AgentNotificationAction {
  const AgentNotificationAction({
    required this.requestId,
    required this.allowAlways,
  });

  final String requestId;

  /// Offer "Always" (not for a high-risk request, which always asks).
  final bool allowAlways;

  @override
  bool operator ==(Object other) =>
      other is AgentNotificationAction &&
      other.requestId == requestId &&
      other.allowAlways == allowAlways;

  @override
  int get hashCode => Object.hash(requestId, allowAlways);
}

/// The one notification of one agent: a summary of what it needs now.
///
/// [title] and [publicTitle] must stay lock-screen safe (agent label, host
/// name); [text] and [lines] may carry request summaries and the agent's
/// message, which the platform hides on a secure lock screen.
@immutable
class AgentNotification {
  const AgentNotification({
    required this.hostId,
    required this.agentId,
    required this.need,
    required this.title,
    required this.text,
    required this.publicTitle,
    this.lines = const [],
    this.alert = false,
    this.alertKey = '',
    this.action,
    this.reviewAll = false,
    this.open,
    this.answers = const [],
    this.question = '',
    this.reply = false,
    this.openButton = false,
  });

  final String hostId;
  final String agentId;
  final AgentNeed need;

  /// "api · VTM needs you".
  final String title;

  /// The most urgent item, then "+2 more".
  final String text;

  /// The expanded view: up to five items, then the dashboard's line.
  final List<String> lines;

  /// The lock screen's version: "Conductore: api needs you".
  final String publicTitle;

  /// Sound and vibration: the agent newly needs you.
  final bool alert;

  /// Names the need that [alert] is for, so the platform never alerts
  /// twice for the same one (an app restart re-posts it).
  final String alertKey;

  /// Allow / Deny (/ Always) for the first item; null for none.
  final AgentNotificationAction? action;

  /// A "Review all" button that opens the agent (several items pending).
  final bool reviewAll;

  /// Where tapping the body goes.
  final AgentOpenTarget? open;

  /// Answer buttons for [action]'s request, a single-choice question: the
  /// option labels, each answering [question].
  final List<String> answers;
  final String question;

  /// A "Reply" button with an inline text field: the text is typed into
  /// the agent.
  final bool reply;

  /// An "Open" button (a high-risk request, or next to Reply), which opens
  /// the agent like the body.
  final bool openButton;

  String get key => agentNotificationKey(hostId, agentId);

  AgentNotification copyWith({bool? alert}) => AgentNotification(
    hostId: hostId,
    agentId: agentId,
    need: need,
    title: title,
    text: text,
    publicTitle: publicTitle,
    lines: lines,
    alert: alert ?? this.alert,
    alertKey: alertKey,
    action: action,
    reviewAll: reviewAll,
    open: open,
    answers: answers,
    question: question,
    reply: reply,
    openButton: openButton,
  );

  /// Channel arguments for the platform notifier.
  Map<String, Object?> toArguments() => {
    'hostId': hostId,
    'agentId': agentId,
    'needsYou': need.needsYou,
    'title': title,
    'text': text,
    'lines': lines,
    'publicTitle': publicTitle,
    'alert': alert,
    'alertKey': alertKey,
    if (action case final action?) ...{
      'requestId': action.requestId,
      'allowAlways': action.allowAlways,
    },
    'reviewAll': reviewAll,
    'answers': answers,
    'question': question,
    'reply': reply,
    'openButton': openButton,
    ...?open?.toArguments(),
  };

  @override
  bool operator ==(Object other) =>
      other is AgentNotification &&
      other.hostId == hostId &&
      other.agentId == agentId &&
      other.need == need &&
      other.title == title &&
      other.text == text &&
      other.publicTitle == publicTitle &&
      listEquals(other.lines, lines) &&
      other.alert == alert &&
      other.alertKey == alertKey &&
      other.action == action &&
      other.reviewAll == reviewAll &&
      other.open == open &&
      listEquals(other.answers, answers) &&
      other.question == question &&
      other.reply == reply &&
      other.openButton == openButton;

  @override
  int get hashCode => Object.hash(
    hostId,
    agentId,
    need,
    title,
    text,
    publicTitle,
    Object.hashAll(lines),
    alert,
    alertKey,
    action,
    reviewAll,
    open,
    Object.hash(Object.hashAll(answers), question, reply, openButton),
  );

  @override
  String toString() => 'AgentNotification($key, $title, $text, alert: $alert)';
}

/// The platform's id for [agentId]'s notification on [hostId] (the
/// Android side derives the same string from the same two ids).
String agentNotificationKey(String hostId, String agentId) =>
    'agent:$hostId:$agentId';

/// What was last notified for one agent, kept between polls.
@immutable
class AgentNotice {
  const AgentNotice({required this.need, this.requestIds = const {}});

  final AgentNeed need;

  /// The pending requests it listed (approvals only).
  final Set<String> requestIds;
}

/// Decides what an agent's notification says and when it alerts. Pure:
/// the controller feeds it one agent at a time.
abstract final class AgentNotificationPolicy {
  /// Items listed in the expanded notification.
  static const maxLines = 5;

  /// Longest request summary or message line in a notification.
  static const maxItemLength = 120;

  /// What [agent] needs now, or null when its notification should go.
  ///
  /// [entered]: the agent reached its state since the last snapshot (not
  /// on the first snapshot after monitoring starts, which is [initial]).
  /// [previousState] is its state in that snapshot. [ended]: the session
  /// is over. Approvals notify whenever they are pending; questions and
  /// errors when entered (or when they follow an approval that timed out);
  /// a finished turn when the agent was busy before. On the [initial]
  /// snapshot every need is carried over, silently (see [shouldAlert]):
  /// the platform only updates a notification an earlier run left
  /// showing.
  static AgentNeed? needFor({
    required AgentInfo agent,
    required AgentNotice? previous,
    required bool entered,
    required AgentAttentionState? previousState,
    required bool ended,
    bool initial = false,
    required AgentNotifyLevel level,
    required AgentNotificationPreferences preferences,
  }) {
    if (ended) {
      return null;
    }
    AgentNeed? need;
    if (agent.pendingRequests.isNotEmpty) {
      need = AgentNeed.approval;
    } else {
      switch (agent.state) {
        case AgentAttentionState.needsInput || AgentAttentionState.blocked:
          final waiting = agent.state == AgentAttentionState.needsInput
              ? AgentNeed.question
              : AgentNeed.error;
          if (initial || entered || (previous?.need.needsYou ?? false)) {
            need = waiting;
          }
        case AgentAttentionState.idle || AgentAttentionState.finished:
          final wasBusy =
              previousState == AgentAttentionState.working ||
              (previousState?.needsAttention ?? false) ||
              (previous?.need.needsYou ?? false);
          if (initial ||
              previous?.need == AgentNeed.finished ||
              (entered && wasBusy)) {
            need = AgentNeed.finished;
          }
        case AgentAttentionState.working || AgentAttentionState.unknown:
          break;
      }
    }
    if (need == null || !preferences.notifies(need)) {
      return null;
    }
    final allowed = need == AgentNeed.finished
        ? level.notifiesFinished
        : level.notifiesApprovalsAndErrors;
    return allowed ? need : null;
  }

  /// Whether posting [need] (listing [requestIds]) should alert.
  ///
  /// A new notification alerts, and so does a switch between waiting and
  /// finished. Within "needs you" updates are silent, except a new request
  /// after every earlier one was answered, a state [entered] again (the
  /// agent was answered and asked again between two polls), or with
  /// [quietUpdates] off any new request. On the [initial] snapshot only
  /// approvals alert (the platform stays silent when the same ones still
  /// show).
  static bool shouldAlert({
    required AgentNotice? previous,
    required AgentNeed need,
    required Set<String> requestIds,
    required bool entered,
    required bool quietUpdates,
    bool initial = false,
  }) {
    if (previous == null) {
      return !initial || need == AgentNeed.approval;
    }
    if (previous.need != need) {
      return previous.need.needsYou != need.needsYou;
    }
    if (need != AgentNeed.approval) {
      return entered;
    }
    final added = requestIds.difference(previous.requestIds);
    if (added.isEmpty) {
      return false;
    }
    if (!requestIds.any(previous.requestIds.contains)) {
      return true;
    }
    return !quietUpdates;
  }

  /// The agent's notification for [need].
  ///
  /// [detail] is the agents dashboard's cached headline or summary for
  /// the agent, when there is one.
  static AgentNotification build({
    required String hostId,
    required String hostName,
    required AgentInfo agent,
    required AgentNeed need,
    required bool alert,
    required AgentNotificationPreferences preferences,
    required AgentOpenTarget open,
    String? detail,
  }) {
    // Which agent, when it is not Claude Code: "api (Codex)".
    final kindName = otherAgentKindName(agent.kind);
    final label = kindName == null
        ? agentLabel(agent)
        : '${agentLabel(agent)} ($kindName)';
    final requests = need == AgentNeed.approval
        ? agent.pendingRequests
        : const <PendingPermissionRequest>[];
    final message = _firstLine(agent.lastMessage);
    final extra = _cap(detail?.trim() ?? '');
    final String text;
    final items = <String>[];
    if (requests.isNotEmpty) {
      final more = requests.length - 1;
      text = '${itemLine(requests.first)}${more > 0 ? ' · +$more more' : ''}';
      for (final (index, request) in requests.take(maxLines).indexed) {
        items.add(itemLine(request));
        // The buttons answer the first one: say why it is risky.
        final reason = request.risk?.reason ?? '';
        if (index == 0 && reason.isNotEmpty) {
          items.add('  ${_cap(reason)}');
        }
      }
      if (requests.length > maxLines) {
        items.add('+${requests.length - maxLines} more');
      }
    } else {
      text = switch (need) {
        AgentNeed.question => message ?? 'Waiting for your answer',
        AgentNeed.error => message ?? 'Stopped. Open it to see why',
        AgentNeed.stuck => message ?? 'Open it to see what it is doing',
        AgentNeed.finished =>
          (extra.isEmpty ? null : extra) ?? message ?? 'Turn finished',
        AgentNeed.approval => 'Waiting for approval',
      };
      items.add(text);
    }
    if (extra.isNotEmpty && !items.contains(extra)) {
      items.add(extra);
    }
    final first = requests.firstOrNull;
    // A question has no Allow: its answer needs the app (the card's
    // options), so a tap opens it instead.
    // One the agent's own prompt answers (Gemini CLI) has none either.
    final actionable =
        first != null &&
        !first.isQuestion &&
        !first.terminalOnly &&
        !preferences.summaryOnly;
    return AgentNotification(
      hostId: hostId,
      agentId: agent.id,
      need: need,
      title: '$label · $hostName ${need.verb}',
      text: text,
      lines: items,
      publicTitle: 'Conductore: $label ${need.verb}',
      alert: alert,
      alertKey: alertKey(agent, need),
      action: actionable
          ? AgentNotificationAction(
              requestId: first.id,
              allowAlways: first.risk?.level != PermissionRiskLevel.high,
            )
          : null,
      reviewAll: actionable && requests.length > 1,
      open: open,
    );
  }

  /// "Approve Bash: npm test -- due-date · High risk"; a question:
  /// "Question: Which database?".
  static String itemLine(PendingPermissionRequest request) {
    final summary = _cap(request.summary.trim());
    if (request.isQuestion) {
      return 'Question${summary.isEmpty ? '' : ': $summary'}';
    }
    final risk = request.risk?.level.label;
    if (request.terminalOnly) {
      return 'Approve ${request.toolName} in the terminal'
          '${summary.isEmpty ? '' : ': $summary'}'
          '${risk == null ? '' : ' · $risk'}';
    }
    return 'Approve ${request.toolName}'
        '${summary.isEmpty ? '' : ': $summary'}'
        '${risk == null ? '' : ' · $risk'}';
  }

  /// The agent's project (else its name): "api".
  static String agentLabel(AgentInfo agent) =>
      agentDisplayName(project: agent.projectLabel, name: agent.name);

  /// Names one need: the pending request ids for approvals, else the
  /// state's sequence when the provider numbers them.
  static String alertKey(AgentInfo agent, AgentNeed need) {
    if (need == AgentNeed.approval) {
      final ids = [for (final request in agent.pendingRequests) request.id]
        ..sort();
      return 'approval:${ids.join(',')}';
    }
    return '${need.name}:${agent.stateSequence ?? ''}';
  }

  static String? _firstLine(String? message) {
    final line = message
        ?.split('\n')
        .map((line) => line.trim())
        .firstWhere((line) => line.isNotEmpty, orElse: () => '');
    if (line == null || line.isEmpty) {
      return null;
    }
    return _cap(line);
  }

  static String _cap(String text) => text.length > maxItemLength
      ? '${text.substring(0, maxItemLength)}…'
      : text;
}
