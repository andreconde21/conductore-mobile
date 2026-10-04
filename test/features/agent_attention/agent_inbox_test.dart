import 'package:conduit/features/agent_attention/data/conductore_host_attention_provider.dart';
import 'package:conduit/features/agent_attention/data/herdr_attention_provider.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/agent_attention/domain/agent_inbox.dart';
import 'package:conduit/features/agent_attention/domain/agent_notifications.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

void main() {
  DateTime at(int minute) => DateTime.utc(2026, 9, 25, 12, minute);

  AgentInfo agent(
    String id, {
    AgentAttentionState state = AgentAttentionState.working,
    String? cwd,
    int? minute,
    String? message,
    List<PendingPermissionRequest> pending = const [],
  }) => AgentInfo(
    id: id,
    name: id,
    state: state,
    workspace: cwd,
    stateChangedAt: minute == null ? null : at(minute),
    lastMessage: message,
    pendingRequests: pending,
  );

  const request = PendingPermissionRequest(
    id: 'r1',
    toolName: 'Bash',
    summary: 'ls',
  );

  List<String> ids(AgentInbox inbox, AgentInboxSection section) => [
    for (final group in inbox.sections[section] ?? const <AgentInboxGroup>[])
      for (final entry in group.entries) entry.agent.id,
  ];

  group('sections and sorting', () {
    test('puts approvals first and sorts one host newest first', () {
      final inbox = AgentInbox.build([
        (
          hostId: 'h',
          hostName: 'Host h',
          agents: [
            agent('old-work', minute: 1),
            agent('done', state: AgentAttentionState.finished, minute: 9),
            agent(
              'asks',
              state: AgentAttentionState.needsInput,
              pending: [request],
              minute: 2,
            ),
            agent('new-work', minute: 5),
            agent('question', state: AgentAttentionState.needsInput),
            agent('blocked', state: AgentAttentionState.blocked, minute: 3),
            agent('idle', state: AgentAttentionState.idle, minute: 8),
            agent('mystery', state: AgentAttentionState.unknown),
          ],
        ),
      ]);

      expect(inbox.sections.keys, [
        AgentInboxSection.needsApproval,
        AgentInboxSection.needsInput,
        AgentInboxSection.working,
        AgentInboxSection.doneIdle,
      ]);
      expect(ids(inbox, AgentInboxSection.needsApproval), ['asks']);
      // Timed agents first (newest first), untimed last.
      expect(ids(inbox, AgentInboxSection.needsInput), ['blocked', 'question']);
      expect(ids(inbox, AgentInboxSection.working), ['new-work', 'old-work']);
      expect(ids(inbox, AgentInboxSection.doneIdle), [
        'done',
        'idle',
        'mystery',
      ]);
      // One host: no host/project group headers.
      expect(inbox.sections[AgentInboxSection.working]!.single.hostName, null);
    });

    test('groups by host then project when there are several hosts', () {
      final inbox = AgentInbox.build([
        (
          hostId: 'b',
          hostName: 'Beta',
          agents: [
            agent('b-web', cwd: '/srv/web', minute: 1),
            agent('b-api', cwd: '/srv/api', minute: 2),
            agent('b-api-2', cwd: '/home/x/api/', minute: 3),
          ],
        ),
        (
          hostId: 'a',
          hostName: 'Alpha',
          agents: [agent('a-zed', cwd: '/z/zed', minute: 4)],
        ),
      ]);

      final groups = inbox.sections[AgentInboxSection.working]!;
      expect(
        [for (final group in groups) '${group.hostName}/${group.project}'],
        ['Beta/api', 'Beta/web', 'Alpha/zed'],
      );
      expect(
        [for (final entry in groups.first.entries) entry.agent.id],
        ['b-api-2', 'b-api'],
      );
    });

    test('keeps one row per agent session', () {
      final inbox = AgentInbox.build([
        (
          hostId: 'h',
          hostName: 'Host h',
          agents: [
            agent('s-1', minute: 1),
            agent('s-1', state: AgentAttentionState.finished),
          ],
        ),
      ]);
      expect(inbox.countIn(AgentInboxSection.working), 1);
      expect(inbox.countIn(AgentInboxSection.doneIdle), 0);
    });
  });

  group('project label', () {
    test('prefers the reported project, then the cwd basename', () {
      expect(
        const AgentInfo(
          id: 'x',
          name: 'x',
          state: AgentAttentionState.idle,
          workspace: '/home/a/monorepo/packages/app',
          project: 'monorepo',
        ).projectLabel,
        'monorepo',
      );
      expect(agent('x', cwd: '/home/a/api/').projectLabel, 'api');
      // Herdr workspace ids are not projects.
      expect(agent('x', cwd: 'w1').projectLabel, isNull);
    });
  });

  group('dismissals', () {
    test('hide a row until the agent changes', () {
      final dismissals = AgentInboxDismissals();
      addTearDown(dismissals.dispose);
      final done = agent(
        's',
        state: AgentAttentionState.finished,
        minute: 1,
        message: 'All green.',
      );
      AgentInbox build(AgentInfo value) => AgentInbox.build([
        (hostId: 'h', hostName: 'Host h', agents: [value]),
      ], dismissals: dismissals);

      dismissals.dismiss('h', done);
      final hidden = build(done);
      expect(hidden.isEmpty, isTrue);
      expect(hidden.hiddenCount, 1);

      // The same agent on another host is a different row.
      expect(dismissals.isHidden('other', done), isFalse);

      final resumed = agent('s', minute: 2, message: 'On it.');
      expect(ids(build(resumed), AgentInboxSection.working), ['s']);
      // The dismissal is gone for good once the agent changed.
      expect(ids(build(done), AgentInboxSection.doneIdle), ['s']);
    });

    test('restoreAll brings every row back', () {
      final dismissals = AgentInboxDismissals();
      addTearDown(dismissals.dispose);
      final done = agent('s', state: AgentAttentionState.idle);
      dismissals.dismiss('h', done);
      var notified = 0;
      dismissals.addListener(() => notified += 1);
      dismissals.restoreAll();
      expect(dismissals.isHidden('h', done), isFalse);
      expect(notified, 1);
    });
  });

  group('companion usage field', () {
    AgentInfo parse(String agentJson) =>
        ConductoreHostAttentionProvider.parseSnapshot(
          '{"version":1,"seq":1,"agents":[$agentJson]}',
        ).agents.single;

    test('parses usage, kind and project when present', () {
      final parsed = parse(
        '{"sessionId":"s","cwd":"/w/app","state":"working","kind":"codex",'
        '"project":"mono","usage":{"contextUsedPct":42.5,"contextTokens":'
        '85000,"windowLabel":"200k","limits":[{"label":"5h","usedPct":23.5,'
        '"resetsAt":1790000000000},{"label":"7d","usedPct":"bad"}]}}',
      );
      expect(parsed.kind, 'codex');
      expect(parsed.projectLabel, 'mono');
      final usage = parsed.usage!;
      expect(usage.contextUsedPct, 42.5);
      expect(usage.contextTokens, 85000);
      expect(usage.windowLabel, '200k');
      expect(usage.limits, [
        AgentRateLimit(
          label: '5h',
          usedPct: 23.5,
          resetsAt: DateTime.fromMillisecondsSinceEpoch(
            1790000000000,
            isUtc: true,
          ),
        ),
      ]);
    });

    test('an older daemon without usage still parses', () {
      final parsed = parse('{"sessionId":"s","cwd":"/w/app","state":"ended"}');
      expect(parsed.usage, isNull);
      expect(parsed.kind, 'claude');
      expect(parsed.projectLabel, 'app');
      expect(parse('{"sessionId":"s","usage":{}}').usage, isNull);
      expect(
        parse(
          '{"sessionId":"s","usage":{"contextUsedPct":180}}',
        ).usage!.contextUsedPct,
        100,
      );
    });
  });

  group('notification level', () {
    test('maps the legacy flags', () {
      AgentNotifyLevel level(bool input, bool finished) =>
          AgentNotifyLevel.fromFlags(input: input, finished: finished);
      expect(level(true, true), AgentNotifyLevel.all);
      expect(level(true, false), AgentNotifyLevel.approvalsAndErrors);
      expect(level(false, false), AgentNotifyLevel.none);
      // Input off muted approvals; keep them muted.
      expect(level(false, true), AgentNotifyLevel.none);
    });

    test('is stored as the legacy flags and round-trips', () {
      final host = buildHost('h');
      expect(host.agentNotifyLevel, AgentNotifyLevel.all);
      for (final value in AgentNotifyLevel.values) {
        final updated = host.copyWith(agentNotifyLevel: value);
        expect(updated.agentNotifyLevel, value);
        expect(SavedHost.fromJson(updated.toJson()).agentNotifyLevel, value);
      }
      final json = host
          .copyWith(agentNotifyLevel: AgentNotifyLevel.approvalsAndErrors)
          .toJson();
      expect(json['agentNotifyInput'], isTrue);
      expect(json['agentNotifyFinished'], isFalse);
    });

    group('controller', () {
      AgentCommandResult herdr(String state) => AgentCommandResult(
        stdout: '[{"name": "builder", "state": "$state"}]',
        stderr: '',
        exitCode: 0,
      );
      AgentCommandResult companion(String state, {bool pending = false}) =>
          AgentCommandResult(
            stdout:
                '{"version":1,"seq":1,"agents":[{"sessionId":"s","cwd":"/a",'
                '"state":"$state","pending":[${pending ? '{"id":"r1",'
                          '"toolName":"Bash","summary":"ls"}' : ''}]}]}',
            stderr: '',
            exitCode: 0,
          );

      Future<RecordingAgentNotifier> run(
        AgentNotifyLevel level,
        List<AgentCommandResult> script, {
        bool useCompanion = false,
      }) async {
        final workspace = TerminalWorkspaceController(
          ImmediateTerminalRepository(TrackableTerminalSession()),
        );
        final notifier = RecordingAgentNotifier();
        final controller = AgentAttentionController(
          workspace: workspace,
          runnerFactory: (_) => ScriptedAgentCommandRunner(script),
          provider: useCompanion
              ? const ConductoreHostAttentionProvider()
              : const HerdrAttentionProvider(),
          notifier: notifier,
          // The machine levels, under the "Everything" mode.
          notificationPreferences: MemoryAgentNotificationPreferencesStore(
            const AgentNotificationPreferences(
              mode: AgentNotificationMode.everything,
            ),
          ),
          pollInterval: const Duration(days: 1),
        );
        controller.setAppForeground(false);
        addTearDown(controller.dispose);
        addTearDown(workspace.dispose);
        final host = buildHost(
          'h',
        ).copyWith(agentAttentionEnabled: true, agentNotifyLevel: level);
        await workspace.open(host).connect();
        await pumpEventQueue();
        for (var i = 1; i < script.length; i++) {
          await controller.pollNow('h');
        }
        return notifier;
      }

      test('All notifies waiting and finished agents', () async {
        final notifier = await run(AgentNotifyLevel.all, [
          herdr('working'),
          herdr('blocked'),
          herdr('done'),
        ]);
        expect(
          [for (final alert in notifier.alerts) alert.need],
          [AgentNeed.question, AgentNeed.finished],
        );
      });

      test('Approvals and errors keeps finished agents quiet', () async {
        final notifier = await run(AgentNotifyLevel.approvalsAndErrors, [
          herdr('working'),
          herdr('blocked'),
          herdr('done'),
          herdr('idle'),
          herdr('working'),
        ]);
        expect(
          [for (final alert in notifier.alerts) alert.need],
          [AgentNeed.question],
        );
        // The finished turn does not notify: the question's notification
        // goes away.
        expect(notifier.agents, isEmpty);
      });

      test('Approvals and errors still posts permission requests', () async {
        final notifier = await run(AgentNotifyLevel.approvalsAndErrors, [
          companion('working'),
          companion('needs_permission', pending: true),
        ], useCompanion: true);
        expect(notifier.alerts.single.need, AgentNeed.approval);
      });

      test('None posts nothing, approvals included', () async {
        final notifier = await run(AgentNotifyLevel.none, [
          companion('working'),
          companion('needs_permission', pending: true),
          companion('ended'),
        ], useCompanion: true);
        expect(notifier.agentPosts, isEmpty);
      });
    });
  });
}
