import 'dart:async';
import 'dart:convert';

import 'package:conduit/core/app_failure.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/chat_view/domain/chat_items.dart';
import 'package:conduit/features/chat_view/domain/chat_outgoing.dart';
import 'package:conduit/features/chat_view/domain/chat_transcript.dart';
import 'package:conduit/features/chat_view/domain/chat_user_input.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_controller.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chat_fixtures.dart';

AgentCommandResult ok(String stdout) =>
    AgentCommandResult(stdout: stdout, stderr: '', exitCode: 0);

AgentCommandResult refused(String error) => AgentCommandResult(
  stdout: jsonEncode({'error': error}),
  stderr: '',
  exitCode: 1,
);

/// A host whose `transcript` replies come from [pages], in turn (nothing
/// new once they run out), and whose `send` replies come from [sends] (ok
/// when empty); a [Completer] in [sends] holds that send in flight.
class FakeHost implements AgentCommandRunner {
  final List<String> pages = [];
  final List<Object> sends = [];
  final List<String> sent = [];
  var _offset = 0;

  @override
  Future<AgentCommandResult> run(
    String command, {
    required Duration timeout,
  }) async {
    if (command.contains(' transcript ')) {
      if (pages.isEmpty) {
        return ok(page([], offset: _offset));
      }
      final reply = pages.removeAt(0);
      _offset = (jsonDecode(reply) as Map)['offset'] as int;
      return ok(reply);
    }
    final b64 = RegExp('--text-b64 ([A-Za-z0-9+/=]+)').firstMatch(command)![1]!;
    sent.add(utf8.decode(base64.decode(b64)));
    final step = sends.isEmpty ? ok('{"ok":true}') : sends.removeAt(0);
    return switch (step) {
      final Completer<AgentCommandResult> c => c.future,
      final AgentCommandResult r => r,
      _ => throw StateError('bad step'),
    };
  }

  @override
  Future<void> close() async {}
}

/// Reads what is new, including a poll a send scheduled meanwhile.
Future<void> settle(ChatViewController controller) async {
  await controller.refresh();
  await pumpEventQueue();
}

