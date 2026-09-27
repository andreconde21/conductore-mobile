import 'dart:async';

import 'package:conduit/core/platform_features.dart';
import 'package:conduit/core/presentation/adaptive_modal.dart';
import 'package:flutter/material.dart';

/// On desktop, what swiping does on a phone: a "Hide" button on hover and a
/// right-click menu (Open, Review, Chat, Hide) on an inbox row that can be
/// hidden. Phones get [child] as it was; they swipe it away.
class InboxRowDesktopActions extends StatefulWidget {
  const InboxRowDesktopActions({
    required this.entryKey,
    required this.onHide,
    required this.onOpen,
    required this.child,
    this.onOpenChat,
    this.onReview,
    super.key,
  });

  /// The inbox entry's key, for the widgets' keys.
  final String entryKey;
  final VoidCallback onHide;
  final VoidCallback onOpen;
  final VoidCallback? onOpenChat;
  final VoidCallback? onReview;
  final Widget child;

  @override
  State<InboxRowDesktopActions> createState() => _InboxRowDesktopActionsState();
}

class _InboxRowDesktopActionsState extends State<InboxRowDesktopActions> {
  bool _hovered = false;

  Future<void> _menu(Offset position) async {
    final actions = <(String, IconData, VoidCallback)>[
      ('Open', Icons.open_in_new_rounded, widget.onOpen),
      if (widget.onReview case final review?)
        ('Review', Icons.rate_review_outlined, review),
      if (widget.onOpenChat case final chat?)
        ('Chat', Icons.chat_bubble_outline_rounded, chat),
      ('Hide', Icons.visibility_off_outlined, widget.onHide),
    ];
    final picked = await showAdaptiveModal<VoidCallback>(
      context: context,
      kind: AdaptiveModalKind.menu,
      anchorPosition: position,
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (label, icon, action) in actions)
            ListTile(
              key: ValueKey('agent-row-menu-$label'),
              dense: true,
              leading: Icon(icon, size: 20),
              title: Text(label),
              onTap: () => Navigator.of(context).pop(action),
            ),
        ],
      ),
    );
    picked?.call();
  }

  @override
  Widget build(BuildContext context) {
    if (!PlatformFeatures.isDesktop) return widget.child;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onSecondaryTapUp: (details) => unawaited(_menu(details.globalPosition)),
        child: Stack(
          children: [
            widget.child,
            if (_hovered)
              Positioned(
                top: 4,
                right: 4,
                child: Material(
                  color: Theme.of(context).colorScheme.surface,
                  shape: const CircleBorder(),
                  child: IconButton(
                    key: ValueKey('agent-row-hide-${widget.entryKey}'),
                    tooltip: 'Hide',
                    iconSize: 18,
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close_rounded),
                    onPressed: widget.onHide,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
