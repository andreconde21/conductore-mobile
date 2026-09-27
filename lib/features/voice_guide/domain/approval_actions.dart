import 'package:conduit/features/agent_attention/domain/agent_attention.dart';

/// How risky approving a request is. Today's companion does not label
/// requests ([unknown]); smart approvals (feat/smart-approvals) will.
enum ApprovalRisk { low, medium, high, unknown }

/// One pending request on one machine.
typedef ApprovalTarget = ({String hostId, PendingPermissionRequest request});

/// What the voice guide may do with permission requests. The guide codes
/// against this seam; [DecideApprovalActions] is today's implementation
/// (allow or deny one request through the companion's `decide`). Smart
/// approvals plug in by implementing [riskOf], [approveAllSafe] and
/// [trust]; until then the guide says those are not available yet.
abstract class ApprovalActions {
  const ApprovalActions();

  ApprovalRisk riskOf(String hostId, PendingPermissionRequest request);

  /// Answers one request. Throws when the machine refused or the request
  /// is gone (answered elsewhere, timed out).
  Future<void> decide(
    String hostId,
    PendingPermissionRequest request,
    PermissionVerdict verdict,
  );

  /// Whether [approveAllSafe] works.
  bool get supportsApproveAllSafe;

  /// Approves [targets], every one of them labelled low risk by [riskOf]
  /// (the guide never passes a high-risk one). Returns how many were
  /// approved.
  Future<int> approveAllSafe(List<ApprovalTarget> targets);

  /// Whether [trust] works.
  bool get supportsTrust;

  /// Lets [agentId] on [hostId] run without asking for [duration].
  Future<void> trust(String hostId, String agentId, Duration duration);
}

/// Today's approvals: one allow or deny at a time, no risk labels, no
/// batch approval and no time-boxed trust.
class DecideApprovalActions extends ApprovalActions {
  const DecideApprovalActions(this._decide);

  final Future<void> Function(
    String hostId,
    PendingPermissionRequest request,
    PermissionVerdict verdict,
  )
  _decide;

  @override
  ApprovalRisk riskOf(String hostId, PendingPermissionRequest request) =>
      ApprovalRisk.unknown;

  @override
  Future<void> decide(
    String hostId,
    PendingPermissionRequest request,
    PermissionVerdict verdict,
  ) => _decide(hostId, request, verdict);

  @override
  bool get supportsApproveAllSafe => false;

  @override
  Future<int> approveAllSafe(List<ApprovalTarget> targets) =>
      throw UnsupportedError('Approve all safe is not available yet.');

  @override
  bool get supportsTrust => false;

  @override
  Future<void> trust(String hostId, String agentId, Duration duration) =>
      throw UnsupportedError('Trust is not available yet.');
}
