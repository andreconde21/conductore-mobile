import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/voice_guide/domain/approval_actions.dart';
import 'package:flutter_test/flutter_test.dart';

import 'guide_fixtures.dart';

void main() {
  test('today: one decision at a time, nothing else', () async {
    final decided = <String>[];
    final actions = DecideApprovalActions(
      (hostId, request, verdict) async => decided.add('$hostId/${request.id}'),
    );
    await actions.decide('vtm', npmTest, PermissionVerdict.allow);
    expect(decided, ['vtm/req-npm']);
    expect(actions.riskOf('vtm', npmTest), ApprovalRisk.unknown);
    expect(actions.supportsApproveAllSafe, isFalse);
    expect(actions.supportsTrust, isFalse);
  });

  test('smart approvals never batch or trust a high-risk request', () async {
    final batched = <String>[];
    final trusted = <String>[];
    final actions = SmartApprovalActions(
      riskOf: (_, request) =>
          request.id == rmRf.id ? ApprovalRisk.high : ApprovalRisk.low,
      decide: (_, _, _) async {},
      supportedOn: (hostId) => hostId == 'vtm',
      supported: () => true,
      approveLow: (targets) async {
        batched.addAll(targets.map((t) => t.request.id));
        return targets.length;
      },
      trust: (_, request, _) async => trusted.add(request.id),
    );
    expect(
      await actions.approveAllSafe([
        (hostId: 'vtm', request: npmTest),
        (hostId: 'vtm', request: rmRf),
      ]),
      1,
    );
    expect(batched, ['req-npm']);
    expect(
      () => actions.trust('vtm', rmRf, const Duration(minutes: 5)),
      throwsUnsupportedError,
    );
    await actions.trust('vtm', npmTest, const Duration(minutes: 5));
    expect(trusted, ['req-npm']);
    // A machine without the capability: nothing batched or trusted there.
    expect(actions.canTrust('old'), isFalse);
    expect(
      await actions.approveAllSafe([(hostId: 'old', request: npmTest)]),
      0,
    );
    expect(
      () => actions.trust('old', npmTest, const Duration(minutes: 5)),
      throwsUnsupportedError,
    );
  });
}
