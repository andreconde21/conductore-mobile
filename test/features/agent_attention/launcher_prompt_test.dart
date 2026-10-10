import 'dart:convert';

import 'package:conduit/features/agent_attention/data/conductore_host_attention_provider.dart';
import 'package:conduit/features/agent_attention/data/herdr_attention_provider.dart';
import 'package:conduit/features/agent_attention/data/platform_agent_notifier.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/agent_attention/domain/agent_permission_actions.dart';
import 'package:conduit/features/agent_attention/domain/launcher_prompt.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

PendingPermissionRequest _request(
  String id, {
  String toolName = 'Bash',
  String summary = 'npm test',
  PermissionRiskLevel? risk,
  String reason = '',
  bool terminalOnly = false,
  List<PendingQuestion> questions = const [],
}) => PendingPermissionRequest(
  id: id,
  toolName: toolName,
  summary: summary,
  risk: risk == null ? null : PermissionRisk(risk, reason),
  terminalOnly: terminalOnly,
  questions: questions,
);

AgentInfo _agent({
  AgentAttentionState state = AgentAttentionState.needsInput,
  List<PendingPermissionRequest> pending = const [],
  String? lastMessage,
}) => AgentInfo(
  id: 's-1',
  name: 'api',
  state: state,
  pendingRequests: pending,
  lastMessage: lastMessage,
);

LauncherPrompt? _of(AgentInfo agent, {bool canReply = true}) =>
    LauncherPrompt.of(hostId: 'h', agent: agent, canReply: canReply);

