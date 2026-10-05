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
/// it: null once done, else why it failed. With no listener (the app is
/// locked, or not on its home page yet) the platform tells the launcher
/// to open Conductore.
abstract class LauncherActionSource {
  void setListener(
    Future<String?> Function(AgentPermissionAction action)? listener,
  );
}
