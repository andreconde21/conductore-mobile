import 'dart:convert';
import 'dart:io';

import 'package:conduit/features/chat_view/domain/chat_items.dart';
import 'package:conduit/features/chat_view/domain/neutral_chat_items.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Built by host/lib/adapters/chat-items.js (host/test/fixtures/
  // neutral-chat-page.js); the companion's tests check it stays so.
  final page =
      jsonDecode(
            File(
              'test/fixtures/agent_adapters/neutral_chat_page.json',
            ).readAsStringSync(),
          )
          as Map<String, Object?>;

  test('a neutral page becomes the same chat rows Claude entries build', () {
    expect(NeutralChatItems.isNeutralPage(page), isTrue);
    expect(NeutralChatItems.isNeutralPage({'entries': []}), isFalse);
    final items = NeutralChatItems.parse(page['items']! as List<Object?>);
    expect(items.map((i) => i.id), [
      'u1',
      'th1',
      'a1',
      't1',
      't2',
      't4',
      'td1',
      'p1',
      'q1',
      'n1',
      'n2',
      's1',
    ]);

    final user = items[0] as ChatUserMessage;
    expect(user.text, 'Fix the failing test');
    expect(user.timestamp, DateTime.utc(2026, 10, 3, 10));

    // Consecutive thinking steps merge, as for Claude Code.
    expect((items[1] as ChatThinking).count, 2);
    expect((items[2] as ChatAssistantText).text, 'Running the tests first.');

    final bash = items[3] as ChatToolCall;
    expect(bash.name, 'exec_command');
    expect(bash.kind, ChatToolKind.bash);
    expect(bash.input, {'cmd': 'npm test'});
    expect(bash.failed, isTrue);
    expect(bash.result!.content, '1 failing');

    // The subagent's call is folded under its task.
    final task = items[4] as ChatToolCall;
    expect(task.kind, ChatToolKind.task);
    expect(task.running, isTrue);
    expect(task.children.single.name, 'read_file');
    expect(task.children.single.kind, ChatToolKind.read);

    expect((items[5] as ChatToolCall).kind, ChatToolKind.other);

    final todos = (items[6] as ChatTodoList).todos;
    expect(todos.map((t) => t.status), [
      ChatTodoStatus.inProgress,
      ChatTodoStatus.pending,
      ChatTodoStatus.completed,
    ]);

    final plan = items[7] as ChatPlan;
    expect(plan.status, ChatPlanStatus.rejected);
    expect(plan.feedback, 'Too long');

    final question = items[8] as ChatQuestion;
    expect(question.answered, isTrue);
    expect(question.questions.single.header, 'DB');
    expect(question.questions.single.options.map((o) => o.label), [
      'Postgres',
      'SQLite',
    ]);
    expect(question.questions.single.options.first.description, 'SQL');

    expect((items[9] as ChatNotice).kind, ChatNoticeKind.compacted);
    expect((items[10] as ChatNotice).kind, ChatNoticeKind.error);
    final shell = items[11] as ChatShellCommand;
    expect(shell.command, 'git status');
    expect(shell.stdout, 'clean');
  });

  test('malformed and unknown items are skipped', () {
    final items = NeutralChatItems.parse([
      null,
      7,
      {'type': 'user', 'text': 'no id'},
      {'id': 'x', 'type': 'nope'},
      {'id': 'a', 'type': 'assistant', 'text': '  '},
      {'id': 'o', 'type': 'tool', 'sidechain': true, 'parentId': 'missing'},
      {'id': 'ok', 'type': 'user', 'text': 'hi', 'at': 'not a time'},
    ]);
    expect(items.map((i) => i.id), ['ok']);
    expect((items.single as ChatUserMessage).timestamp, isNull);
  });
}
