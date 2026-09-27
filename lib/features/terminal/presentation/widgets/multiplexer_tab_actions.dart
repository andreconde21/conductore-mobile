import 'dart:async';

import 'package:conduit/core/platform_features.dart';
import 'package:conduit/core/presentation/adaptive_modal.dart';
import 'package:conduit/core/presentation/system_navigation_insets.dart';
import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/core/theme/app_theme.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/hosts/presentation/widgets/home_session_grid.dart'
    show agentStateColor;
import 'package:conduit/features/terminal/domain/multiplexer_tabs.dart';
import 'package:conduit/features/terminal/presentation/multiplexer_tabs_controller.dart';
import 'package:flutter/material.dart';

/// "window" for tmux, "tab" for Herdr.
String multiplexerTabNoun(MultiplexerTabsController controller) =>
    controller.kind == MultiplexerTabsKind.tmux ? 'window' : 'tab';

/// The dot a tab carries: its agent's state when that is worth a look,
/// else the accent for news since it was last shown; null for neither.
Color? multiplexerTabDot(BuildContext context, MultiplexerTab tab) {
  final status = tab.status;
  if (status != null &&
      status != AgentAttentionState.idle &&
      status != AgentAttentionState.unknown) {
    return agentStateColor(context, status);
  }
  return tab.unread ? AppPalette.of(context).accent : null;
}

/// A tab's dot, or nothing.
class MultiplexerTabDot extends StatelessWidget {
  const MultiplexerTabDot({required this.tab, this.size = 6, super.key});

  final MultiplexerTab tab;
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = multiplexerTabDot(context, tab);
    if (color == null) return const SizedBox.shrink();
    final status = tab.status;
    final agent =
        status != null &&
        status != AgentAttentionState.idle &&
        status != AgentAttentionState.unknown;
    return Container(
      key: ValueKey(agent ? 'mux-tab-status' : 'mux-tab-unread'),
      width: size,
      height: size,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

/// Long-press (or right-click, on desktop) on a tab (strip chip or list
/// row): rename, move left or right (when the multiplexer can), close
/// after asking. [onDone] runs after the action (or the dismissal), to
/// give the terminal its focus. [anchorPosition] places the desktop menu
/// at the pointer.
Future<void> showMultiplexerTabActions(
  BuildContext context,
  MultiplexerTabsController controller,
  MultiplexerTab tab, {
  VoidCallback? onDone,
  Offset? anchorPosition,
}) async {
  final noun = multiplexerTabNoun(controller);
  final index = controller.tabs.indexWhere((other) => other.id == tab.id);
  final last = controller.tabs.length - 1;
  final action = await showAdaptiveModal<_TabAction>(
    context: context,
    kind: AdaptiveModalKind.menu,
    anchorPosition: anchorPosition,
    useSafeArea: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            title: Text(
              tab.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            subtitle: Text(
              controller.kind == MultiplexerTabsKind.tmux
                  ? 'tmux window ${tab.index}'
                  : 'Herdr tab',
            ),
          ),
          const Divider(height: 1),
          ListTile(
            key: const ValueKey('mux-tab-rename'),
            leading: const Icon(Icons.drive_file_rename_outline_rounded),
            title: Text('Rename $noun'),
            onTap: () => Navigator.of(context).pop(_TabAction.rename),
          ),
          if (controller.canReorder) ...[
            ListTile(
              key: const ValueKey('mux-tab-move-left'),
              enabled: index > 0,
              leading: const Icon(Icons.arrow_back_rounded),
              title: const Text('Move left'),
              onTap: () => Navigator.of(context).pop(_TabAction.moveLeft),
            ),
            ListTile(
              key: const ValueKey('mux-tab-move-right'),
              enabled: index < last,
              leading: const Icon(Icons.arrow_forward_rounded),
              title: const Text('Move right'),
              onTap: () => Navigator.of(context).pop(_TabAction.moveRight),
            ),
          ],
          ListTile(
            key: const ValueKey('mux-tab-close'),
            leading: const Icon(Icons.close_rounded),
            title: Text('Close $noun'),
            onTap: () => Navigator.of(context).pop(_TabAction.close),
          ),
        ],
      ),
    ),
  );
  if (!context.mounted || action == null) {
    onDone?.call();
    return;
  }
  await _runTabAction(context, controller, tab, action);
  onDone?.call();
}

/// Asks for a new name for [tab] and renames it (a desktop double-click
/// on a strip chip).
Future<void> renameMultiplexerTab(
  BuildContext context,
  MultiplexerTabsController controller,
  MultiplexerTab tab, {
  VoidCallback? onDone,
}) async {
  await _runTabAction(context, controller, tab, _TabAction.rename);
  onDone?.call();
}

/// Closes [tab] after asking (a desktop chip's close button or a
/// middle-click).
Future<void> closeMultiplexerTab(
  BuildContext context,
  MultiplexerTabsController controller,
  MultiplexerTab tab, {
  VoidCallback? onDone,
}) async {
  await _runTabAction(context, controller, tab, _TabAction.close);
  onDone?.call();
}

Future<void> _runTabAction(
  BuildContext context,
  MultiplexerTabsController controller,
  MultiplexerTab tab,
  _TabAction action,
) async {
  final noun = multiplexerTabNoun(controller);
  void snack(String message) => ScaffoldMessenger.maybeOf(
    context,
  )?.showSnackBar(SnackBar(content: Text(message)));
  switch (action) {
    case _TabAction.rename:
      final name = await showDialog<String>(
        context: context,
        builder: (context) =>
            _RenameDialog(title: 'Rename $noun', initial: tab.label),
      );
      if (name != null && !await controller.rename(tab, name)) {
        snack('Could not rename the $noun.');
      }
    case _TabAction.moveLeft:
      await controller.move(tab, -1);
    case _TabAction.moveRight:
      await controller.move(tab, 1);
    case _TabAction.close:
      if (!context.mounted) break;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Close "${tab.label}"?'),
          content: Text(
            'Everything running in this $noun ends, on the machine too.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const ValueKey('mux-tab-close-confirm'),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Close'),
            ),
          ],
        ),
      );
      if ((confirmed ?? false) && !await controller.close(tab)) {
        snack('Could not close the $noun.');
      }
  }
}

