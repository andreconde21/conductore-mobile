import 'package:conduit/core/app_failure.dart';
import 'package:conduit/features/agent_attention/data/conductore_host_attention_provider.dart';
import 'package:conduit/features/agent_attention/data/herdr_attention_provider.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/agent_attention/domain/agent_notifications.dart';
import 'package:conduit/features/agent_attention/domain/agent_permission_actions.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

void main() {
  SavedHost monitoredHost(
    String id, {
    AgentMonitorKind monitor = AgentMonitorKind.auto,
  }) => buildHost(
    id,
  ).copyWith(agentAttentionEnabled: true, agentMonitor: monitor);

  AgentCommandResult ok(String stdout) =>
      AgentCommandResult(stdout: stdout, stderr: '', exitCode: 0);

  final version = ok('{"version":"0.1.0"}');
  const notInstalled = AgentCommandResult(
    stdout: '',
    stderr: 'sh: conductore-hostd: not found',
    exitCode: 127,
  );
  final herdrWorking = ok('[{"name": "builder", "state": "working"}]');
  final working = ok(
    '{"version":1,"seq":1,"agents":[{"sessionId":"s-1","name":"api",'
    '"cwd":"/a","state":"working","pending":[]}]}',
  );
  final pending = ok(
    '{"version":1,"seq":2,"agents":[{"sessionId":"s-1","name":"api",'
    '"cwd":"/a","state":"needs_permission","pending":[{"id":"req-1",'
    '"toolName":"Bash","summary":"rm -rf build","toolInput":{"command":'
    '"rm -rf build"}}]}]}',
  );
  final decided = ok('{"ok":true}');

  /// One `events` line carrying the full agent record.
  String changeLine(int seq, String agentJson, {String reason = 'Stop'}) =>
      '{"seq":$seq,"type":"change","sessionId":"s-1","reason":"$reason",'
      '"agent":$agentJson}';
  const pendingAgent =
      '{"sessionId":"s-1","name":"api","cwd":"/a","state":"needs_permission",'
      '"lastMessage":"Cleaning up first.","pending":[{"id":"req-1",'
      '"toolName":"Bash","summary":"rm -rf build"}]}';
  const workingAgent =
      '{"sessionId":"s-1","name":"api","cwd":"/a","state":"working",'
      '"pending":[]}';
  const terminalAgent =
      '{"sessionId":"s-1","name":"api","cwd":"/a","state":"needs_permission",'
      '"lastMessage":"Permission prompt is waiting in the terminal",'
      '"pending":[]}';

  (
    TerminalWorkspaceController,
    AgentAttentionController,
    ScriptedAgentCommandRunner,
    RecordingAgentNotifier,
  )
  build(List<Object> script, {bool foreground = false}) {
    final workspace = TerminalWorkspaceController(FreshTerminalRepository());
    final runner = ScriptedAgentCommandRunner(script);
    final notifier = RecordingAgentNotifier();
    final controller = AgentAttentionController(
      workspace: workspace,
      runnerFactory: (_) => runner,
      provider: const HerdrAttentionProvider(),
      companionProvider: const ConductoreHostAttentionProvider(),
      notifier: notifier,
      pollInterval: const Duration(days: 1),
      watchRestartDelay: Duration.zero,
    );
    // The long-poll loop is exercised explicitly; elsewhere the scripted
    // runner would feed it forever.
    controller.setAppForeground(foreground);
    addTearDown(controller.dispose);
    addTearDown(workspace.dispose);
    return (workspace, controller, runner, notifier);
  }

  group('provider selection', () {
    test('auto picks the companion when version answers', () async {
      final (workspace, controller, runner, _) = build([version, working]);
      await workspace.open(monitoredHost('h')).connect();
      await pumpEventQueue();

      expect(controller.providerFor('h').id, 'conductore');
      expect(runner.commands[0], contains('conductore-hostd version'));
      expect(runner.commands[1], contains('conductore-hostd status'));
      expect(controller.statusFor('h')?.agents.single.name, 'api');

      // The probe is cached: the next poll goes straight to status.
      await controller.pollNow('h');
      expect(runner.commands, hasLength(3));
      expect(runner.commands[2], contains('conductore-hostd status'));
    });

    test('auto falls back to Herdr when the companion is missing', () async {
      final (workspace, controller, runner, _) = build([
        notInstalled,
        herdrWorking,
      ]);
      await workspace.open(monitoredHost('h')).connect();
      await pumpEventQueue();

      expect(controller.providerFor('h').id, 'herdr');
      expect(runner.commands[1], contains('herdr agent list'));
      expect(controller.statusFor('h')?.agents.single.name, 'builder');
    });

    test('an explicit choice skips the probe', () async {
      final (workspace, controller, runner, _) = build([working]);
      await workspace
          .open(monitoredHost('h', monitor: AgentMonitorKind.companion))
          .connect();
      await pumpEventQueue();
      expect(controller.providerFor('h').id, 'conductore');
      expect(runner.commands.single, contains('conductore-hostd status'));

      final (workspace2, controller2, runner2, _) = build([herdrWorking]);
      await workspace2
          .open(monitoredHost('h', monitor: AgentMonitorKind.herdr))
          .connect();
      await pumpEventQueue();
      expect(controller2.providerFor('h').id, 'herdr');
      expect(runner2.commands.single, contains('herdr agent list'));
    });

    test('the companion being uninstalled stops monitoring', () async {
      final (workspace, controller, _, _) = build([notInstalled]);
      await workspace
          .open(monitoredHost('h', monitor: AgentMonitorKind.companion))
          .connect();
      await pumpEventQueue();
      expect(
        controller.statusFor('h')?.unavailableReason,
        contains('not installed'),
      );
    });
  });

  group('permission notifications', () {
    test('posts one actionable notification per agent, even on the '
        'first snapshot', () async {
      final (workspace, controller, _, notifier) = build([
        version,
        pending,
        pending,
      ]);
      await workspace.open(monitoredHost('h')).connect();
      await pumpEventQueue();

      expect(notifier.agentPosts, hasLength(1));
      final shown = notifier.agentPosts.single;
      expect(shown.key, 'agent:h:s-1');
      expect(shown.title, 'a · Host h needs you');
      expect(shown.text, 'Approve Bash: rm -rf build');
      expect(shown.publicTitle, 'Conductore: a needs you');
      expect(shown.alert, isTrue);
      expect(shown.action?.requestId, 'req-1');
      expect(shown.reviewAll, isFalse);
      // No plain notification next to it.
      expect(notifier.shown, isEmpty);
      expect(controller.attentionCount, 1);

      // Seeing the same request again does not re-post.
      await controller.pollNow('h');
      expect(notifier.agentPosts, hasLength(1));
    });

    test('cancels the notification when the request disappears', () async {
      final (workspace, controller, _, notifier) = build([
        version,
        pending,
        ok('{"version":1,"seq":3,"agents":[$workingAgent]}'),
      ]);
      await workspace.open(monitoredHost('h')).connect();
      await pumpEventQueue();
      expect(notifier.agents.keys, ['agent:h:s-1']);

      await controller.pollNow('h');
      expect(notifier.agentCancelled, ['agent:h:s-1']);
      expect(notifier.agents, isEmpty);
    });

    test('respects the per-host input notification toggle', () async {
      final muted = monitoredHost('h').copyWith(agentNotifyInput: false);
      final (workspace, _, _, notifier) = build([version, pending]);
      await workspace.open(muted).connect();
      await pumpEventQueue();
      expect(notifier.agentPosts, isEmpty);
    });
  });

  group('decisions', () {
    test('sends decide, drops the request and re-polls', () async {
      final (workspace, controller, runner, notifier) = build([
        version,
        pending,
        decided,
        working,
      ]);
      await workspace.open(monitoredHost('h')).connect();
      await pumpEventQueue();
      final request = controller
          .statusFor('h')!
          .agents
          .single
          .pendingRequests
          .single;

      await controller.decide('h', request, PermissionVerdict.allow);
      await pumpEventQueue();

      expect(
        runner.commands[2],
        contains('conductore-hostd decide req-1 allow'),
      );
      expect(runner.commands[3], contains('conductore-hostd status'));
      expect(controller.statusFor('h')?.agents.single.pendingRequests, isEmpty);
      expect(
        controller.statusFor('h')?.agents.single.state,
        AgentAttentionState.working,
      );
      // Answered in the app: the agent's notification goes.
      expect(notifier.agentCancelled, ['agent:h:s-1']);
      expect(controller.isDeciding('req-1'), isFalse);
    });

    test('a rejected decision throws and keeps the request', () async {
      final (workspace, controller, _, notifier) = build([
        version,
        pending,
        const AgentCommandResult(
          stdout: '{"error":"daemon not reachable"}',
          stderr: '',
          exitCode: 1,
        ),
      ]);
      await workspace.open(monitoredHost('h')).connect();
      await pumpEventQueue();
      final request = controller
          .statusFor('h')!
          .agents
          .single
          .pendingRequests
          .single;

      await expectLater(
        controller.decide('h', request, PermissionVerdict.deny),
        throwsA(isA<AppFailure>()),
      );
      expect(
        controller.statusFor('h')?.agents.single.pendingRequests,
        hasLength(1),
      );
      expect(notifier.agentCancelled, isEmpty);
      expect(notifier.agents, hasLength(1));
    });

    test('an expired request is dropped but the agent keeps waiting', () async {
      final (workspace, controller, runner, notifier) = build([
        version,
        pending,
        const AgentCommandResult(
          stdout: '{"error":"request expired; answer it in the terminal"}',
          stderr: '',
          exitCode: 1,
        ),
        ok('{"version":1,"seq":3,"agents":[$terminalAgent]}'),
      ]);
      await workspace.open(monitoredHost('h')).connect();
      await pumpEventQueue();
      final request = controller
          .statusFor('h')!
          .agents
          .single
          .pendingRequests
          .single;

      await expectLater(
        controller.decide('h', request, PermissionVerdict.allow),
        throwsA(
          isA<AppFailure>().having(
            (failure) => failure.message,
            'message',
            contains('answer it in the terminal'),
          ),
        ),
      );
      await pumpEventQueue();
      expect(runner.commands[3], contains('conductore-hostd status'));
      final agent = controller.statusFor('h')!.agents.single;
      expect(agent.pendingRequests, isEmpty);
      expect(agent.state, AgentAttentionState.needsInput);
      expect(agent.lastMessage, contains('waiting in the terminal'));
      expect(notifier.agent('h', 's-1')?.need, AgentNeed.question);
      expect(notifier.agent('h', 's-1')?.action, isNull);
    });

    test('Herdr agents cannot be decided', () async {
      final (workspace, controller, _, _) = build([notInstalled, herdrWorking]);
      await workspace.open(monitoredHost('h')).connect();
      await pumpEventQueue();
      await expectLater(
        controller.decide(
          'h',
          const PendingPermissionRequest(id: 'r', toolName: 't', summary: 's'),
          PermissionVerdict.allow,
        ),
        throwsA(isA<AppFailure>()),
      );
    });
  });

  group('notification action taps', () {
    const tap = AgentPermissionAction(
      notificationId: 'agent:h:s-1',
      hostId: 'h',
      requestId: 'req-1',
      agentId: 's-1',
      verdict: 'always',
    );

    test('use the live monitor when the host is connected', () async {
      final (workspace, controller, runner, notifier) = build([
        version,
        pending,
        decided,
        working,
      ]);
      final host = monitoredHost('h');
      await workspace.open(host).connect();
      await pumpEventQueue();

      await controller.completePermissionAction(tap, host);
      await pumpEventQueue();

      expect(runner.commands[2], contains('decide req-1 always'));
      expect(notifier.agentCancelled, ['agent:h:s-1']);
      expect(runner.closeCount, 0);
    });

    test('open a one-off connection when the host is not monitored', () async {
      final (_, controller, runner, notifier) = build([decided]);

      await controller.completePermissionAction(tap, monitoredHost('h'));

      expect(runner.commands.single, contains('decide req-1 always'));
      expect(runner.closeCount, 1);
    });

    test(
      'a tap queued by an older build cancels its own notification',
      () async {
        final (_, controller, _, notifier) = build([decided]);

        await controller.completePermissionAction(
          const AgentPermissionAction(
            notificationId: 'h:perm:req-1',
            hostId: 'h',
            requestId: 'req-1',
            verdict: 'allow',
          ),
          monitoredHost('h'),
        );

        expect(notifier.cancelled, ['h:perm:req-1']);
      },
    );

    test('rewrite the notification when the decision fails', () async {
      final (_, controller, _, notifier) = build([StateError('no route')]);

      await controller.completePermissionAction(tap, monitoredHost('h'));

      expect(notifier.agentCancelled, isEmpty);
      // The agent's one notification says so; no second one.
      expect(notifier.shown, isEmpty);
      final failed = notifier.agent('h', 's-1')!;
      expect(failed.title, 'Permission decision failed');
      expect(failed.text, contains('Open Conductore'));
      expect(failed.action, isNull);
    });

    test('fail gracefully for a deleted host or unknown verdict', () async {
      final (_, controller, runner, notifier) = build([decided]);
      await controller.completePermissionAction(tap, null);
      await controller.completePermissionAction(
        const AgentPermissionAction(
          notificationId: 'n',
          hostId: 'h',
          requestId: 'r',
          verdict: 'maybe',
        ),
        monitoredHost('h'),
      );
      expect(runner.commands, isEmpty);
      expect(notifier.agentPosts, hasLength(1));
      expect(notifier.shown, hasLength(1));
    });
  });

  group('long-poll', () {
    test('runs events in the foreground and falls back on failure', () async {
      final (workspace, controller, runner, notifier) = build([
        version,
        working,
        ok(changeLine(2, pendingAgent, reason: 'PermissionRequest')),
        StateError('channel closed'), // events: the link drops
      ], foreground: true);
      await workspace.open(monitoredHost('h')).connect();
      await pumpEventQueue();

      expect(
        runner.commands[2],
        contains('conductore-hostd events --since 1 --timeout 55'),
      );
      expect(
        controller.statusFor('h')?.agents.single.pendingRequests,
        hasLength(1),
      );
      expect(notifier.agentPosts, hasLength(1));
      expect(notifier.agentPosts.single.text, 'Approve Bash: rm -rf build');
      // The failed long-poll leaves the loop; periodic polling takes over.
      expect(controller.isWatching('h'), isFalse);
      expect(controller.statusFor('h')?.error, contains('channel closed'));
    });

    test('is not started while backgrounded', () async {
      final (workspace, controller, runner, _) = build([version, working]);
      await workspace.open(monitoredHost('h')).connect();
      await pumpEventQueue();
      expect(controller.isWatching('h'), isFalse);
      expect(runner.commands, hasLength(2));
      expect(
        runner.commands.any((command) => command.contains('events')),
        isFalse,
      );
    });

    test('skips changes a status poll already covered', () async {
      final (workspace, controller, runner, _) = build([
        version,
        pending, // status, seq 2
        // events answering with seq 1 (overtaken), then an empty timeout
        ok(changeLine(1, workingAgent)),
        StateError('stop'),
      ], foreground: true);
      await workspace.open(monitoredHost('h')).connect();
      await pumpEventQueue();
      expect(runner.commands[2], contains('events --since 2'));
      expect(runner.commands[3], contains('events --since 2'));
      expect(
        controller.statusFor('h')?.agents.single.pendingRequests,
        hasLength(1),
      );
    });

    test('applies removals and a resync snapshot', () async {
      final (workspace, controller, runner, _) = build([
        version,
        ok(
          '{"version":1,"seq":5,"agents":[$workingAgent,'
          '{"sessionId":"s-2","name":"web","state":"working"}]}',
        ),
        ok(
          '{"seq":6,"type":"remove","sessionId":"s-2","reason":"prune",'
          '"agent":null}',
        ),
        ok(
          '{"type":"snapshot","version":1,"seq":2,"agents":'
          '[{"sessionId":"s-9","name":"fresh","state":"waiting_input"}]}',
        ),
        StateError('stop'),
      ], foreground: true);
      await workspace.open(monitoredHost('h')).connect();
      await pumpEventQueue();
      expect(runner.commands[3], contains('events --since 6'));
      // The daemon restarted with a lower counter: the snapshot wins and
      // the cursor follows it.
      expect(runner.commands[4], contains('events --since 2'));
      expect(controller.statusFor('h')?.agents.single.name, 'fresh');
    });
  });

  group('status polls', () {
    test('a lower sequence after a host reset still applies', () async {
      final (workspace, controller, _, _) = build([
        version,
        pending, // seq 2
        working, // seq 1: state.json was lost, the counter restarted
      ]);
      await workspace.open(monitoredHost('h')).connect();
      await pumpEventQueue();
      await controller.pollNow('h');
      expect(
        controller.statusFor('h')?.agents.single.state,
        AgentAttentionState.working,
      );
    });

    test(
      'a timed-out request becomes a plain needs-input notification',
      () async {
        final (workspace, controller, _, notifier) = build([
          version,
          pending,
          ok('{"version":1,"seq":3,"agents":[$terminalAgent]}'),
        ]);
        await workspace.open(monitoredHost('h')).connect();
        await pumpEventQueue();
        await controller.pollNow('h');

        // The same notification, updated in place and silently.
        expect(notifier.agentCancelled, isEmpty);
        final [asked, waiting] = notifier.agentPosts;
        expect(waiting.key, asked.key);
        expect(waiting.title, 'a · Host h is waiting for you');
        expect(waiting.text, 'Permission prompt is waiting in the terminal');
        expect(waiting.alert, isFalse);
        expect(waiting.action, isNull);
        expect(controller.attentionCount, 1);
      },
    );

    test(
      'a reconnect neither re-alerts nor keeps stale notifications',
      () async {
        final (workspace, controller, _, notifier) = build([
          version,
          pending,
          version,
          pending,
          working,
        ]);
        final session = workspace.open(monitoredHost('h'));
        await session.connect();
        await pumpEventQueue();
        expect(notifier.agentPosts, hasLength(1));

        await session.disconnect();
        await pumpEventQueue();
        expect(controller.isMonitoring('h'), isFalse);
        await session.connect();
        await pumpEventQueue();
        expect(notifier.agentPosts, hasLength(1));

        await controller.pollNow('h');
        expect(notifier.agentCancelled, ['agent:h:s-1']);
      },
    );
  });
}
