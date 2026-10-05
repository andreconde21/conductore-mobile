import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';

/// Thrown when a provider's tooling is missing or too old on the host —
/// a terminal condition for monitoring (until the session reconnects),
/// unlike transient fetch errors.
class AgentProviderUnavailable implements Exception {
  const AgentProviderUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Reads agent state from one remote agent/session manager.
///
/// Implementations must use the manager's machine-readable interface, parse
/// defensively (older versions, partial output), and never scrape terminal
/// contents. The optional capabilities (availability probe, change stream,
/// permission decisions) default to "not supported" so a plain polling
/// provider only needs [fetchAgents] and [focusCommand].
abstract class AgentAttentionProvider {
  const AgentAttentionProvider();

  /// Stable identifier, e.g. `herdr`.
  String get id;

  /// Human-readable name shown in UI, e.g. `Herdr`.
  String get label;

  Future<AgentAttentionSnapshot> fetchAgents(AgentCommandRunner runner);

  /// Command that focuses [agent] in the remote manager's UI, or null when
  /// the provider has no such command.
  String? focusCommand(AgentInfo agent);

  /// Cheap check whether this provider's tooling exists on the host, used
  /// to pick a provider automatically. Must not throw for "not installed".
  Future<bool> isAvailable(AgentCommandRunner runner) async => true;

  /// Whether [watchAgents] blocks until something changes instead of
  /// returning immediately.
  bool get supportsWatch => false;

  /// Waits for the changes after sequence [since] (a long-poll on the
  /// host) and returns them, or null when nothing changed before the
  /// provider's own timeout. The caller applies the batch to the state it
  /// holds, skipping changes it has already seen.
  Future<AgentChangeBatch?> watchAgents(
    AgentCommandRunner runner, {
    required int? since,
  }) async => null;

  /// Command that answers [request] with [verdict], or null when the
  /// provider cannot relay permission decisions. With [sessionId], the
  /// companion refuses it unless the request is that agent's.
  String? decideCommand(
    PendingPermissionRequest request,
    PermissionVerdict verdict, {
    String? sessionId,
  }) => null;
}
