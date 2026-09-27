import 'dart:math' as math;

import 'package:conduit/features/chat_view/presentation/chat_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Find in the conversation: the query, "3 of 12", older (up) and newer
/// (down) matches, and close. Enter goes to the next older match,
/// Shift+Enter to the next newer one, Esc closes.
class ChatFindBar extends StatelessWidget {
  const ChatFindBar({
    required this.search,
    required this.controller,
    required this.focusNode,
    required this.onOlder,
    required this.onNewer,
    required this.onClose,
    this.canSearchEarlier = false,
    this.earlierInTerminal = false,
    super.key,
  });

  final ChatSearch search;
  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onOlder;
  final VoidCallback onNewer;
  final VoidCallback onClose;

  /// Older messages can still be loaded to look further back.
  final bool canSearchEarlier;

  /// The rest of the conversation is only in the terminal.
  final bool earlierInTerminal;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: search,
      builder: (context, _) {
        final count = search.matches.length;
        final status = !search.active
            ? ''
            : search.searchingEarlier
            ? 'Searching earlier…'
            : count == 0
            ? (canSearchEarlier && !search.noEarlier
                  ? 'None loaded'
                  : 'No matches')
            : '${search.current + 1} of $count';
        final note = search.active && search.noEarlier
            ? (earlierInTerminal
                  ? 'Nothing earlier here; older messages are in the terminal.'
                  : 'No earlier matches.')
            : null;
        final older = search.atOldest && canSearchEarlier
            ? 'Search earlier messages'
            : 'Previous match (older)';
        return Material(
          key: const ValueKey('chat-find-bar'),
          color: theme.colorScheme.surfaceContainer,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LayoutBuilder(
                  builder: (context, constraints) {
                    final width = constraints.maxWidth;
                    return Row(
                      children: [
                        Expanded(
                          child: CallbackShortcuts(
                            bindings: {
                              const SingleActivator(LogicalKeyboardKey.enter):
                                  onOlder,
                              const SingleActivator(
                                LogicalKeyboardKey.enter,
                                shift: true,
                              ): onNewer,
                              const SingleActivator(LogicalKeyboardKey.escape):
                                  onClose,
                            },
                            child: TextField(
                              key: const ValueKey('chat-find-field'),
                              controller: controller,
                              focusNode: focusNode,
                              autofocus: true,
                              textInputAction: TextInputAction.search,
                              onChanged: (value) => search.query = value,
                              onSubmitted: (_) => onOlder(),
                              // Keep the field focused for the next Enter.
                              onEditingComplete: () {},
                              decoration: const InputDecoration(
                                isDense: true,
                                border: InputBorder.none,
                                prefixIcon: Icon(
                                  Icons.search_rounded,
                                  size: 20,
                                ),
                                prefixIconConstraints: BoxConstraints(
                                  minWidth: 32,
                                ),
                                hintText: 'Find in conversation',
                              ),
                            ),
                          ),
                        ),
                        if (search.searchingEarlier)
                          const Padding(
                            padding: EdgeInsets.only(right: 8),
                            child: SizedBox.square(
                              dimension: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                        // Clear of the field; a long state ellipsises rather
                        // than squeeze the field on a narrow phone.
                        Padding(
                          padding: const EdgeInsets.only(left: 12, right: 4),
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: math.min(120, width * 0.22),
                            ),
                            child: Text(
                              status,
                              key: const ValueKey('chat-find-count'),
                              maxLines: 1,
                              softWrap: false,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ),
                        ),
                        IconButton(
                          key: const ValueKey('chat-find-older'),
                          tooltip: older,
                          onPressed: search.active ? onOlder : null,
                          icon: const Icon(Icons.keyboard_arrow_up_rounded),
                        ),
                        IconButton(
                          key: const ValueKey('chat-find-newer'),
                          tooltip: 'Next match (newer)',
                          onPressed: search.active && count > 0
                              ? onNewer
                              : null,
                          icon: const Icon(Icons.keyboard_arrow_down_rounded),
                        ),
                        IconButton(
                          key: const ValueKey('chat-find-close'),
                          tooltip: 'Close search (Esc)',
                          onPressed: onClose,
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ],
                    );
                  },
                ),
                if (note != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 32, bottom: 4),
                    child: Text(
                      note,
                      key: const ValueKey('chat-find-note'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
