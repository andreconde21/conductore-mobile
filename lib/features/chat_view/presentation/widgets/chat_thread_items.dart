import 'package:conduit/core/theme/app_theme.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/presentation/widgets/approval_widgets.dart';
import 'package:conduit/features/chat_view/domain/chat_items.dart';
import 'package:conduit/features/chat_view/domain/chat_outgoing.dart';
import 'package:conduit/features/chat_view/domain/chat_tool_activity.dart';
import 'package:conduit/features/chat_view/domain/chat_tool_summary.dart';
import 'package:conduit/features/chat_view/presentation/widgets/chat_injected_items.dart';
import 'package:conduit/features/chat_view/presentation/widgets/chat_markdown.dart';
import 'package:conduit/features/chat_view/presentation/widgets/chat_search_highlight.dart';
import 'package:flutter/material.dart';

const _mono = 'monospace';

/// A prompt (or answer) sent from the chat view that the transcript has
/// not shown yet: a dimmer user bubble with its state underneath, and
/// Retry / Edit once it failed.
class ChatOutgoingBubble extends StatelessWidget {
  const ChatOutgoingBubble({
    required this.item,
    this.onRetry,
    this.onEdit,
    super.key,
  });

  final ChatOutgoing item;
  final VoidCallback? onRetry;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final failed = item.state == ChatSendState.failed;
    final (icon, status) = switch (item.state) {
      ChatSendState.sending => (Icons.schedule_rounded, 'Sending…'),
      ChatSendState.failed => (
        Icons.error_outline_rounded,
        'Not sent${item.error == null ? '' : ': ${item.error}'}',
      ),
      ChatSendState.sent when item.late => (
        Icons.done_rounded,
        'Sent · not in the transcript yet',
      ),
      ChatSendState.sent => (Icons.done_rounded, 'Sent'),
    };
    final statusColor = failed ? scheme.error : scheme.onSurfaceVariant;
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.85,
        ),
        child: Padding(
          padding: const EdgeInsets.only(left: 40, top: 6, bottom: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  color: scheme.primaryContainer.withValues(alpha: 0.5),
                  border: failed ? Border.all(color: scheme.error) : null,
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(AppTheme.radius),
                    topRight: Radius.circular(AppTheme.radius),
                    bottomLeft: Radius.circular(AppTheme.radius),
                    bottomRight: Radius.circular(4),
                  ),
                ),
                child: Text(
                  item.answer ? 'Answer: ${item.text}' : item.text,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onPrimaryContainer.withValues(alpha: 0.7),
                  ),
                ),
              ),
              const SizedBox(height: 3),
              Row(
                key: const ValueKey('outgoing-status'),
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 13, color: statusColor),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      status,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: statusColor,
                      ),
                    ),
                  ),
                ],
              ),
              if (failed)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (onEdit != null)
                      TextButton(
                        key: const ValueKey('outgoing-edit'),
                        onPressed: onEdit,
                        child: const Text('Edit'),
                      ),
                    if (onRetry != null)
                      TextButton(
                        key: const ValueKey('outgoing-retry'),
                        onPressed: onRetry,
                        child: const Text('Retry'),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The user's prompt, right-aligned.
class ChatUserBubble extends StatelessWidget {
  const ChatUserBubble({required this.item, super.key});

  final ChatUserMessage item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    if (item.isCommand && item.text.startsWith('/')) {
      // A slash command: a compact chip, not a prompt bubble.
      return Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Chip(
            key: const ValueKey('slash-command-chip'),
            visualDensity: VisualDensity.compact,
            avatar: const Icon(Icons.keyboard_command_key_rounded, size: 16),
            label: ChatHighlightedText(
              item.text,
              itemId: item.id,
              segment: 0,
              style: theme.textTheme.bodySmall?.copyWith(fontFamily: _mono),
            ),
          ),
        ),
      );
    }
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.85,
        ),
        child: Container(
          margin: const EdgeInsets.only(left: 40, top: 6, bottom: 6),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: scheme.primaryContainer,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(AppTheme.radius),
              topRight: Radius.circular(AppTheme.radius),
              bottomLeft: Radius.circular(AppTheme.radius),
              bottomRight: Radius.circular(4),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (item.text.isNotEmpty)
                ChatHighlightedText(
                  item.text,
                  itemId: item.id,
                  segment: 0,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onPrimaryContainer,
                    fontFamily: item.isCommand ? _mono : null,
                  ),
                ),
              for (final block in item.pasted)
                ChatPastedBlock(text: block, color: scheme.onPrimaryContainer),
              if (item.imageCount > 0) ...[
                const SizedBox(height: 6),
                _ImageChip(count: item.imageCount),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The agent's reply, full width, rendered as Markdown.
class ChatAssistantBubble extends StatelessWidget {
  const ChatAssistantBubble({required this.item, super.key});

  final ChatAssistantText item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 6, right: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ChatMarkdown(item.text, style: theme.textTheme.bodyMedium),
          if (item.truncated)
            Text(
              'Message shortened; the full text is in the terminal.',
              style: theme.textTheme.bodySmall,
            ),
        ],
      ),
    );
  }
}

