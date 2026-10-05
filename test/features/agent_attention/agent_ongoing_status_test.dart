import 'dart:convert';

import 'package:conduit/features/agent_attention/data/conductore_host_attention_provider.dart';
import 'package:conduit/features/agent_attention/data/herdr_attention_provider.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/agent_attention/domain/agent_naming.dart';
import 'package:conduit/features/agent_attention/domain/agent_notifications.dart';
import 'package:conduit/features/agent_attention/domain/agent_urgent_notifications.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

/// CON-079: the ongoing notification read "8 active sessions · 6 stuck ·
/// 116 done · 4 idle", five lines "agent-a205b124f4354e391 @ development…"
/// and "+121 more" while dev-central ran 16 agents (14 waiting, 2 working).
/// Every Herdr workspace opened in the app is its own session host
/// (`<hostId>#herdr:wN`) with its own monitor, so 8 sessions listed the
/// same 16 agents 8 times.

final _now = DateTime.utc(2026, 10, 5, 8, 14);

int _ms(Duration ago) => _now.subtract(ago).millisecondsSinceEpoch;

Map<String, Object?> _agent(
  String id,
  String cwd,
  String pane, {
  String state = 'waiting_input',
  String? name,
  Duration ago = const Duration(minutes: 5),
  String? lastMessage = 'Claude is waiting for your input',
  String lastEvent = 'Notification',
}) => {
  'kind': 'claude',
  'sessionId': id,
  'name': name ?? cwd.split('/').last,
  'cwd': cwd,
  'tmux': null,
  'herdr': {'workspaceId': pane.split(':').first, 'paneId': pane},
  'state': state,
  'lastEvent': lastEvent,
  'lastToolName': 'Bash',
  'lastMessage': lastMessage,
  'updatedAt': _ms(ago),
  'endedAt': null,
  'pending': <Object>[],
};

/// The companion's `status` on dev-central, 2026-10-05 09:14 (Lisbon).
final _devCentral = jsonEncode({
  'version': 1,
  'seq': 218507,
  'agents': [
    _agent(
      'a03b1740',
      '/root/Projects/Conductore-Mobile',
      'wX:p1',
      state: 'working',
      lastEvent: 'PreToolUse',
      lastMessage: 'Logged it as CON-079.',
      ago: const Duration(seconds: 10),
    ),
    _agent(
      'a04b9572',
      '/root/Projects/lf-seguros-web/.claude/worktrees/agent-a205b124f4354e391',
      'w8:p1',
      state: 'working',
      lastEvent: 'PreToolUse',
      lastMessage: 'Started: LF-100482 (named limiters)',
      ago: const Duration(seconds: 30),
    ),
    _agent('5a57ee59', '/root/Projects/TheCalendar/Api', 'w14:p1'),
    _agent(
      'f966c202',
      '/root/Projects/yoke-wt/integration',
      'w1C:p1',
      ago: const Duration(minutes: 20),
    ),
    for (final (i, (id, cwd, pane)) in [
      ('326e221d', '/root/Projects', 'w1D:p1'),
      ('6b1b8b57', '/root/Projects', 'w12:p1'),
      ('6bd0511d', '/root/Projects/DTech', 'wE:p1'),
      ('7f9776ae', '/root/Projects/CarMirror/android', 'w1B:p1'),
      ('a2c8fa00', '/root', 'wS:p1'),
      ('870e406f', '/root/Projects/Zaplyze', 'w5:p1'),
      ('fedc75e1', '/root', 'w4:p4'),
      ('dd691e3d', '/root/Projects', 'w16:p1'),
      ('1a030a8a', '/root/Projects/VTM-Api', 'w11:p1'),
      ('9f701ab7', '/root/Projects', 'wW:p1'),
      ('fde4598c', '/root/Projects/Conductore-Lite', 'wV:p1'),
      ('a6befba8', '/root/Projects', 'wY:p1'),
    ].indexed)
      _agent(id, cwd, pane, ago: Duration(hours: 1 + i)),
  ],
});

List<AgentInfo> get _agents =>
    ConductoreHostAttentionProvider.parseSnapshot(_devCentral).agents;

