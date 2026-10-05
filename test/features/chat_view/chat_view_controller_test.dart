import 'dart:convert';
import 'dart:io';

import 'package:conduit/core/app_failure.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/chat_view/data/conductore_chat_client.dart';
import 'package:conduit/features/chat_view/domain/chat_items.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_controller.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';
import 'chat_fixtures.dart';

AgentCommandResult ok(String stdout) =>
    AgentCommandResult(stdout: stdout, stderr: '', exitCode: 0);

AgentCommandResult failed(String error) => AgentCommandResult(
  stdout: jsonEncode({'error': error}),
  stderr: '',
  exitCode: 1,
);

void main() {
  ChatViewController controllerFor(
    ScriptedAgentCommandRunner runner, {
    ChatDecide? decide,
    Listenable? agentChanges,
  }) {
    final controller = ChatViewController(
      runner: runner,
      sessionId: 's-1',
      decide: decide,
      agentChanges: agentChanges,
      pollInterval: const Duration(days: 1),
      tailBytes: 1000,
    );
    addTearDown(controller.dispose);
    return controller;
  }

  test(
    'first load reads the tail, later polls continue from the offset',
    () async {
      final runner = ScriptedAgentCommandRunner([
        ok(
          page([userLine('u1', 'hi')], offset: 50, start: 20, state: 'working'),
        ),
        ok(
          page([
            assistantLine('a1', [text('hello')]),
          ], offset: 90),
        ),
        ok(page([], offset: 90)),
      ]);
      final controller = controllerFor(runner);
      await controller.refresh();
      expect(
        runner.commands.single,
        contains('transcript s-1 --tail-bytes 1000'),
      );
      expect(controller.loading, isFalse);
      expect(controller.items.single, isA<ChatUserMessage>());
      expect(controller.hasOlder, isTrue);
      expect(controller.activity, ChatActivity.thinking);

      await controller.refresh();
      expect(runner.commands[1], contains('transcript s-1 --since 50'));
      expect(controller.items.last, isA<ChatAssistantText>());
      expect(controller.name, 'api');
      expect(controller.activity, ChatActivity.idle);

      await controller.refresh();
      expect(runner.commands[2], contains('--since 90'));
      expect(controller.items, hasLength(2));
    },
  );

  test('keeps reading while the transcript is ahead of the offset', () async {
    final runner = ScriptedAgentCommandRunner([
      ok(page([userLine('u1', 'a')], offset: 50, size: 120)),
      ok(page([userLine('u2', 'b')], offset: 120)),
    ]);
    final controller = controllerFor(runner);
    await controller.refresh();
    expect(runner.commands, hasLength(2));
    expect(runner.commands[1], contains('--since 50'));
    expect(controller.items, hasLength(2));
  });

  test('a reset page replaces what was loaded', () async {
    final runner = ScriptedAgentCommandRunner([
      ok(page([userLine('u1', 'old')], offset: 50)),
      ok(page([userLine('u9', 'new')], offset: 30, reset: true)),
    ]);
    final controller = controllerFor(runner);
    await controller.refresh();
    await controller.refresh();
    expect((controller.items.single as ChatUserMessage).text, 'new');
  });

  test('loadOlder pages backwards and prepends', () async {
    final runner = ScriptedAgentCommandRunner([
      ok(page([userLine('u2', 'recent')], offset: 90, start: 40)),
      ok(page([userLine('u1', 'older')], offset: 40)),
    ]);
    final controller = controllerFor(runner);
    await controller.refresh();
    await controller.loadOlder();
    expect(runner.commands[1], contains('--before 40 --max-bytes 1000'));
    expect(controller.items.map((i) => (i as ChatUserMessage).text), [
      'older',
      'recent',
    ]);
    expect(controller.hasOlder, isFalse);
  });

  test(
    'send types base64 text and polls; errors surface as AppFailure',
    () async {
      final runner = ScriptedAgentCommandRunner([
        ok(page([], offset: 10)),
        ok('{"ok":true}'),
        ok(page([userLine('u1', "it's done?\nyes")], offset: 60)),
        failed('agent is waiting for a permission decision; answer it first'),
      ]);
      final controller = controllerFor(runner);
      await controller.refresh();
      await controller.send("it's done?\nyes");
      final encoded = base64.encode(utf8.encode("it's done?\nyes"));
      expect(runner.commands[1], contains('send s-1 --text-b64 $encoded'));
      expect(runner.commands[1], isNot(contains('--no-enter')));
      await pumpEventQueue();
      expect(controller.items.single, isA<ChatUserMessage>());
      await expectLater(
        controller.send('again'),
        throwsA(
          isA<AppFailure>().having(
            (f) => f.userMessage,
            'message',
            contains('permission decision'),
          ),
        ),
      );
      expect(controller.sending, isFalse);
    },
  );

  test('interrupt and question answers use the right commands', () async {
    final runner = ScriptedAgentCommandRunner([
      ok(page([], offset: 10)),
      ok('{"ok":true}'),
      ok(page([], offset: 10)),
      ok('{"ok":true}'),
      ok(page([], offset: 10)),
    ]);
    final controller = controllerFor(runner);
    await controller.refresh();
    await controller.interrupt();
    expect(runner.commands[1], contains('interrupt s-1'));
    await pumpEventQueue();
    await controller.answerQuestion(2);
    expect(
      runner.commands[3],
      contains(
        'send s-1 --text-b64 ${base64.encode(utf8.encode('2'))} '
        '--no-enter',
      ),
    );
  });

  test(
    'a missing or old companion stops polling with a clear reason',
    () async {
      final missing = ScriptedAgentCommandRunner([
        const AgentCommandResult(
          stdout: '',
          stderr: 'sh: conductore-hostd: not found',
          exitCode: 127,
        ),
      ]);
      final a = controllerFor(missing);
      await a.refresh();
      expect(a.unsupported, contains('not installed'));
      expect(a.canSend, isFalse);
      await a.refresh();
      expect(missing.commands, hasLength(1));

      final old = ScriptedAgentCommandRunner([
        failed('unknown command transcript\nusage: ...'),
      ]);
      final b = controllerFor(old);
      await b.refresh();
      expect(b.unsupported, contains('too old'));
      expect(a.unsupportedKind, ChatUnsupportedKind.notInstalled);
      expect(b.unsupportedKind, ChatUnsupportedKind.outdated);
    },
  );

  test('other errors keep the thread and are retried', () async {
    final runner = ScriptedAgentCommandRunner([
      ok(page([userLine('u1', 'hi')], offset: 50)),
      failed('unknown session s-1'),
      ok(page([], offset: 50)),
    ]);
    final controller = controllerFor(runner);
    await controller.refresh();
    await controller.refresh();
    expect(controller.error, contains('unknown session'));
    expect(controller.items, hasLength(1));
    await controller.refresh();
    expect(controller.error, isNull);
  });

  test('no transcript before the first turn is an empty chat, still '
      'polled (CON-071)', () async {
    final runner = ScriptedAgentCommandRunner([
      // An older companion: only the message says so.
      failed('transcript not found: /home/me/.claude/projects/x/s-1.jsonl'),
      // Since CON-071 it is marked.
      AgentCommandResult(
        stdout: jsonEncode({'error': 'anything', 'notYet': true}),
        stderr: '',
        exitCode: 1,
      ),
      failed(
        'no session file recorded for this Codex session yet (it appears '
        'with the next hook event)',
      ),
      ok(page([userLine('u1', 'hi')], offset: 50)),
    ]);
    final controller = controllerFor(runner);
    for (var i = 0; i < 3; i++) {
      await controller.refresh();
      expect(controller.loading, isFalse);
      expect(controller.error, isNull);
      expect(controller.items, isEmpty);
      expect(controller.unsupported, isNull);
    }
    await controller.refresh();
    expect(runner.commands.last, contains('--tail-bytes 1000'));
    expect(controller.items.single, isA<ChatUserMessage>());
  });

  test('a real transcript failure is still an error', () async {
    final runner = ScriptedAgentCommandRunner([
      failed('cannot read transcript: EACCES'),
    ]);
    final controller = controllerFor(runner);
    await controller.refresh();
    expect(controller.error, isNotNull);
  });

  test(
    'decide goes through the attention flow and drops the request',
    () async {
      final decided = <(String, PermissionVerdict)>[];
      final runner = ScriptedAgentCommandRunner([
        ok(
          page(
            [],
            offset: 10,
            state: 'needs_permission',
            pending: [
              {'id': 'req-1', 'toolName': 'Bash', 'summary': 'rm -rf build'},
            ],
          ),
        ),
        ok(page([], offset: 10, state: 'working')),
      ]);
      final controller = controllerFor(
        runner,
        decide: (request, verdict) async => decided.add((request.id, verdict)),
      );
      await controller.refresh();
      expect(controller.activity, ChatActivity.needsApproval);
      expect(controller.canSend, isFalse);
      await controller.decide(
        controller.pending.single,
        PermissionVerdict.allow,
      );
      expect(decided, [('req-1', PermissionVerdict.allow)]);
      expect(controller.pending, isEmpty);
    },
  );

  test('an agent change triggers a poll while visible', () async {
    final changes = ChangeNotifier();
    addTearDown(changes.dispose);
    final runner = ScriptedAgentCommandRunner([ok(page([], offset: 10))]);
    final controller = controllerFor(runner, agentChanges: changes);
    changes.notifyListeners();
    await pumpEventQueue();
    expect(runner.commands, isEmpty);
    controller.setVisible(true);
    await pumpEventQueue();
    expect(runner.commands, hasLength(1));
    changes.notifyListeners();
    await pumpEventQueue();
    expect(runner.commands, hasLength(2));
    controller.setVisible(false);
  });

  test('a quiet chat polls less often; anything new returns to the pace, '
      'and quiet polls notify no one', () {
    fakeAsync((async) {
      final runner = ScriptedAgentCommandRunner([
        ok(page([userLine('u1', 'hi')], offset: 50)),
        ok(page([], offset: 50)),
      ]);
      final controller = ChatViewController(
        runner: runner,
        sessionId: 's-1',
        pollInterval: const Duration(seconds: 1),
      );
      var notifies = 0;
      controller
        ..addListener(() => notifies += 1)
        ..setVisible(true);
      async.elapse(const Duration(seconds: 1));
      notifies = 0;
      final start = runner.commands.length;
      // 10 polls at 1 s, 10 at 2 s, then every 4 s.
      async.elapse(const Duration(seconds: 60));
      final polls = runner.commands.length - start;
      expect(polls, inInclusiveRange(22, 27));
      expect(notifies, 0);

      // The monitor saw a change: back to every second.
      final changes = ChangeNotifier();
      final watched = ChatViewController(
        runner: runner,
        sessionId: 's-1',
        agentChanges: changes,
        pollInterval: const Duration(seconds: 1),
      )..setVisible(true);
      async.elapse(const Duration(seconds: 60));
      changes.notifyListeners();
      async.flushMicrotasks();
      final after = runner.commands.length;
      async.elapse(const Duration(seconds: 5));
      // The timer keeps its 4 s pace until the next poll retimes it; from
      // then on it is every second again.
      expect(runner.commands.length - after, greaterThanOrEqualTo(2));
      controller.dispose();
      watched.dispose();
    });
  });

  test(
    'transcript asks for gzip last, and a packed page reads the same',
    () async {
      final plain = page([userLine('u1', 'hi')], offset: 50);
      final runner = ScriptedAgentCommandRunner([
        ok(
          jsonEncode({
            'encoding': 'gzip',
            'data': base64.encode(gzip.encode(utf8.encode(plain))),
          }),
        ),
      ]);
      final controller = controllerFor(runner);
      await controller.refresh();
      expect(runner.commands.single, contains('--tail-bytes 1000 --gzip'));
      expect(controller.items.single, isA<ChatUserMessage>());
    },
  );

  test('the window keeps the newest entries and pages back to the dropped '
      'ones (CON-089)', () async {
    // 21 reads of 100 entries each, read 1 at byte 1000, read n at n*1000.
    final reads = [
      for (var n = 1; n <= 21; n++)
        ok(
          page(
            [for (var i = 0; i < 100; i++) userLine('u$n-$i', 'line')],
            start: n == 1 ? 1000 : 0,
            offset: (n + 1) * 1000,
          ),
        ),
      ok(page([userLine('old', 'older')], start: 2000, offset: 3000)),
    ];
    final runner = ScriptedAgentCommandRunner(reads);
    final controller = controllerFor(runner);
    for (var n = 1; n <= 21; n++) {
      await controller.refresh();
    }
    // 2100 entries > 1500 + 500: the oldest reads went, down to 1500.
    expect(controller.windowEntries, 1500);
    expect(controller.hasOlder, isTrue);
    await controller.loadOlder();
    // Back from where the first kept read began (read 7 at 7000).
    expect(runner.commands.last, contains('--before 7000'));
  });

  test('a working agent that writes nothing slows the 1 s poll (CON-089)', () {
    fakeAsync((async) {
      final runner = ScriptedAgentCommandRunner([
        ok(page([userLine('u1', 'hi')], offset: 50, state: 'working')),
        ok(page([], offset: 50, state: 'working')),
      ]);
      final controller = ChatViewController(
        runner: runner,
        sessionId: 's-1',
        pollInterval: const Duration(milliseconds: 1500),
      )..setVisible(true);
      async.elapse(const Duration(seconds: 2));
      final start = runner.commands.length;
      // 10 polls at 1 s, 10 at 2 s, then every 4 s: not 60.
      async.elapse(const Duration(seconds: 60));
      expect(runner.commands.length - start, inInclusiveRange(22, 28));
      controller.dispose();
    });
  });
}