enum _TabAction { rename, moveLeft, moveRight, close }

/// Owns its text field's controller, so it outlives the closing animation.
class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.title, required this.initial});

  final String title;
  final String initial;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final _field = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        key: const ValueKey('mux-tab-name'),
        controller: _field,
        autofocus: true,
        textInputAction: TextInputAction.done,
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_field.text),
          child: const Text('Rename'),
        ),
      ],
    );
  }
}

/// The compact mode's list of every tab, from the session tab's label: a
/// state dot, a news dot, "+" for a new one; tap switches, long-press
/// offers rename, move and close.
Future<void> showMultiplexerTabsSheet(
  BuildContext context,
  MultiplexerTabsController controller, {
  required String sessionLabel,
  VoidCallback? onDone,
}) async {
  unawaited(controller.refresh());
  // Livelier while the list is open; back to the caller's pace after.
  final endBoost = controller.boostPolling();
  final noun = multiplexerTabNoun(controller);
  try {
    // On desktop a popover at the session tab's label (the click that
    // opened it), like a tab overflow list.
    await showAdaptiveModal<void>(
      context: context,
      kind: AdaptiveModalKind.menu,
      desktopMaxWidth: 360,
      useSafeArea: true,
      isScrollControlled: true,
      sheetAnimationStyle: MediaQuery.maybeDisableAnimationsOf(context) ?? false
          ? AnimationStyle.noAnimation
          : null,
      builder: (sheetContext) => ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.6,
        ),
        child: Padding(
          padding: EdgeInsets.only(
            bottom: shouldApplyBottomSafeArea(sheetContext)
                ? MediaQuery.viewPaddingOf(sheetContext).bottom
                : 0,
          ),
          child: ListenableBuilder(
            listenable: controller,
            builder: (sheetContext, _) {
              final theme = Theme.of(sheetContext);
              final tabs = controller.tabs;
              return Column(
                key: const ValueKey('mux-tabs-sheet'),
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 14, 8, 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '$sessionLabel · ${tabs.length} '
                            '${noun}s',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        TextButton.icon(
                          key: const ValueKey('mux-tabs-sheet-new'),
                          icon: const Icon(Icons.add_rounded),
                          label: Text('New $noun'),
                          onPressed: () {
                            Navigator.of(sheetContext).pop();
                            unawaited(controller.create());
                            onDone?.call();
                          },
                        ),
                      ],
                    ),
                  ),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                      children: [
                        for (final (i, tab) in tabs.indexed)
                          GestureDetector(
                            // Right-click on desktop, like the long-press.
                            onSecondaryTapUp: PlatformFeatures.isDesktop
                                ? (details) => unawaited(
                                    showMultiplexerTabActions(
                                      sheetContext,
                                      controller,
                                      tab,
                                      anchorPosition: details.globalPosition,
                                    ),
                                  )
                                : null,
                            child: ListTile(
                              key: ValueKey('mux-tabs-sheet-${tab.id}'),
                              dense: true,
                              selected: tab.active,
                              shape: RoundedRectangleBorder(
                                borderRadius: AppTheme.borderRadius,
                              ),
                              leading: SizedBox(
                                width: 28,
                                child: Text(
                                  controller.kind == MultiplexerTabsKind.tmux
                                      ? '${tab.index}'
                                      : '${i + 1}',
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                              title: Text(
                                tab.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontWeight: tab.active
                                      ? FontWeight.w800
                                      : FontWeight.w600,
                                ),
                              ),
                              subtitle: _subtitle(tab),
                              trailing: PlatformFeatures.isDesktop
                                  ? Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        MultiplexerTabDot(tab: tab, size: 8),
                                        IconButton(
                                          key: ValueKey(
                                            'mux-tabs-sheet-more-${tab.id}',
                                          ),
                                          tooltip:
                                              '${noun[0].toUpperCase()}'
                                              '${noun.substring(1)} actions',
                                          iconSize: 18,
                                          visualDensity: VisualDensity.compact,
                                          icon: const Icon(
                                            Icons.more_horiz_rounded,
                                          ),
                                          onPressed: () => unawaited(
                                            showMultiplexerTabActions(
                                              sheetContext,
                                              controller,
                                              tab,
                                            ),
                                          ),
                                        ),
                                      ],
                                    )
                                  : MultiplexerTabDot(tab: tab, size: 8),
                              onTap: () {
                                Navigator.of(sheetContext).pop();
                                unawaited(
                                  controller.select(tab).whenComplete(() {
                                    onDone?.call();
                                  }),
                                );
                              },
                              onLongPress: () => unawaited(
                                showMultiplexerTabActions(
                                  sheetContext,
                                  controller,
                                  tab,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  } finally {
    endBoost();
  }
  onDone?.call();
}

Widget? _subtitle(MultiplexerTab tab) {
  final parts = [
    if (tab.active) 'on screen',
    if (tab.status case final status?
        when status != AgentAttentionState.idle &&
            status != AgentAttentionState.unknown)
      status.label,
    if (tab.unread && !tab.active) 'new output',
  ];
  return parts.isEmpty ? null : Text(parts.join(' · '));
}
