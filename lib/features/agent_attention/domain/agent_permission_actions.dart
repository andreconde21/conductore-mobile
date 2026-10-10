import 'package:flutter/foundation.dart';

/// One action tap on an agent notification, as relayed by the platform:
/// Allow / Deny / Always on a permission request, an answer button of a
/// question ([answerVerdict]), or a Reply typed into the agent
/// ([replyVerdict]).
class AgentPermissionAction {
  const AgentPermissionAction({
    required this.notificationId,
    required this.hostId,
    required this.requestId,
    required this.verdict,
    this.agentId = '',
    this.text = '',
    this.question = '',
  });

  /// An answer button: [text] answers [question].
  static const answerVerdict = 'answer';

  /// The inline Reply: [text] is typed into the agent.
  static const replyVerdict = 'reply';

  final String notificationId;
  final String hostId;
  final String requestId;

  /// The agent whose notification carried the button; empty for a tap
  /// queued by an older build.
  final String agentId;

  /// `allow`, `deny`, `always`, [answerVerdict] or [replyVerdict] as the
  /// platform stored it.
  final String verdict;

  /// The picked option's label, or the reply's text.
  final String text;

  /// The question an answer button answers (exactly as asked).
  final String question;

  @override
  bool operator ==(Object other) {
    return other is AgentPermissionAction &&
        other.notificationId == notificationId &&
        other.hostId == hostId &&
        other.requestId == requestId &&
        other.agentId == agentId &&
        other.verdict == verdict &&
        other.text == text &&
        other.question == question;
  }

  @override
  int get hashCode => Object.hash(
    notificationId,
    hostId,
    requestId,
    agentId,
    verdict,
    text,
    question,
  );
}

/// Where notification action taps arrive from.
///
/// The platform queues every tap durably (so one made while the app was
/// dead is delivered after the next start) and, while the app runs, also
/// pings the listener so the queue is drained right away.
abstract class AgentPermissionActionSource {
  /// Takes every queued tap, clearing the queue.
  Future<List<AgentPermissionAction>> consumeActions();

  /// Called when a new tap was queued while the app is running; the
  /// listener returns whether it will drain the queue now (false while
  /// nothing can, e.g. the app is locked, so the platform can say so).
  void setListener(bool Function()? listener);
}

/// Where answers from the launcher's details sheet (Yoke, CON-082)
/// arrive from. The platform only hands one over while the app runs and
/// waits (a few seconds) for the outcome, so the listener answers with
/// it: null once done, else why it failed.
///
/// Contract 3 (CON-119): while the app lock is up, or the app is not
/// running (or not on its home page yet), the platform holds the answer
/// instead, encrypted, for [QueuedLauncherAnswer.expiry]; the app takes
/// the held ones with [consumeQueued] after the next unlock.
abstract class LauncherActionSource {
  void setListener(
    Future<String?> Function(AgentPermissionAction action)? listener,
  );

  /// Takes every held answer (expired ones too), clearing them.
  Future<List<QueuedLauncherAnswer>> consumeQueued();

  /// Called when an answer was held while the app runs (it may have been
  /// unlocked meanwhile).
  void setQueuedListener(void Function()? listener);
}

/// An answer from the launcher held while Conductore could not send it
/// (contract 3, CON-119): [action] as the launcher made it, [title] and
/// [host] naming the agent, [since] when the agent entered the state it
/// was answered in (null unknown), [queuedAt] when it was held.
@immutable
class QueuedLauncherAnswer {
  const QueuedLauncherAnswer({
    required this.action,
    required this.queuedAt,
    this.title = '',
    this.host = '',
    this.since,
  });

  /// How long an answer waits for the unlock: the companion's permission
  /// wait. The platform drops older ones too.
  static const expiry = Duration(minutes: 15);

  /// Why an expired answer was not sent.
  static const expiredError = 'it waited more than 15 minutes';

  final AgentPermissionAction action;
  final String title;
  final String host;
  final DateTime? since;
  final DateTime queuedAt;

  bool expiredAt(DateTime now) => !now.isBefore(queuedAt.add(expiry));

  /// The agent as the in-app message names it.
  String get label => switch ((title, host)) {
    ('', _) => 'an agent',
    (final title, '') => title,
    (final title, final host) => '$title on $host',
  };

  /// What the platform hands over; null for anything unreadable.
  static QueuedLauncherAnswer? fromMap(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    String text(String key) => raw[key] is String ? raw[key] as String : '';
    DateTime? time(String key) => raw[key] is int && raw[key] as int > 0
        ? DateTime.fromMillisecondsSinceEpoch(raw[key] as int)
        : null;
    final queuedAt = time('queuedAt');
    if (text('hostId').isEmpty ||
        text('agentId').isEmpty ||
        text('verdict').isEmpty ||
        queuedAt == null) {
      return null;
    }
    return QueuedLauncherAnswer(
      action: AgentPermissionAction(
        notificationId: '',
        hostId: text('hostId'),
        agentId: text('agentId'),
        requestId: text('requestId'),
        verdict: text('verdict'),
        text: text('text'),
      ),
      title: text('title'),
      host: text('host'),
      since: time('since'),
      queuedAt: queuedAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is QueuedLauncherAnswer &&
      other.action == action &&
      other.title == title &&
      other.host == host &&
      other.since == since &&
      other.queuedAt == queuedAt;

  @override
  int get hashCode => Object.hash(action, title, host, since, queuedAt);
}