AgentStatusEntry _entry(
  AgentInfo agent, {
  String machineId = 'dev',
  String hostName = 'development-central',
  String? stuck,
  String? detail,
}) => (
  machineId: machineId,
  hostName: hostName,
  agent: agent,
  companion: true,
  detail: detail,
  stuck: stuck,
);

/// One entry per agent per open session, like the controller with 8
/// Herdr workspaces of dev-central open.
List<AgentStatusEntry> _eightSessions({String? stuckFor}) => [
  for (var session = 0; session < 8; session++)
    for (final agent in _agents)
      _entry(
        agent,
        hostName: 'development-central: workspace $session',
        stuck: agent.id == stuckFor ? 'The same error 4 times' : null,
      ),
];

void main() {
  group('naming', () {
    test('a worktree folder names the repository above it', () {
      expect(
        projectFromPath(
          '/root/Projects/lf-seguros-web/.claude/worktrees/'
          'agent-a205b124f4354e391',
        ),
        'lf-seguros-web',
      );
      expect(projectFromPath('/root/.herdr/worktrees/api/fix-login'), 'api');
      expect(projectFromPath('/w/api/.worktrees/feature-x'), 'api');
      expect(projectFromPath('/w/api/a205b124f4354e391aa'), 'api');
      expect(projectFromPath('/root/Projects/TheCalendar/Api'), 'Api');
      expect(
        projectFromPath('/root/Projects/yoke-wt/integration'),
        'integration',
      );
      expect(projectFromPath(null), isNull);
    });

    test('generated ids are never a name', () {
      expect(isOpaqueName('agent-a205b124f4354e391'), isTrue);
      expect(isOpaqueName('a04b9572-31e5-4ef9-b125-a294a13a7fd2'), isTrue);
      expect(isOpaqueName('lf-seguros-web'), isFalse);
      expect(isOpaqueName('wt-con079'), isFalse);
      expect(isOpaqueName('deadbeef'), isFalse);
      expect(agentDisplayName(name: 'agent-a205b124f4354e391'), 'Agent');
      expect(
        agentDisplayName(project: ' ', name: 'Conductore-Mobile'),
        'Conductore-Mobile',
      );
    });

    test('the companion\'s worktree agent reads as its project everywhere', () {
      final agent = _agents.firstWhere((a) => a.id == 'a04b9572');
      expect(agent.name, 'lf-seguros-web');
      expect(agent.projectLabel, 'lf-seguros-web');
      expect(AgentNotificationPolicy.agentLabel(agent), 'lf-seguros-web');
      // A provider without a project falls back to the cwd the same way.
      const herdr = AgentInfo(
        id: 'herdr/w8:p1',
        name: 'agent-a205b124f4354e391',
        state: AgentAttentionState.working,
        workspace:
            '/root/Projects/lf-seguros-web/.claude/worktrees/'
            'agent-a205b124f4354e391',
      );
      expect(herdr.projectLabel, 'lf-seguros-web');
      expect(AgentNotificationPolicy.agentLabel(herdr), 'lf-seguros-web');
    });
  });

  group('what counts', () {
    test('eight sessions of one machine list its 16 agents once', () {
      final status = AgentStatusSummary.build(
        _eightSessions(stuckFor: 'a04b9572'),
        now: _now,
      )!;
      // 2 working; of the 14 waiting, only the 2 of the last 30 min.
      expect(status.title, '2 working · 2 idle');
      expect(status.publicTitle, 'Conductore: 4 agents');
      expect(status.lines, [
        'Conductore-Mobile · Working · Logged it as CON-079.',
        'lf-seguros-web · Stuck · The same error 4 times',
        'Api · Idle',
        'integration · Idle',
      ]);
      for (final line in status.lines) {
        expect(line, isNot(contains('agent-a205')));
        expect(line, isNot(contains('development-central')));
      }
    });

    test('"+N more" counts distinct agents', () {
      final status = AgentStatusSummary.build(
        _eightSessions(),
        now: _now.add(const Duration(minutes: 1)),
      );
      // Without the idle window: every live agent, once.
      final all = AgentStatusSummary.build(_eightSessions())!;
      expect(all.title, '2 working · 14 idle');
      expect(all.lines, hasLength(AgentStatusSummary.maxLines));
      expect(all.lines.take(2), [
        'Conductore-Mobile · Working · Logged it as CON-079.',
        'lf-seguros-web · Working · Started: LF-100482 (named limiters)',
      ]);
      expect(all.lines.last, '+11 more');
      expect(status!.lines.last, isNot(startsWith('+')));
    });

    test('Herdr\'s sighting of a hook agent folds into it', () {
      final hook = _agents.firstWhere((a) => a.id == 'a04b9572');
      const herdr = AgentInfo(
        id: 'herdr/w8:p1',
        name: 'lf-seguros-web',
        state: AgentAttentionState.needsInput,
        pane: 'w8:p1',
      );
      final status = AgentStatusSummary.build([
        (
          machineId: 'dev',
          hostName: 'development-central',
          agent: herdr,
          companion: false,
          detail: null,
          stuck: null,
        ),
        _entry(hook),
      ], now: _now)!;
      expect(status.lines, [
        'lf-seguros-web · Working · Started: LF-100482 (named limiters)',
      ]);
      expect(status.title, '1 working');
    });

    test('a subagent in its parent\'s pane folds into it, the urgent one '
        'winning', () {
      final parent = _agents.firstWhere((a) => a.id == 'a04b9572');
      const child = AgentInfo(
        id: 'sub-1',
        name: 'agent-ad3630561c5e991ef',
        state: AgentAttentionState.needsInput,
        pane: 'w8:p1',
        workspace: '/root/Projects/lf-seguros-web/.claude/worktrees/x',
        pendingRequests: [
          PendingPermissionRequest(
            id: 'r1',
            toolName: 'Bash',
            summary: 'git push',
          ),
        ],
      );
      final status = AgentStatusSummary.build([
        _entry(parent),
        _entry(child),
      ], now: _now)!;
      expect(status.title, '1 needs you');
      expect(status.lines.single, startsWith('lf-seguros-web · Needs you'));
    });

    test('several machines: the machine is a suffix', () {
      final agent = _agents.first;
      final status = AgentStatusSummary.build([
        _entry(agent),
        _entry(agent, machineId: 'laptop', hostName: 'omarchy'),
      ], now: _now)!;
      expect(status.lines, [
        'Conductore-Mobile · Working · Logged it as CON-079. '
            '(development-central)',
        'Conductore-Mobile · Working · Logged it as CON-079. (omarchy)',
      ]);
    });

    test('urgent first, then working, then idle', () {
      final status = AgentStatusSummary.build([
        _entry(_agents[2]),
        _entry(_agents[0]),
        _entry(
          _agents[3].copyWith(
            pendingRequests: const [
              PendingPermissionRequest(
                id: 'r',
                toolName: 'Bash',
                summary: 'rm -rf build',
              ),
            ],
          ),
        ),
      ], now: _now)!;
      expect(status.title, '1 needs you · 1 working · 1 idle');
      expect(status.lines.map((line) => line.split(' · ')[1]), [
        'Needs you',
        'Working',
        'Idle',
      ]);
    });
  });

  test('the controller lists a machine\'s agents once however many of its '
      'Herdr workspaces are open', () async {
    final workspace = TerminalWorkspaceController(FreshTerminalRepository());
    final notifier = RecordingAgentNotifier();
    final controller = AgentAttentionController(
      workspace: workspace,
      runnerFactory: (_) => ScriptedAgentCommandRunner([
        const AgentCommandResult(
          stdout: '{"version":"1.5.1"}',
          stderr: '',
          exitCode: 0,
        ),
        AgentCommandResult(stdout: _devCentral, stderr: '', exitCode: 0),
      ]),
      provider: const HerdrAttentionProvider(),
      companionProvider: const ConductoreHostAttentionProvider(),
      notifier: notifier,
      notificationPreferences: MemoryAgentNotificationPreferencesStore(),
      statusThrottle: AgentStatusThrottle(interval: Duration.zero),
      pollInterval: const Duration(days: 1),
      clock: () => _now,
    );
    controller
      ..setAppForeground(false)
      ..machineName = (id) => id == 'dev' ? 'development-central' : null;
    addTearDown(controller.dispose);
    addTearDown(workspace.dispose);
    final machine = buildHost('dev').copyWith(agentAttentionEnabled: true);
    for (final w in ['w8', 'wX', 'w14']) {
      await workspace
          .open(machine.copyWith(id: 'dev#herdr:$w', name: 'dev: $w'))
          .connect();
    }
    await pumpEventQueue();
    expect(notifier.status?.title, '2 working · 2 idle');
    expect(notifier.status?.lines, hasLength(4));
    expect(notifier.status?.lines[1], startsWith('lf-seguros-web · Working'));
  });

  test('8 open sessions of one machine: 1 monitor, 1 poll, 1 alert per '
      'state', () async {
    final workspace = TerminalWorkspaceController(FreshTerminalRepository());
    final notifier = RecordingAgentNotifier();
    final runners = <String, ScriptedAgentCommandRunner>{};
    final approval = jsonEncode({
      'version': 1,
      'seq': 2,
      'agents': [
        {
          ..._agent(
            'a04b9572',
            '/root/Projects/lf-seguros-web/.claude/worktrees/'
                'agent-a205b124f4354e391',
            'w8:p1',
            state: 'needs_permission',
            lastEvent: 'PermissionRequest',
          ),
          'stateSeq': 2,
          'pending': [
            {'id': 'r1', 'toolName': 'Bash', 'summary': 'git push'},
          ],
        },
      ],
    });
    final controller = AgentAttentionController(
      workspace: workspace,
      runnerFactory: (host) => runners[host.id] = ScriptedAgentCommandRunner([
        const AgentCommandResult(
          stdout: '{"version":"1.5.1"}',
          stderr: '',
          exitCode: 0,
        ),
        AgentCommandResult(stdout: approval, stderr: '', exitCode: 0),
      ]),
      provider: const HerdrAttentionProvider(),
      companionProvider: const ConductoreHostAttentionProvider(),
      notifier: notifier,
      notificationPreferences: MemoryAgentNotificationPreferencesStore(),
      statusThrottle: AgentStatusThrottle(interval: Duration.zero),
      pollInterval: const Duration(days: 1),
      clock: () => _now,
    );
    controller
      ..setAppForeground(false)
      ..machineName = (id) => id == 'dev' ? 'development-central' : null;
    addTearDown(controller.dispose);
    addTearDown(workspace.dispose);
    final machine = buildHost('dev').copyWith(agentAttentionEnabled: true);
    final sessions = [
      for (var w = 0; w < 8; w++)
        workspace.open(machine.copyWith(id: 'dev#herdr:w$w', name: 'dev: w$w')),
    ];
    for (final session in sessions) {
      await session.connect();
    }
    await pumpEventQueue();

    // One monitor, under the machine's id and name, one connection.
    expect(runners.keys, ['dev']);
    expect(controller.monitoredHosts.map((h) => (h.id, h.name)), [
      ('dev', 'development-central'),
    ]);
    final statusPolls = runners['dev']!.commands.where(
      (command) => command.contains(' status'),
    );
    expect(statusPolls, hasLength(1));
    // Every session sees the machine's agents.
    for (final session in sessions) {
      expect(controller.statusFor(session.host.id)?.agents, hasLength(1));
    }
    // One alert, keyed by the machine; the status counts the agent once.
    expect(notifier.alerts, hasLength(1));
    expect(notifier.alerts.single.hostId, 'dev');
    expect(notifier.status?.title, '1 needs you');

    // The followed session closes: the monitor moves to another session
    // and keeps what it knows (no second alert, no new connection).
    await workspace.close(sessions.first);
    await pumpEventQueue();
    expect(controller.isMonitoring('dev#herdr:w3'), isTrue);
    expect(runners.keys, ['dev']);
    await controller.resyncNotifications();
    expect(notifier.alerts, hasLength(1));
  });
}
