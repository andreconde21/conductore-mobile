import 'dart:convert';

import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/domain/agent_permission_actions.dart';
import 'package:flutter/foundation.dart';

/// One choice the launcher may offer for a [LauncherPrompt]: [label] as
/// shown, and the [verdict] it decides (`allow`, `always`, `deny`, or
/// [AgentPermissionAction.answerVerdict] with the label as the answer).
@immutable
class LauncherOption {
  const LauncherOption(this.label, this.verdict);

  final String label;
  final String verdict;

  Map<String, Object?> toJson() => {'label': label, 'verdict': verdict};

  @override
  bool operator ==(Object other) =>
      other is LauncherOption &&
      other.label == label &&
      other.verdict == verdict;

  @override
  int get hashCode => Object.hash(label, verdict);
}

/// What the launcher's details sheet (Yoke, CON-082) may show and answer
/// for one agent that needs the user: the question, its options, or a
/// reply box. Not lock-screen safe (it carries the agent's own text), so
/// it never goes into the widget snapshot: the native side keeps it apart
/// and serves it only through the launcher details provider.
///
/// The launcher answers through the running app: the native side hands
/// the choice back as an [AgentPermissionAction], and
/// `AgentAttentionController.completeLauncherAction` checks it against
/// the prompt the live status gives now.
@immutable
class LauncherPrompt {
  const LauncherPrompt({
    required this.hostId,
    required this.agentId,
    required this.requestId,
    required this.question,
    this.options,
    this.replyVerdict,
    this.answers = '',
    this.note,
  });

  /// Longest [question] handed to the launcher.
  static const maxQuestionLength = 600;

  /// Longest reply the launcher may send (the native side checks it too).
  static const maxReplyLength = 4000;

  /// What a launcher action on an agent that no longer waits (or waits
  /// for something else now) is told.
  static const staleError = "That agent isn't waiting any more";

  static const highRiskNote = 'High-risk request: open it in Conductore';
  static const terminalNote = 'Answer it in the terminal';
  static const openNote = 'Open it in Conductore to answer';
  static const severalQuestionsNote =
      'Several questions: answer them in Conductore';
  static const multiSelectNote =
      'A pick-several question: answer it in Conductore';

  final String hostId;
  final String agentId;

  /// The request [options] decide, or [replyRequest] for a reply.
  final String requestId;

  /// What the agent asks: the permission request, the question, or its
  /// last message; at most [maxQuestionLength]. Empty when unknown.
  final String question;

  /// The choices, in order; null when there are none (a reply box, or
  /// nothing the launcher may answer).
  final List<LauncherOption>? options;

  /// How a typed reply is sent: [AgentPermissionAction.replyVerdict]
  /// (typed into the agent) or [AgentPermissionAction.answerVerdict] (the
  /// answer to a free-text question); null when the launcher may not
  /// reply.
  final String? replyVerdict;

  /// The question an answer answers, exactly as asked; empty otherwise.
  final String answers;

  /// Why the launcher may not answer, when it may not.
  final String? note;

  /// What a reply's request id is (no request is pending).
  static const replyRequest = 'reply';

  bool get answerable => options != null || replyVerdict != null;

  /// The provider's row id for the agent (the widget line key).
  String get id => '$hostId/$agentId';