class ChatThinkingRow extends StatelessWidget {
  const ChatThinkingRow({required this.item, super.key});

  final ChatThinking item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(
            Icons.psychology_outlined,
            size: 16,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Text(
            item.count > 1 ? 'Thought (${item.count} steps)' : 'Thought',
            style: theme.textTheme.bodySmall?.copyWith(
              fontStyle: FontStyle.italic,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class ChatNoticeRow extends StatelessWidget {
  const ChatNoticeRow({required this.item, super.key});

  final ChatNotice item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (icon, color) = switch (item.kind) {
      ChatNoticeKind.error => (Icons.error_outline_rounded, scheme.error),
      ChatNoticeKind.interrupted => (
        Icons.stop_circle_outlined,
        scheme.onSurfaceVariant,
      ),
      ChatNoticeKind.compacted => (
        Icons.compress_rounded,
        scheme.onSurfaceVariant,
      ),
      ChatNoticeKind.info => (
        Icons.info_outline_rounded,
        scheme.onSurfaceVariant,
      ),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(child: Divider(color: scheme.outlineVariant)),
          const SizedBox(width: 8),
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Flexible(
            child: ChatHighlightedText(
              item.text,
              itemId: item.id,
              segment: 0,
              style: theme.textTheme.bodySmall?.copyWith(color: color),
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(child: Divider(color: scheme.outlineVariant)),
        ],
      ),
    );
  }
}

/// A compact, expandable card for one tool call. Failures are flagged in
/// red; Task/Agent calls list their subagent's tool calls inside.
class ChatToolCard extends StatefulWidget {
  const ChatToolCard({required this.item, super.key});

  final ChatToolCall item;

  @override
  State<ChatToolCard> createState() => _ChatToolCardState();
}

class _ChatToolCardState extends State<ChatToolCard> {
  bool _expanded = false;

  static IconData iconFor(ChatToolKind kind) => switch (kind) {
    ChatToolKind.bash => Icons.terminal_rounded,
    ChatToolKind.edit => Icons.edit_note_rounded,
    ChatToolKind.write => Icons.note_add_outlined,
    ChatToolKind.read => Icons.description_outlined,
    ChatToolKind.search => Icons.search_rounded,
    ChatToolKind.web => Icons.public_rounded,
    ChatToolKind.task => Icons.account_tree_outlined,
    ChatToolKind.other => Icons.build_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final item = widget.item;
    final summary = ChatToolSummary.of(item);
    final failed = item.failed;
    // Open while the find bar has a match here, to show it.
    final expanded =
        _expanded || ChatSearchHighlight.forItem(context, item.id) != null;
    final border = failed ? scheme.error : scheme.outlineVariant;
    final exit = summary.exitCode;
    final status = item.running
        ? const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : failed
        ? Icon(Icons.error_rounded, size: 18, color: scheme.error)
        : Icon(Icons.check_rounded, size: 18, color: scheme.tertiary);
    final small = theme.textTheme.bodySmall;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Material(
        color: failed
            ? scheme.errorContainer.withValues(alpha: 0.25)
            : scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radius),
          side: BorderSide(color: border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(
                      iconFor(item.kind),
                      size: 18,
                      color: failed ? scheme.error : scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      summary.title,
                      style: theme.textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ChatHighlightedText(
                        summary.subject,
                        itemId: item.id,
                        segment: 0,
                        maxLines: expanded ? 6 : 1,
                        overflow: TextOverflow.ellipsis,
                        style: small?.copyWith(fontFamily: _mono),
                      ),
                    ),
                    if (item.kind == ChatToolKind.bash &&
                        exit != null &&
                        exit != 0) ...[
                      const SizedBox(width: 6),
                      Text(
                        'exit $exit',
                        style: small?.copyWith(
                          color: scheme.error,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                    const SizedBox(width: 6),
                    status,
                  ],
                ),
                if (summary.detail case final detail?)
                  Padding(
                    padding: const EdgeInsets.only(left: 26, top: 2),
                    child: Text(
                      detail,
                      style: small,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                if (item.kind == ChatToolKind.task && item.children.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(left: 26, top: 2),
                    child: Text(
                      '${item.children.length} tool call'
                      '${item.children.length == 1 ? '' : 's'}'
                      '${item.children.any((c) => c.failed) ? ', some failed' : ''}',
                      style: small,
                    ),
                  ),
                if (summary.diff.isNotEmpty && expanded)
                  _DiffPreview(lines: summary.diff),
                if (summary.resultPreview case final preview?)
                  if (expanded || failed || item.kind == ChatToolKind.bash)
                    _Output(
                      text: expanded
                          ? (item.result?.content ?? preview)
                          : preview,
                      error: failed,
                      maxLines: expanded ? null : 6,
                      itemId: expanded && item.result != null ? item.id : null,
                    ),
                if (expanded && item.kind == ChatToolKind.task)
                  for (final child in item.children)
                    Padding(
                      padding: const EdgeInsets.only(left: 12),
                      child: ChatToolCard(item: child),
                    ),
                if (item.result case final result? when expanded) ...[
                  if (summary.resultPreview == null &&
                      result.content.trim().isNotEmpty)
                    _Output(
                      text: result.content,
                      error: failed,
                      itemId: item.id,
                    ),
                  if (result.images > 0) _ImageChip(count: result.images),
                  if (result.truncated)
                    Text(
                      'Output shortened; the rest is in the terminal.',
                      style: small,
                    ),
                ],
                if (expanded && item.inputTruncated)
                  Text('Input shortened by the host.', style: small),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DiffPreview extends StatelessWidget {
  const _DiffPreview({required this.lines});

  final List<ChatDiffLine> lines;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(fontFamily: _mono);
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppTheme.radius),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final line in lines)
              Text(
                '${line.sign} ${line.text}',
                style: style?.copyWith(
                  color: switch (line.sign) {
                    '+' => Colors.green.shade600,
                    '-' => Colors.red.shade400,
                    _ => theme.colorScheme.onSurfaceVariant,
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Output extends StatelessWidget {
  const _Output({
    required this.text,
    required this.error,
    this.maxLines,
    this.itemId,
  });

  final String text;
  final bool error;
  final int? maxLines;

  /// Set when [text] is the call's full result (search run 1 of its row).
  final String? itemId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(6),
      constraints: const BoxConstraints(maxHeight: 320),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppTheme.radius),
      ),
      child: SingleChildScrollView(
        child: ChatHighlightedText(
          text,
          itemId: itemId ?? '',
          segment: 1,
          maxLines: maxLines,
          overflow: maxLines == null ? null : TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            fontFamily: _mono,
            color: error ? theme.colorScheme.error : null,
          ),
        ),
      ),
    );
  }
}

class _ImageChip extends StatelessWidget {
  const _ImageChip({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Chip(
      visualDensity: VisualDensity.compact,
      avatar: const Icon(Icons.image_outlined, size: 16),
      label: Text(
        count == 1 ? 'Image (open the terminal to view)' : '$count images',
      ),
    );
  }
}

/// TodoWrite as a checklist.
class ChatTodoCard extends StatelessWidget {
  const ChatTodoCard({required this.item, super.key});

  final ChatTodoList item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final done = item.todos
        .where((t) => t.status == ChatTodoStatus.completed)
        .length;
    return _CardShell(
      icon: Icons.checklist_rounded,
      title: 'Tasks $done/${item.todos.length}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (index, todo) in item.todos.indexed)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    switch (todo.status) {
                      ChatTodoStatus.completed => Icons.check_box_rounded,
                      ChatTodoStatus.inProgress =>
                        Icons.indeterminate_check_box_outlined,
                      ChatTodoStatus.pending =>
                        Icons.check_box_outline_blank_rounded,
                    },
                    size: 18,
                    color: todo.status == ChatTodoStatus.inProgress
                        ? scheme.primary
                        : scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ChatHighlightedText(
                      todo.content,
                      itemId: item.id,
                      segment: index,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        decoration: todo.status == ChatTodoStatus.completed
                            ? TextDecoration.lineThrough
                            : null,
                        fontWeight: todo.status == ChatTodoStatus.inProgress
                            ? FontWeight.w700
                            : null,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// ExitPlanMode: the plan, rendered, with its status. Approving happens on
/// the approval card below it when the companion relays the prompt.
class ChatPlanCard extends StatelessWidget {
  const ChatPlanCard({required this.item, super.key});

  final ChatPlan item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (label, color) = switch (item.status) {
      ChatPlanStatus.pending => ('Waiting for approval', scheme.primary),
      ChatPlanStatus.approved => ('Approved', scheme.tertiary),
      ChatPlanStatus.rejected => ('Not approved', scheme.error),
    };
    return _CardShell(
      icon: Icons.map_outlined,
      title: 'Plan',
      trailing: Text(
        label,
        style: theme.textTheme.labelMedium?.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ChatMarkdown(item.plan, style: theme.textTheme.bodyMedium),
          if (item.status == ChatPlanStatus.rejected &&
              (item.feedback?.trim().isNotEmpty ?? false)) ...[
            const SizedBox(height: 6),
            Text(
              item.feedback!.trim(),
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}

/// AskUserQuestion: the questions and their options. While unanswered and
/// the agent waits, each option is a button that types its number into the
/// terminal menu ([onPick] gets the 1-based number).
class ChatQuestionCard extends StatelessWidget {
  const ChatQuestionCard({required this.item, required this.onPick, super.key});

  final ChatQuestion item;

  /// Null when options cannot be picked now (answered, or the agent is not
  /// waiting on this question).
  final ValueChanged<int>? onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _CardShell(
      icon: Icons.help_outline_rounded,
      title: item.answered ? 'Question answered' : 'Question',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final question in item.questions) ...[
            if (question.header case final header?)
              Text(header, style: theme.textTheme.labelMedium),
            Text(question.question, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 6),
            for (var i = 0; i < question.options.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    alignment: Alignment.centerLeft,
                  ),
                  onPressed: onPick == null ? null : () => onPick!(i + 1),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${i + 1}. ${question.options[i].label}'),
                      if (question.options[i].description case final d?)
                        Text(d, style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 6),
          ],
          if (item.answer case final answer?)
            Text(
              answer.trim(),
              style: theme.textTheme.bodySmall,
              maxLines: 6,
              overflow: TextOverflow.ellipsis,
            )
          else if (onPick != null && item.questions.length > 1)
            Text(
              'Answer the questions in order; each tap picks for the one '
              'the terminal shows.',
              style: theme.textTheme.bodySmall,
            ),
        ],
      ),
    );
  }
}

/// A permission prompt relayed by the companion, answered in the thread.
class ChatApprovalCard extends StatelessWidget {
  const ChatApprovalCard({
    required this.request,
    required this.busy,
    required this.onDecide,
    this.onTrust,
    super.key,
  });

  final PendingPermissionRequest request;
  final bool busy;
  final ValueChanged<PermissionVerdict> onDecide;

  /// Saves a time-boxed rule (companions with smart approvals); hidden for
  /// high-risk requests, which then also lose "Always".
  final VoidCallback? onTrust;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isPlan = request.toolName == 'ExitPlanMode';
    final high = request.risk?.level == PermissionRiskLevel.high;
    final onTrust = request.trustable && !isPlan ? this.onTrust : null;
    String label(PermissionVerdict verdict) => switch (verdict) {
      PermissionVerdict.allow => isPlan ? 'Approve' : 'Allow',
      PermissionVerdict.deny => isPlan ? 'Keep planning' : 'Deny',
      PermissionVerdict.always => isPlan ? 'Approve, auto-edit' : 'Always',
    };
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(AppTheme.radius),
        border: Border.all(color: scheme.error),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.shield_outlined, size: 18, color: scheme.error),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  isPlan ? 'Approve the plan?' : 'Allow ${request.toolName}?',
                  style: theme.textTheme.titleSmall,
                ),
              ),
            ],
          ),
          if (!isPlan) ...[
            const SizedBox(height: 6),
            Text(
              request.summary,
              style: theme.textTheme.bodyMedium?.copyWith(fontFamily: _mono),
              maxLines: 6,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          if (request.risk case final risk?) ...[
            const SizedBox(height: 6),
            RiskLine(risk: risk),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: busy
                      ? null
                      : () => onDecide(PermissionVerdict.deny),
                  child: Text(label(PermissionVerdict.deny)),
                ),
              ),
              if (onTrust != null) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.tonal(
                    key: ValueKey('chat-trust-${request.id}'),
                    onPressed: busy ? null : onTrust,
                    child: const Text('Trust…'),
                  ),
                ),
              ],
              if (!(high && this.onTrust != null)) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.tonal(
                    onPressed: busy
                        ? null
                        : () => onDecide(PermissionVerdict.always),
                    child: Text(label(PermissionVerdict.always)),
                  ),
                ),
              ],
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  onPressed: busy
                      ? null
                      : () => onDecide(PermissionVerdict.allow),
                  child: Text(label(PermissionVerdict.allow)),
                ),
              ),
            ],
          ),
          if (busy)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: LinearProgressIndicator(),
            ),
        ],
      ),
    );
  }
}

