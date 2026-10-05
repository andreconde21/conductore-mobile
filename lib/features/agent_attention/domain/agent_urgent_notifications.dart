import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention_notifier.dart';
import 'package:conduit/features/agent_attention/domain/agent_kinds.dart';
import 'package:conduit/features/agent_attention/domain/agent_naming.dart';
import 'package:conduit/features/agent_attention/domain/agent_notifications.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/live/domain/live_host_model.dart';
import 'package:flutter/foundation.dart';

/// What an agent waiting for input is waiting for (the companion's
/// `waiting_input` covers both a question and a turn that simply ended).
enum AgentWaitKind {
  /// It asked something (a question tool, or its last line asks).
  question,

  /// Its last turn ended on an API error.
  error,

  /// Its turn ended: nothing is asked.
  turnEnded,
}

/// The urgent-only notifications of the "Ongoing + urgent" and "Urgent
/// only" modes (CON-074). Pure: the controller feeds it one agent at a
/// time, as it does [AgentNotificationPolicy] in the "Everything" mode.
///
/// Urgent is: a permission request, a question, an error, an agent the
/// dashboard flags as stuck or looping, and a finished turn only when the
/// user opted in. Each agent has at most one alert, which alerts when the
/// agent enters an urgent state (never twice for the same one) and goes
/// once nothing urgent is left.
abstract final class UrgentNotificationPolicy {
  /// Claude Code's tools that ask the user (the companion's
  /// `QUESTION_TOOLS`).
  static const questionTools = {'AskUserQuestion', 'ExitPlanMode'};

  /// Most options offered as answer buttons (Android shows three actions).
  static const maxAnswerButtons = 3;

