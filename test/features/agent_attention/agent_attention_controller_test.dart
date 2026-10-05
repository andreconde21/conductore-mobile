import 'dart:async';

import 'package:conduit/features/agent_attention/data/herdr_attention_provider.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention_notifier.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/agent_attention/domain/agent_notifications.dart';
import 'package:conduit/features/agent_attention/domain/agent_urgent_notifications.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

void main() {
  SavedHost monitoredHost(String id) =>
      buildHost(id).copyWith(agentAttentionEnabled: true);

  AgentCommandResult agents(String json) =>
      AgentCommandResult(stdout: json, stderr: '', exitCode: 0);

  const working = '[{"name": "builder", "state": "working"}]';
  const blocked = '[{"name": "builder", "state": "blocked"}]';
  const done = '[{"name": "builder", "state": "done"}]';

  (
    TerminalWorkspaceController,
    AgentAttentionController,
    ScriptedAgentCommandRunner,
    RecordingAgentNotifier,
  )
  build(
    List<Object> script, {
    SavedHost? host,
    AgentNotificationMode mode = AgentNotificationMode.ongoingAndUrgent,
  }) {
    final workspace = TerminalWorkspaceController(
      ImmediateTerminalRepository(TrackableTerminalSession()),
    );
    final runner = ScriptedAgentCommandRunner(script);
    final notifier = RecordingAgentNotifier();
    final controller = AgentAttentionController(
      workspace: workspace,
      runnerFactory: (_) => runner,
      provider: const HerdrAttentionProvider(),
      notifier: notifier,
      notificationPreferences: MemoryAgentNotificationPreferencesStore(
        AgentNotificationPreferences(mode: mode),
      ),
      statusThrottle: AgentStatusThrottle(interval: Duration.zero),
      // Far beyond test duration; polls are driven manually via pollNow.
      pollInterval: const Duration(days: 1),
    );
    addTearDown(controller.dispose);
    addTearDown(workspace.dispose);
    return (workspace, controller, runner, notifier);
  }

  test('monitors only enabled, connected, non-local hosts', () async {
    final (workspace, controller, _, _) = build([agents(working)]);

    final enabled = workspace.open(monitoredHost('on'));
    final disabled = workspace.open(buildHost('off'));
    expect(controller.isMonitoring('on'), isFalse);

    await enabled.connect();
    await disabled.connect();
    expect(controller.isMonitoring('on'), isTrue);
    expect(controller.isMonitoring('off'), isFalse);
    expect(controller.monitoredHosts.map((host) => host.id), ['on']);
  });

  test('does not notify for the initial snapshot', () async {
    final (workspace, controller, _, notifier) = build([agents(blocked)]);
    await workspace.open(monitoredHost('h')).connect();
    await pumpEventQueue();

    expect(controller.statusFor('h')?.agents, hasLength(1));
    expect(notifier.alerts, isEmpty);
  });

  test('notifies exactly once per transition into needing input', () async {
    final (workspace, controller, _, notifier) = build([
      agents(working),
      agents(blocked),
      agents(blocked),
      agents(working),
      agents(blocked),
    ]);
    await workspace.open(monitoredHost('h')).connect();
    await pumpEventQueue();

    await controller.pollNow('h');
    expect(notifier.alerts, hasLength(1));
    expect(notifier.alerts.single.title, 'builder · Host h is waiting for you');
    expect(notifier.alerts.single.text, 'Waiting for your answer');
    // No buttons: nothing to approve.
    expect(notifier.alerts.single.action, isNull);

    // Unchanged state on the next poll must not re-notify (or re-post).
    final posts = notifier.agentPosts.length;
    await controller.pollNow('h');
    expect(notifier.agentPosts, hasLength(posts));

    // Leaving the state removes the notification; re-entering notifies
    // again.
    await controller.pollNow('h');
    expect(notifier.agents, isEmpty);
    await controller.pollNow('h');
    expect(notifier.alerts, hasLength(2));
  });

  test('a notification opens the agent at its Herdr place', () async {
    const herdrWorking =
        '[{"name": "builder", "state": "working", "pane_id": "w2:p3",'
        ' "tab_id": "w2:t1", "workspace_id": "w2"}]';
    const herdrBlocked =
        '[{"name": "builder", "state": "blocked", "pane_id": "w2:p3",'
        ' "tab_id": "w2:t1", "workspace_id": "w2"}]';
    final (workspace, controller, _, notifier) = build([
      agents(herdrWorking),
      agents(herdrBlocked),
    ]);
    await workspace.open(monitoredHost('h')).connect();
    await pumpEventQueue();

    await controller.pollNow('h');
    expect(
      notifier.alerts.single.open,
      isA<AgentOpenTarget>()
          .having((target) => target.hostId, 'hostId', 'h')
          .having((target) => target.workspaceId, 'workspaceId', 'w2')
          .having((target) => target.tabId, 'tabId', 'w2:t1')
          .having((target) => target.paneId, 'paneId', 'w2:p3'),
    );
  });

  test('"Everything" notifies when background work finishes', () async {
    final (workspace, controller, _, notifier) = build([
      agents(working),
      agents(done),
    ], mode: AgentNotificationMode.everything);
    await workspace.open(monitoredHost('h')).connect();
    await pumpEventQueue();

    await controller.pollNow('h');
    expect(notifier.alerts.single.title, 'builder · Host h finished');
  });

  test('"Ongoing + urgent" keeps a finished turn to the status '
      'notification', () async {
    final (workspace, controller, _, notifier) = build([
      agents(working),
      agents(done),
    ]);
    await workspace.open(monitoredHost('h')).connect();
    await pumpEventQueue();

    await controller.pollNow('h');
    expect(notifier.alerts, isEmpty);
    expect(notifier.status?.lines.single, startsWith('builder · Idle'));
  });

  test('honors per-host notification toggles', () async {
    final muted = monitoredHost(
      'h',
    ).copyWith(agentNotifyInput: false, agentNotifyFinished: false);
    final (workspace, controller, _, notifier) = build([
      agents(working),
      agents(blocked),
      agents(done),
    ], host: muted);
    await workspace.open(muted).connect();
    await pumpEventQueue();

    await controller.pollNow('h');
    await controller.pollNow('h');
    expect(notifier.alerts, isEmpty);
  });

  test('handles agents disappearing between polls', () async {
    final (workspace, controller, _, notifier) = build([
      agents(working),
      agents('[]'),
      agents(blocked),
    ]);
    await workspace.open(monitoredHost('h')).connect();
    await pumpEventQueue();

    await controller.pollNow('h');
    expect(controller.statusFor('h')?.agents, isEmpty);
    expect(notifier.alerts, isEmpty);

    // The agent coming back blocked is a fresh transition — notify once.
    await controller.pollNow('h');
    expect(notifier.alerts, hasLength(1));
  });

  test('stops polling and reports when Herdr is unavailable', () async {
    final (workspace, controller, _, notifier) = build([
      const AgentCommandResult(
        stdout: '',
        stderr: 'sh: herdr: command not found',
        exitCode: 127,
      ),
    ]);
    await workspace.open(monitoredHost('h')).connect();
    await pumpEventQueue();

    expect(
      controller.statusFor('h')?.unavailableReason,
      contains('not installed'),
    );
    expect(notifier.alerts, isEmpty);
  });

  test('keeps known agents and reports transient errors', () async {
    final (workspace, controller, _, _) = build([
      agents(working),
      StateError('connection reset'),
    ]);
    await workspace.open(monitoredHost('h')).connect();
    await pumpEventQueue();

    await controller.pollNow('h');
    final status = controller.statusFor('h')!;
    expect(status.error, contains('connection reset'));
    expect(status.agents, hasLength(1));
  });

  test('attention count reflects agents needing input', () async {
    final (workspace, controller, _, _) = build([
      agents(
        '[{"name": "a", "state": "blocked"},'
        ' {"name": "b", "state": "working"},'
        ' {"name": "c", "state": "blocked"}]',
      ),
    ]);
    await workspace.open(monitoredHost('h')).connect();
    await pumpEventQueue();

    expect(controller.attentionCount, 2);
  });

  test(
    'stops the monitor and closes the runner when the session closes',
    () async {
      final (workspace, controller, runner, _) = build([agents(working)]);
      final session = workspace.open(monitoredHost('h'));
      await session.connect();
      await pumpEventQueue();
      expect(controller.isMonitoring('h'), isTrue);

      unawaited(workspace.close(session));
      await pumpEventQueue();

      expect(controller.isMonitoring('h'), isFalse);
      expect(runner.closeCount, 1);
    },
  );

  test('stops the monitor when the session disconnects', () async {
    final (workspace, controller, _, _) = build([agents(working)]);
    final session = workspace.open(monitoredHost('h'));
    await session.connect();
    await pumpEventQueue();
    expect(controller.isMonitoring('h'), isTrue);

    await session.disconnect();
    await pumpEventQueue();

    expect(controller.isMonitoring('h'), isFalse);
  });

  test('pausing keeps known states so background transitions still notify '
      'once', () async {
    final (workspace, controller, _, notifier) = build([
      agents(working),
      agents(blocked),
    ]);
    await workspace.open(monitoredHost('h')).connect();
    await pumpEventQueue();

    controller.setAppActive(false);
    controller.setAppActive(true);
    await pumpEventQueue();

    expect(notifier.alerts, hasLength(1));
  });

  test(
    'resuming the app does not resurrect polling on unavailable hosts',
    () async {
      final (workspace, controller, runner, _) = build([
        const AgentCommandResult(
          stdout: '',
          stderr: 'sh: herdr: command not found',
          exitCode: 127,
        ),
      ]);
      await workspace.open(monitoredHost('h')).connect();
      await pumpEventQueue();
      expect(controller.statusFor('h')?.unavailableReason, isNotNull);
      final commandsAfterDetection = runner.commands.length;

      controller.setAppActive(false);
      controller.setAppActive(true);
      await pumpEventQueue();

      expect(runner.commands.length, commandsAfterDetection);
    },
  );

  test('runs the provider focus command for an agent', () async {
    final (workspace, controller, runner, _) = build([agents(working)]);
    await workspace.open(monitoredHost('h')).connect();
    await pumpEventQueue();

    final agent = controller.statusFor('h')!.agents.single;
    await controller.focusAgent('h', agent);

    expect(
      runner.commands.last,
      HerdrAttentionProvider.remoteCommand('agent focus builder'),
    );
  });

  test('lists hardware-key hosts without ever polling them', () async {
    final hardwareKeyHost = monitoredHost('hk').copyWith(
      authMethod: SshAuthMethod.hardwareKey,
      hardwareKeys: const [HardwareKeyEntry(id: 'k', privateKey: 'stub')],
    );
    final (workspace, controller, runner, _) = build([agents(blocked)]);
    await workspace.open(hardwareKeyHost).connect();
    await pumpEventQueue();

    expect(controller.isMonitoring('hk'), isTrue);
    expect(
      controller.statusFor('hk')?.unavailableReason,
      AgentAttentionController.hardwareKeyUnavailableReason,
    );
    expect(runner.commands, isEmpty);

    await controller.refresh('hk');
    controller.setAppActive(false);
    controller.setAppActive(true);
    await pumpEventQueue();
    expect(runner.commands, isEmpty);
    expect(controller.attentionCount, 0);
  });

  test('backs off after consecutive failures and recovers', () async {
    final (workspace, controller, runner, _) = build([
      agents(working),
      StateError('reset 1'),
      StateError('reset 2'),
      agents(working),
    ]);
    await workspace.open(monitoredHost('h')).connect();
    await pumpEventQueue();
    expect(runner.commands, hasLength(1));

    await controller.tickNow('h'); // fails: skip one tick
    expect(runner.commands, hasLength(2));
    await controller.tickNow('h');
    expect(runner.commands, hasLength(2));
    await controller.tickNow('h'); // fails again: skip two ticks
    expect(runner.commands, hasLength(3));
    await controller.tickNow('h');
    await controller.tickNow('h');
    expect(runner.commands, hasLength(3));
    await controller.tickNow('h'); // succeeds: backoff cleared
    expect(runner.commands, hasLength(4));
    expect(controller.statusFor('h')?.error, isNull);
    await controller.tickNow('h');
    expect(runner.commands, hasLength(5));
  });

  test('a manual refresh ignores the failure backoff', () async {
    final (workspace, controller, runner, _) = build([
      agents(working),
      StateError('reset'),
      agents(working),
    ]);
    await workspace.open(monitoredHost('h')).connect();
    await pumpEventQueue();

    await controller.tickNow('h');
    expect(controller.statusFor('h')?.error, contains('reset'));
    await controller.refresh('h');
    expect(runner.commands, hasLength(3));
    expect(controller.statusFor('h')?.error, isNull);
  });

  test(
    're-notifies when the same state is reached again between polls',
    () async {
      String blockedSeq(int seq) =>
          '[{"name": "builder", "state": "blocked", "state_change_seq": $seq}]';
      final (workspace, controller, _, notifier) = build([
        agents(working),
        agents(blockedSeq(10)),
        agents(blockedSeq(10)),
        agents(blockedSeq(12)),
      ]);
      await workspace.open(monitoredHost('h')).connect();
      await pumpEventQueue();

      await controller.pollNow('h');
      expect(notifier.alerts, hasLength(1));
      await controller.pollNow('h');
      expect(notifier.alerts, hasLength(1));
      // Answered and blocked again within one interval: the sequence moved.
      await controller.pollNow('h');
      expect(notifier.alerts, hasLength(2));
    },
  );
}
