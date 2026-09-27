import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agents_digest/domain/agents_digest.dart';
import 'package:conduit/features/home_widget/domain/agent_status_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 9, 27, 14);

  AgentInfo agent(
    String id,
    AgentAttentionState state, {
    List<PendingPermissionRequest> pending = const [],
  }) => AgentInfo(
    id: id,
    name: id,
    state: state,
    workspace: 'w-$id',
    tab: 't-$id',
    pane: 'p-$id',
    pendingRequests: pending,
  );

  DigestAgent digested(
    String sessionId, {
    String hostId = 'box',
    String state = 'waiting_input',
    List<DigestStuckFlag> stuck = const [],
    DateTime? lastActivityAt,
  }) => DigestAgent(
    hostId: hostId,
    hostName: 'Box',
    sessionId: sessionId,
    name: sessionId,
    state: state,
    stuck: stuck,
    lastActivityAt: lastActivityAt ?? now.subtract(const Duration(minutes: 5)),
  );

  final monitored = [
    (
      hostId: 'box',
      hostName: 'Box',
      agents: [
        agent('web', AgentAttentionState.working),
        agent('ops', AgentAttentionState.blocked),
        agent(
          'api',
          AgentAttentionState.needsInput,
          pending: [
            const PendingPermissionRequest(
              id: 'r1',
              toolName: 'Bash',
              summary: 'npm publish',
            ),
          ],
        ),
        agent('cli', AgentAttentionState.working),
        agent('doc', AgentAttentionState.idle),
      ],
    ),
  ];

  test('without the digest: needs you and working from the monitor, stuck '
      'and done unknown', () {
    final dashboard = AgentStatusDashboard.derive(hosts: monitored);
    expect(dashboard.needsYou, 2);
    expect(dashboard.working, 2);
    expect(dashboard.stuck, isNull);
    expect(dashboard.done, isNull);
    expect(dashboard.factsAt, isNull);
    // Waiting for an answer before blocked; each line knows its agent.
    expect(dashboard.lines.map((line) => (line.name, line.reason)), [
      ('api', 'approve Bash'),
      ('ops', 'blocked'),
    ]);
    final api = dashboard.lines.first;
    expect(api.kind, AgentStatusLineKind.needsYou);
    expect(api.host, 'Box');
    expect((api.hostId, api.agentId), ('box', 'api'));
    expect((api.workspace, api.tab, api.pane), ('w-api', 't-api', 'p-api'));
  });

  test('with a cached digest: stuck and done, no agent counted twice', () {
    final since = now.subtract(const Duration(hours: 1));
    final overview = DigestOverview([
      // Stuck and still working: stuck, not working.
      digested(
        'web',
        state: 'working',
        stuck: const [DigestStuckFlag('tests', '`npm test` failed 3 times')],
      ),
      // Stuck per the digest but needing you now: needs you only.
      digested(
        'api',
        stuck: const [DigestStuckFlag('loop', 'same edit 4 times')],
      ),
      // Done since the last check; quiet counts as done too.
      digested('doc'),
      digested('old', lastActivityAt: now.subtract(const Duration(hours: 3))),
      // Done per the digest, but the monitor sees it working again.
      digested('cli'),
    ], since: since);
    final factsAt = now.subtract(const Duration(minutes: 2));
    final dashboard = AgentStatusDashboard.derive(
      hosts: monitored,
      digest: overview,
      factsAt: factsAt,
    );
    expect(dashboard.needsYou, 2);
    expect(dashboard.stuck, 1);
    expect(dashboard.working, 1);
    expect(dashboard.done, 2);
    expect(dashboard.factsAt, factsAt);
    expect(dashboard.lines.map((line) => (line.kind, line.name, line.reason)), [
      (AgentStatusLineKind.needsYou, 'api', 'approve Bash'),
      (AgentStatusLineKind.needsYou, 'ops', 'blocked'),
      (AgentStatusLineKind.stuck, 'web', 'npm test failed 3 times'),
    ]);
    // The stuck line opens the agent where the monitor sees it.
    expect(dashboard.lines.last.workspace, 'w-web');
  });

  test('at most three lines, needing you first', () {
    final dashboard = AgentStatusDashboard.derive(
      hosts: [
        (
          hostId: 'box',
          hostName: 'Box',
          agents: [
            for (var i = 0; i < 5; i++)
              agent('a$i', AgentAttentionState.needsInput),
          ],
        ),
      ],
      digest: DigestOverview([
        digested('s', stuck: const [DigestStuckFlag('r', 'looping')]),
      ], since: now),
    );
    expect(dashboard.needsYou, 5);
    expect(dashboard.stuck, 1);
    expect(dashboard.lines, hasLength(AgentStatusDashboard.maxLines));
    expect(
      dashboard.lines.every((l) => l.kind == AgentStatusLineKind.needsYou),
      isTrue,
    );
  });

  test('a monitored session host matches its machine in the digest', () {
    final dashboard = AgentStatusDashboard.derive(
      hosts: [
        (
          hostId: 'box#tmux:main',
          hostName: 'Box',
          agents: [agent('web', AgentAttentionState.working)],
        ),
      ],
      digest: DigestOverview([
        digested(
          'web',
          state: 'working',
          stuck: const [DigestStuckFlag('r', 'looping')],
        ),
      ], since: now),
    );
    expect(dashboard.stuck, 1);
    expect(dashboard.working, 0);
  });
}
