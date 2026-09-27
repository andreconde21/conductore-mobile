import 'package:conduit/features/chat_view/domain/chat_transcript.dart';
import 'package:conduit/features/chat_view/domain/chat_user_input.dart';

/// What kind of card a tool call renders as.
enum ChatToolKind { bash, edit, write, read, search, web, task, other }

/// One row of the chat thread.
sealed class ChatItem {
  const ChatItem(this.id);

  /// Stable across rebuilds (tool_use id, or line uuid plus block index),
  /// used as the widget key so expanded cards stay expanded while polling.
  final String id;
}

class ChatUserMessage extends ChatItem {
  const ChatUserMessage(
    super.id, {
    required this.text,
    this.imageCount = 0,
    this.timestamp,
    this.isCommand = false,
    this.pasted = const [],
    this.truncated = false,
  });

  final String text;
  final int imageCount;
  final DateTime? timestamp;

  /// The host cut the prompt at its text cap.
  final bool truncated;

  /// A slash command rather than a prompt.
  final bool isCommand;

  /// Blocks the user pasted (`<pasted_content>`), shown collapsed.
  final List<String> pasted;
}

/// A message from another agent, not from the user: a teammate
/// (`<teammate-message>`) or another Claude session
/// (`<cross-session-message>`), or a teammate's idle notification.
class ChatAgentMessage extends ChatItem {
  const ChatAgentMessage(
    super.id, {
    required this.from,
    required this.body,
    this.summary,
    this.idle = false,
    this.session = false,
    this.timestamp,
  });

  /// The teammate id or session name.
  final String from;

  /// The sender's one-line summary, when it gave one.
  final String? summary;
  final String body;

  /// An `idle_notification`: the teammate finished; [body] is its result.
  final bool idle;

  /// From another Claude session rather than a teammate.
  final bool session;
  final DateTime? timestamp;
}

/// A background task finished (`<task-notification>`).
class ChatTaskNotice extends ChatItem {
  const ChatTaskNotice(super.id, {required this.summary, this.status});

  final String summary;

  /// `completed`, `failed`, ... as reported.
  final String? status;

  bool get failed => status == 'failed' || status == 'error';
}

/// A `!` shell command the user ran in Claude Code, with its output once
/// the next line brings it.
class ChatShellCommand extends ChatItem {
  const ChatShellCommand(
    super.id, {
    required this.command,
    this.stdout,
    this.stderr,
    this.timestamp,
  });

  final String command;
  final String? stdout;
  final String? stderr;
  final DateTime? timestamp;

  bool get hasOutput => stdout != null || stderr != null;
  bool get failed =>
      (stderr?.trim().isNotEmpty ?? false) && (stdout?.trim().isEmpty ?? true);

  ChatShellCommand withOutput(String stdout, String stderr) => ChatShellCommand(
    id,
    command: command,
    stdout: stdout,
    stderr: stderr,
    timestamp: timestamp,
  );
}

class ChatAssistantText extends ChatItem {
  const ChatAssistantText(
    super.id, {
    required this.text,
    this.timestamp,
    this.truncated = false,
  });

  final String text;
  final DateTime? timestamp;
  final bool truncated;
}

/// A reasoning step (text not transferred); consecutive ones are merged.
class ChatThinking extends ChatItem {
  const ChatThinking(super.id, {this.count = 1});

  final int count;
}

class ChatToolResult {
  const ChatToolResult({
    required this.content,
    required this.isError,
    this.images = 0,
    this.truncated = false,
  });

  final String content;
  final bool isError;
  final int images;
  final bool truncated;
}

class ChatToolCall extends ChatItem {
  ChatToolCall(
    super.id, {
    required this.name,
    required this.input,
    required this.kind,
    this.result,
    this.inputTruncated = false,
    this.timestamp,
  });

  final String name;
  final Map<String, Object?> input;
  final ChatToolKind kind;

