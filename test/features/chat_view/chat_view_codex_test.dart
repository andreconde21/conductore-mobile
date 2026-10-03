import 'dart:convert';
import 'dart:io';

import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/chat_view/domain/chat_items.dart';
import 'package:conduit/features/chat_view/domain/chat_tool_summary.dart';
import 'package:conduit/features/chat_view/domain/chat_transcript.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

/// Chat View for Codex (CON-068): neutral pages paged by the companion's
/// opaque cursor. The page is what the companion's Codex adapter reads
/// from a real Codex 0.160.0 session (host/test/codex-adapter.test.js
/// keeps it so).
void main() {
  final real =
      jsonDecode(
            File(
              'test/fixtures/agent_adapters/codex_chat_page.json',
            ).readAsStringSync(),
          )
          as Map<String, Object?>;
  final realItems = (real['items']! as List<Object?>)
      .cast<Map<String, Object?>>();

  AgentCommandResult ok(Map<String, Object?> page) =>
      AgentCommandResult(stdout: jsonEncode(page), stderr: '', exitCode: 0);

  Map<String, Object?> itemsPage(
    List<Map<String, Object?>> items, {
    required String cursor,
    String? startCursor,
    bool more = false,
    bool reset = false,
    String state = 'waiting_input',
  }) => {
    'sessionId': 's-1',
    'agent': {...(real['agent']! as Map<String, Object?>), 'state': state},
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

  test('the real Codex page parses as a neutral transcript page', () {
    final page = TranscriptParser.parsePage(jsonEncode(real));
    expect(page.isNeutral, isTrue);
    expect(page.items, hasLength(15));
    expect(page.cursor, real['cursor']);
    expect(page.startCursor, isNull);
    expect(page.more, isFalse);
    expect(page.entries, isEmpty);
    // A Claude Code page stays as it was.
    final claude = TranscriptParser.parsePage(
      jsonEncode({'offset': 10, 'size': 10, 'start': 0, 'entries': []}),
    );
    expect(claude.isNeutral, isFalse);
    expect(claude.cursor, isNull);
  });

  test(
    'a Codex session reads by cursor: the tail, then what comes after',
    () async {
      final first = realItems.take(5).toList();
      final runner = ScriptedAgentCommandRunner([
        ok(itemsPage(first, cursor: '19864', startCursor: '4850')),
        ok(itemsPage(realItems.skip(5).toList(), cursor: '44075')),
        ok(itemsPage([], cursor: '44075')),
      ]);
      final controller = controllerFor(runner);
      await controller.refresh();
      expect(
        runner.commands.single,
        contains('transcript s-1 --tail-bytes 1000'),
      );
      expect(controller.items.map((i) => i.runtimeType), [
        ChatUserMessage,
        ChatThinking,
        ChatToolCall,
        ChatToolCall,
        ChatAssistantText,
      ]);
      expect(controller.hasOlder, isTrue);
      expect(controller.name, 'repo');

      await controller.refresh();
      expect(runner.commands[1], contains("transcript s-1 --cursor 19864"));
      expect(controller.items, hasLength(15));
      final denied = controller.items.whereType<ChatToolCall>().where(
        (c) => c.result?.isError ?? false,
      );
      expect(denied.map((c) => c.result!.content), [
        contains('Rejected'),
        'Denied from the phone',
      ]);

      // Nothing new: nothing rebuilt, the cursor stays.
      final before = controller.items;
      await controller.refresh();
      expect(runner.commands[2], contains("--cursor 44075"));
      expect(identical(controller.items, before), isTrue);
    },
  );

  test(
    "a running call's result arrives with the same id and replaces it",
    () async {
      final call = Map<String, Object?>.of(
        realItems.firstWhere((i) => i['id'] == 'call_5'),
      );
      final running = {...call, 'result': null};
      final runner = ScriptedAgentCommandRunner([
        ok(
          itemsPage([realItems[0], running], cursor: '5695', state: 'working'),
        ),
        // The companion held its cursor on the call: it comes again, done.
        ok(itemsPage([call, realItems[4]], cursor: '19864')),
      ]);
      final controller = controllerFor(runner);
      await controller.refresh();
      final tool = controller.items.whereType<ChatToolCall>().single;
      expect(tool.running, isTrue);
      expect(controller.activity, ChatActivity.working);

      await controller.refresh();
      expect(runner.commands[1], contains("--cursor 5695"));
      final done = controller.items.whereType<ChatToolCall>().single;
      expect(done.id, 'call_5');
      expect(done.running, isFalse);
      expect(controller.items.map((i) => i.id), ['4850', 'call_5', '12369']);
    },
  );

  test('more pages are read at once while the companion says so', () async {
    final runner = ScriptedAgentCommandRunner([
      ok(itemsPage(realItems.take(3).toList(), cursor: '10', more: true)),
      ok(itemsPage(realItems.skip(3).toList(), cursor: '44075')),
    ]);
    final controller = controllerFor(runner);
    await controller.refresh();
    expect(runner.commands, hasLength(2));
    expect(runner.commands[1], contains("--cursor 10"));
    expect(controller.items, hasLength(15));
  });

  test('loadOlder pages back by the start cursor until the start', () async {
    final runner = ScriptedAgentCommandRunner([
      ok(
        itemsPage(
          realItems.skip(10).toList(),
          cursor: '44075',
          startCursor: '34116',
        ),
      ),
      ok(
        itemsPage(
          realItems.skip(5).take(5).toList(),
          cursor: '34116',
          startCursor: '19864',
        ),
      ),
      ok(itemsPage(realItems.take(5).toList(), cursor: '19864')),
    ]);
    final controller = controllerFor(runner);
    await controller.refresh();
    expect(controller.items, hasLength(5));
    await controller.loadOlder();
    expect(
      runner.commands[1],
      contains("--before-cursor 34116 --max-bytes 1000"),
    );
    expect(controller.hasOlder, isTrue);
    await controller.loadOlder();
    expect(runner.commands[2], contains("--before-cursor 19864"));
    expect(controller.hasOlder, isFalse);
    expect(controller.olderOnlyInTerminal, isFalse);
    expect(
      controller.items.map((i) => i.id),
      realItems.map((i) => i['id']).toList(),
    );
    expect(
      controller.startedAt,
      DateTime.parse(realItems.first['at']! as String),
    );
  });

  test('a reset page replaces what was loaded', () async {
    final runner = ScriptedAgentCommandRunner([
      ok(itemsPage(realItems.take(5).toList(), cursor: '19864')),
      ok(itemsPage([realItems[10]], cursor: '900', reset: true)),
    ]);
    final controller = controllerFor(runner);
    await controller.refresh();
    await controller.refresh();
    expect(controller.items.map((i) => i.id), [realItems[10]['id']]);
  });

  test("Codex's tools read as a shell command and a patch", () {
    final page = TranscriptParser.parsePage(jsonEncode(real));
    final controllerItems = page.items!;
    final shell = controllerItems.firstWhere((i) => i['id'] == 'call_5');
    final patch = controllerItems.firstWhere((i) => i['id'] == 'call_7');
    ChatToolCall call(Map<Object?, Object?> raw) => ChatToolCall(
      raw['id']! as String,
      name: raw['tool']! as String,
      input: Map<String, Object?>.from(raw['input']! as Map),
      kind: raw['toolKind'] == 'bash' ? ChatToolKind.bash : ChatToolKind.edit,
    );
    final s = ChatToolSummary.of(call(shell));
    expect(s.title, 'Shell');
    expect(s.subject, 'touch /outside.txt');
    expect(s.detail, 'Need to write outside the workspace');
    final p = ChatToolSummary.of(call(patch));
    expect(p.title, 'Edit');
    expect(p.subject, 'hello.txt');
    expect(p.diff.map((l) => '${l.sign}${l.text}'), ['+hello from codex']);
  });
}
