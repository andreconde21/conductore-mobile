import 'dart:convert';

import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/chat_view/domain/chat_items.dart';
import 'package:conduit/features/chat_view/domain/chat_transcript.dart';
import 'package:conduit/features/chat_view/domain/terminal_answers.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_controller.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';
import 'chat_fixtures.dart';

// CON-096: questions and prompts whose hook wait ran out are answered by
// typing into Claude Code's own dialog (`terminal-answer`); CON-094:
// requests waiting on return show at once.

AgentCommandResult ok(String stdout) =>
    AgentCommandResult(stdout: stdout, stderr: '', exitCode: 0);

Map<String, Object?> payloadOf(String command) =>
    jsonDecode(
          utf8.decode(
            base64.decode(
              RegExp(
                r'--json-b64 ([A-Za-z0-9+/=]+)',
              ).firstMatch(command)!.group(1)!,
            ),
          ),
        )
        as Map<String, Object?>;

const questions = [
  {
    'question': 'Part-time minimum wage?',
    'header': 'Part-time',
    'multiSelect': false,
    'options': [
      {'label': 'Proportional to hours', 'description': 'CT rule'},
      {'label': 'Full RMMG always'},
      {'label': 'Skip part-time'},
    ],
  },
  {
    'question': 'Which checks?',
    'header': 'Checks',
    'multiSelect': true,
    'options': [
      {'label': 'Warn, then block'},
      {'label': 'Log'},
      {'label': 'Email'},
    ],
  },
];

final askLine = assistantLine('a1', [
  toolUse('q1', 'AskUserQuestion', {'questions': questions}),
]);