  /// Null while the tool is still running (or was interrupted).
  final ChatToolResult? result;
  final bool inputTruncated;
  final DateTime? timestamp;

  /// For Task/Agent: the subagent's own tool calls (sidechain lines).
  final List<ChatToolCall> children = [];

  bool get failed => result?.isError ?? false;
  bool get running => result == null;
}

enum ChatTodoStatus { pending, inProgress, completed }

class ChatTodo {
  const ChatTodo({required this.content, required this.status});

  final String content;
  final ChatTodoStatus status;
}

class ChatTodoList extends ChatItem {
  const ChatTodoList(super.id, {required this.todos});

  final List<ChatTodo> todos;
}

enum ChatPlanStatus { pending, approved, rejected }

class ChatPlan extends ChatItem {
  const ChatPlan(
    super.id, {
    required this.plan,
    required this.status,
    this.feedback,
  });

  final String plan;
  final ChatPlanStatus status;

  /// The tool result text (why a plan was rejected, or the approval note).
  final String? feedback;
}

class ChatQuestionOption {
  const ChatQuestionOption({required this.label, this.description});

  final String label;
  final String? description;
}

class ChatQuestionPrompt {
  const ChatQuestionPrompt({
    required this.question,
    this.header,
    this.options = const [],
    this.multiSelect = false,
  });

  final String question;
  final String? header;
  final List<ChatQuestionOption> options;
  final bool multiSelect;
}

class ChatQuestion extends ChatItem {
  const ChatQuestion(super.id, {required this.questions, this.answer});

  final List<ChatQuestionPrompt> questions;

  /// The tool result (the user's answers), or null while unanswered.
  final String? answer;

  bool get answered => answer != null;
}

enum ChatNoticeKind { info, error, interrupted, compacted }

class ChatNotice extends ChatItem {
  const ChatNotice(super.id, {required this.text, required this.kind});

  final String text;
  final ChatNoticeKind kind;
}

/// Turns transcript lines into chat rows.
///
/// Tool results are matched to their calls by id (a result line never
/// renders on its own). Sidechain lines (a subagent's work) are folded into
/// the Task/Agent call that spawned them. Meta lines (injected skill text,
/// caveats) and bookkeeping system lines are dropped.
class ChatItemBuilder {
  const ChatItemBuilder._();

  static const _taskTools = {'Task', 'Agent'};

  static List<ChatItem> build(List<TranscriptEntry> entries) {
    final results = <String, ChatToolResult>{};
    for (final entry in entries) {
      for (final block in entry.blocks) {
        if (block is ToolResultBlock && block.toolUseId.isNotEmpty) {
          results[block.toolUseId] = ChatToolResult(
            content: block.content,
            isError: block.isError,
            images: block.images,
            truncated: block.truncated,
          );
        }
      }
    }

    final items = <ChatItem>[];
    final tasks = <ChatToolCall>[];
    for (var e = 0; e < entries.length; e++) {
      final entry = entries[e];
      final key = entry.uuid ?? 'line$e';
      if (entry.isMeta) {
        continue;
      }
      switch (entry.type) {
        case TranscriptEntryType.summary:
          // Session titles from older Claude Code versions; not a message.
          continue;
        case TranscriptEntryType.system:
          final notice = _systemNotice(key, entry);
          if (notice != null) {
            items.add(notice);
          }
          continue;
        case TranscriptEntryType.user:
        case TranscriptEntryType.assistant:
          break;
      }
      if (entry.isSidechain) {
        _addSidechain(entry, tasks, results);
        continue;
      }
      if (entry.isCompactSummary) {
        items.add(
          ChatNotice(
            key,
            text: 'Conversation compacted',
            kind: ChatNoticeKind.compacted,
          ),
        );
        continue;
      }
      if (entry.type == TranscriptEntryType.user) {
        _addUser(key, entry, items);
        continue;
      }
      if (entry.isApiError) {
        final text = entry.blocks.whereType<TextBlock>().map((b) => b.text);
        items.add(
          ChatNotice(key, text: text.join('\n'), kind: ChatNoticeKind.error),
        );
        continue;
      }
      for (var b = 0; b < entry.blocks.length; b++) {
        final block = entry.blocks[b];
        final id = '$key#$b';
        switch (block) {
          case TextBlock(:final text, :final truncated):
            if (text.trim().isEmpty || text.trim() == '(no content)') {
              continue;
            }
            items.add(
              ChatAssistantText(
                id,
                text: text,
                timestamp: entry.timestamp,
                truncated: truncated,
              ),
            );
          case ThinkingBlock():
            final last = items.lastOrNull;
            if (last is ChatThinking) {
              items[items.length - 1] = ChatThinking(
                last.id,
                count: last.count + 1,
              );
            } else {
              items.add(ChatThinking(id));
            }
          case ToolUseBlock():
            final item = _toolItem(
              block,
              results[block.id],
              entry.timestamp,
              id,
            );
            items.add(item);
            if (item is ChatToolCall && item.kind == ChatToolKind.task) {
              tasks.add(item);
            }
          case ToolResultBlock():
          case ImageBlock():
          case UnknownBlock():
            continue;
        }
      }
    }
    return items;
  }