  /// What a waiting agent waits for. A Herdr agent's "blocked" always
  /// waits on a human; a companion agent asks when it used a question tool
  /// (and its turn has not ended since) or its last line is a question,
  /// like the dashboard's `attentionOf`.
  static AgentWaitKind waitKind(AgentInfo agent, {required bool companion}) {
    if (agent.lastError != null) {
      return AgentWaitKind.error;
    }
    if (agent.state == AgentAttentionState.blocked) {
      return AgentWaitKind.error;
    }
    if (!companion) {
      return AgentWaitKind.question;
    }
    final event = agent.lastEvent;
    // A permission prompt that timed out on the phone waits in the
    // terminal.
    if (event == 'PermissionRequest') {
      return AgentWaitKind.question;
    }
    if (questionTools.contains(agent.lastToolName) &&
        event != 'Stop' &&
        event != 'SessionStart') {
      return AgentWaitKind.question;
    }
    final lines = (agent.lastMessage ?? '')
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty);
    if (lines.isNotEmpty && _asksLine.hasMatch(lines.last)) {
      return AgentWaitKind.question;
    }
    return AgentWaitKind.turnEnded;
  }

  static final _asksLine = RegExp(r'''\?[\s*_)"'`]*$''');

  /// The urgent need of [agent], or null when nothing about it is urgent
  /// (its alert, if any, goes).
  ///
  /// [stuckReason]: the dashboard's first stuck flag for the agent.
  /// [companion]: the agent comes from the Conductore companion (which
  /// reports a turn that ended as waiting). Like
  /// [AgentNotificationPolicy.needFor], questions, errors and finished
  /// turns notify when [entered] and stay while the agent stays there; on
  /// the [initial] snapshot they are carried over silently.
  static AgentNeed? needFor({
    required AgentInfo agent,
    required AgentNotice? previous,
    required bool entered,
    required AgentAttentionState? previousState,
    required bool ended,
    required bool companion,
    required AgentNotifyLevel level,
    required AgentNotificationPreferences preferences,
    String? stuckReason,
    bool initial = false,
  }) {
    if (ended) {
      return null;
    }
    bool held(AgentNeed need) => initial || entered || previous?.need == need;
    AgentNeed? need;
    if (agent.pendingRequests.isNotEmpty) {
      need = AgentNeed.approval;
    } else {
      switch (agent.state) {
        case AgentAttentionState.needsInput || AgentAttentionState.blocked:
          need = switch (waitKind(agent, companion: companion)) {
            AgentWaitKind.question =>
              held(AgentNeed.question) ? AgentNeed.question : null,
            AgentWaitKind.error =>
              held(AgentNeed.error) ? AgentNeed.error : null,
            // Still waiting after a request or question went away without
            // the turn ending (it timed out here): the terminal asks now.
            AgentWaitKind.turnEnded
                when (previous?.need == AgentNeed.approval ||
                        previous?.need == AgentNeed.question) &&
                    agent.lastEvent != 'Stop' &&
                    agent.lastEvent != 'StopFailure' =>
              AgentNeed.question,
            AgentWaitKind.turnEnded => _finished(
              previous: previous,
              entered: entered,
              previousState: previousState,
              initial: initial,
            ),
          };
        case AgentAttentionState.idle || AgentAttentionState.finished:
          need = _finished(
            previous: previous,
            entered: entered,
            previousState: previousState,
            initial: initial,
          );
        case AgentAttentionState.working || AgentAttentionState.unknown:
          break;
      }
    }
    // A finished turn that is not alerted still yields to a stuck flag
    // (the dashboard's "stopped on an API error" included).
    if ((need == null ||
            (need == AgentNeed.finished && !preferences.notifies(need))) &&
        (stuckReason?.trim().isNotEmpty ?? false)) {
      need = AgentNeed.stuck;
    }
    if (need == null || !preferences.notifies(need)) {
      return null;
    }
    final allowed = need == AgentNeed.finished
        ? level.notifiesFinished
        : level.notifiesApprovalsAndErrors;
    return allowed ? need : null;
  }

  static AgentNeed? _finished({
    required AgentNotice? previous,
    required bool entered,
    required AgentAttentionState? previousState,
    required bool initial,
  }) {
    final wasBusy =
        previousState == AgentAttentionState.working ||
        (previousState?.needsAttention ?? false) ||
        (previous?.need.needsYou ?? false);
    if (initial ||
        previous?.need == AgentNeed.finished ||
        (entered && wasBusy)) {
      return AgentNeed.finished;
    }
    return null;
  }

  /// Whether posting [need] (listing [requestIds]) alerts: a new urgent
  /// state does, a switch to another urgent state does (an approval that
  /// became a question in the terminal is the same ask), the same state
  /// never does, unless the agent [entered] it again (answered, then asked
  /// again between two polls) or a new request arrives after every earlier
  /// one was answered (with [quietUpdates] off: any new request). A stuck
  /// flag alerts once until it clears. On the [initial] snapshot only
  /// approvals alert.
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
      // A request that timed out into the terminal is the same ask.
      return !(_asks(previous.need) && _asks(need));
    }
    switch (need) {
      case AgentNeed.approval:
        final added = requestIds.difference(previous.requestIds);
        if (added.isEmpty) {
          return false;
        }
        if (!requestIds.any(previous.requestIds.contains)) {
          return true;
        }
        return !quietUpdates;
      case AgentNeed.stuck:
        return false;
      case AgentNeed.question || AgentNeed.error || AgentNeed.finished:
        return entered;
    }
  }

  static bool _asks(AgentNeed need) =>
      need == AgentNeed.approval || need == AgentNeed.question;

  /// [agent]'s urgent alert for [need], with its actions:
  /// - an approval: Allow and Deny, plus Open (Review all for several);
  ///   a high-risk one, or one only the agent's own prompt answers, only
  ///   Open;
  /// - a single-choice question with up to [maxAnswerButtons] options:
  ///   one button per option (the body opens the agent); any other
  ///   question: Open;
  /// - a question, error, stuck agent or finished turn: Reply (typed into
  ///   the agent) when [canReply], and Open.
  /// [AgentNotificationPreferences.summaryOnly] leaves only Open.
  static AgentNotification build({
    required String hostId,
    required String hostName,
    required AgentInfo agent,
    required AgentNeed need,
    required bool alert,
    required AgentNotificationPreferences preferences,
    required AgentOpenTarget open,
    required bool canReply,
    String? detail,
    String? stuckReason,
  }) {
    final base = AgentNotificationPolicy.build(
      hostId: hostId,
      hostName: hostName,
      agent: agent,
      need: need,
      alert: alert,
      // The actions are decided below.
      preferences: preferences.copyWith(summaryOnly: true),
      open: open,
      detail: need == AgentNeed.stuck ? stuckReason : detail,
    );
    final buttons = !preferences.summaryOnly;
    final first = need == AgentNeed.approval
        ? agent.pendingRequests.firstOrNull
        : null;
    var text = base.text;
    var lines = base.lines;
    if (need == AgentNeed.stuck && stuckReason != null) {
      text = stuckReason.trim();
      lines = [text, ...base.lines.where((line) => line != text)];
    }
    AgentNotificationAction? action;
    var answers = const <String>[];
    var question = '';
    var reply = false;
    if (first != null) {
      final choice = singleChoice(first);
      if (first.terminalOnly) {
        // Only the agent's own prompt answers it (Gemini CLI): Open.
      } else if (first.isQuestion) {
        if (choice != null && buttons) {
          action = AgentNotificationAction(
            requestId: first.id,
            allowAlways: false,
          );
          question = choice.question;
          answers = [for (final option in choice.options) option.label];
        }
      } else if (first.risk?.level != PermissionRiskLevel.high && buttons) {
        action = AgentNotificationAction(
          requestId: first.id,
          allowAlways: false,
        );
      }
    } else {
      reply = buttons && canReply;
    }
    // Allow and Deny for one of several: the third button reviews them all.
    final reviewAll =
        action != null && answers.isEmpty && agent.pendingRequests.length > 1;
    return AgentNotification(
      hostId: hostId,
      agentId: agent.id,
      need: need,
      title: base.title,
      text: text,
      lines: lines,
      publicTitle: base.publicTitle,
      alert: alert,
      alertKey: base.alertKey,
      action: action,
      reviewAll: reviewAll,
      open: open,
      answers: answers,
      question: question,
      reply: reply,
      // Answer buttons take every slot; the body still opens the agent.
      openButton: answers.isEmpty && !reviewAll,
    );
  }

  /// The one question of [request] when it can be answered with a button:
  /// a single, single-choice question with 1 to [maxAnswerButtons]
  /// options.
  static PendingQuestion? singleChoice(PendingPermissionRequest request) {
    if (!request.answerable ||
        request.terminalOnly ||
        request.questions.length != 1) {
      return null;
    }
    final question = request.questions.single;
    if (question.kind != 'choice' ||
        question.multiSelect ||
        question.options.isEmpty ||
        question.options.length > maxAnswerButtons) {
      return null;
    }
    return question;
  }
}

