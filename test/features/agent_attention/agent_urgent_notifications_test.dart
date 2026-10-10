import 'dart:convert';

import 'package:conduit/features/agent_attention/data/conductore_host_attention_provider.dart';
import 'package:conduit/features/agent_attention/data/herdr_attention_provider.dart';
import 'package:conduit/features/agent_attention/data/platform_agent_notifier.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention_notifier.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/agent_attention/domain/agent_notifications.dart';
import 'package:conduit/features/agent_attention/domain/agent_permission_actions.dart';
import 'package:conduit/features/agent_attention/domain/agent_urgent_notifications.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/agent_attention/presentation/agent_notification_settings.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

PendingPermissionRequest _request(
  String id, {
  String tool = 'Bash',
  String summary = 'npm test',
  PermissionRiskLevel? risk,
  List<PendingQuestion> questions = const [],
}) => PendingPermissionRequest(
  id: id,
  toolName: tool,
  summary: summary,
  risk: risk == null ? null : PermissionRisk(risk, ''),
  questions: questions,
);

PendingQuestion _choice(int options, {bool multi = false}) => PendingQuestion(
  question: 'Which database?',
  multiSelect: multi,
  options: [
    for (var i = 0; i < options; i++) PendingQuestionOption(label: 'DB $i'),
  ],
);

AgentInfo _agent({
  String id = 's-1',
  AgentAttentionState state = AgentAttentionState.needsInput,
  List<PendingPermissionRequest> pending = const [],
  String? lastMessage,
  String? lastEvent,
  String? lastToolName,
  String? lastError,
  String kind = 'claude',
  String project = 'api',
}) => AgentInfo(
  id: id,
  name: 'agent',
  project: project,
  kind: kind,
  state: state,
  pendingRequests: pending,
  lastMessage: lastMessage,
  lastEvent: lastEvent,
  lastToolName: lastToolName,
  lastError: lastError,
);

const _defaults = AgentNotificationPreferences();