PendingQuestion _choice(
  String question, {
  List<String> options = const ['Postgres', 'SQLite'],
  bool multiSelect = false,
  String kind = 'choice',
}) => PendingQuestion(
  question: question,
  kind: kind,
  multiSelect: multiSelect,
  options: [for (final label in options) PendingQuestionOption(label: label)],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LauncherPrompt.of', () {
    test('only agents needing the user have one', () {
      for (final state in [
        AgentAttentionState.working,
        AgentAttentionState.idle,
        AgentAttentionState.finished,
        AgentAttentionState.unknown,
      ]) {
        expect(_of(_agent(state: state, lastMessage: 'Done?')), isNull);
      }
      expect(_of(_agent(state: AgentAttentionState.blocked)), isNotNull);
    });

    test('a permission request offers Allow, Always allow and Deny', () {
      final prompt = _of(
        _agent(
          pending: [
            _request(
              'r1',
              risk: PermissionRiskLevel.medium,
              reason: 'Edits files',
            ),
          ],
        ),
      )!;
      expect(prompt.id, 'h/s-1');
      expect(prompt.requestId, 'r1');
      expect(
        prompt.question,
        'Approve Bash: npm test · Medium risk\nEdits files',
      );
      expect(prompt.options, const [
        LauncherOption('Allow', 'allow'),
        LauncherOption('Always allow', 'always'),
        LauncherOption('Deny', 'deny'),
      ]);
      expect(prompt.replyVerdict, isNull);
      expect(prompt.answerable, isTrue);
      expect(prompt.note, isNull);
    });

    test('several requests: the first one, and how many more wait', () {
      final prompt = _of(
        _agent(pending: [_request('r1'), _request('r2'), _request('r3')]),
      )!;
      expect(prompt.requestId, 'r1');
      expect(prompt.question, 'Approve Bash: npm test\n(+2 more waiting)');
    });

    test('high risk and terminal-only requests are never answerable', () {
      final high = _of(
        _agent(pending: [_request('r1', risk: PermissionRiskLevel.high)]),
      )!;
      expect(high.options, isNull);
      expect(high.replyVerdict, isNull);
      expect(high.answerable, isFalse);
      expect(high.note, LauncherPrompt.highRiskNote);
      expect(high.question, contains('High risk'));

      final terminal = _of(
        _agent(pending: [_request('r1', terminalOnly: true)]),
      )!;
      expect(terminal.answerable, isFalse);
      expect(terminal.note, LauncherPrompt.terminalNote);

      final terminalQuestion = _of(
        _agent(
          pending: [
            _request(
              'q1',
              toolName: PendingPermissionRequest.questionTool,
              terminalOnly: true,
              questions: [_choice('Which database?')],
            ),
          ],
        ),
      )!;
      expect(terminalQuestion.answerable, isFalse);
      expect(terminalQuestion.note, LauncherPrompt.terminalNote);
    });

    test('a single-choice question offers its options as answers', () {
      final prompt = _of(
        _agent(
          pending: [
            _request(
              'q1',
              toolName: PendingPermissionRequest.questionTool,
              summary: 'Which database?',
              questions: [_choice('Which database?')],
            ),
          ],
        ),
      )!;
      expect(prompt.question, 'Which database?');
      expect(prompt.options, const [
        LauncherOption('Postgres', 'answer'),
        LauncherOption('SQLite', 'answer'),
      ]);
      expect(prompt.replyVerdict, isNull);
      expect(prompt.answers, 'Which database?');
    });

    test('a free-text question takes a reply that answers it', () {
      final prompt = _of(
        _agent(
          pending: [
            _request(
              'q1',
              toolName: PendingPermissionRequest.questionTool,
              questions: [
                _choice('Name the branch', kind: 'text', options: const []),
              ],
            ),
          ],
        ),
      )!;
      expect(prompt.options, isNull);
      expect(prompt.replyVerdict, AgentPermissionAction.answerVerdict);
      expect(prompt.answers, 'Name the branch');
    });

    test('several questions or a pick-several one are not answerable', () {
      final several = _of(
        _agent(
          pending: [
            _request(
              'q1',
              toolName: PendingPermissionRequest.questionTool,
              questions: [_choice('Which database?'), _choice('Which ORM?')],
            ),
          ],
        ),
      )!;
      expect(several.answerable, isFalse);
      expect(several.note, LauncherPrompt.severalQuestionsNote);
      expect(several.question, 'Which database?\nWhich ORM?');

      final multi = _of(
        _agent(
          pending: [
            _request(
              'q1',
              toolName: PendingPermissionRequest.questionTool,
              questions: [_choice('Which targets?', multiSelect: true)],
            ),
          ],
        ),
      )!;
      expect(multi.answerable, isFalse);
      expect(multi.note, LauncherPrompt.multiSelectNote);
    });

    test('a question from an older companion (no questions) is not '
        'answerable', () {
      final prompt = _of(
        _agent(
          pending: [
            _request(
              'q1',
              toolName: PendingPermissionRequest.questionTool,
              summary: 'Which database?',
            ),
          ],
        ),
      )!;
      expect(prompt.answerable, isFalse);
      expect(prompt.note, LauncherPrompt.openNote);
      expect(prompt.question, 'Which database?');
    });

    test('nothing pending: a reply with the last message as question', () {
      final prompt = _of(_agent(lastMessage: '  Which branch?  '))!;
      expect(prompt.requestId, LauncherPrompt.replyRequest);
      expect(prompt.question, 'Which branch?');
      expect(prompt.options, isNull);
      expect(prompt.replyVerdict, AgentPermissionAction.replyVerdict);

      final cannot = _of(_agent(lastMessage: 'Which?'), canReply: false)!;
      expect(cannot.answerable, isFalse);
      expect(cannot.note, LauncherPrompt.openNote);
    });

    test('the question is capped', () {
      final prompt = _of(_agent(lastMessage: 'x' * 2000))!;
      expect(prompt.question, hasLength(LauncherPrompt.maxQuestionLength));
      expect(prompt.question, endsWith('…'));
    });

    test('encodes what the native side parses', () {
      final prompt = _of(_agent(pending: [_request('r1')]))!;
      final decoded = jsonDecode(LauncherPrompt.encodeAll([prompt])) as List;
      expect(decoded.single, {
        'id': 'h/s-1',
        'hostId': 'h',
        'agentId': 's-1',
        'requestId': 'r1',
        'question': 'Approve Bash: npm test',
        'options': [
          {'label': 'Allow', 'verdict': 'allow'},
          {'label': 'Always allow', 'verdict': 'always'},
          {'label': 'Deny', 'verdict': 'deny'},
        ],
        'replyVerdict': null,
        'answers': '',
        'note': null,
      });
    });
  });

  group('PlatformLauncherActions', () {
    test('parses the native call', () {
      expect(
        PlatformLauncherActions.parseAction({
          'hostId': 'h',
          'agentId': 's-1',
          'requestId': 'r1',
          'verdict': 'always',
          'text': '',
        }),
        const AgentPermissionAction(
          notificationId: '',
          hostId: 'h',
          agentId: 's-1',
          requestId: 'r1',
          verdict: 'always',
        ),
      );
      expect(PlatformLauncherActions.parseAction({'hostId': 'h'}), isNull);
      expect(PlatformLauncherActions.parseAction('nope'), isNull);
    });

    test('answers null without a listener, else ok and error', () async {
      final actions = PlatformLauncherActions.instance;
      addTearDown(() => actions.setListener(null));
      final call = {
        'hostId': 'h',
        'agentId': 's-1',
        'requestId': 'r1',
        'verdict': 'allow',
      };
      actions.setListener(null);
      expect(await actions.handle(call), isNull);

      actions.setListener((_) async => null);
      expect(await actions.handle(call), {'ok': true, 'error': null});
      actions.setListener((_) async => 'Nope');
      expect(await actions.handle(call), {'ok': false, 'error': 'Nope'});
      expect(await actions.handle({'x': 1}), {
        'ok': false,
        'error': 'Unknown action',
      });
    });
  });

  group('completeLauncherAction', () {
    AgentCommandResult ok(String stdout) =>
        AgentCommandResult(stdout: stdout, stderr: '', exitCode: 0);
    final version = ok('{"version":"0.1.0"}');
    AgentCommandResult status(
      String state, {
      Object? pending,
      String? message,
    }) => ok(
      jsonEncode({
        'version': 1,
        'seq': 1,
        'agents': [
          {
            'sessionId': 's-1',
            'cwd': '/w/api',
            'state': state,
            'lastMessage': ?message,
            'pending': [?pending],
          },
        ],
      }),
    );
    final permission = status(
      'needs_permission',
      pending: {
        'id': 'r1',
        'toolName': 'Bash',
        'summary': 'npm test',
        'risk': {'level': 'medium', 'reason': 'Runs tests'},
      },
    );
    final host = buildHost('h').copyWith(agentAttentionEnabled: true);

    Future<
      (
        AgentAttentionController,
        RecordingAgentNotifier,
        ScriptedAgentCommandRunner,
      )
    >
    run(List<Object> script) async {
      final workspace = TerminalWorkspaceController(FreshTerminalRepository());
      final notifier = RecordingAgentNotifier();
      final runner = ScriptedAgentCommandRunner(script);
      final controller = AgentAttentionController(
        workspace: workspace,
        runnerFactory: (_) => runner,
        provider: const HerdrAttentionProvider(),
        companionProvider: const ConductoreHostAttentionProvider(),
        notifier: notifier,
        pollInterval: const Duration(days: 1),
      );
      controller.setLongPoll(false);
      addTearDown(controller.dispose);
      addTearDown(workspace.dispose);
      await workspace.open(host).connect();
      await pumpEventQueue();
      return (controller, notifier, runner);
    }

    AgentPermissionAction action(
      String verdict, {
      String requestId = 'r1',
      String text = '',
    }) => AgentPermissionAction(
      notificationId: '',
      hostId: 'h',
      agentId: 's-1',
      requestId: requestId,
      verdict: verdict,
      text: text,
    );

    test('the launcher prompts follow the live status', () async {
      final (controller, _, _) = await run([version, permission]);
      final prompt = controller.launcherPrompts.single;
      expect(prompt.id, 'h/s-1');
      expect(prompt.requestId, 'r1');
      expect(prompt.options?.map((option) => option.verdict), [
        'allow',
        'always',
        'deny',
      ]);
    });

    test('a chosen option decides the request', () async {
      final (controller, notifier, runner) = await run([
        version,
        permission,
        ok('{"ok":true}'),
        status('working'),
      ]);
      expect(
        await controller.completeLauncherAction(action('always'), host),
        isNull,
      );
      expect(runner.commands[2], contains('decide r1 always'));
      expect(notifier.shown, isEmpty);
    });

    test('a stale request or another agent is not waiting', () async {
      final (controller, _, runner) = await run([version, permission]);
      expect(
        await controller.completeLauncherAction(
          action('allow', requestId: 'r0'),
          host,
        ),
        LauncherPrompt.staleError,
      );
      expect(
        await controller.completeLauncherAction(
          const AgentPermissionAction(
            notificationId: '',
            hostId: 'h',
            agentId: 's-9',
            requestId: 'r1',
            verdict: 'allow',
          ),
          host,
        ),
        LauncherPrompt.staleError,
      );
      expect(runner.commands, hasLength(2));
    });

    test('a request answered meanwhile fails quietly as stale', () async {
      final (controller, notifier, _) = await run([
        version,
        permission,
        const AgentCommandResult(
          stdout: '{"error":"unknown request r1"}',
          stderr: '',
          exitCode: 1,
        ),
        status('working'),
      ]);
      expect(
        await controller.completeLauncherAction(action('allow'), host),
        LauncherPrompt.staleError,
      );
      // The launcher shows why; the notifications are left alone.
      expect(
        notifier.agentPosts.where((post) => post.title.contains('failed')),
        isEmpty,
      );
    });

    test('a high-risk request is refused before anything is sent', () async {
      final (controller, _, runner) = await run([
        version,
        status(
          'needs_permission',
          pending: {
            'id': 'r1',
            'toolName': 'Bash',
            'summary': 'git push --force',
            'risk': {'level': 'high', 'reason': 'Force push'},
          },
        ),
      ]);
      expect(
        await controller.completeLauncherAction(action('allow'), host),
        LauncherPrompt.highRiskNote,
      );
      expect(runner.commands, hasLength(2));
    });

    test('an answer must be one of the options', () async {
      final (controller, _, runner) = await run([
        version,
        status(
          'needs_permission',
          pending: {
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
          },
        ),
        ok('{"ok":true}'),
        status('working'),
      ]);
      expect(
        await controller.completeLauncherAction(
          action('answer', requestId: 'q1', text: 'MySQL'),
          host,
        ),
        LauncherPrompt.staleError,
      );
      expect(
        await controller.completeLauncherAction(
          action('answer', requestId: 'q1', text: 'SQLite'),
          host,
        ),
        isNull,
      );
      expect(runner.commands[2], contains('decide q1 answer --answers'));
      expect(runner.commands[2], contains('{"Which database?":"SQLite"}'));
    });

    test('a reply is typed into the agent', () async {
      final (controller, _, runner) = await run([
        version,
        status('waiting_input', message: 'Which branch?'),
        ok('{"ok":true}'),
        status('working'),
      ]);
      expect(
        await controller.completeLauncherAction(
          action('reply', requestId: 'reply', text: 'Use main'),
          host,
        ),
        isNull,
      );
      expect(runner.commands[2], contains('send s-1 --text-b64 '));
      expect(
        runner.commands[2],
        contains(base64.encode(utf8.encode('Use main'))),
      );
    });

    test('a host that is not monitored says so', () async {
      final (controller, _, _) = await run([version, permission]);
      expect(
        await controller.completeLauncherAction(action('allow'), null),
        isNotNull,
      );
      expect(
        await controller.completeLauncherAction(
          action('allow'),
          buildHost('other'),
        ),
        'Conductore is not monitoring that machine',
      );
    });

    // Contract 3 (CON-119): answers held while Conductore was locked.

    QueuedLauncherAnswer held(
      String verdict, {
      String requestId = 'r1',
      String text = '',
      DateTime? since,
      DateTime? queuedAt,
    }) => QueuedLauncherAnswer(
      action: action(verdict, requestId: requestId, text: text),
      title: 'api',
      host: 'Host h',
      since: since,
      queuedAt: queuedAt ?? DateTime.now(),
    );

    AgentCommandResult waiting(int updatedAt) => ok(
      jsonEncode({
        'version': 1,
        'seq': 1,
        'agents': [
          {
            'sessionId': 's-1',
            'cwd': '/w/api',
            'state': 'waiting_input',
            'lastMessage': 'Which branch?',
            'updatedAt': updatedAt,
            'pending': <Object>[],
          },
        ],
      }),
    );

    test('a held answer is sent after a fresh look at the agent', () async {
      final (controller, _, runner) = await run([
        version,
        permission,
        permission,
        ok('{"ok":true}'),
        status('working'),
      ]);
      expect(
        await controller.deliverQueuedLauncherAnswer(held('allow'), host),
        isNull,
      );
      // version, the first status, the status read again, then the answer.
      expect(runner.commands[2], isNot(contains('decide')));
      expect(runner.commands[3], contains('decide r1 allow'));
    });

    test('a held answer to a request answered elsewhere is dropped', () async {
      final (controller, _, runner) = await run([
        version,
        permission,
        // Answered in the terminal while Conductore was locked.
        status('working'),
      ]);
      expect(
        await controller.deliverQueuedLauncherAnswer(held('allow'), host),
        LauncherPrompt.staleError,
      );
      expect(runner.commands, hasLength(3));
      expect(
        runner.commands.where((command) => command.contains('decide')),
        isEmpty,
      );
    });

    test('a held answer to another request of the agent is dropped', () async {
      final (controller, _, runner) = await run([
        version,
        permission,
        status(
          'needs_permission',
          pending: {'id': 'r2', 'toolName': 'Bash', 'summary': 'rm -rf build'},
        ),
      ]);
      expect(
        await controller.deliverQueuedLauncherAnswer(held('allow'), host),
        LauncherPrompt.staleError,
      );
      expect(runner.commands, hasLength(3));
    });

    test('a held reply goes only into the wait it answered', () async {
      final since = DateTime.fromMillisecondsSinceEpoch(1790000000000);
      final (controller, _, runner) = await run([
        version,
        waiting(1790000000000),
        // The agent moved on and waits again: another wait.
        waiting(1790000600000),
      ]);
      expect(
        await controller.deliverQueuedLauncherAnswer(
          held('reply', requestId: 'reply', text: 'Use main', since: since),
          host,
        ),
        LauncherPrompt.staleError,
      );
      expect(runner.commands, hasLength(3));

      final (same, _, sameRunner) = await run([
        version,
        waiting(1790000000000),
        waiting(1790000000000),
        ok('{"ok":true}'),
        status('working'),
      ]);
      expect(
        await same.deliverQueuedLauncherAnswer(
          held('reply', requestId: 'reply', text: 'Use main', since: since),
          host,
        ),
        isNull,
      );
      expect(sameRunner.commands[3], contains('send s-1 --text-b64 '));
    });

    test('a held answer expires after 15 minutes', () async {
      final (controller, _, runner) = await run([version, permission]);
      final queuedAt = DateTime(2026, 10, 10, 12);
      final answer = held('allow', queuedAt: queuedAt);
      expect(
        await controller.deliverQueuedLauncherAnswer(
          answer,
          host,
          now: () => queuedAt.add(QueuedLauncherAnswer.expiry),
        ),
        QueuedLauncherAnswer.expiredError,
      );
      expect(runner.commands, hasLength(2));
      expect(
        answer.expiredAt(
          queuedAt.add(
            QueuedLauncherAnswer.expiry - const Duration(seconds: 1),
          ),
        ),
        isFalse,
      );
    });

    test('a held answer for a machine not monitored in time says so', () async {
      final (controller, _, _) = await run([version, permission]);
      expect(
        await controller.deliverQueuedLauncherAnswer(
          held('allow'),
          buildHost('other'),
          wait: Duration.zero,
        ),
        'Conductore is not monitoring that machine',
      );
      expect(
        await controller.deliverQueuedLauncherAnswer(held('allow'), null),
        'The machine is no longer saved',
      );
    });

    test('held answers parse from the platform', () {
      final answers = PlatformLauncherActions.parseQueued([
        {
          'hostId': 'h',
          'agentId': 's-1',
          'requestId': 'reply',
          'verdict': 'reply',
          'text': 'Use main',
          'key': 'h/s-1@1790000060000',
          'title': 'api',
          'host': 'dev',
          'since': 1790000000000,
          'queuedAt': 1790000060000,
        },
        // No time it was held, or no agent: unreadable.
        {'hostId': 'h', 'agentId': 's-1', 'verdict': 'allow'},
        {'hostId': 'h', 'verdict': 'allow', 'queuedAt': 1},
        'junk',
      ]);
      expect(answers, [
        QueuedLauncherAnswer(
          action: const AgentPermissionAction(
            notificationId: '',
            hostId: 'h',
            agentId: 's-1',
            requestId: 'reply',
            verdict: 'reply',
            text: 'Use main',
          ),
          key: 'h/s-1@1790000060000',
          title: 'api',
          host: 'dev',
          since: DateTime.fromMillisecondsSinceEpoch(1790000000000),
          queuedAt: DateTime.fromMillisecondsSinceEpoch(1790000060000),
        ),
      ]);
      expect(answers.single.label, 'api on dev');
      expect(PlatformLauncherActions.parseQueued(null), isEmpty);
    });
  });
}