/// The ongoing status notification: one silent notification that lists
/// every agent compactly and is updated in place.
///
/// [title] and [publicTitle] are lock-screen safe (counts only); [lines]
/// carry project names, tools and message lines, which the platform hides
/// on a secure lock screen.
@immutable
class AgentOngoingStatus {
  const AgentOngoingStatus({
    required this.title,
    required this.text,
    required this.lines,
    required this.publicTitle,
    this.needsYou = 0,
  });

  /// "2 working · 1 needs you".
  final String title;

  /// The collapsed line: the most urgent agent's line.
  final String text;

  /// One line per agent, most urgent first.
  final List<String> lines;

  /// "Conductore: 3 agents".
  final String publicTitle;

  /// How many agents need the user.
  final int needsYou;

  Map<String, Object?> toArguments() => {
    'title': title,
    'text': text,
    'lines': lines,
    'publicTitle': publicTitle,
    'needsYou': needsYou,
  };

  @override
  bool operator ==(Object other) =>
      other is AgentOngoingStatus &&
      other.title == title &&
      other.text == text &&
      listEquals(other.lines, lines) &&
      other.publicTitle == publicTitle &&
      other.needsYou == needsYou;

  @override
  int get hashCode =>
      Object.hash(title, text, Object.hashAll(lines), publicTitle, needsYou);

  @override
  String toString() => 'AgentOngoingStatus($title, $lines)';
}

/// One agent as the ongoing status lists it.
typedef AgentStatusEntry = ({
  /// The machine's saved host id: one Conductore session per Herdr
  /// workspace or tmux session each monitor the same machine, so the same
  /// agent comes once per session and is counted once per machine.
  String machineId,

  /// The machine's name, shown only when agents of several machines are
  /// listed.
  String hostName,
  AgentInfo agent,
  bool companion,

  /// The dashboard's summary or headline, if any.
  String? detail,

  /// The dashboard's first stuck flag, if any.
  String? stuck,
});

