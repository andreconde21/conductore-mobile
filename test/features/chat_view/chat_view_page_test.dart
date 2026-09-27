import 'dart:convert';

import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_controller.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_page.dart';
import 'package:conduit/features/chat_view/presentation/widgets/chat_markdown.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';
import 'chat_fixtures.dart';

AgentCommandResult ok(String stdout) =>
    AgentCommandResult(stdout: stdout, stderr: '', exitCode: 0);

void main() {
  final thread = [
    userLine('u1', 'Fix the **tests**'),
    assistantLine('a1', [
      thinking(),
      text('Running them now. See `pubspec.yaml` and **this**:\n- one\n- two'),
      toolUse('t1', 'Bash', {'command': 'flutter test', 'description': 'Run'}),
    ]),
    userLine('r1', [
      toolResult('t1', 'Exit code 1\nSome tests failed', error: true),
    ]),
    assistantLine('a2', [
      toolUse('t2', 'Edit', {
        'file_path': '/w/lib/a.dart',
        'old_string': 'old',
        'new_string': 'new',
      }),
      toolUse('t3', 'TodoWrite', {
        'todos': [
          {'content': 'Fix parser', 'status': 'completed'},
          {'content': 'Run suite', 'status': 'in_progress'},
        ],
      }),
      toolUse('p1', 'ExitPlanMode', {'plan': '## Plan\n1. Fix\n2. Ship'}),
    ]),
  ];

  Future<(ChatViewController, ScriptedAgentCommandRunner)> pumpPage(
    WidgetTester tester,
    List<Object> script, {
    ChatDecide? decide,
    VoidCallback? onOpenTerminal,
    VoidCallback? onSetUpCompanion,
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
          onSetUpCompanion: onSetUpCompanion,
        ),
      ),
    );
    // Not pumpAndSettle: a running tool's spinner never settles.
    await tester.pump();
    await tester.pump();
    addTearDown(() => tester.pumpWidget(const SizedBox()));
    return (controller, runner);
  }

  testWidgets('renders bubbles, tool cards, todo and plan cards', (
    tester,
  ) async {
    // Tall enough that the whole thread is built.
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pumpPage(tester, [ok(page(thread, state: 'working'))]);
    expect(find.text('Fix the **tests**'), findsOneWidget);
    expect(find.textContaining('Running them now.'), findsOneWidget);
    expect(find.text('Thought'), findsOneWidget);
    // Tool activity is Collapsed by default: the run is one row that
    // opens on tap.
    expect(find.text('Ran 1 command, edited 1 file'), findsOneWidget);
    expect(find.text('flutter test'), findsNothing);
    await tester.tap(find.text('Ran 1 command, edited 1 file'));
    await tester.pump();
    // Bash failure flagged with its exit code and output tail.
    expect(find.text('flutter test'), findsOneWidget);
    expect(find.text('exit 1'), findsOneWidget);
    expect(find.byIcon(Icons.error_rounded), findsOneWidget);
    expect(find.textContaining('Some tests failed'), findsOneWidget);
    // Edit card: path, diff on expand.
    expect(find.text('/w/lib/a.dart'), findsOneWidget);
    expect(find.text('- old'), findsNothing);
    await tester.tap(find.text('/w/lib/a.dart'));
    await tester.pump();
    expect(find.text('- old'), findsOneWidget);
    expect(find.text('+ new'), findsOneWidget);
    expect(find.text('Tasks 1/2'), findsOneWidget);
    expect(find.text('Plan'), findsWidgets);
    expect(find.text('Waiting for approval'), findsOneWidget);
    // Header: name, state and host.
    expect(find.text('api'), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-header-status')), findsOneWidget);
    expect(find.textContaining('dev'), findsWidgets);
  });

  testWidgets('approval card answers through decide', (tester) async {
    final decided = <(String, PermissionVerdict)>[];
    await pumpPage(tester, [
      ok(
        page(
          [userLine('u1', 'clean up')],
          state: 'needs_permission',
          pending: [
            {'id': 'req-1', 'toolName': 'Bash', 'summary': 'rm -rf build'},
          ],
        ),
      ),
      ok(page([], state: 'working')),
    ], decide: (request, verdict) async => decided.add((request.id, verdict)));
    expect(find.text('Allow Bash?'), findsOneWidget);
    expect(find.text('rm -rf build'), findsOneWidget);
    expect(find.text('Answer the approval above first'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Allow'));
    // Not pumpAndSettle: Claude works again, so the typing dots animate.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(decided, [('req-1', PermissionVerdict.allow)]);
    expect(find.text('Allow Bash?'), findsNothing);
  });

  testWidgets('a plan approval uses plan wording', (tester) async {
    await pumpPage(tester, [
      ok(
        page(
          [],
          state: 'needs_permission',
          pending: [
            {'id': 'req-2', 'toolName': 'ExitPlanMode', 'summary': 'plan'},
          ],
        ),
      ),
    ]);
    expect(find.text('Approve the plan?'), findsOneWidget);
    expect(find.text('Keep planning'), findsOneWidget);
  });

  testWidgets('composer sends on Enter and clears the field', (tester) async {
    final (_, runner) = await pumpPage(tester, [
      ok(page([userLine('u1', 'hi')])),
      ok('{"ok":true}'),
      ok(page([])),
    ]);
    final field = find.byKey(const ValueKey('chat-composer-field'));
    await tester.enterText(field, 'run the tests');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();
    expect(
      runner.commands[1],
      contains(
        'send s-1 --text-b64 ${base64.encode(utf8.encode('run the tests'))}',
      ),
    );
    expect(tester.widget<TextField>(field).controller!.text, isEmpty);
  });

  testWidgets('a failed send keeps the text in its bubble and says why', (
    tester,
  ) async {
    await pumpPage(tester, [
      ok(page([])),
      const AgentCommandResult(
        stdout: '{"error":"session not in tmux or Herdr"}',
        stderr: '',
        exitCode: 1,
      ),
    ]);
    final field = find.byKey(const ValueKey('chat-composer-field'));
    await tester.enterText(field, 'hello');
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();
    expect(find.text('hello'), findsOneWidget);
    expect(find.textContaining('session not in tmux or Herdr'), findsOneWidget);
    // Edit puts it back in the composer.
    await tester.tap(find.byKey(const ValueKey('outgoing-edit')));
    await tester.pump();
    expect(tester.widget<TextField>(field).controller!.text, 'hello');
  });

  testWidgets('open question options type the option number', (tester) async {
    final (_, runner) = await pumpPage(tester, [
      ok(
        page([
          assistantLine('a1', [
            toolUse('q1', 'AskUserQuestion', {
              'questions': [
                {
                  'question': 'Which DB?',
                  'options': [
                    {'label': 'Postgres'},
                    {'label': 'SQLite'},
                  ],
                },
              ],
            }),
          ]),
        ]),
      ),
      ok('{"ok":true}'),
      ok(page([])),
    ]);
    await tester.tap(find.text('2. SQLite'));
    await tester.pumpAndSettle();
    expect(
      runner.commands[1],
      contains('--text-b64 ${base64.encode(utf8.encode('2'))} --no-enter'),
    );
  });

  testWidgets('Esc interrupts and Terminal leaves the chat', (tester) async {
    var toTerminal = 0;
    final (_, runner) = await pumpPage(tester, [
      ok(page([], state: 'working')),
      ok('{"ok":true}'),
      ok(page([])),
    ], onOpenTerminal: () => toTerminal += 1);
    await tester.tap(find.byTooltip('Interrupt (Esc)'));
    await tester.pumpAndSettle();
    expect(runner.commands[1], contains('interrupt s-1'));
    await tester.tap(find.text('Terminal'));
    expect(toTerminal, 1);
  });

  testWidgets('a missing companion explains how to install it', (tester) async {
    await pumpPage(tester, [
      const AgentCommandResult(
        stdout: '',
        stderr: 'sh: 1: conductore-hostd: not found',
        exitCode: 127,
      ),
    ]);
    expect(find.textContaining('host/install.sh'), findsOneWidget);
    expect(find.text('Chat unavailable'), findsOneWidget);
  });

  test('Markdown blocks: fences, lists, headings, tables, quotes', () {
    final blocks = parseMarkdownBlocks(
      '# Title\n\nPara one\nstill one\n\n```dart\nvoid main() {}\n```\n'
      '- a\n  - nested\n1. first\n- [x] done\n> quoted\n| a | b |\n|---|---|\n---',
    );
    expect(blocks.map((b) => b.runtimeType), [
      MarkdownHeading,
      MarkdownParagraph,
      MarkdownCode,
      MarkdownListItem,
      MarkdownListItem,
      MarkdownListItem,
      MarkdownListItem,
      MarkdownQuote,
      MarkdownTableBlock,
      MarkdownRule,
    ]);
    expect((blocks[2] as MarkdownCode).language, 'dart');
    expect((blocks[4] as MarkdownListItem).indent, 1);
    expect((blocks[5] as MarkdownListItem).marker, '1.');
    expect((blocks[6] as MarkdownListItem).marker, '☑');
  });

  testWidgets('a missing companion offers the Agent hooks screen', (
    tester,
  ) async {
    var opened = 0;
    await pumpPage(tester, [
      const AgentCommandResult(
        stdout: '',
        stderr: 'sh: conductore-hostd: not found',
        exitCode: 127,
      ),
    ], onSetUpCompanion: () => opened += 1);
    expect(find.textContaining('not installed'), findsOneWidget);
    await tester.tap(find.text('Install agent hooks'));
    expect(opened, 1);
  });

  testWidgets('an old companion offers the update', (tester) async {
    var opened = 0;
    await pumpPage(tester, [
      const AgentCommandResult(
        stdout: '{"error":"unknown command transcript"}',
        stderr: '',
        exitCode: 1,
      ),
    ], onSetUpCompanion: () => opened += 1);
    expect(find.textContaining('too old'), findsOneWidget);
    await tester.tap(find.text('Update agent hooks'));
    expect(opened, 1);
  });

  testWidgets('without a setup callback the reason shows alone', (
    tester,
  ) async {
    await pumpPage(tester, [
      const AgentCommandResult(stdout: '', stderr: '', exitCode: 127),
    ]);
    expect(find.textContaining('not installed'), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-set-up-companion')), findsNothing);
  });
}
