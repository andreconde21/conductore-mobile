import 'dart:convert';
import 'dart:io';

import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/chat_view/data/conductore_chat_client.dart';
import 'package:conduit/features/chat_view/domain/chat_items.dart';
import 'package:conduit/features/chat_view/domain/chat_transcript.dart';
import 'package:conduit/features/chat_view/domain/neutral_chat_window.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_controller.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

AgentCommandResult ok(String stdout) =>
    AgentCommandResult(stdout: stdout, stderr: '', exitCode: 0);

/// Chat View on OpenCode sessions (CON-069): neutral pages, paged by the
/// companion's cursor. The replies are what the companion's OpenCode
/// adapter reads from a session recorded with OpenCode 1.18.34
/// (host/test/fixtures/opencode-transcript.js keeps them in sync).
void main() {
  final fixture =
      jsonDecode(
            File(
              'test/fixtures/agent_adapters/opencode_transcript.json',
            ).readAsStringSync(),
          )
          as Map<String, Object?>;
  final bash = fixture['bash']! as Map<String, Object?>;
  final question = fixture['question']! as Map<String, Object?>;
  String reply(Map<String, Object?> page) => jsonEncode(page);

  Map<String, Object?> item(String id, String type, [String? text]) => {
    'id': id,
    'type': type,
    'at': null,
    'text': ?text,
  };

  Map<String, Object?> pageOf(
    List<Map<String, Object?>> items, {
    String cursor = 'm2',
    String? startCursor,
    bool more = false,
    bool reset = false,
    String state = 'working',
  }) => {
    'sessionId': 's-1',
    'agent': {'name': 'proj', 'state': state, 'pending': <Object?>[]},
    'format': 'items',
    'items': items,
    'cursor': cursor,
    'startCursor': startCursor,
    'more': more,
    'reset': ?(reset ? true : null),
  };

  ChatViewController controllerFor(ScriptedAgentCommandRunner runner) {
    final controller = ChatViewController(
      runner: runner,
      sessionId: 's-1',
      pollInterval: const Duration(days: 1),
      tailBytes: 1000,
    );
    addTearDown(controller.dispose);
    return controller;
  }

  test('a neutral reply parses as a cursor page; the client sends cursors', () {
    final page = TranscriptParser.parsePage(reply(bash));
    expect(page.isNeutral, isTrue);
    expect(page.neutralItems, hasLength(4));
    expect(page.cursor, isNotEmpty);
    expect(page.startCursor, isNull);
    expect(page.entries, isEmpty);
    expect(page.agent?.name, 'proj');
    final claude = TranscriptParser.parsePage(
      jsonEncode({'entries': <Object?>[], 'offset': 3, 'size': 3}),
    );
    expect(claude.isNeutral, isFalse);
    expect(
      ConductoreChatClient.transcriptCommand('s-1', cursor: 'msg_1'),
      contains('transcript s-1 --cursor msg_1 --gzip'),
    );
    expect(
      ConductoreChatClient.transcriptCommand('s-1', beforeCursor: 'msg_0'),
      contains('--before-cursor msg_0'),
    );
  });

  test('the window replaces items sent again and resets on request', () {
    final window = NeutralChatWindow();
    expect(
      window.apply(
        TranscriptParser.parsePage(
          jsonEncode(
            pageOf([item('u1', 'user', 'hi'), item('a1', 'assistant', 'He')]),
          ),
        ),
      ),
      isTrue,
    );
    expect(window.cursor, 'm2');
    // The last message again, grown, plus a new item.
    expect(
      window.apply(
        TranscriptParser.parsePage(
          jsonEncode(
            pageOf([
              item('a1', 'assistant', 'Hello'),
              item('a2', 'assistant', 'Bye'),
            ], cursor: 'm3'),
          ),
        ),
      ),
      isTrue,
    );
    expect(window.build().map((i) => i is ChatAssistantText ? i.text : i.id), [
      'u1',
      'Hello',
      'Bye',
    ]);
    // The same again: nothing changed.
    expect(
      window.apply(
        TranscriptParser.parsePage(
          jsonEncode(pageOf([item('a2', 'assistant', 'Bye')], cursor: 'm3')),
        ),
      ),
      isFalse,
    );
    expect(
      window.apply(
        TranscriptParser.parsePage(
          jsonEncode(pageOf([item('x1', 'user', 'new')], reset: true)),
        ),
      ),
      isTrue,
    );
    expect(window.build().map((i) => i.id), ['x1']);
  });

  test(
    'OpenCode: the first load, polls from the cursor, older pages before',
    () async {
      final runner = ScriptedAgentCommandRunner([
        ok(
          reply(
            pageOf(
              [item('u2', 'user', 'second'), item('a2', 'assistant', 'Wor')],
              cursor: 'msg_2',
              startCursor: 'msg_2a',
            ),
          ),
        ),
        // The poll sends the last message again (it grew) and more.
        ok(
          reply(
            pageOf(
              [
                item('a2', 'assistant', 'Working on it'),
                item('a3', 'assistant', 'Done'),
              ],
              cursor: 'msg_3',
              startCursor: 'msg_2a',
              state: 'waiting_input',
            ),
          ),
        ),
        ok(reply(pageOf([item('u1', 'user', 'first')], cursor: 'msg_2a'))),
      ]);
      final controller = controllerFor(runner);
      await controller.refresh();
      expect(controller.items.map((i) => i.id), ['u2', 'a2']);
      expect(controller.hasOlder, isTrue);
      expect(controller.olderOnlyInTerminal, isFalse);

      await controller.refresh();
      expect(runner.commands[1], contains('transcript s-1 --cursor msg_2'));
      expect(runner.commands[1], isNot(contains('--since')));
      expect(controller.items.map((i) => i.id), ['u2', 'a2', 'a3']);
      expect((controller.items[1] as ChatAssistantText).text, 'Working on it');
      expect(controller.activity, ChatActivity.idle);

      await controller.loadOlder();
      expect(runner.commands[2], contains('--before-cursor msg_2a'));
      expect(controller.items.map((i) => i.id), ['u1', 'u2', 'a2', 'a3']);
      expect(controller.hasOlder, isFalse);
    },
  );

  test('OpenCode: keeps reading while the companion says more', () async {
    final runner = ScriptedAgentCommandRunner([
      ok(reply(pageOf([item('u1', 'user', 'a')], cursor: 'c1'))),
      ok(
        reply(pageOf([item('a1', 'assistant', 'b')], cursor: 'c2', more: true)),
      ),
      ok(reply(pageOf([item('a2', 'assistant', 'c')], cursor: 'c3'))),
    ]);
    final controller = controllerFor(runner);
    await controller.refresh();
    await controller.refresh();
    expect(runner.commands, hasLength(3));
    expect(runner.commands[2], contains('--cursor c2'));
    expect(controller.items.map((i) => i.id), ['u1', 'a1', 'a2']);
  });

  testWidgets('OpenCode session from the recorded transcript: bubbles, the '
      'command it ran and the answered question', (tester) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Future<ChatViewController> pump(Map<String, Object?> page) async {
      final controller = ChatViewController(
        runner: ScriptedAgentCommandRunner([ok(reply(page))]),
        sessionId: page['sessionId']! as String,
        pollInterval: const Duration(days: 1),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: ChatViewPage(
            controller: controller,
            hostName: 'dev',
            onOpenTerminal: () {},
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      return controller;
    }

    final chat = await pump(bash);
    expect(find.text('do it'), findsOneWidget);
    expect(
      find.textContaining('Running a command.', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining('All done.', findRichText: true),
      findsOneWidget,
    );
    // The command shows as a Bash card with its output.
    expect(find.text('Bash'), findsOneWidget);
    expect(find.text('echo hello-from-mock'), findsOneWidget);
    expect(find.text('hello-from-mock'), findsOneWidget);
    final call = chat.items.whereType<ChatToolCall>().single;
    expect(call.name, 'Bash');
    expect(call.input['command'], 'echo hello-from-mock');
    expect(call.result?.isError, isFalse);
    await tester.pumpWidget(const SizedBox());

    final asked = await pump(question);
    final q = asked.items.whereType<ChatQuestion>().single;
    expect(q.questions.single.question, 'Which colour?');
    expect(q.answer, 'Blue');
    expect(
      find.textContaining('Which colour?', findRichText: true),
      findsWidgets,
    );
    await tester.pumpWidget(const SizedBox());
  });
}