/// Builds the ongoing status notification. Pure.
abstract final class AgentStatusSummary {
  /// Lines in the expanded notification: agents, then "+N more".
  static const maxLines = 6;

  /// Agents listed before "+N more".
  static const maxAgents = 5;

  /// Longest progress text on a line.
  static const maxProgressLength = 60;

  /// How long an idle agent (its turn ended, or finished) stays listed
  /// after its last change.
  static const idleWindow = Duration(minutes: 30);

  /// The status of [entries]; null when no agent is left, so the
  /// notification goes. One line per live agent: the same agent seen by
  /// several sessions of a machine, or by Herdr next to its hook (same
  /// pane), counts once, the hook-reported one winning; agents idle for
  /// longer than [idleWindow] at [now] are left out.
  static AgentOngoingStatus? build(
    List<AgentStatusEntry> entries, {
    DateTime? now,
  }) {
    final rows = <_Row>[];
    final byKey = <String, int>{};
    for (final entry in entries) {
      final row = _Row(entry, _describe(entry));
      if (row.rank == _idle && _stale(entry.agent, now)) continue;
      final agent = entry.agent;
      final keys = [
        '${entry.machineId}/id/${agent.id}',
        if (agent.pane case final pane? when pane.isNotEmpty)
          '${entry.machineId}/pane/$pane',
      ];
      final at = keys.map((key) => byKey[key]).nonNulls.firstOrNull;
      if (at == null) {
        for (final key in keys) {
          byKey[key] = rows.length;
        }
        rows.add(row);
      } else {
        if (_better(row, rows[at])) rows[at] = row;
        for (final key in keys) {
          byKey[key] = at;
        }
      }
    }
    if (rows.isEmpty) {
      return null;
    }
    final machines = {for (final row in rows) row.entry.machineId};
    // Stable within a rank: the provider's order (newest first).
    final ordered = [
      for (var rank = _needsYou; rank <= _idle; rank++)
        for (final row in rows)
          if (row.rank == rank) _line(row, withMachine: machines.length > 1),
    ];
    int count(int rank) => rows.where((row) => row.rank == rank).length;
    final needsYou = count(_needsYou);
    final working = count(_working);
    final idle = count(_idle);
    final total = rows.length;
    final parts = [
      if (needsYou > 0) '$needsYou ${needsYou == 1 ? 'needs' : 'need'} you',
      if (working > 0) '$working working',
      if (idle > 0) '$idle idle',
    ];
    final lines = ordered.length > maxLines
        ? [...ordered.take(maxAgents), '+${ordered.length - maxAgents} more']
        : ordered;
    return AgentOngoingStatus(
      title: parts.join(' · '),
      text: ordered.first,
      lines: lines,
      publicTitle: 'Conductore: $total ${total == 1 ? 'agent' : 'agents'}',
      needsYou: needsYou,
    );
  }

  static const _needsYou = 0;
  static const _working = 1;
  static const _idle = 2;

  static bool _stale(AgentInfo agent, DateTime? now) {
    final at = agent.stateChangedAt;
    return now != null && at != null && now.difference(at) > idleWindow;
  }

  /// Which of two sightings of one agent to keep: the hook-reported one
  /// over Herdr's, then the more urgent, then the newer.
  static bool _better(_Row candidate, _Row kept) {
    final hook = !isHerdrOnlyAgent(candidate.entry.agent);
    final keptHook = !isHerdrOnlyAgent(kept.entry.agent);
    if (hook != keptHook) return hook;
    if (candidate.rank != kept.rank) return candidate.rank < kept.rank;
    final at = candidate.entry.agent.stateChangedAt;
    final keptAt = kept.entry.agent.stateChangedAt;
    return at != null && (keptAt == null || at.isAfter(keptAt));
  }

  /// "lf-seguros-web · Working · Fixing the login (dev-central)".
  static String _line(_Row row, {required bool withMachine}) {
    final progress = row.progress;
    final tail = progress == null || progress.isEmpty
        ? ''
        : ' · ${_cap(progress)}';
    final where = withMachine ? ' (${row.entry.hostName})' : '';
    return '${_name(row.entry.agent)} · ${row.label}$tail$where';
  }

