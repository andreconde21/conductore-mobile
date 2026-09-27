// ignore_for_file: prefer_initializing_formals

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

  /// Whether [approveAllSafe] works on some machine.
  bool get supportsApproveAllSafe;

  /// Whether [hostId]'s requests can be approved in a batch.
  bool canBatch(String hostId) => supportsApproveAllSafe;

  /// Approves [targets], every one of them labelled low risk by [riskOf]
  /// (the guide never passes a high-risk one). Returns how many were
  /// approved.
  Future<int> approveAllSafe(List<ApprovalTarget> targets);

  /// Whether [trust] works on some machine.
  bool get supportsTrust;

  /// Whether [trust] works for [hostId]'s requests.
  bool canTrust(String hostId) => supportsTrust;

  /// Approves [request] on [hostId] and lets requests like it through
  /// without asking for [duration] (the companion saves a rule from it).
  /// Refused for high-risk requests.
  Future<void> trust(
    String hostId,
    PendingPermissionRequest request,
    Duration duration,
  );
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
  Future<void> trust(
    String hostId,
    PendingPermissionRequest request,
    Duration duration,
  ) => throw UnsupportedError('Trust is not available yet.');
}

/// Smart approvals: risk labels, approve all low-risk and time-boxed
/// trust, through the companion's `approve-low` and `trust` (capability
/// `smart-approvals`). Built from callbacks so the domain stays free of
/// the attention controller; the app wires it in
/// `attentionApprovalActions`. Machines whose companion lacks the
/// capability ([supportedOn] false) still answer one request at a time,
/// and the guide says approve all safe and trust are not available there.
class SmartApprovalActions extends ApprovalActions {
  const SmartApprovalActions({
    required ApprovalRisk Function(
      String hostId,
      PendingPermissionRequest request,
    )
    riskOf,
    required Future<void> Function(
      String hostId,
      PendingPermissionRequest request,
      PermissionVerdict verdict,
    )
    decide,
    required bool Function(String hostId) supportedOn,
    required bool Function() supported,
    required Future<int> Function(List<ApprovalTarget> targets) approveLow,
    required Future<void> Function(
      String hostId,
      PendingPermissionRequest request,
      Duration duration,
    )
    trust,
  }) : _riskOf = riskOf,
       _decide = decide,
       _supportedOn = supportedOn,
       _supported = supported,
       _approveLow = approveLow,
       _trust = trust;

  final ApprovalRisk Function(String, PendingPermissionRequest) _riskOf;
  final Future<void> Function(
    String,
    PendingPermissionRequest,
    PermissionVerdict,
  )
  _decide;
  final bool Function(String) _supportedOn;
  final bool Function() _supported;
  final Future<int> Function(List<ApprovalTarget>) _approveLow;
  final Future<void> Function(String, PendingPermissionRequest, Duration)
  _trust;

  @override
  ApprovalRisk riskOf(String hostId, PendingPermissionRequest request) =>
      _riskOf(hostId, request);

  @override
  Future<void> decide(
    String hostId,
    PendingPermissionRequest request,
    PermissionVerdict verdict,
  ) => _decide(hostId, request, verdict);

  @override
  bool get supportsApproveAllSafe => _supported();

  @override
  bool canBatch(String hostId) => _supportedOn(hostId);

  @override
  Future<int> approveAllSafe(List<ApprovalTarget> targets) => _approveLow([
    // Never a high-risk one, nor one on a machine without the capability,
    // whatever the caller passed.
    for (final t in targets)
      if (_supportedOn(t.hostId) &&
          _riskOf(t.hostId, t.request) == ApprovalRisk.low)
        t,
  ]);

  @override
  bool get supportsTrust => _supported();

  @override
  bool canTrust(String hostId) => _supportedOn(hostId);

  @override
  Future<void> trust(
    String hostId,
    PendingPermissionRequest request,
    Duration duration,
  ) {
    if (!_supportedOn(hostId)) {
      throw UnsupportedError('Trust is not available on that machine.');
    }
    if (_riskOf(hostId, request) == ApprovalRisk.high) {
      throw UnsupportedError('High-risk requests cannot be trusted.');
    }
    return _trust(hostId, request, duration);
  }
}
