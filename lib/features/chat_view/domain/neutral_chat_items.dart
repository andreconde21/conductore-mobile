import 'package:conduit/features/chat_view/domain/chat_items.dart';

/// Turns a neutral transcript page (`transcript` with `format: "items"`,
/// host/lib/adapters/chat-items.js) into the chat rows Claude Code's
/// entries build. The companion sends this format for every agent except
/// Claude Code, so the app never parses Codex, OpenCode or Gemini files.
///
/// Unknown item types and malformed items are skipped, so a newer
/// companion can add them. A `sidechain` item (a subagent's tool call) is
/// folded under the `task` call whose id is its `parentId`.
class NeutralChatItems {
  const NeutralChatItems._();

  static const format = 'items';

  /// Whether [page] (one decoded `transcript` reply) is in this format.
  static bool isNeutralPage(Map<Object?, Object?> page) =>
      page['format'] == format;

  static List<ChatItem> parse(List<Object?> raw) {
    final items = <ChatItem>[];
    final calls = <String, ChatToolCall>{};
    for (final entry in raw) {
      if (entry is! Map) {
        continue;
      }
      final id = _string(entry['id']);
      if (id == null || id.isEmpty) {
        continue;
      }
      final at = _time(entry['at']);
      if (entry['sidechain'] == true) {
        final parent = calls[_string(entry['parentId']) ?? ''];
        final child = _item(id, at, entry);
        if (parent != null && child is ChatToolCall) {
          parent.children.add(child);
        }
        continue;
      }
      final item = _item(id, at, entry);
      if (item == null) {
        continue;
      }
      if (item is ChatThinking && items.lastOrNull is ChatThinking) {
        final last = items.removeLast() as ChatThinking;
        items.add(ChatThinking(last.id, count: last.count + 1));
        continue;
      }
      if (item is ChatToolCall) {
        calls[id] = item;
      }
      items.add(item);
    }
    return items;
  }

  static ChatItem? _item(String id, DateTime? at, Map<Object?, Object?> e) {
    switch (e['type']) {
      case 'user':
        return ChatUserMessage(
          id,
          text: _string(e['text']) ?? '',
          imageCount: _int(e['images']),
          timestamp: at,
          truncated: e['truncated'] == true,
        );
      case 'assistant':
        final text = _string(e['text']) ?? '';
        if (text.trim().isEmpty) {
          return null;
        }
        return ChatAssistantText(
          id,
          text: text,
          timestamp: at,
          truncated: e['truncated'] == true,
        );
      case 'thinking':
        return ChatThinking(id);
      case 'tool':
        final result = e['result'];
        return ChatToolCall(
          id,
          name: _string(e['tool']) ?? 'tool',
          input: {
            if (e['input'] case final Map<Object?, Object?> input)
              for (final field in input.entries)
                if (field.key is String) field.key! as String: field.value,
          },
          kind: toolKind(_string(e['toolKind'])),
          result: result is Map
              ? ChatToolResult(
                  content: _string(result['text']) ?? '',
                  isError: result['ok'] == false,
                  images: _int(result['images']),
                  truncated: result['truncated'] == true,
                )
              : null,
          inputTruncated: e['inputTruncated'] == true,
          timestamp: at,
        );
      case 'todo':
        return ChatTodoList(
          id,
          todos: [
            if (e['todos'] case final List<Object?> todos)
              for (final todo in todos)
                if (todo is Map && todo['text'] is String)
                  ChatTodo(
                    content: todo['text'] as String,
                    status: switch (todo['status']) {
                      'completed' => ChatTodoStatus.completed,
                      'in_progress' => ChatTodoStatus.inProgress,
                      _ => ChatTodoStatus.pending,
                    },
                  ),
          ],
        );
      case 'plan':
        return ChatPlan(
          id,
          plan: _string(e['plan']) ?? '',
          status: switch (e['status']) {
            'approved' => ChatPlanStatus.approved,
            'rejected' => ChatPlanStatus.rejected,
            _ => ChatPlanStatus.pending,
          },
          feedback: _string(e['feedback']),
        );
      case 'question':
        return ChatQuestion(
          id,
          questions: [
            if (e['questions'] case final List<Object?> questions)
              for (final q in questions)
                if (q is Map && q['question'] is String)
                  ChatQuestionPrompt(
                    question: q['question'] as String,
                    header: _string(q['header']),
                    multiSelect: q['multiSelect'] == true,
                    options: [
                      if (q['options'] case final List<Object?> options)
                        for (final o in options)
                          if (o is Map && o['label'] is String)
                            ChatQuestionOption(
                              label: o['label'] as String,
                              description: _string(o['description']),
                            ),
                    ],
                  ),
          ],
          answer: _string(e['answer']),
        );
      case 'notice':
        final text = _string(e['text']) ?? '';
        return ChatNotice(
          id,
          text: text,
          kind: switch (e['level']) {
            'error' => ChatNoticeKind.error,
            'interrupted' => ChatNoticeKind.interrupted,
            'compacted' => ChatNoticeKind.compacted,
            _ => ChatNoticeKind.info,
          },
        );
      case 'shell':
        return ChatShellCommand(
          id,
          command: _string(e['command']) ?? '',
          stdout: _string(e['stdout']),
          stderr: _string(e['stderr']),
          timestamp: at,
        );
      default:
        return null;
    }
  }

  /// The companion's neutral tool kinds onto the cards the app draws;
  /// kinds without a card of their own (mcp, todo, ...) are `other`.
  static ChatToolKind toolKind(String? kind) => switch (kind) {
    'bash' => ChatToolKind.bash,
    'edit' => ChatToolKind.edit,
    'write' => ChatToolKind.write,
    'read' => ChatToolKind.read,
    'search' => ChatToolKind.search,
    'web' => ChatToolKind.web,
    'task' => ChatToolKind.task,
    _ => ChatToolKind.other,
  };

  static String? _string(Object? value) => value is String ? value : null;

  static int _int(Object? value) => value is int && value > 0 ? value : 0;

  static DateTime? _time(Object? value) =>
      value is String ? DateTime.tryParse(value) : null;
}
