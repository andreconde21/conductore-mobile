import 'package:conduit/features/agent_attention/domain/agent_notifications.dart';

/// Where tapping a notification's body takes the app: one agent on one
/// host, with its Herdr location when the provider reports it.
class AgentOpenTarget {
  const AgentOpenTarget({
    required this.hostId,
    this.agentId = '',
    this.workspaceId = '',
    this.tabId = '',
    this.paneId = '',
  });

  final String hostId;
  final String agentId;
  final String workspaceId;
  final String tabId;
  final String paneId;

  /// Channel arguments (`openHostId`, ...) for the platform notifier.
  Map<String, String> toArguments() => {
    'openHostId': hostId,
    'openAgentId': agentId,
    'openWorkspaceId': workspaceId,
    'openTabId': tabId,
    'openPaneId': paneId,
  };

  /// Reads the map the platform hands back after a tap; null without a
  /// host.
  static AgentOpenTarget? fromMap(Object? map) {
    if (map is! Map) {
      return null;
    }
    String field(String key) {
      final value = map[key];
      return value is String ? value : '';
    }

    final hostId = field('hostId');
    if (hostId.isEmpty) {
      return null;
    }
    return AgentOpenTarget(
      hostId: hostId,
      agentId: field('agentId'),
      workspaceId: field('workspaceId'),
      tabId: field('tabId'),
      paneId: field('paneId'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AgentOpenTarget &&
      other.hostId == hostId &&
      other.agentId == agentId &&
      other.workspaceId == workspaceId &&
      other.tabId == tabId &&
      other.paneId == paneId;

  @override
  int get hashCode => Object.hash(hostId, agentId, workspaceId, tabId, paneId);

  @override
  String toString() =>
      'AgentOpenTarget($hostId, $workspaceId, $tabId, $paneId)';
}

/// Posts local notifications: one per agent ([showAgents]) and plain ones
/// (the usage alert).
///
/// Titles must be lock-screen safe (agent labels, host names). Bodies may
/// carry the agent's last message and one-line summaries of pending
/// permission requests, so the platform shows only a public version on a
/// secure lock screen; never pass terminal output or full tool inputs.
abstract class AgentAttentionNotifier {
  /// Shows (or replaces, for the same [id]) one plain notification.
  /// Tapping it opens the app at [open] when given.
  Future<void> show({
    required String id,
    required String title,
    required String body,
    AgentOpenTarget? open,
  });

  /// Removes the plain notification with [id], if it is still showing.
  Future<void> cancel({required String id});

  /// Makes [notifications] the agent notifications of [hostId]: each
  /// agent's one notification is posted or updated in place, and the
  /// host's other agent notifications are removed. The platform keeps
  /// every agent notification in one group with a summary ("3 agents need
  /// you"). An action tap reports the notification's first request back
  /// through the app's permission action source.
  Future<void> showAgents({
    required String hostId,
    required List<AgentNotification> notifications,
  });

  /// Posts or updates one agent's notification, leaving the others be.
  Future<void> showAgent(AgentNotification notification);

  /// Removes the agent notification [key] ([agentNotificationKey]).
  Future<void> cancelAgent({required String key});
}

/// Delivers notification taps that should open an agent.
abstract class AgentOpenRequestSource {
  /// Takes the pending tap, if any.
  Future<AgentOpenTarget?> consume();

  /// Called when a tap arrives while the app runs; the listener then calls
  /// [consume].
  void setListener(void Function()? listener);
}
