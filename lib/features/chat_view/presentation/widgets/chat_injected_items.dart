import 'package:conduit/core/theme/app_theme.dart';
import 'package:conduit/features/chat_view/domain/chat_items.dart';
import 'package:conduit/features/chat_view/presentation/widgets/chat_search_highlight.dart';
import 'package:flutter/material.dart';

const _mono = 'monospace';

/// A message from another agent or session: left-aligned like an
/// incoming message, muted, with a robot icon, never mistaken for the
/// user's own bubble. The body is collapsed to a few lines.
class ChatAgentMessageCard extends StatefulWidget {
  const ChatAgentMessageCard({required this.item, super.key});

  final ChatAgentMessage item;

  @override
  State<ChatAgentMessageCard> createState() => _ChatAgentMessageCardState();
}

class _ChatAgentMessageCardState extends State<ChatAgentMessageCard> {
  static const _collapsedLines = 4;
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = scheme.onSurfaceVariant;
    if (item.idle) {
      return _IdleChip(item: item);
    }
    final from = item.session
        ? 'From session ${item.from}'
        : 'From agent ${item.from}';
    final long =
        item.body.split('\n').length > _collapsedLines ||
        item.body.length > 280;
    // Open while the find bar has a match here.
    final expanded =
        _expanded || ChatSearchHighlight.forItem(context, item.id) != null;
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.88,
        ),
        child: Container(
          margin: const EdgeInsets.only(right: 32, top: 6, bottom: 6),
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow,
            border: Border.all(color: scheme.outlineVariant),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(4),
              topRight: Radius.circular(AppTheme.radius),
              bottomLeft: Radius.circular(AppTheme.radius),
              bottomRight: Radius.circular(AppTheme.radius),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(Icons.smart_toy_outlined, size: 16, color: muted),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      from,
                      key: const ValueKey('agent-message-from'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(color: muted),
                    ),
                  ),
                ],
              ),
              if (item.summary case final summary? when summary.isNotEmpty) ...[
                const SizedBox(height: 4),
                ChatHighlightedText(
                  summary,
                  itemId: item.id,
                  segment: 0,
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
              if (item.body.isNotEmpty) ...[
                const SizedBox(height: 4),
                ChatHighlightedText(
                  item.body,
                  itemId: item.id,
                  segment: 1,
                  maxLines: expanded ? null : _collapsedLines,
                  overflow: expanded ? null : TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: muted),
                ),
              ],
              if (long)
                TextButton(
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(0, 32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: () => setState(() => _expanded = !_expanded),
                  child: Text(expanded ? 'Show less' : 'Show more'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "int-148 finished" with the first line of the result it reported,
/// expandable to the whole result; "int-148 is idle" without one.
class _IdleChip extends StatefulWidget {
  const _IdleChip({required this.item});

  final ChatAgentMessage item;

  @override
  State<_IdleChip> createState() => _IdleChipState();
}

class _IdleChipState extends State<_IdleChip> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final item = widget.item;
    final firstLine = item.body.split('\n').first.trim();
    // More than fits on the collapsed line.
    final more = item.body.trim() != firstLine || firstLine.length > 60;
    // Open while the find bar has a match here.
    final expanded =
        _expanded || ChatSearchHighlight.forItem(context, item.id) != null;
    return Padding(
      key: const ValueKey('agent-idle-row'),
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: InkWell(
        onTap: !more ? null : () => setState(() => _expanded = !_expanded),
        borderRadius: BorderRadius.circular(AppTheme.radius),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.smart_toy_outlined, size: 16, color: muted),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      item.body.isEmpty
                          ? '${item.from} is idle'
                          : '${item.from} finished',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: muted,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (more)
                    Icon(
                      expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 18,
                      color: muted,
                    ),
                ],
              ),
              if (item.body.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 22, top: 2),
                  child: ChatHighlightedText(
                    expanded ? item.body : firstLine,
                    key: const ValueKey('agent-idle-result'),
                    itemId: expanded ? item.id : '',
                    segment: 0,
                    maxLines: expanded ? null : 1,
                    overflow: expanded ? null : TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: muted),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Background command … completed", as a small system line.
class ChatTaskNoticeRow extends StatelessWidget {
  const ChatTaskNoticeRow({required this.item, super.key});

  final ChatTaskNotice item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = item.failed ? scheme.error : scheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(
            item.failed ? Icons.error_outline_rounded : Icons.task_alt_rounded,
            size: 16,
            color: color,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: ChatHighlightedText(
              item.summary,
              itemId: item.id,
              segment: 0,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

/// A `!` command the user ran, like the Bash tool card, labelled "You
/// ran"; tap to see the output.
class ChatShellCommandCard extends StatefulWidget {
  const ChatShellCommandCard({required this.item, super.key});

  final ChatShellCommand item;

  @override
  State<ChatShellCommandCard> createState() => _ChatShellCommandCardState();
}

class _ChatShellCommandCardState extends State<ChatShellCommandCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final item = widget.item;
    final output = [
      if (item.stdout?.trim().isNotEmpty ?? false) item.stdout!.trim(),
      if (item.stderr?.trim().isNotEmpty ?? false) item.stderr!.trim(),
    ].join('\n');
    // Open while the find bar has a match here.
    final expanded =
        _expanded || ChatSearchHighlight.forItem(context, item.id) != null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Material(
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radius),
          side: BorderSide(
            color: item.failed ? scheme.error : scheme.outlineVariant,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: output.isEmpty
              ? null
              : () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.terminal_rounded,
                      size: 18,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'You ran',
                      style: theme.textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ChatHighlightedText(
                        item.command,
                        itemId: item.id,
                        segment: 0,
                        maxLines: expanded ? 6 : 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontFamily: _mono,
                        ),
                      ),
                    ),
                    if (item.hasOutput)
                      Icon(
                        item.failed ? Icons.error_rounded : Icons.check_rounded,
                        size: 18,
                        color: item.failed ? scheme.error : scheme.tertiary,
                      ),
                  ],
                ),
                if (expanded && output.isNotEmpty)
                  Container(
                    margin: const EdgeInsets.only(top: 6),
                    padding: const EdgeInsets.all(6),
                    constraints: const BoxConstraints(maxHeight: 320),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(AppTheme.radius),
                    ),
                    child: SingleChildScrollView(
                      child: ChatHighlightedText(
                        output,
                        itemId: item.id,
                        segment: 1,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontFamily: _mono,
                          color: item.failed ? scheme.error : null,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A block the user pasted, collapsed to its first lines.
class ChatPastedBlock extends StatefulWidget {
  const ChatPastedBlock({required this.text, required this.color, super.key});

  final String text;
  final Color color;

  @override
  State<ChatPastedBlock> createState() => _ChatPastedBlockState();
}

class _ChatPastedBlockState extends State<ChatPastedBlock> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lines = widget.text.split('\n').length;
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: widget.color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppTheme.radius),
      ),
      child: InkWell(
        onTap: () => setState(() => _expanded = !_expanded),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.content_paste_rounded,
                  size: 14,
                  color: widget.color,
                ),
                const SizedBox(width: 4),
                Text(
                  'Pasted text · $lines line${lines == 1 ? '' : 's'}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: widget.color,
                  ),
                ),
                Icon(
                  _expanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  size: 16,
                  color: widget.color,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              widget.text,
              maxLines: _expanded ? null : 3,
              overflow: _expanded ? null : TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: _mono,
                color: widget.color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