  static ChatNotice? _systemNotice(String key, TranscriptEntry entry) {
    if (entry.subtype == 'compact_boundary') {
      return ChatNotice(
        key,
        text: 'Conversation compacted',
        kind: ChatNoticeKind.compacted,
      );
    }
    final text = entry.text?.trim();
    if (text == null || text.isEmpty) {
      return null;
    }
    if (entry.subtype == 'api_error' || entry.subtype == 'error') {
      return ChatNotice(key, text: text, kind: ChatNoticeKind.error);
    }
    // Hook summaries, local command output and the like stay in the TUI.
    return null;
  }

  static void _addUser(
    String key,
    TranscriptEntry entry,
    List<ChatItem> items,
  ) {
    final texts = <String>[];
    var images = 0;
    var truncated = false;
    for (final block in entry.blocks) {
      switch (block) {
        case TextBlock(:final text, truncated: final cut):
          texts.add(text);
          truncated = truncated || cut;
        case ImageBlock():
          images += 1;
        default:
          break;
      }
    }
    if (texts.isEmpty && images == 0) {
      return; // Tool results only.
    }
    final raw = texts.join('\n').trim();
    if (raw.startsWith('[Request interrupted by user')) {
      items.add(
        ChatNotice(
          key,
          text: 'Interrupted by user',
          kind: ChatNoticeKind.interrupted,
        ),
      );
      return;
    }
    final parts = ChatUserInput.parse(raw);
    var imagesLeft = images;
    for (var k = 0; k < parts.length; k++) {
      final id = parts.length == 1 ? key : '$key#u$k';
      switch (parts[k]) {
        case UserTextPart(:final text, :final pasted):
          items.add(
            ChatUserMessage(
              id,
              text: text,
              pasted: pasted,
              imageCount: imagesLeft,
              timestamp: entry.timestamp,
              truncated: truncated,
            ),
          );
          imagesLeft = 0;
        case SlashCommandPart(:final command):
          items.add(
            ChatUserMessage(
              id,
              text: command,
              isCommand: true,
              timestamp: entry.timestamp,
            ),
          );
        case ShellInputPart(:final command):
          items.add(
            ChatShellCommand(id, command: command, timestamp: entry.timestamp),
          );
        case ShellOutputPart(:final stdout, :final stderr):
          final index = items.lastIndexWhere(
            (item) => item is ChatShellCommand && !item.hasOutput,
          );
          if (index != -1) {
            items[index] = (items[index] as ChatShellCommand).withOutput(
              stdout,
              stderr,
            );
          }
        case AgentMessagePart(
          :final from,
          :final summary,
          :final body,
          :final idle,
          :final session,
        ):
          items.add(
            ChatAgentMessage(
              id,
              from: from,
              summary: summary,
              body: body,
              idle: idle,
              session: session,
              timestamp: entry.timestamp,
            ),
          );
        case TaskPart(:final summary, :final status):
          items.add(ChatTaskNotice(id, summary: summary, status: status));
      }
    }
    if (imagesLeft > 0) {
      items.add(
        ChatUserMessage(
          key,
          text: '',
          imageCount: imagesLeft,
          timestamp: entry.timestamp,
        ),
      );
    }
  }