/// A run of tool calls as one compact row ("Ran 4 commands, edited 2
/// files"); a tap shows the individual rows ([children]) under it.
class ChatToolGroupRow extends StatelessWidget {
  const ChatToolGroupRow({
    required this.group,
    required this.expanded,
    required this.onToggle,
    required this.children,
    super.key,
  });

  final ChatToolGroup group;
  final bool expanded;
  final VoidCallback onToggle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final failed = group.failed;
    final small = theme.textTheme.bodySmall;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Material(
            color: scheme.surfaceContainerLow,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppTheme.radius),
              side: BorderSide(
                color: failed > 0 ? scheme.error : scheme.outlineVariant,
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onToggle,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
                child: Row(
                  children: [
                    Icon(
                      Icons.handyman_outlined,
                      size: 18,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        group.label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelLarge,
                      ),
                    ),
                    if (failed > 0) ...[
                      const SizedBox(width: 6),
                      Text(
                        '$failed failed',
                        style: small?.copyWith(color: scheme.error),
                      ),
                    ],
                    if (group.running) ...[
                      const SizedBox(width: 8),
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ],
                    Icon(
                      expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      color: scheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.only(left: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              ),
            ),
        ],
      ),
    );
  }
}

class _CardShell extends StatelessWidget {
  const _CardShell({
    required this.icon,
    required this.title,
    required this.child,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppTheme.radius),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: scheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              ?trailing,
            ],
          ),
          const SizedBox(height: 6),
          child,
        ],
      ),
    );
  }
}