  /// "api (Codex)" / "api".
  static String _name(AgentInfo agent) {
    final kind = otherAgentKindName(agent.kind);
    final label = AgentNotificationPolicy.agentLabel(agent);
    return kind == null ? label : '$label ($kind)';
  }

  /// Rank (needs you, working or idle), state label and progress text. A
  /// stuck flag shows in the line ("Stuck · `npm test` failed 3 times")
  /// and counts under the agent's state.
  static (int, String, String?) _describe(AgentStatusEntry entry) {
    final agent = entry.agent;
    final message = _firstLine(agent.lastMessage);
    final first = agent.pendingRequests.firstOrNull;
    if (first != null) {
      return (_needsYou, 'Needs you', AgentNotificationPolicy.itemLine(first));
    }
    final stuck = entry.stuck?.trim();
    final isStuck = stuck != null && stuck.isNotEmpty;
    final topic = agentTopic(summary: entry.detail, lastMessage: message);
    switch (agent.state) {
      case AgentAttentionState.needsInput || AgentAttentionState.blocked:
        switch (UrgentNotificationPolicy.waitKind(
          agent,
          companion: entry.companion,
        )) {
          case AgentWaitKind.question:
            return (_needsYou, 'Asks', message);
          case AgentWaitKind.error:
            final error = agent.lastError;
            return (
              _needsYou,
              'Error',
              error == null ? message : error.replaceAll('_', ' '),
            );
          case AgentWaitKind.turnEnded:
            return isStuck ? (_idle, 'Stuck', stuck) : (_idle, 'Idle', topic);
        }
      case AgentAttentionState.working:
        if (isStuck) return (_working, 'Stuck', stuck);
        final tool = agent.lastToolName?.trim();
        return (
          _working,
          'Working',
          topic ?? (tool != null && tool.isNotEmpty ? tool : null),
        );
      case AgentAttentionState.idle ||
          AgentAttentionState.finished ||
          AgentAttentionState.unknown:
        return isStuck ? (_idle, 'Stuck', stuck) : (_idle, 'Idle', topic);
    }
  }

  static String? _firstLine(String? message) {
    for (final line in (message ?? '').split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isNotEmpty) return trimmed;
    }
    return null;
  }

  static String _cap(String text) {
    final line = text.replaceAll('\n', ' ').trim();
    return line.length > maxProgressLength
        ? '${line.substring(0, maxProgressLength)}…'
        : line;
  }
}

class _Row {
  _Row(this.entry, (int, String, String?) described)
    : rank = described.$1,
      label = described.$2,
      progress = described.$3;

  final AgentStatusEntry entry;
  final int rank;
  final String label;
  final String? progress;
}

/// When the ongoing status may be posted: at most once per [interval],
/// the latest version winning, and an unchanged one again after
/// [refreshEvery] (the platform drops a status nobody refreshed, so a
/// killed app leaves no stale one behind). Pure: the caller keeps time.
class AgentStatusThrottle {
  AgentStatusThrottle({
    this.interval = const Duration(seconds: 5),
    this.refreshEvery = const Duration(minutes: 10),
  });

  final Duration interval;
  final Duration refreshEvery;

  AgentOngoingStatus? _sent;
  bool _hasSent = false;
  DateTime? _sentAt;

  /// What to do with [status] at [now]: post it now, wait (and ask again
  /// after the returned delay), or nothing (already posted).
  ({bool post, Duration? retryAfter}) offer(
    AgentOngoingStatus? status,
    DateTime now,
  ) {
    final at = _sentAt;
    final same = _hasSent && status == _sent;
    if (same &&
        (status == null || at == null || now.difference(at) < refreshEvery)) {
      return (post: false, retryAfter: null);
    }
    if (at != null && !same) {
      final wait = interval - now.difference(at);
      // Clearing the status is never held back.
      if (wait > Duration.zero && status != null) {
        return (post: false, retryAfter: wait);
      }
    }
    return (post: true, retryAfter: null);
  }

  /// Records that [status] was posted at [now].
  void posted(AgentOngoingStatus? status, DateTime now) {
    _sent = status;
    _hasSent = true;
    _sentAt = now;
  }

  /// Forgets what was posted: the next offer posts.
  void reset() {
    _hasSent = false;
    _sent = null;
    _sentAt = null;
  }
}
