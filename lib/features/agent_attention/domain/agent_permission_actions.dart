/// One Allow / Deny / Always tap on a permission notification, as relayed
/// by the platform.
class AgentPermissionAction {
  const AgentPermissionAction({
    required this.notificationId,
    required this.hostId,
    required this.requestId,
    required this.verdict,
    this.agentId = '',
  });

  final String notificationId;
  final String hostId;
  final String requestId;

  /// The agent whose notification carried the button; empty for a tap
  /// queued by an older build.
  final String agentId;

  /// `allow`, `deny` or `always` as the platform stored it.
  final String verdict;

  @override
  bool operator ==(Object other) {
    return other is AgentPermissionAction &&
        other.notificationId == notificationId &&
        other.hostId == hostId &&
        other.requestId == requestId &&
        other.agentId == agentId &&
        other.verdict == verdict;
  }

  @override
  int get hashCode =>
      Object.hash(notificationId, hostId, requestId, agentId, verdict);
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