void main() {
  var now = DateTime.utc(2026, 9, 25, 10, 0, 30);

  ChatViewController controllerFor(FakeHost host) {
    final controller = ChatViewController(
      runner: host,
      sessionId: 's-1',
      pollInterval: const Duration(days: 1),
      clock: () => now,
    );
    addTearDown(controller.dispose);
    return controller;
  }

  setUp(() => now = DateTime.utc(2026, 9, 25, 10, 0, 30));

  final earlier = [
    userLine('u0', 'start'),
    assistantLine('a0', [text('Working on it.')]),
  ];

  group('controller', () {
    test('a prompt shows at once, then is replaced by its entry', () async {
      final host = FakeHost()..pages.add(page(earlier, offset: 10));
      final controller = controllerFor(host);
      await settle(controller);

      final inFlight = Completer<AgentCommandResult>();
      host.sends.add(inFlight);
      final sending = controller.send('also fix the docs');
      expect(controller.outgoing.single.state, ChatSendState.sending);
      expect(controller.outgoing.single.text, 'also fix the docs');
      // Never a transcript item: read-aloud and Talk do not see it.
      expect(controller.items, hasLength(2));

      host.pages.add(page([], offset: 10));
      inFlight.complete(ok('{"ok":true}'));
      await sending;
      expect(controller.outgoing.single.state, ChatSendState.sent);
      expect(controller.outgoing.single.pending, isTrue);

      host.pages.add(page([userLine('u1', 'also fix the docs')], offset: 30));
      await settle(controller);
      final user = controller.items.whereType<ChatUserMessage>().toList();
      expect(user.map((u) => u.text), ['start', 'also fix the docs']);
      expect(controller.outgoing.single.pending, isFalse);
      expect(controller.outgoing.single.confirmedId, 'u1');
      expect(controller.outgoing.where((o) => o.pending), isEmpty);
    });

    test('an old entry with the same text does not confirm it', () async {
      final host = FakeHost()
        ..pages.add(
          page([
            userLine('u0', 'please continue'),
            assistantLine('a0', [text('Done.')]),
          ], offset: 10),
        );
      final controller = controllerFor(host);
      await settle(controller);
      await controller.send('please continue');
      await pumpEventQueue();
      expect(controller.outgoing.single.pending, isTrue);
      host.pages.add(page([userLine('u1', 'please continue')], offset: 20));
      await settle(controller);
      expect(controller.outgoing.single.confirmedId, 'u1');
    });

    test(
      'a refused send fails with its reason; retry sends it again',
      () async {
        final host = FakeHost()
          ..pages.add(page(earlier, offset: 10))
          ..sends.add(
            refused(
              'agent is waiting for a permission decision; answer it first',
            ),
          );
        final controller = controllerFor(host);
        await settle(controller);
        await expectLater(
          controller.send('ship it'),
          throwsA(isA<AppFailure>()),
        );
        final failed = controller.outgoing.single;
        expect(failed.state, ChatSendState.failed);
        expect(failed.error, contains('permission decision'));

        await controller.retry(failed.id);
        expect(host.sent, ['ship it', 'ship it']);
        final retried = controller.outgoing.single;
        expect(retried.id, isNot(failed.id));
        expect(retried.state, ChatSendState.sent);
      },
    );

    test('discard hands a failed prompt back for editing', () async {
      final host = FakeHost()
        ..pages.add(page(earlier, offset: 10))
        ..sends.add(refused('session has ended'));
      final controller = controllerFor(host);
      await settle(controller);
      await expectLater(controller.send('draft'), throwsA(isA<AppFailure>()));
      expect(controller.discard(controller.outgoing.single.id), 'draft');
      expect(controller.outgoing, isEmpty);
    });

    test(
      'a sent prompt missing from the transcript says so and stays',
      () async {
        final host = FakeHost()..pages.add(page(earlier, offset: 10));
        final controller = controllerFor(host);
        await settle(controller);
        await controller.send('are you there?');
        expect(controller.outgoing.single.late, isFalse);

        now = now.add(const Duration(minutes: 3));
        host.pages.add(
          page(
            [
              assistantLine('a1', [text('Still working.')]),
            ],
            offset: 20,
            state: 'working',
          ),
        );
        await settle(controller);
        await settle(controller);
        final late = controller.outgoing.single;
        expect(late.state, ChatSendState.sent);
        expect(late.late, isTrue);
        expect(late.pending, isTrue);

        // It still merges when it finally shows.
        host.pages.add(page([userLine('u9', 'are you there?')], offset: 40));
        await settle(controller);
        expect(controller.outgoing.single.confirmedId, 'u9');
      },
    );

    test('quick sends go out in order and confirm in order', () async {
      final host = FakeHost()..pages.add(page(earlier, offset: 10));
      final controller = controllerFor(host);
      await settle(controller);
      final first = Completer<AgentCommandResult>();
      host.sends.add(first);
      final sends = [
        controller.send('one'),
        controller.send('two'),
        controller.send('one'),
      ];
      expect(controller.outgoing.map((o) => o.text), ['one', 'two', 'one']);
      await pumpEventQueue();
      // The second waits for the first.
      expect(host.sent, ['one']);
      first.complete(ok('{"ok":true}'));
      await Future.wait(sends);
      expect(host.sent, ['one', 'two', 'one']);

      host.pages.add(
        page([
          userLine('u1', 'one'),
          userLine('u2', 'two'),
          userLine('u3', 'one'),
        ], offset: 40),
      );
      await settle(controller);
      expect(controller.outgoing.map((o) => o.confirmedId), ['u1', 'u2', 'u3']);
    });

    test('a failure fails the sends queued behind it', () async {
      final host = FakeHost()..pages.add(page(earlier, offset: 10));
      final controller = controllerFor(host);
      await settle(controller);
      final first = Completer<AgentCommandResult>();
      host.sends.add(first);
      final a = controller.send('one');
      final b = controller.send('two');
      first.complete(refused('session not in tmux or Herdr'));
      await expectLater(a, throwsA(isA<AppFailure>()));
      await expectLater(b, throwsA(isA<AppFailure>()));
      expect(host.sent, ['one']);
      expect(
        controller.outgoing.map((o) => o.state),
        everyElement(ChatSendState.failed),
      );
      expect(controller.outgoing.last.error, contains('before it failed'));
    });

    test('a question answer shows until the question is answered', () async {
      final question = assistantLine('a1', [
        toolUse('q1', 'AskUserQuestion', {
          'questions': [
            {
              'question': 'Which one?',
              'options': [
                {'label': 'Left'},
                {'label': 'Right'},
              ],
            },
          ],
        }),
      ]);
      final host = FakeHost()..pages.add(page([question], offset: 10));
      final controller = controllerFor(host);
      await settle(controller);
      await controller.answerQuestion(2, label: 'Right');
      expect(host.sent, ['2']);
      final answer = controller.outgoing.single;
      expect(answer.answer, isTrue);
      expect(answer.text, '2. Right');
      expect(controller.isAnswering('q1'), isTrue);

      host.pages.add(
        page([
          userLine('r1', [toolResult('q1', 'User answered: Right')]),
        ], offset: 20),
      );
      await settle(controller);
      expect(controller.outgoing.single.pending, isFalse);
      expect(controller.isAnswering('q1'), isFalse);
    });

    test('without an open question an answer types only the key', () async {
      final host = FakeHost()..pages.add(page(earlier, offset: 10));
      final controller = controllerFor(host);
      await settle(controller);
      await controller.answerQuestion(1);
      expect(host.sent, ['1']);
      expect(controller.outgoing, isEmpty);
    });

    test('a prompt typed mid-turn confirms from its queued entry', () async {
      final host = FakeHost()..pages.add(page(earlier, offset: 10));
      final controller = controllerFor(host);
      await settle(controller);
      await controller.send('and the changelog');
      host.pages.add(
        page(
          [
            assistantLine('a1', [
              toolUse('t1', 'Bash', {'command': 'ls'}),
            ]),
            // What the host now makes of Claude Code's queued_command
            // attachment.
            {...userLine('q1', 'and the changelog'), 'queued': true},
          ],
          offset: 40,
          state: 'working',
        ),
      );
      await settle(controller);
      expect(controller.outgoing.single.confirmedId, 'q1');
    });
  });

  group('matching', () {
    ChatUserMessage user(
      String text, {
      List<String> pasted = const [],
      bool truncated = false,
    }) =>
        ChatUserMessage('u', text: text, pasted: pasted, truncated: truncated);

    test('whitespace, pastes, images and the host cap', () {
      expect(ChatOutgoingMatch.matches('fix  it\n', user('fix it')), isTrue);
      expect(
        ChatOutgoingMatch.matches(
          'look:\nline 1\nline 2',
          user('look:', pasted: ['line 1\nline 2']),
        ),
        isTrue,
      );
      expect(
        ChatOutgoingMatch.matches(
          'why red? /tmp/conductore/shot-1.png',
          user('why red? [Image #1]'),
        ),
        isTrue,
      );
      final long = List.filled(9000, 'word').join(' ');
      expect(
        ChatOutgoingMatch.matches(
          long,
          user('${long.substring(0, 32 * 1024 - 1)}…', truncated: true),
        ),
        isTrue,
      );
      expect(ChatOutgoingMatch.matches('fix it', user('fix that')), isFalse);
      expect(
        ChatOutgoingMatch.matches(
          '!git status',
          const ChatShellCommand('s', command: 'git status'),
        ),
        isTrue,
      );
      expect(
        ChatOutgoingMatch.matches(
          '/review 42',
          const ChatUserMessage('c', text: '/review 42', isCommand: true),
        ),
        isTrue,
      );
    });

    test('the transcript shapes of prompts confirm', () {
      String? shown(Map<String, Object?> line) {
        final items = ChatItemBuilder.build([
          TranscriptParser.parseEntry(line)!,
        ]);
        return items.whereType<ChatUserMessage>().singleOrNull?.text;
      }

      // Older Claude Code: the queued prompt as a wrapped user line.
      expect(
        shown(
          userLine(
            'w1',
            'The user sent a new message while you were working:\n'
                'and the tests\n\nIMPORTANT: After completing your current task, '
                "you MUST address the user's message above.",
          ),
        ),
        'and the tests',
      );
      // With images: placeholder text and image blocks.
      expect(
        shown(
          userLine('i1', [
            text('[Image #3] this one'),
            {'type': 'image', 'omitted': true, 'mediaType': 'image/png'},
          ]),
        ),
        '[Image #3] this one',
      );
      // Capped by the host.
      final capped = {
        ...userLine('l1', '${'x' * 100}…'),
        'message': {
          'role': 'user',
          'content': '${'x' * 100}…',
          'truncated': true,
        },
      };
      final item =
          ChatItemBuilder.build([TranscriptParser.parseEntry(capped)!]).single
              as ChatUserMessage;
      expect(item.truncated, isTrue);
      expect(ChatOutgoingMatch.matches('x' * 5000, item), isTrue);
    });
  });

  group('genuine prompts are never taken for injected content', () {
    // Property-style: every sample is something a person could type; each
    // must come back whole as the user's text.
    const samples = [
      'fix it',
      'Check the <system-reminder> handling in chat_user_input.dart',
      'the tag <system-reminder> is stripped, then what?',
      'why does <teammate-message> render as a card?',
      'Another Claude session sent a message: is what the harness writes',
      'what does "This came from another Claude session" mean here?',
      'I saw [SYSTEM NOTIFICATION - NOT USER INPUT] in the log',
      'compare a < b and b > c',
      '<div class="x">html</div> is broken',
      'IMPORTANT: do not push',
      'Olá, podes ver isto? ção ñ 🎉',
      '```dart\nfinal x = <String>[];\n```',
      '- one\n- two\n\n1. three',
      '<command-name> is a tag Claude Code writes',
      'please remove <bash-input> handling',
    ];

    for (final sample in samples) {
      test(sample.split('\n').first, () {
        final parts = ChatUserInput.parse(sample);
        expect(parts, hasLength(1), reason: sample);
        final part = parts.single;
        if (part is UserTextPart) {
          expect(part.text, sample.trim());
        } else {
          // Literal harness tags a person typed whole are the only ones
          // allowed to read as that input.
          fail('"$sample" parsed as ${part.runtimeType}');
        }
      });
    }

    test('pasted text full of harness tags stays the user\'s paste', () {
      const log =
          '<system-reminder>quoted</system-reminder>\n'
          '<teammate-message teammate_id="x">quoted</teammate-message>\n'
          '<bash-input>ls</bash-input>';
      final part =
          ChatUserInput.parse(
                'what is this?\n<pasted_content id="p1">\n$log\n'
                '</pasted_content>',
              ).single
              as UserTextPart;
      expect(part.text, 'what is this?');
      expect(part.pasted, [log]);
    });

    test('long prompts survive whole up to the cap', () {
      final long = List.generate(3000, (i) => 'line $i').join('\n');
      final part = ChatUserInput.parse(long).single as UserTextPart;
      expect(part.text, long);
    });
  });

  group('page', () {
    Future<(ChatViewController, FakeHost)> pumpPage(WidgetTester tester) async {
      final host = FakeHost()..pages.add(page(earlier, offset: 10));
      final controller = ChatViewController(
        runner: host,
        sessionId: 's-1',
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
      // The page owns (and disposes) the controller.
      addTearDown(() => tester.pumpWidget(const SizedBox()));
      return (controller, host);
    }

    testWidgets('a sent prompt shows at once, then once as the real bubble', (
      tester,
    ) async {
      final (_, host) = await pumpPage(tester);
      final inFlight = Completer<AgentCommandResult>();
      host.sends.add(inFlight);
      await tester.enterText(find.byType(TextField), 'also the docs');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      expect(find.text('also the docs'), findsOneWidget);
      expect(find.text('Sending…'), findsOneWidget);

      host.pages.add(page([], offset: 10));
      inFlight.complete(ok('{"ok":true}'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Sent'), findsOneWidget);

      host.pages.add(page([userLine('u1', 'also the docs')], offset: 30));
      await tester
          .widget<ChatViewPage>(find.byType(ChatViewPage))
          .controller
          .refresh();
      await tester.pump();
      expect(find.text('also the docs'), findsOneWidget);
      expect(find.text('Sent'), findsNothing);
      expect(find.text('Sending…'), findsNothing);
    });

    testWidgets('a failed prompt offers Retry and Edit', (tester) async {
      final (controller, host) = await pumpPage(tester);
      host.sends.add(refused('session not in tmux or Herdr'));
      await tester.enterText(find.byType(TextField), 'ship it');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('Not sent'), findsOneWidget);
      // The composer did not keep it: the bubble does.
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );

      await tester.tap(find.byKey(const ValueKey('outgoing-edit')));
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'ship it',
      );
      expect(controller.outgoing, isEmpty);

      host.sends.add(refused('session not in tmux or Herdr'));
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('outgoing-retry')));
      await tester.pump();
      await tester.pump();
      expect(host.sent, ['ship it', 'ship it', 'ship it']);
      expect(find.text('Sent'), findsOneWidget);
    });
  });
}