  static void _addSidechain(
    TranscriptEntry entry,
    List<ChatToolCall> tasks,
    Map<String, ChatToolResult> results,
  ) {
    if (tasks.isEmpty) {
      return;
    }
    // The most recent task still running owns the line; else the last one.
    final owner = tasks.lastWhere(
      (task) => task.running,
      orElse: () => tasks.last,
    );
    for (final block in entry.blocks) {
      if (block is ToolUseBlock) {
        final item = _toolItem(block, results[block.id], entry.timestamp, '');
        if (item is ChatToolCall) {
          owner.children.add(item);
        }
      }
    }
  }

  static ChatItem _toolItem(
    ToolUseBlock block,
    ChatToolResult? result,
    DateTime? timestamp,
    String fallbackId,
  ) {
    final id = block.id.isEmpty ? fallbackId : block.id;
    final input = block.input;
    switch (block.name) {
      case 'TodoWrite':
        final todos = <ChatTodo>[
          if (input['todos'] case final List<Object?> list)
            for (final todo in list)
              if (todo is Map && todo['content'] is String)
                ChatTodo(
                  content: todo['content'] as String,
                  status: switch (todo['status']) {
                    'completed' => ChatTodoStatus.completed,
                    'in_progress' => ChatTodoStatus.inProgress,
                    _ => ChatTodoStatus.pending,
                  },
                ),
        ];
        return ChatTodoList(id, todos: todos);
      case 'ExitPlanMode':
        return ChatPlan(
          id,
          plan: input['plan'] is String ? input['plan'] as String : '',
          status: result == null
              ? ChatPlanStatus.pending
              : result.isError
              ? ChatPlanStatus.rejected
              : ChatPlanStatus.approved,
          feedback: result?.content,
        );
      case 'AskUserQuestion':
        final questions = <ChatQuestionPrompt>[
          if (input['questions'] case final List<Object?> list)
            for (final q in list)
              if (q is Map && q['question'] is String)
                ChatQuestionPrompt(
                  question: q['question'] as String,
                  header: q['header'] is String ? q['header'] as String : null,
                  multiSelect: q['multiSelect'] == true,
                  options: [
                    if (q['options'] case final List<Object?> options)
                      for (final o in options)
                        if (o is Map && o['label'] is String)
                          ChatQuestionOption(
                            label: o['label'] as String,
                            description: o['description'] is String
                                ? o['description'] as String
                                : null,
                          ),
                  ],
                ),
        ];
        return ChatQuestion(id, questions: questions, answer: result?.content);
    }
    return ChatToolCall(
      id,
      name: block.name,
      input: input,
      kind: toolKind(block.name),
      result: result,
      inputTruncated: block.truncated,
      timestamp: timestamp,
    );
  }

  static ChatToolKind toolKind(String name) => switch (name) {
    'Bash' || 'BashOutput' || 'KillShell' || 'KillBash' => ChatToolKind.bash,
    'Edit' || 'MultiEdit' || 'NotebookEdit' => ChatToolKind.edit,
    'Write' => ChatToolKind.write,
    'Read' => ChatToolKind.read,
    'Grep' || 'Glob' || 'LS' => ChatToolKind.search,
    'WebFetch' || 'WebSearch' => ChatToolKind.web,
    _ when _taskTools.contains(name) => ChatToolKind.task,
    _ => ChatToolKind.other,
  };
}