void main() {
  group('terminalAnswerParts', () {
    final qs = [for (final q in questions) PendingQuestion.parse(q)!];

    test('splits picks (a label may hold ", ") from the own text', () {
      expect(
        terminalAnswerParts(qs, {
          'Part-time minimum wage?': 'Full RMMG always',
          'Which checks?': 'Warn, then block, Email, call me, maybe',
        }),
        {
          'Part-time minimum wage?': ['Full RMMG always'],
          'Which checks?': ['Warn, then block', 'Email', 'call me, maybe'],
        },
      );
    });

    test('a single answer stays whole', () {
      expect(terminalAnswerParts(qs, {'Part-time minimum wage?': 'a, b'}), {
        'Part-time minimum wage?': ['a, b'],
      });
    });
  });

  test('answeredInResult reads each question\'s answer', () {
    final item =
        ChatItemBuilder.build([TranscriptParser.parseEntry(askLine)!]).single
            as ChatQuestion;
    expect(
      answeredInResult(
        item.questions,
        'Your questions have been answered: "Part-time minimum wage?"='
        '"Proportional to hours", "Which checks?"="Log, Email". You can now '
        'continue with these answers in mind.',
      ),
      {
        'Part-time minimum wage?': 'Proportional to hours',
        'Which checks?': 'Log, Email',
      },
    );
    expect(answeredInResult(item.questions, 'User declined'), isEmpty);
  });

  test('the transcript carries expired and terminal-only requests', () {
    final parsed = TranscriptParser.parsePage(
      page(
        [],
        pending: [
          {
            'id': 'r1',
            'toolName': 'Bash',
            'summary': 'ls',
            'answerable': false,
            'expired': true,
            'batchable': true,
          },
        ],
      ),
    );
    final request = parsed.agent!.pending.single;
    expect(request.terminalOnly, isTrue);
    expect(request.expired, isTrue);
    expect(request.batchable, isFalse);
  });

  Future<(ChatViewController, ScriptedAgentCommandRunner)> pumpPage(
    WidgetTester tester,
    List<Object> script, {
    ChatDecide? decide,
    VoidCallback? onOpenTerminal,
  }) async {
    final runner = ScriptedAgentCommandRunner(script);
    final controller = ChatViewController(
      runner: runner,
      sessionId: 's-1',
      decide: decide,
      pollInterval: const Duration(days: 1),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ChatViewPage(
          controller: controller,
          hostName: 'dev',
          onOpenTerminal: onOpenTerminal ?? () {},
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    addTearDown(() => tester.pumpWidget(const SizedBox()));
    return (controller, runner);
  }

  void tall(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets('the screenshot case: a two-question form while "working" is '
      'answered in the terminal', (tester) async {
    tall(tester);
    final (_, runner) = await pumpPage(tester, [
      ok(page([askLine], state: 'working')),
      ok('{"ok":true,"steps":["question 1: pick 1"]}'),
      ok(page([], state: 'working')),
    ]);
    // Not greyed: the options answer, through the terminal.
    expect(
      find.byKey(const ValueKey('question-via-terminal-q1')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('question-option-Proportional to hours')),
    );
    await tester.tap(find.byKey(const ValueKey('question-option-Log')));
    await tester.enterText(
      find.byKey(const ValueKey('question-other-Which checks?')),
      'and a call',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('question-send-q1')));
    // Not pumpAndSettle: a working agent's dots never settle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    final payload = payloadOf(runner.commands[1]);
    expect(runner.commands[1], contains('terminal-answer'));
    expect(payload['answers'], {
      'Part-time minimum wage?': ['Proportional to hours'],
      'Which checks?': ['Log', 'and a call'],
    });
    expect((payload['questions'] as List).length, 2);
    expect(payload.containsKey('requestId'), isFalse);
  });

  testWidgets('an answered question shows what was answered', (tester) async {
    tall(tester);
    await pumpPage(tester, [
      ok(
        page([
          askLine,
          userLine('r1', [
            toolResult(
              'q1',
              'Your questions have been answered: "Part-time minimum wage?"='
                  '"Skip part-time", "Which checks?"="Email". You can now '
                  'continue with these answers in mind.',
            ),
          ]),
        ]),
      ),
    ]);
    expect(find.text('Question answered'), findsOneWidget);
    expect(find.text('Answered: Skip part-time'), findsOneWidget);
    expect(find.text('Answered: Email'), findsOneWidget);
  });

  testWidgets('an expired question request is answered in the terminal by id', (
    tester,
  ) async {
    tall(tester);
    final decided = <String>[];
    final (_, runner) = await pumpPage(tester, [
      ok(
        page(
          [askLine],
          pending: [
            {
              'id': 'req-q',
              'toolName': 'AskUserQuestion',
              'summary': 'Part-time minimum wage?',
              'questions': questions,
              'answerable': false,
              'expired': true,
            },
          ],
        ),
      ),
      ok('{"ok":true}'),
      ok(page([askLine], state: 'working')),
    ], decide: (request, verdict) async => decided.add(request.id));
    expect(find.text('Answer it below.'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('question-via-terminal-req-q')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('question-decline-req-q')), findsNothing);
    await tester.tap(
      find.byKey(const ValueKey('question-option-Full RMMG always')),
    );
    await tester.tap(find.byKey(const ValueKey('question-option-Email')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('question-send-req-q')));
    // Not pumpAndSettle: a working agent's dots never settle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(decided, isEmpty);
    expect(payloadOf(runner.commands[1]), {
      'requestId': 'req-q',
      'answers': {
        'Part-time minimum wage?': ['Full RMMG always'],
        'Which checks?': ['Email'],
      },
    });
  });

  testWidgets('an expired permission prompt: Allow presses 1 in the terminal', (
    tester,
  ) async {
    tall(tester);
    final (_, runner) = await pumpPage(tester, [
      ok(
        page(
          [userLine('u1', 'clean up')],
          state: 'needs_permission',
          pending: [
            {
              'id': 'req-1',
              'toolName': 'Bash',
              'summary': 'rm -rf build',
              'answerable': false,
              'expired': true,
            },
          ],
        ),
      ),
      ok('{"ok":true}'),
      ok(page([], state: 'working')),
    ]);
    expect(
      find.byKey(const ValueKey('chat-approval-via-terminal-req-1')),
      findsOneWidget,
    );
    expect(find.text('Always'), findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, 'Allow'));
    // Not pumpAndSettle: a working agent's dots never settle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(payloadOf(runner.commands[1]), {
      'requestId': 'req-1',
      'decision': 'allow',
    });
  });

  testWidgets('a failed terminal answer says why and offers the terminal', (
    tester,
  ) async {
    tall(tester);
    var toTerminal = 0;
    await pumpPage(tester, [
      ok(page([askLine], state: 'working')),
      const AgentCommandResult(
        stdout:
            '{"error":"the terminal does not show this question (answered '
            'already, or another dialog is open)","steps":[]}',
        stderr: '',
        exitCode: 1,
      ),
      ok(page([askLine], state: 'working')),
    ], onOpenTerminal: () => toTerminal += 1);
    await tester.tap(find.byKey(const ValueKey('question-option-Log')));
    await tester.tap(
      find.byKey(const ValueKey('question-option-Skip part-time')),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('question-send-q1')));
    // Not pumpAndSettle: a working agent's dots never settle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.textContaining('does not show this question'), findsOneWidget);
    await tester.tap(find.text('Open terminal').last);
    expect(toTerminal, 1);
  });

  testWidgets('CON-094: requests held while scrolled up show on return', (
    tester,
  ) async {
    final long = [
      for (var i = 0; i < 60; i++)
        assistantLine('m$i', [
          text('Message number $i, long enough to scroll.'),
        ]),
    ];
    final (controller, _) = await pumpPage(tester, [
      ok(page(long, state: 'working')),
      ok(
        page(
          [],
          offset: 200,
          state: 'needs_permission',
          pending: [
            {'id': 'req-1', 'toolName': 'Bash', 'summary': 'make deploy'},
            {'id': 'req-2', 'toolName': 'Bash', 'summary': 'make clean'},
          ],
        ),
      ),
    ]);
    // The user reads further up; the thread freezes.
    await tester.drag(
      find.byKey(const ValueKey('chat-thread')),
      const Offset(0, 600),
    );
    await tester.pump();
    // The requests arrive while away (app paused, then resumed).
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await controller.refresh();
    await tester.pump();
    // Held while frozen: the pill names a waiting request, not messages.
    expect(find.text('Approval waiting'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    // Both show, oldest first, at the bottom where the list now is.
    final first = tester.getTopLeft(find.text('make deploy'));
    final second = tester.getTopLeft(find.text('make clean'));
    expect(first.dy, lessThan(second.dy));
    expect(find.text('Approval waiting'), findsNothing);
  });
}