void main() {
  group('what a waiting agent waits for', () {
    AgentWaitKind kind(AgentInfo agent, {bool companion = true}) =>
        UrgentNotificationPolicy.waitKind(agent, companion: companion);

    test('a turn that ended is not a question', () {
      expect(
        kind(_agent(lastEvent: 'Stop', lastMessage: 'All tests pass.')),
        AgentWaitKind.turnEnded,
      );
      expect(kind(_agent()), AgentWaitKind.turnEnded);
    });

    test('a question tool, a last line that asks, or a prompt that timed '
        'out into the terminal is a question', () {
      expect(
        kind(_agent(lastEvent: 'PreToolUse', lastToolName: 'AskUserQuestion')),
        AgentWaitKind.question,
      );
      expect(
        kind(
          _agent(
            lastEvent: 'Stop',
            lastMessage: 'Done with the parser.\nShould I also fix the lexer?',
          ),
        ),
        AgentWaitKind.question,
      );
      expect(
        kind(_agent(lastEvent: 'PermissionRequest')),
        AgentWaitKind.question,
      );
      // After Stop the question tool is history.
      expect(
        kind(_agent(lastEvent: 'Stop', lastToolName: 'AskUserQuestion')),
        AgentWaitKind.turnEnded,
      );
    });

    test('an API error, or Herdr\'s blocked, is an error; Herdr\'s waiting '
        'is a question', () {
      expect(
        kind(_agent(lastEvent: 'StopFailure', lastError: 'rate_limit')),
        AgentWaitKind.error,
      );
      expect(
        kind(_agent(state: AgentAttentionState.blocked)),
        AgentWaitKind.error,
      );
      expect(kind(_agent(), companion: false), AgentWaitKind.question);
    });
  });

  group('urgent policy: which alert an agent has', () {
    AgentNeed? need(
      AgentInfo agent, {
      AgentNotice? previous,
      bool entered = true,
      AgentAttentionState? previousState = AgentAttentionState.working,
      bool initial = false,
      bool companion = true,
      String? stuck,
      AgentNotifyLevel level = AgentNotifyLevel.all,
      AgentNotificationPreferences preferences = _defaults,
    }) => UrgentNotificationPolicy.needFor(
      agent: agent,
      previous: previous,
      entered: entered,
      previousState: previousState,
      ended: false,
      companion: companion,
      initial: initial,
      level: level,
      preferences: preferences,
      stuckReason: stuck,
    );

    test('permission requests and questions are urgent', () {
      expect(need(_agent(pending: [_request('r1')])), AgentNeed.approval);
      expect(
        need(_agent(lastEvent: 'Stop', lastMessage: 'Which branch?')),
        AgentNeed.question,
      );
    });

    test('a finished turn only alerts when opted in', () {
      final done = _agent(lastEvent: 'Stop', lastMessage: 'All green.');
      expect(need(done), isNull);
      expect(
        need(_agent(state: AgentAttentionState.idle)),
        isNull,
        reason: 'idle after work',
      );
      final optedIn = _defaults.copyWith(finishedAlerts: true);
      expect(need(done, preferences: optedIn), AgentNeed.finished);
      // The machine's level still applies.
      expect(
        need(
          done,
          preferences: optedIn,
          level: AgentNotifyLevel.approvalsAndErrors,
        ),
        isNull,
      );
    });

    test('an error is urgent', () {
      expect(
        need(_agent(lastEvent: 'StopFailure', lastError: 'overloaded')),
        AgentNeed.error,
      );
      expect(
        need(
          _agent(lastError: 'overloaded'),
          preferences: _defaults.copyWith(errors: false),
        ),
        isNull,
      );
    });

    test('a stuck flag alerts while working or after a quiet finish', () {
      const reason = '`npm test` failed 3 times';
      expect(
        need(_agent(state: AgentAttentionState.working), stuck: reason),
        AgentNeed.stuck,
      );
      expect(need(_agent(lastEvent: 'Stop'), stuck: reason), AgentNeed.stuck);
      expect(
        need(
          _agent(state: AgentAttentionState.working),
          stuck: reason,
          preferences: _defaults.copyWith(stuck: false),
        ),
        isNull,
      );
      // A pending request outranks it.
      expect(
        need(_agent(pending: [_request('r1')]), stuck: reason),
        AgentNeed.approval,
      );
      // The "Everything" mode has no stuck alert.
      expect(
        need(
          _agent(state: AgentAttentionState.working),
          stuck: reason,
          preferences: _defaults.copyWith(
            mode: AgentNotificationMode.everything,
          ),
        ),
        isNull,
      );
    });

    test('a question stays until it is answered; it is not re-entered on '
        'every poll', () {
      final asking = _agent(lastEvent: 'Stop', lastMessage: 'Which branch?');
      expect(
        need(
          asking,
          entered: false,
          previous: const AgentNotice(need: AgentNeed.question),
        ),
        AgentNeed.question,
      );
      // Seen asking before monitoring of this need started: no alert.
      expect(need(asking, entered: false), isNull);
    });

    test('a request that timed out into the terminal keeps asking', () {
      expect(
        need(
          _agent(lastMessage: 'Permission prompt is waiting in the terminal'),
          previous: const AgentNotice(
            need: AgentNeed.approval,
            requestIds: {'r1'},
          ),
        ),
        AgentNeed.question,
      );
    });
  });

  group('urgent policy: alert or update silently', () {
    bool alert({
      AgentNotice? previous,
      required AgentNeed need,
      Set<String> requestIds = const {},
      bool entered = false,
      bool initial = false,
    }) => UrgentNotificationPolicy.shouldAlert(
      previous: previous,
      need: need,
      requestIds: requestIds,
      entered: entered,
      quietUpdates: true,
      initial: initial,
    );

    test('a new urgent state alerts once', () {
      expect(alert(need: AgentNeed.question), isTrue);
      expect(
        alert(
          previous: const AgentNotice(need: AgentNeed.question),
          need: AgentNeed.question,
        ),
        isFalse,
      );
      // Asked again between two polls (a new state sequence).
      expect(
        alert(
          previous: const AgentNotice(need: AgentNeed.question),
          need: AgentNeed.question,
          entered: true,
        ),
        isTrue,
      );
    });

    test('a switch to another urgent state alerts, except approval and '
        'question, which are the same ask', () {
      expect(
        alert(
          previous: const AgentNotice(need: AgentNeed.question),
          need: AgentNeed.error,
        ),
        isTrue,
      );
      expect(
        alert(
          previous: const AgentNotice(
            need: AgentNeed.approval,
            requestIds: {'r1'},
          ),
          need: AgentNeed.question,
        ),
        isFalse,
      );
    });

    test('stuck alerts once until it clears', () {
      expect(alert(need: AgentNeed.stuck), isTrue);
      expect(
        alert(
          previous: const AgentNotice(need: AgentNeed.stuck),
          need: AgentNeed.stuck,
          entered: true,
        ),
        isFalse,
      );
    });

    test('approvals: a new batch alerts, a growing one is quiet', () {
      const before = AgentNotice(need: AgentNeed.approval, requestIds: {'r1'});
      expect(
        alert(
          previous: before,
          need: AgentNeed.approval,
          requestIds: {'r1', 'r2'},
        ),
        isFalse,
      );
      expect(
        alert(previous: before, need: AgentNeed.approval, requestIds: {'r2'}),
        isTrue,
      );
    });

    test('the first snapshot carries everything but approvals over '
        'silently', () {
      expect(alert(need: AgentNeed.question, initial: true), isFalse);
      expect(alert(need: AgentNeed.approval, initial: true), isTrue);
    });
  });

  group('urgent alert actions', () {
    AgentNotification build(
      AgentInfo agent, {
      AgentNeed need = AgentNeed.approval,
      bool canReply = true,
      AgentNotificationPreferences preferences = _defaults,
      String? stuck,
    }) => UrgentNotificationPolicy.build(
      hostId: 'h',
      hostName: 'VTM',
      agent: agent,
      need: need,
      alert: true,
      preferences: preferences,
      open: const AgentOpenTarget(hostId: 'h', agentId: 's-1'),
      canReply: canReply,
      stuckReason: stuck,
    );

    test('a low-risk approval gets Allow, Deny and Open; no Always', () {
      final n = build(
        _agent(pending: [_request('r1', risk: PermissionRiskLevel.low)]),
      );
      expect(n.action?.requestId, 'r1');
      expect(n.action?.allowAlways, isFalse);
      expect(n.openButton, isTrue);
      expect(n.reviewAll, isFalse);
      expect(n.reply, isFalse);
    });

    test('several approvals: Allow and Deny for the first, Review all', () {
      final n = build(_agent(pending: [_request('r1'), _request('r2')]));
      expect(n.action?.requestId, 'r1');
      expect(n.reviewAll, isTrue);
      expect(n.openButton, isFalse);
    });

    test('a high-risk approval, or one only the terminal answers, only '
        'opens', () {
      final n = build(
        _agent(pending: [_request('r1', risk: PermissionRiskLevel.high)]),
      );
      expect(n.action, isNull);
      expect(n.openButton, isTrue);
      final terminal = build(
        _agent(
          pending: const [
            PendingPermissionRequest(
              id: 'r1',
              toolName: 'run_shell_command',
              summary: 'ls',
              terminalOnly: true,
            ),
          ],
        ),
      );
      expect(terminal.action, isNull);
      expect(terminal.openButton, isTrue);
    });

    test('a single-choice question with up to three options gets its '
        'answers', () {
      final question = _request(
        'q1',
        tool: PendingPermissionRequest.questionTool,
        questions: [_choice(3)],
      );
      final n = build(_agent(pending: [question]));
      expect(n.answers, ['DB 0', 'DB 1', 'DB 2']);
      expect(n.question, 'Which database?');
      expect(n.action?.requestId, 'q1');
      expect(n.openButton, isFalse);
      expect(n.toArguments()['answers'], ['DB 0', 'DB 1', 'DB 2']);
    });

    test('other questions only open', () {
      for (final questions in [
        [_choice(4)],
        [_choice(2, multi: true)],
        [_choice(2), _choice(2)],
        const <PendingQuestion>[],
      ]) {
        final n = build(
          _agent(
            pending: [
              _request(
                'q1',
                tool: PendingPermissionRequest.questionTool,
                questions: questions,
              ),
            ],
          ),
        );
        expect(n.answers, isEmpty);
        expect(n.action, isNull);
        expect(n.openButton, isTrue);
      }
    });

    test('a question in its text, an error or a stuck agent: Reply and '
        'Open', () {
      final asking = build(
        _agent(lastEvent: 'Stop', lastMessage: 'Which branch?'),
        need: AgentNeed.question,
      );
      expect(asking.reply, isTrue);
      expect(asking.openButton, isTrue);
      expect(asking.action, isNull);

      final stuck = build(
        _agent(state: AgentAttentionState.working),
        need: AgentNeed.stuck,
        stuck: 'Ran `npm test` 6 times',
      );
      expect(stuck.title, 'api · VTM looks stuck');
      expect(stuck.text, 'Ran `npm test` 6 times');
      expect(stuck.reply, isTrue);

      // An agent that cannot take a prompt has no Reply.
      expect(
        build(_agent(), need: AgentNeed.error, canReply: false).reply,
        isFalse,
      );
    });

    test('"Summary only" leaves only Open', () {
      final summary = _defaults.copyWith(summaryOnly: true);
      final approval = build(
        _agent(pending: [_request('r1')]),
        preferences: summary,
      );
      expect(approval.action, isNull);
      expect(approval.openButton, isTrue);
      final asking = build(
        _agent(lastMessage: 'Which branch?'),
        need: AgentNeed.question,
        preferences: summary,
      );
      expect(asking.reply, isFalse);
    });
  });

  group('ongoing status', () {
    AgentStatusEntry entry(
      AgentInfo agent, {
      String host = 'VTM',
      String? detail,
      String? stuck,
    }) => (
      machineId: host,
      hostName: host,
      agent: agent,
      companion: true,
      detail: detail,
      stuck: stuck,
    );

    test('lists every agent compactly, most urgent first', () {
      final status = AgentStatusSummary.build([
        entry(
          _agent(
            id: 'a',
            project: 'web',
            state: AgentAttentionState.working,
            lastToolName: 'Bash',
          ),
        ),
        entry(
          _agent(
            id: 'b',
            project: 'docs',
            lastEvent: 'Stop',
            lastMessage: 'Rewrote the intro.',
          ),
        ),
        entry(
          _agent(
            id: 'c',
            kind: 'codex',
            pending: [_request('r1', summary: 'git push')],
          ),
        ),
        entry(
          _agent(id: 'd', project: 'cli', state: AgentAttentionState.working),
          stuck: '`npm test` failed 3 times',
        ),
      ])!;
      // A stuck agent counts under its state; the line says why.
      expect(status.title, '1 needs you · 2 working · 1 idle');
      expect(status.lines, [
        'api (Codex) · Needs you · Approve Bash: git push',
        'web · Working · Bash',
        'cli · Stuck · `npm test` failed 3 times',
        'docs · Idle · Rewrote the intro.',
      ]);
      expect(status.text, status.lines.first);
      expect(status.publicTitle, 'Conductore: 4 agents');
      expect(status.needsYou, 1);
    });

    test('names the machine when there are several, caps the lines', () {
      final status = AgentStatusSummary.build([
        for (var i = 0; i < 8; i++)
          entry(
            _agent(
              id: 'a$i',
              project: 'p$i',
              state: AgentAttentionState.working,
            ),
            host: i.isEven ? 'VTM' : 'Laptop',
            detail: 'x' * 100,
          ),
      ])!;
      expect(status.lines, hasLength(AgentStatusSummary.maxLines));
      expect(status.lines.first, startsWith('p0 · Working · xxx'));
      expect(status.lines.first, endsWith('… (VTM)'));
      expect(status.lines.last, '+3 more');
    });

    test('no agents: no status', () {
      expect(AgentStatusSummary.build(const []), isNull);
    });
  });

  group('status throttle', () {
    const one = AgentOngoingStatus(
      title: '1 working',
      text: 'a',
      lines: ['a'],
      publicTitle: 'Conductore: 1 agent',
    );
    const two = AgentOngoingStatus(
      title: '2 working',
      text: 'a',
      lines: ['a', 'b'],
      publicTitle: 'Conductore: 2 agents',
    );
    final t0 = DateTime(2026, 10, 4, 12);

    test('posts at most once per interval, the latest winning', () {
      final throttle = AgentStatusThrottle();
      expect(throttle.offer(one, t0).post, isTrue);
      throttle.posted(one, t0);
      // Unchanged: nothing to do.
      expect(
        throttle.offer(one, t0.add(const Duration(seconds: 1))).post,
        isFalse,
      );
      // Changed too soon: wait for the rest of the interval.
      final soon = throttle.offer(two, t0.add(const Duration(seconds: 2)));
      expect(soon.post, isFalse);
      expect(soon.retryAfter, const Duration(seconds: 3));
      expect(
        throttle.offer(two, t0.add(const Duration(seconds: 5))).post,
        isTrue,
      );
    });

    test('clearing is never held back; an unchanged status is refreshed', () {
      final throttle = AgentStatusThrottle();
      throttle.posted(one, t0);
      expect(
        throttle.offer(null, t0.add(const Duration(seconds: 1))).post,
        isTrue,
      );
      expect(
        throttle.offer(one, t0.add(const Duration(minutes: 10))).post,
        isTrue,
      );
    });
  });

  group('controller', () {
    AgentCommandResult ok(String stdout) =>
        AgentCommandResult(stdout: stdout, stderr: '', exitCode: 0);
    final version = ok('{"version":"0.1.0"}');
    AgentCommandResult status(
      String state, {
      String lastEvent = 'Stop',
      String? lastMessage,
      String pending = '',
      int stateSeq = 1,
    }) => ok(
      jsonEncode({
        'version': 1,
        'seq': stateSeq,
        'agents': [
          {
            'sessionId': 's-1',
            'cwd': '/w/api',
            'state': state,
            'lastEvent': lastEvent,
            'stateSeq': stateSeq,
            'lastMessage': ?lastMessage,
            'pending': [if (pending.isNotEmpty) jsonDecode(pending)],
          },
        ],
      }),
    );

    Future<
      (
        AgentAttentionController,
        RecordingAgentNotifier,
        ScriptedAgentCommandRunner,
      )
    >
    run(
      List<Object> script, {
      AgentNotificationPreferences preferences = _defaults,
    }) async {
      final workspace = TerminalWorkspaceController(FreshTerminalRepository());
      final notifier = RecordingAgentNotifier();
      final runner = ScriptedAgentCommandRunner(script);
      final controller = AgentAttentionController(
        workspace: workspace,
        runnerFactory: (_) => runner,
        provider: const HerdrAttentionProvider(),
        companionProvider: const ConductoreHostAttentionProvider(),
        notifier: notifier,
        notificationPreferences: MemoryAgentNotificationPreferencesStore(
          preferences,
        ),
        statusThrottle: AgentStatusThrottle(interval: Duration.zero),
        pollInterval: const Duration(days: 1),
      );
      controller.setLongPoll(false);
      addTearDown(controller.dispose);
      addTearDown(workspace.dispose);
      await workspace
          .open(buildHost('h').copyWith(agentAttentionEnabled: true))
          .connect();
      await pumpEventQueue();
      return (controller, notifier, runner);
    }

    test('a turn that ends updates the ongoing status, no alert', () async {
      final (controller, notifier, _) = await run([
        version,
        status('working', lastEvent: 'PreToolUse'),
        status('waiting_input', lastMessage: 'All green.', stateSeq: 2),
      ]);
      expect(notifier.status?.lines, ['api · Working']);
      await controller.pollNow('h');
      expect(notifier.alerts, isEmpty);
      expect(notifier.agents, isEmpty);
      expect(notifier.status?.lines, ['api · Idle · All green.']);
    });

    test('a question alerts once, with Reply; answered, it goes', () async {
      final (controller, notifier, _) = await run([
        version,
        status('working', lastEvent: 'PreToolUse'),
        status('waiting_input', lastMessage: 'Which branch?', stateSeq: 2),
        status('waiting_input', lastMessage: 'Which branch?', stateSeq: 2),
        status('working', lastEvent: 'UserPromptSubmit', stateSeq: 3),
      ]);
      await controller.pollNow('h');
      await controller.pollNow('h');
      final asked = notifier.alerts.single;
      expect(asked.need, AgentNeed.question);
      expect(asked.reply, isTrue);
      expect(asked.openButton, isTrue);
      await controller.pollNow('h');
      expect(notifier.agents, isEmpty);
    });

    test('a muted agent never alerts; the status still lists it', () async {
      final (controller, notifier, _) = await run([
        version,
        status('working', lastEvent: 'PreToolUse'),
        status(
          'needs_permission',
          lastEvent: 'PermissionRequest',
          pending: '{"id":"r1","toolName":"Bash","summary":"ls"}',
        ),
      ], preferences: _defaults.withMuted('h', 's-1', muted: true));
      expect(controller.isAgentMuted('h', 's-1'), isTrue);
      await controller.pollNow('h');
      expect(notifier.agentPosts, isEmpty);
      expect(notifier.status?.lines.single, startsWith('api · Needs you'));

      await controller.setAgentMuted('h', 's-1', muted: false);
      expect(notifier.agents.values.single.need, AgentNeed.approval);
    });

    test('a stuck flag from the dashboard alerts once', () async {
      final (controller, notifier, _) = await run([
        version,
        status('working', lastEvent: 'PostToolUse'),
      ]);
      String? reason;
      controller.stuckReasonFor = (hostId, agentId) => reason;
      await controller.resyncNotifications();
      expect(notifier.agentPosts, isEmpty);

      reason = 'Ran `npm test` 6 times';
      await controller.resyncNotifications();
      await controller.resyncNotifications();
      final stuck = notifier.alerts.single;
      expect(stuck.need, AgentNeed.stuck);
      expect(stuck.text, 'Ran `npm test` 6 times');
      expect(notifier.status?.lines.single, contains('Stuck'));

      reason = null;
      await controller.resyncNotifications();
      expect(notifier.agents, isEmpty);
    });

    test('"Urgent only" has no ongoing status; "Everything" neither', () async {
      final (controller, notifier, _) = await run([
        version,
        status('working', lastEvent: 'PreToolUse'),
      ]);
      expect(notifier.status, isNotNull);
      await controller.setNotificationPreferences(
        _defaults.copyWith(mode: AgentNotificationMode.urgentOnly),
      );
      expect(notifier.status, isNull);
    });

    test('Reply types the text into the agent and clears the alert', () async {
      final (controller, notifier, runner) = await run([
        version,
        status('working', lastEvent: 'PreToolUse'),
        status('waiting_input', lastMessage: 'Which branch?', stateSeq: 2),
        ok('{"ok":true}'),
        status('working', lastEvent: 'UserPromptSubmit', stateSeq: 3),
      ]);
      await controller.pollNow('h');
      expect(notifier.agents, hasLength(1));

      await controller.completePermissionAction(
        const AgentPermissionAction(
          notificationId: 'agent:h:s-1',
          hostId: 'h',
          agentId: 's-1',
          requestId: 'reply',
          verdict: AgentPermissionAction.replyVerdict,
          text: 'Use main, and flag anything odd',
        ),
        buildHost('h').copyWith(agentAttentionEnabled: true),
      );
      final send = runner.commands[3];
      expect(send, contains('send s-1 --text-b64 '));
      expect(
        send,
        contains(base64.encode(utf8.encode('Use main, and flag anything odd'))),
      );
      expect(notifier.agentCancelled, contains('agent:h:s-1'));
      expect(runner.closeCount, 0);
    });

    test('a failed Reply says so on the agent\'s notification', () async {
      final (controller, notifier, _) = await run([
        version,
        status('waiting_input', lastMessage: 'Which branch?'),
        const AgentCommandResult(
          stdout: '{"error":"session not in tmux or Herdr"}',
          stderr: '',
          exitCode: 1,
        ),
      ]);
      await controller.completePermissionAction(
        const AgentPermissionAction(
          notificationId: 'agent:h:s-1',
          hostId: 'h',
          agentId: 's-1',
          requestId: 'reply',
          verdict: AgentPermissionAction.replyVerdict,
          text: 'go on',
        ),
        buildHost('h').copyWith(agentAttentionEnabled: true),
      );
      final failed = notifier.agents['agent:h:s-1']!;
      expect(failed.title, 'Reply not sent');
      expect(failed.alert, isTrue);
    });

    test('an answer button answers the question through decide', () async {
      final question = jsonEncode({
        'id': 'q1',
        'toolName': 'AskUserQuestion',
        'summary': 'Which database?',
        'questions': [
          {
            'question': 'Which database?',
            'options': [
              {'label': 'Postgres'},
              {'label': 'SQLite'},
            ],
          },
        ],
      });
      final (controller, notifier, runner) = await run([
        version,
        status(
          'needs_permission',
          lastEvent: 'PermissionRequest',
          pending: question,
        ),
        ok('{"ok":true}'),
        status('working', lastEvent: 'PostToolUse', stateSeq: 2),
      ]);
      final posted = notifier.agents.values.single;
      expect(posted.answers, ['Postgres', 'SQLite']);

      await controller.completePermissionAction(
        const AgentPermissionAction(
          notificationId: 'agent:h:s-1',
          hostId: 'h',
          agentId: 's-1',
          requestId: 'q1',
          verdict: AgentPermissionAction.answerVerdict,
          text: 'SQLite',
          question: 'Which database?',
        ),
        buildHost('h').copyWith(agentAttentionEnabled: true),
      );
      expect(runner.commands[2], contains('decide q1 answer --answers'));
      expect(runner.commands[2], contains('{"Which database?":"SQLite"}'));
    });
  });

  test('the platform hands back answer and reply taps', () {
    expect(
      PlatformAgentPermissionActions.parseActions([
        {
          'notificationId': 'agent:h:s-1',
          'hostId': 'h',
          'agentId': 's-1',
          'requestId': 'q1',
          'verdict': 'answer',
          'text': 'SQLite',
          'question': 'Which database?',
        },
      ]),
      [
        const AgentPermissionAction(
          notificationId: 'agent:h:s-1',
          hostId: 'h',
          agentId: 's-1',
          requestId: 'q1',
          verdict: 'answer',
          text: 'SQLite',
          question: 'Which database?',
        ),
      ],
    );
  });

  group('preferences', () {
    test('default to "Ongoing + urgent"; mode, mutes and the new switches '
        'round-trip', () {
      expect(_defaults.mode, AgentNotificationMode.ongoingAndUrgent);
      final custom = _defaults
          .copyWith(
            mode: AgentNotificationMode.urgentOnly,
            stuck: false,
            finishedAlerts: true,
          )
          .withMuted('h#ws1', 's-1', muted: true);
      expect(custom.mutedAgents, {'h/s-1'});
      expect(custom.isMuted('h', 's-1'), isTrue);
      expect(AgentNotificationPreferences.fromJson(custom.toJson()), custom);
      // Saved before CON-074: the new default mode.
      expect(
        AgentNotificationPreferences.fromJson({'finished': false}).mode,
        AgentNotificationMode.ongoingAndUrgent,
      );
      expect(custom.withMuted('h', 's-1', muted: false).mutedAgents, isEmpty);
    });

    test('mutes are capped, the oldest going first', () {
      var preferences = _defaults;
      for (var i = 0; i <= AgentNotificationPreferences.maxMutedAgents; i++) {
        preferences = preferences.withMuted('h', 's-$i', muted: true);
      }
      expect(
        preferences.mutedAgents,
        hasLength(AgentNotificationPreferences.maxMutedAgents),
      );
      expect(preferences.isMuted('h', 's-0'), isFalse);
    });
  });

  testWidgets('Settings: Notify me, Custom, the details and Unmute all '
      '(CON-108)', (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final workspace = TerminalWorkspaceController(FreshTerminalRepository());
    final store = MemoryAgentNotificationPreferencesStore(
      _defaults.withMuted('h', 's-1', muted: true),
    );
    final controller = AgentAttentionController(
      workspace: workspace,
      runnerFactory: (_) => ScriptedAgentCommandRunner(const []),
      provider: const HerdrAttentionProvider(),
      notificationPreferences: store,
      pollInterval: const Duration(days: 1),
    );
    addTearDown(controller.dispose);
    addTearDown(workspace.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Column(
              children: [
                AgentNotifyChoiceCard(controller: controller),
                AgentNotificationDetailsCard(controller: controller),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final semantics = tester.ensureSemantics();

    /// Only [selected] is checked (none: Custom).
    void expectChecked(AgentNotifyChoice? selected) {
      for (final choice in AgentNotifyChoice.values) {
        expect(
          tester.getSemantics(
            find.byKey(ValueKey('agent-notify-choice-${choice.name}')),
          ),
          isSemantics(isChecked: choice == selected),
          reason: choice.name,
        );
      }
    }

    final custom = find.byKey(const ValueKey('agent-notify-choice-custom'));

    // The default is Urgent only, with the ongoing notification.
    expectChecked(AgentNotifyChoice.urgentOnly);
    expect(custom, findsNothing);
    expect(find.text('Ongoing notification'), findsOne);
    expect(find.text('Also alert when an agent finishes'), findsOne);
    expect(find.text('Stuck or looping'), findsOne);
    expect(find.text('1 muted agent'), findsOne);

    // A detail that matches a choice selects it.
    await tester.tap(
      find.byKey(const ValueKey('agent-notify-finished-alerts')),
    );
    await tester.pump();
    expect(controller.notificationPreferences.finishedAlerts, isTrue);
    expectChecked(AgentNotifyChoice.urgentAndFinished);

    // One that matches none is Custom, and stays as set.
    await tester.tap(find.byKey(const ValueKey('agent-notify-stuck')));
    await tester.pump();
    expect(controller.notificationPreferences.stuck, isFalse);
    expect(custom, findsOne);
    expectChecked(null);

    await tester.tap(find.byKey(const ValueKey('agent-notify-unmute-all')));
    await tester.pump();
    expect(store.value.mutedAgents, isEmpty);
    expect(find.text('1 muted agent'), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey('agent-notify-choice-everything')),
    );
    await tester.pump();
    expect(
      controller.notificationPreferences.mode,
      AgentNotificationMode.everything,
    );
    expect(custom, findsNothing);
    expectChecked(AgentNotifyChoice.everything);
    // "Everything" has its own finished switch, no stuck alerts and no
    // ongoing notification.
    expect(find.text('Notify when an agent finishes'), findsOne);
    expect(find.text('Stuck or looping'), findsNothing);
    expect(find.text('Ongoing notification'), findsNothing);

    // Back to urgent: stuck alerts are on again.
    await tester.tap(
      find.byKey(const ValueKey('agent-notify-choice-urgentOnly')),
    );
    await tester.pump();
    expect(
      controller.notificationPreferences.mode,
      AgentNotificationMode.ongoingAndUrgent,
    );
    expect(controller.notificationPreferences.stuck, isTrue);
    expect(controller.notificationPreferences.finishedAlerts, isFalse);
    semantics.dispose();
  });
}