  /// The prompt of [agent] on [hostId], or null when it does not need the
  /// user (only `needsInput` and `blocked` agents have one). [canReply]:
  /// the app could type into it (a companion agent whose kind takes
  /// prompts, see `AgentAttentionController.canReplyTo`).
  ///
  /// - A permission request: Allow, Always allow (not for high risk) and
  ///   Deny, the first request when several wait. A high-risk one, or one
  ///   only the agent's own prompt answers (Gemini, Cursor), has no
  ///   options and a [note].
  /// - A question with a single question: its options when it is
  ///   single-choice, else a reply that answers it; several questions or
  ///   a pick-several one: a [note].
  /// - Nothing pending: a reply typed into the agent when [canReply].
  static LauncherPrompt? of({
    required String hostId,
    required AgentInfo agent,
    required bool canReply,
  }) {
    if (agent.state != AgentAttentionState.needsInput &&
        agent.state != AgentAttentionState.blocked) {
      return null;
    }
    final requests = agent.pendingRequests;
    final first = requests.firstOrNull;
    if (first == null) {
      return LauncherPrompt(
        hostId: hostId,
        agentId: agent.id,
        requestId: replyRequest,
        question: cap(agent.lastMessage?.trim() ?? ''),
        replyVerdict: canReply ? AgentPermissionAction.replyVerdict : null,
        note: canReply ? null : openNote,
      );
    }
    final more = requests.length > 1
        ? '\n(+${requests.length - 1} more waiting)'
        : '';
    if (first.isQuestion) {
      return _question(hostId, agent, first, more);
    }
    final risk = first.risk;
    final summary = first.summary.trim();
    final reason = risk?.reason.trim() ?? '';
    final question = cap(
      'Approve ${first.toolName}'
      '${summary.isEmpty || summary == first.toolName ? '' : ': $summary'}'
      '${risk == null ? '' : ' · ${risk.level.label}'}'
      '${reason.isEmpty ? '' : '\n$reason'}'
      '$more',
    );
    String? note;
    if (first.terminalOnly) {
      note = terminalNote;
    } else if (risk?.level == PermissionRiskLevel.high) {
      note = highRiskNote;
    }
    return LauncherPrompt(
      hostId: hostId,
      agentId: agent.id,
      requestId: first.id,
      question: question,
      options: note != null
          ? null
          : [
              LauncherOption(
                PermissionVerdict.allow.label,
                PermissionVerdict.allow.wireName,
              ),
              const LauncherOption('Always allow', 'always'),
              LauncherOption(
                PermissionVerdict.deny.label,
                PermissionVerdict.deny.wireName,
              ),
            ],
      note: note,
    );
  }

  static LauncherPrompt _question(
    String hostId,
    AgentInfo agent,
    PendingPermissionRequest request,
    String more,
  ) {
    LauncherPrompt closed(String question, String note) => LauncherPrompt(
      hostId: hostId,
      agentId: agent.id,
      requestId: request.id,
      question: cap('$question$more'),
      note: note,
    );
    final summary = request.summary.trim();
    if (request.terminalOnly) {
      return closed(summary, terminalNote);
    }
    if (!request.answerable) {
      return closed(summary, openNote);
    }
    if (request.questions.length != 1) {
      return closed(
        request.questions.map((question) => question.question).join('\n'),
        severalQuestionsNote,
      );
    }
    final asked = request.questions.single;
    if (asked.multiSelect) {
      return closed(asked.question, multiSelectNote);
    }
    final choice = asked.kind == 'choice' && asked.options.isNotEmpty;
    return LauncherPrompt(
      hostId: hostId,
      agentId: agent.id,
      requestId: request.id,
      question: cap('${asked.question}$more'),
      options: choice
          ? [
              for (final option in asked.options)
                LauncherOption(
                  option.label,
                  AgentPermissionAction.answerVerdict,
                ),
            ]
          : null,
      replyVerdict: choice ? null : AgentPermissionAction.answerVerdict,
      answers: asked.question,
    );
  }

  /// [text] cut to [maxQuestionLength] (with an ellipsis).
  static String cap(String text) => text.length > maxQuestionLength
      ? '${text.substring(0, maxQuestionLength - 1)}…'
      : text;

  Map<String, Object?> toJson() => {
    'id': id,
    'hostId': hostId,
    'agentId': agentId,
    'requestId': requestId,
    'question': question,
    'options': options?.map((option) => option.toJson()).toList(),
    'replyVerdict': replyVerdict,
    'answers': answers,
    'note': note,
  };

  /// The payload the native side stores: every prompt, as JSON.
  static String encodeAll(List<LauncherPrompt> prompts) =>
      jsonEncode([for (final prompt in prompts) prompt.toJson()]);

  @override
  bool operator ==(Object other) =>
      other is LauncherPrompt &&
      other.hostId == hostId &&
      other.agentId == agentId &&
      other.requestId == requestId &&
      other.question == question &&
      listEquals(other.options, options) &&
      other.replyVerdict == replyVerdict &&
      other.answers == answers &&
      other.note == note;

  @override
  int get hashCode => Object.hash(
    hostId,
    agentId,
    requestId,
    question,
    options == null ? null : Object.hashAll(options!),
    replyVerdict,
    answers,
    note,
  );
}
