import 'package:conduit/features/agent_attention/data/conductore_host_attention_provider.dart';
import 'package:conduit/features/agent_attention/data/herdr_attention_provider.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention_notifier.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/agent_attention/domain/agent_kinds.dart';
import 'package:conduit/features/agent_attention/domain/agent_notifications.dart';
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
  String summary = 'npm test -- due-date',
  PermissionRiskLevel? risk,
  String reason = '',
}) => PendingPermissionRequest(
  id: id,
  toolName: tool,
  summary: summary,
  risk: risk == null ? null : PermissionRisk(risk, reason),
);

AgentInfo _agent({
  AgentAttentionState state = AgentAttentionState.needsInput,
  List<PendingPermissionRequest> pending = const [],
  String? lastMessage,
}) => AgentInfo(
  id: 's-1',
  name: 'claude',
  project: 'api',
  state: state,
  pendingRequests: pending,
  lastMessage: lastMessage,
);

/// The "Everything" mode: one notification per agent for every need, as
/// before CON-074.
const _everything = AgentNotificationPreferences(
  mode: AgentNotificationMode.everything,
);

void main() {
  group('policy: what the agent needs', () {
    AgentNeed? need(
      AgentInfo agent, {
      AgentNotice? previous,
      bool entered = true,
      AgentAttentionState? previousState = AgentAttentionState.working,
      bool ended = false,
      bool initial = false,
      AgentNotifyLevel level = AgentNotifyLevel.all,
      AgentNotificationPreferences preferences = _everything,
    }) => AgentNotificationPolicy.needFor(
      agent: agent,
      previous: previous,
      entered: entered,
      previousState: previousState,
      ended: ended,
      initial: initial,
      level: level,
      preferences: preferences,
    );

    test('pending requests are an approval, whenever they are seen', () {
      final agent = _agent(pending: [_request('r1')]);
      expect(need(agent, entered: false), AgentNeed.approval);
      expect(need(agent, initial: true, entered: false), AgentNeed.approval);
    });

    test('a question or an error notifies when entered', () {
      expect(need(_agent()), AgentNeed.question);
      expect(need(_agent(state: AgentAttentionState.blocked)), AgentNeed.error);
      // Unchanged since the last poll and nothing showing: nothing new.
      expect(need(_agent(), entered: false), isNull);
    });

    test('a timed-out approval turns into a question', () {
      const notice = AgentNotice(need: AgentNeed.approval, requestIds: {'r1'});
      expect(
        need(_agent(), previous: notice, entered: false),
        AgentNeed.question,
      );
    });

    test('a finished turn needs the agent to have been busy', () {
      final idle = _agent(state: AgentAttentionState.idle);
      expect(need(idle), AgentNeed.finished);
      expect(need(idle, previousState: AgentAttentionState.idle), isNull);
      // It stays until the agent works again.
      expect(
        need(
          idle,
          entered: false,
          previous: const AgentNotice(need: AgentNeed.finished),
        ),
        AgentNeed.finished,
      );
      expect(
        need(
          _agent(state: AgentAttentionState.working),
          previous: const AgentNotice(need: AgentNeed.finished),
        ),
        isNull,
      );
    });

    test('an ended agent needs nothing', () {
      expect(need(_agent(pending: [_request('r1')]), ended: true), isNull);
    });

    test('the first snapshot carries every need over', () {
      expect(need(_agent(), initial: true, entered: false), AgentNeed.question);
      expect(
        need(
          _agent(state: AgentAttentionState.idle),
          initial: true,
          entered: false,
          previousState: null,
        ),
        AgentNeed.finished,
      );
    });

    test('settings and the machine level filter events', () {
      const off = AgentNotificationPreferences(
        mode: AgentNotificationMode.everything,
        approvals: false,
        questions: false,
        finished: false,
        errors: false,
      );
      expect(need(_agent(pending: [_request('r1')]), preferences: off), isNull);
      expect(need(_agent(), preferences: off), isNull);
      expect(
        need(_agent(state: AgentAttentionState.blocked), preferences: off),
        isNull,
      );
      expect(
        need(_agent(state: AgentAttentionState.idle), preferences: off),
        isNull,
      );
      expect(
        need(
          _agent(state: AgentAttentionState.idle),
          level: AgentNotifyLevel.approvalsAndErrors,
        ),
        isNull,
      );
      expect(
        need(_agent(pending: [_request('r1')]), level: AgentNotifyLevel.none),
        isNull,
      );
    });
  });

  group('policy: alert or update silently', () {
    bool alert({
      AgentNotice? previous,
      AgentNeed need = AgentNeed.approval,
      Set<String> ids = const {'r1'},
      bool entered = false,
      bool quietUpdates = true,
      bool initial = false,
    }) => AgentNotificationPolicy.shouldAlert(
      previous: previous,
      need: need,
      requestIds: ids,
      entered: entered,
      quietUpdates: quietUpdates,
      initial: initial,
    );

    const one = AgentNotice(need: AgentNeed.approval, requestIds: {'r1'});

    test('a new need alerts', () {
      expect(alert(), isTrue);
      expect(alert(need: AgentNeed.question), isTrue);
      expect(alert(need: AgentNeed.finished), isTrue);
    });

    test('the same need unchanged never alerts', () {
      expect(alert(previous: one), isFalse);
    });

    test('another request while one waits updates silently', () {
      expect(alert(previous: one, ids: {'r1', 'r2'}), isFalse);
      // Unless quiet updates are off.
      expect(
        alert(previous: one, ids: {'r1', 'r2'}, quietUpdates: false),
        isTrue,
      );
    });

    test('a new request after the previous one was answered alerts', () {
      expect(alert(previous: one, ids: {'r2'}), isTrue);
    });

    test('moving within "needs you" is silent', () {
      expect(alert(previous: one, need: AgentNeed.question, ids: {}), isFalse);
      expect(
        alert(
          previous: const AgentNotice(need: AgentNeed.question),
          ids: {'r1'},
        ),
        isFalse,
      );
    });

    test('finishing and needing you again alert', () {
      expect(alert(previous: one, need: AgentNeed.finished, ids: {}), isTrue);
      expect(
        alert(previous: const AgentNotice(need: AgentNeed.finished)),
        isTrue,
      );
    });

    test('a question asked again between two polls alerts', () {
      const asked = AgentNotice(need: AgentNeed.question);
      expect(alert(previous: asked, need: AgentNeed.question), isFalse);
      expect(
        alert(previous: asked, need: AgentNeed.question, entered: true),
        isTrue,
      );
    });

    test('the first snapshot alerts for approvals only', () {
      expect(alert(initial: true), isTrue);
      expect(alert(initial: true, need: AgentNeed.question), isFalse);
      expect(alert(initial: true, need: AgentNeed.finished), isFalse);
    });
  });

  group('summary text', () {
    AgentNotification build(
      AgentInfo agent, {
      AgentNeed need = AgentNeed.approval,
      AgentNotificationPreferences preferences =
          const AgentNotificationPreferences(),
      String? detail,
    }) => AgentNotificationPolicy.build(
      hostId: 'h',
      hostName: 'VTM',
      agent: agent,
      need: need,
      alert: true,
      preferences: preferences,
      open: const AgentOpenTarget(hostId: 'h', agentId: 's-1'),
      detail: detail,
    );

    test('a Codex approval says it is Codex and keeps its buttons', () {
      final codex = AgentInfo(
        id: 's-1',
        name: 'repo',
        project: 'api',
        kind: 'codex',
        state: AgentAttentionState.needsInput,
        pendingRequests: [
          _request('r1', risk: PermissionRiskLevel.low, reason: 'Tests'),
        ],
      );
      final notification = build(codex);
      expect(notification.title, 'api (Codex) · VTM needs you');
      expect(notification.publicTitle, 'Conductore: api (Codex) needs you');
      expect(notification.action?.requestId, 'r1');
      // Claude Code's titles are unchanged (the test below).
      expect(otherAgentKindName('claude'), isNull);
      expect(otherAgentKindName(''), isNull);
      expect(otherAgentKindName('Codex'), 'Codex');
    });

    test('one approval: title, the item with its risk, one set of '
        'buttons', () {
      final notification = build(
        _agent(
          pending: [
            _request('r1', risk: PermissionRiskLevel.low, reason: 'Tests'),
          ],
        ),
      );
      expect(notification.key, 'agent:h:s-1');
      expect(notification.title, 'api · VTM needs you');
      expect(
        notification.text,
        'Approve Bash: npm test -- due-date · Low risk',
      );
      expect(notification.publicTitle, 'Conductore: api needs you');
      expect(notification.lines, [
        'Approve Bash: npm test -- due-date · Low risk',
        '  Tests',
      ]);
      expect(
        notification.action,
        const AgentNotificationAction(requestId: 'r1', allowAlways: true),
      );
      expect(notification.reviewAll, isFalse);
    });

    // CON-062: a question's Allow did nothing (Claude Code waits for the
    // answers): no buttons, the tap opens the question instead.
    test('a question: its text, no Allow / Deny buttons', () {
      final notification = build(
        _agent(
          pending: [
            const PendingPermissionRequest(
              id: 'q1',
              toolName: 'AskUserQuestion',
              summary: 'Which DB?',
              questions: [PendingQuestion(question: 'Which DB?')],
            ),
          ],
        ),
      );
      expect(notification.text, 'Question: Which DB?');
      expect(notification.action, isNull);
      expect(notification.reviewAll, isFalse);
    });

    test('several: the first item, "+N more", up to five lines, Review '
        'all', () {
      final notification = build(
        _agent(
          pending: [
            for (var i = 1; i <= 7; i++)
              _request(
                'r$i',
                summary: 'cmd $i',
                risk: i == 1 ? PermissionRiskLevel.high : null,
              ),
          ],
        ),
        detail: 'Fixing the due-date tests',
      );
      expect(notification.text, 'Approve Bash: cmd 1 · High risk · +6 more');
      expect(notification.lines, [
        'Approve Bash: cmd 1 · High risk',
        'Approve Bash: cmd 2',
        'Approve Bash: cmd 3',
        'Approve Bash: cmd 4',
        'Approve Bash: cmd 5',
        '+2 more',
        'Fixing the due-date tests',
      ]);
      // The buttons act on the first item; high risk offers no Always.
      expect(
        notification.action,
        const AgentNotificationAction(requestId: 'r1', allowAlways: false),
      );
      expect(notification.reviewAll, isTrue);
    });

    test('summary only: no buttons at all', () {
      final notification = build(
        _agent(pending: [_request('r1'), _request('r2')]),
        preferences: const AgentNotificationPreferences(summaryOnly: true),
      );
      expect(notification.action, isNull);
      expect(notification.reviewAll, isFalse);
    });

    test('a question, an error and a finished turn', () {
      final question = build(
        _agent(lastMessage: '\nWhich branch should I use?\nmain or dev'),
        need: AgentNeed.question,
      );
      expect(question.title, 'api · VTM is waiting for you');
      expect(question.text, 'Which branch should I use?');
      expect(question.action, isNull);

      final error = build(
        _agent(state: AgentAttentionState.blocked),
        need: AgentNeed.error,
      );
      expect(error.title, 'api · VTM hit an error');

      final finished = build(
        _agent(state: AgentAttentionState.idle, lastMessage: 'Done.'),
        need: AgentNeed.finished,
        detail: 'Added due dates; 42 tests pass',
      );
      expect(finished.title, 'api · VTM finished');
      expect(finished.text, 'Added due dates; 42 tests pass');
      expect(finished.lines, ['Added due dates; 42 tests pass']);
    });

    test('long summaries are capped', () {
      final notification = build(
        _agent(pending: [_request('r1', summary: 'x' * 500)]),
      );
      expect(notification.text.length, lessThan(160));
      expect(notification.text, contains('…'));
    });
  });

  group('preferences', () {
    test('round-trip JSON with defaults for anything missing', () {
      const custom = AgentNotificationPreferences(
        finished: false,
        summaryOnly: true,
        quietUpdates: false,
      );
      expect(AgentNotificationPreferences.fromJson(custom.toJson()), custom);
      expect(
        AgentNotificationPreferences.fromJson({'errors': false}),
        const AgentNotificationPreferences(errors: false),
      );
      expect(
        AgentNotificationPreferences.fromJson('junk'),
        const AgentNotificationPreferences(),
      );
    });
  });

  group('controller', () {
    AgentCommandResult ok(String stdout) =>
        AgentCommandResult(stdout: stdout, stderr: '', exitCode: 0);
    final version = ok('{"version":"0.1.0"}');
    String request(String id, String summary) =>
        '{"id":"$id","toolName":"Bash","summary":"$summary"}';
    AgentCommandResult status(
      String state, {
      List<String> pending = const [],
      int seq = 1,
      String? lastMessage,
    }) => ok(
      '{"version":1,"seq":$seq,"agents":[{"sessionId":"s-1","cwd":"/w/api",'
      '"state":"$state",'
      '${lastMessage == null ? '' : '"lastMessage":"$lastMessage",'}'
      '"pending":[${pending.join(',')}]}]}',
    );
    final empty = ok('{"version":1,"seq":9,"agents":[]}');

    Future<(AgentAttentionController, RecordingAgentNotifier)> run(
      List<Object> script, {
      AgentNotificationPreferencesStore? preferences,
      bool herdr = false,
    }) async {
      final workspace = TerminalWorkspaceController(FreshTerminalRepository());
      final notifier = RecordingAgentNotifier();
      final controller = AgentAttentionController(
        workspace: workspace,
        runnerFactory: (_) => ScriptedAgentCommandRunner(script),
        provider: const HerdrAttentionProvider(),
        companionProvider: const ConductoreHostAttentionProvider(),
        notifier: notifier,
        notificationPreferences:
            preferences ?? MemoryAgentNotificationPreferencesStore(_everything),
        pollInterval: const Duration(days: 1),
      );
      controller.setLongPoll(false);
      addTearDown(controller.dispose);
      addTearDown(workspace.dispose);
      final host = buildHost('h').copyWith(
        agentAttentionEnabled: true,
        agentMonitor: herdr ? AgentMonitorKind.herdr : AgentMonitorKind.auto,
      );
      await workspace.open(host).connect();
      await pumpEventQueue();
      return (controller, notifier);
    }

    test('a second request updates the same notification silently', () async {
      final (controller, notifier) = await run([
        version,
        status('working'),
        status('needs_permission', pending: [request('r1', 'npm test')]),
        status(
          'needs_permission',
          pending: [request('r1', 'npm test'), request('r2', 'git push')],
        ),
      ]);
      await controller.pollNow('h');
      await controller.pollNow('h');

      final [first, second] = notifier.agentPosts;
      expect(first.key, second.key);
      expect(first.alert, isTrue);
      expect(second.alert, isFalse);
      expect(second.text, 'Approve Bash: npm test · +1 more');
      expect(second.action?.requestId, 'r1');
      expect(second.reviewAll, isTrue);
      expect(notifier.agents, hasLength(1));
    });

    test('a new request after the last was answered alerts again', () async {
      final (controller, notifier) = await run([
        version,
        status('needs_permission', pending: [request('r1', 'npm test')]),
        status('needs_permission', pending: [request('r2', 'git push')]),
      ]);
      await controller.pollNow('h');
      expect(
        [for (final post in notifier.agentPosts) post.alert],
        [true, true],
      );
    });

    test('answered in the terminal or on the laptop: the notification goes '
        '', () async {
      final (controller, notifier) = await run([
        version,
        status('needs_permission', pending: [request('r1', 'npm test')]),
        status('working'),
      ]);
      await controller.pollNow('h');
      expect(notifier.agents, isEmpty);
      expect(notifier.agentCancelled, ['agent:h:s-1']);
    });

    test('an agent that ended, or vanished, loses its notification', () async {
      final (controller, notifier) = await run([
        version,
        status('needs_permission', pending: [request('r1', 'npm test')]),
        status('ended'),
      ]);
      await controller.pollNow('h');
      expect(notifier.agents, isEmpty);

      final (controller2, notifier2) = await run([
        version,
        status('needs_permission', pending: [request('r1', 'npm test')]),
        empty,
      ]);
      await controller2.pollNow('h');
      expect(notifier2.agents, isEmpty);
    });

    test('a finished turn replaces the agent\'s notification', () async {
      final (controller, notifier) = await run([
        version,
        status('needs_permission', pending: [request('r1', 'npm test')]),
        status('working', seq: 2),
        status('idle', seq: 3, lastMessage: 'All tests pass.'),
      ]);
      controller.notificationDetail = (hostId, agentId) =>
          hostId == 'h' && agentId == 's-1' ? 'Fixed the due-date bug' : null;
      await controller.pollNow('h');
      await controller.pollNow('h');

      final finished = notifier.agents.values.single;
      expect(finished.title, 'api · Host h finished');
      expect(finished.text, 'Fixed the due-date bug');
      expect(finished.alert, isTrue);
      expect(finished.action, isNull);
    });

    test('"Notify when an agent finishes" off: a finished turn stays '
        'quiet', () async {
      final (controller, notifier) = await run(
        [version, status('working'), status('idle', seq: 2)],
        preferences: MemoryAgentNotificationPreferencesStore(
          const AgentNotificationPreferences(
            mode: AgentNotificationMode.everything,
            finished: false,
          ),
        ),
      );
      await controller.pollNow('h');
      expect(notifier.agentPosts, isEmpty);
    });

    test('changing the settings re-posts without buttons and saves', () async {
      final store = MemoryAgentNotificationPreferencesStore();
      final (controller, notifier) = await run([
        version,
        status(
          'needs_permission',
          pending: [request('r1', 'npm test'), request('r2', 'ls')],
        ),
      ], preferences: store);
      expect(notifier.agents.values.single.action, isNotNull);

      await controller.setNotificationPreferences(
        const AgentNotificationPreferences(
          mode: AgentNotificationMode.everything,
          summaryOnly: true,
        ),
      );
      final updated = notifier.agents.values.single;
      expect(updated.action, isNull);
      expect(updated.reviewAll, isFalse);
      expect(updated.alert, isFalse);
      expect(store.value.summaryOnly, isTrue);

      await controller.setNotificationPreferences(
        const AgentNotificationPreferences(
          mode: AgentNotificationMode.everything,
          approvals: false,
        ),
      );
      expect(notifier.agents, isEmpty);
    });

    test('saved settings are loaded', () async {
      final (controller, _) = await run(
        [version, status('working')],
        preferences: MemoryAgentNotificationPreferencesStore(
          const AgentNotificationPreferences(
            mode: AgentNotificationMode.everything,
            errors: false,
          ),
        ),
      );
      expect(
        controller.notificationPreferences,
        const AgentNotificationPreferences(
          mode: AgentNotificationMode.everything,
          errors: false,
        ),
      );
    });

    test('the first snapshot carries a question over silently', () async {
      final (_, notifier) = await run([
        version,
        status('waiting_input', lastMessage: 'Which branch?'),
      ]);
      final carried = notifier.agentPosts.single;
      expect(carried.need, AgentNeed.question);
      expect(carried.alert, isFalse);
    });

    testWidgets('Settings › Agents › Advanced › Notification details '
        'switches', (tester) async {
      final workspace = TerminalWorkspaceController(FreshTerminalRepository());
      final store = MemoryAgentNotificationPreferencesStore(_everything);
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
              child: AgentNotificationDetailsCard(controller: controller),
            ),
          ),
        ),
      );
      expect(find.text('Notify when an agent finishes'), findsOne);

      await tester.tap(find.byKey(const ValueKey('agent-notify-finished')));
      await tester.pump();
      expect(controller.notificationPreferences.finished, isFalse);

      await tester.tap(find.byKey(const ValueKey('agent-notify-summary-only')));
      await tester.pump();
      expect(controller.notificationPreferences.summaryOnly, isTrue);
      expect(store.value.summaryOnly, isTrue);
    });
  });
}
