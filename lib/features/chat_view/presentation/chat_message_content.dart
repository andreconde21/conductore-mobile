import 'package:conduit/features/chat_view/domain/chat_items.dart';
import 'package:conduit/features/chat_view/domain/chat_outgoing.dart';
import 'package:conduit/features/chat_view/domain/chat_tool_summary.dart';
import 'package:conduit/features/chat_view/presentation/widgets/chat_markdown.dart';

/// The text of one thread row for its actions (copy, share, send to
/// another agent, quote): [text] as written, Markdown when [markdown].
class ChatMessageContent {
  const ChatMessageContent(this.text, {this.markdown = false});

  final String text;
  final bool markdown;

  /// [text] without Markdown ("Copy").
  String get plain => markdown ? markdownToPlainText(text) : text;

  /// Whether "Copy as Markdown" would copy something else than "Copy".
  bool get hasMarkdown => markdown && plain != text;

  /// The content of [item], or null for rows with nothing to act on
  /// (thinking steps).
  static ChatMessageContent? of(ChatItem item) {
    final text = switch (item) {
      ChatUserMessage(:final text, :final pasted) => [
        if (text.isNotEmpty) text,
        ...pasted,
      ].join('\n\n'),
      ChatAssistantText(:final text) => text,
      ChatAgentMessage(:final summary, :final body) => [
        if (summary != null && summary.isNotEmpty) summary,
        if (body.isNotEmpty) body,
      ].join('\n\n'),
      ChatTaskNotice(:final summary) => summary,
      ChatShellCommand(:final command, :final stdout, :final stderr) => [
        '! $command',
        if (stdout?.trim().isNotEmpty ?? false) stdout!.trim(),
        if (stderr?.trim().isNotEmpty ?? false) stderr!.trim(),
      ].join('\n'),
      ChatToolCall() => _tool(item),
      ChatTodoList(:final todos) => [
        for (final todo in todos)
          '- [${todo.status == ChatTodoStatus.completed ? 'x' : ' '}] '
              '${todo.content}',
      ].join('\n'),
      ChatPlan(:final plan) => plan,
      ChatQuestion(:final questions) => [
        for (final question in questions) ...[
          question.question,
          for (var i = 0; i < question.options.length; i++)
            '${i + 1}. ${question.options[i].label}',
        ],
      ].join('\n'),
      ChatNotice(:final text) => text,
      ChatThinking() => '',
    };
    if (text.trim().isEmpty) return null;
    return ChatMessageContent(
      text,
      markdown: item is ChatAssistantText || item is ChatPlan,
    );
  }

  static ChatMessageContent outgoing(ChatOutgoing item) =>
      ChatMessageContent(item.text);

  static String _tool(ChatToolCall call) {
    final summary = ChatToolSummary.of(call);
    final output = call.result?.content.trim() ?? '';
    return [
      '${summary.title}: ${summary.subject}'.trim(),
      if (output.isNotEmpty) output,
    ].join('\n\n');
  }
}

/// The runs of text [item]'s row shows, in order, as the find bar
/// searches them; the row marks run `i` through `ChatSearchHighlight`.
/// Rows mark what they show: a collapsed card opens while it has the
/// current match.
List<String> chatSearchSegments(ChatItem item) => switch (item) {
  // 0: the prompt; 1..: pasted blocks.
  ChatUserMessage(:final text, :final pasted) => [text, ...pasted],
  ChatAssistantText(:final text) => markdownSearchSegments(text),
  // Idle: 0 the result. Else 0 the summary, 1 the body.
  ChatAgentMessage(:final idle, :final summary, :final body) =>
    idle ? [body] : [summary ?? '', body],
  ChatTaskNotice(:final summary) => [summary],
  // 0 the command, 1 its output.
  ChatShellCommand(:final stdout, :final stderr, :final command) => [
    command,
    [
      if (stdout?.trim().isNotEmpty ?? false) stdout!.trim(),
      if (stderr?.trim().isNotEmpty ?? false) stderr!.trim(),
    ].join('\n'),
  ],
  // 0 the subject line, 1 the full result.
  ChatToolCall() => [
    ChatToolSummary.of(item).subject,
    item.result?.content ?? '',
  ],
  ChatTodoList(:final todos) => [for (final todo in todos) todo.content],
  ChatPlan(:final plan) => markdownSearchSegments(plan),
  ChatQuestion(:final questions) => [
    for (final question in questions) ...[
      question.question,
      for (final option in question.options) option.label,
    ],
  ],
  ChatNotice(:final text) => [text],
  ChatThinking() => const [],
};
