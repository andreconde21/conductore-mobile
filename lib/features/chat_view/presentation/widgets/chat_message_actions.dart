import 'dart:async';

import 'package:conduit/core/platform_features.dart';
import 'package:conduit/core/presentation/adaptive_modal.dart';
import 'package:conduit/features/chat_view/data/platform_text_share.dart';
import 'package:conduit/features/chat_view/presentation/chat_message_content.dart';
import 'package:conduit/features/chat_view/presentation/widgets/chat_markdown.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// What a message's menu can do beyond copying and sharing, given by the
/// chat page: quote it in the composer, send it to another agent.
class ChatMessageActionsScope extends InheritedWidget {
  const ChatMessageActionsScope({
    required super.child,
    this.onQuote,
    this.onForward,
    this.share = PlatformTextShare.share,
    super.key,
  });

  /// Puts the text in the composer as a quote; null hides "Quote in reply".
  final ValueChanged<String>? onQuote;

  /// Sends the text to another agent; null hides the action.
  final ValueChanged<String>? onForward;

  /// The system share sheet; false when there is none.
  final Future<bool> Function(String text) share;

  static ChatMessageActionsScope? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<ChatMessageActionsScope>();

  @override
  bool updateShouldNotify(ChatMessageActionsScope oldWidget) => false;
}

enum ChatMessageAction {
  copy,
  copyMarkdown,
  copySelection,
  select,
  share,
  forward,
  quote,
}

/// A thread row with its actions: long-press (touch) or right-click opens
/// a menu (Copy, Copy as Markdown, Select text, Share, Send to another
/// agent, Quote in reply); on desktop, hovering shows Copy and the menu
/// button, and [selectable] rows allow selecting text with the mouse.
class ChatMessageActions extends StatefulWidget {
  const ChatMessageActions({
    required this.content,
    required this.child,
    this.selectable = false,
    super.key,
  });

  final ChatMessageContent content;
  final Widget child;

  /// Text selection with the mouse on desktop (assistant replies, plans).
  final bool selectable;

  @override
  State<ChatMessageActions> createState() => _ChatMessageActionsState();
}

class _ChatMessageActionsState extends State<ChatMessageActions> {
  bool _hover = false;

  /// The mouse selection inside the row, if any.
  String _selection = '';

  bool get _desktop => PlatformFeatures.isDesktop;

  Future<void> _openMenu({BuildContext? anchor, Offset? at}) async {
    final content = widget.content;
    final scope = ChatMessageActionsScope.maybeOf(context);
    final selection = _selection.trim().isEmpty ? null : _selection;
    final action = await showAdaptiveModal<ChatMessageAction>(
      context: context,
      kind: AdaptiveModalKind.menu,
      anchorContext: anchor,
      anchorPosition: at,
      desktopMaxWidth: 260,
      builder: (context) {
        Widget item(ChatMessageAction action, IconData icon, String label) =>
            ListTile(
              key: ValueKey('chat-action-${action.name}'),
              dense: true,
              leading: Icon(icon, size: 20),
              title: Text(label),
              onTap: () => Navigator.of(context).pop(action),
            );
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (selection != null)
                  item(
                    ChatMessageAction.copySelection,
                    Icons.content_copy_rounded,
                    'Copy selection',
                  ),
                item(ChatMessageAction.copy, Icons.copy_rounded, 'Copy'),
                if (content.hasMarkdown)
                  item(
                    ChatMessageAction.copyMarkdown,
                    Icons.code_rounded,
                    'Copy as Markdown',
                  ),
                if (!_desktop)
                  item(
                    ChatMessageAction.select,
                    Icons.select_all_rounded,
                    'Select text',
                  ),
                item(ChatMessageAction.share, Icons.ios_share_rounded, 'Share'),
                if (scope?.onForward != null)
                  item(
                    ChatMessageAction.forward,
                    Icons.forward_to_inbox_outlined,
                    'Send to another agent…',
                  ),
                if (scope?.onQuote != null)
                  item(
                    ChatMessageAction.quote,
                    Icons.format_quote_rounded,
                    'Quote in reply',
                  ),
              ],
            ),
          ),
        );
      },
    );
    if (action == null || !mounted) return;
    // A selection narrows what is shared, sent and quoted.
    final text = selection ?? content.text;
    switch (action) {
      case ChatMessageAction.copy:
        _copy(content.plain);
      case ChatMessageAction.copyMarkdown:
        _copy(content.text);
      case ChatMessageAction.copySelection:
        _copy(selection ?? content.plain);
      case ChatMessageAction.select:
        await showChatSelectText(context, content);
      case ChatMessageAction.share:
        await _share(selection ?? content.plain, scope);
      case ChatMessageAction.forward:
        scope?.onForward?.call(text);
      case ChatMessageAction.quote:
        scope?.onQuote?.call(text);
    }
  }

  void _copy(String text, {String notice = 'Copied'}) {
    unawaited(Clipboard.setData(ClipboardData(text: text)));
    _tell(notice);
  }

  void _tell(String message) => ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));

  /// The share sheet on phones; the clipboard on desktop (and wherever
  /// there is no share sheet).
  Future<void> _share(String text, ChatMessageActionsScope? scope) async {
    if (!_desktop) {
      final share = scope?.share ?? PlatformTextShare.share;
      try {
        if (await share(text)) return;
      } on PlatformException {
        // Falls back to the clipboard.
      }
      if (!mounted) return;
    }
    _copy(text, notice: 'Copied to the clipboard to share');
  }

  @override
  Widget build(BuildContext context) {
    Widget body = widget.child;
    if (_desktop && widget.selectable) {
      body = SelectionArea(
        // Right-click opens this row's menu, which offers the selection.
        // An empty builder, not null: SelectableRegion still shows its
        // toolbar on a right-click and a null builder throws there.
        contextMenuBuilder: (_, _) => const SizedBox.shrink(),
        onSelectionChanged: (content) => _selection = content?.plainText ?? '',
        child: body,
      );
    }
    body = Listener(
      onPointerDown: (event) {
        if (event.kind == PointerDeviceKind.mouse &&
            event.buttons & kSecondaryMouseButton != 0) {
          unawaited(_openMenu(at: event.position));
        }
      },
      child: GestureDetector(
        supportedDevices: const {
          PointerDeviceKind.touch,
          PointerDeviceKind.stylus,
          PointerDeviceKind.invertedStylus,
          PointerDeviceKind.unknown,
        },
        onLongPress: () => unawaited(_openMenu()),
        child: body,
      ),
    );
    if (!_desktop) return body;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          body,
          if (_hover)
            Positioned(
              top: 0,
              right: 0,
              child: _HoverBar(
                onCopy: () => _copy(widget.content.plain),
                onMore: (anchor) => unawaited(_openMenu(anchor: anchor)),
              ),
            ),
        ],
      ),
    );
  }
}

/// Copy and the menu button, shown over a row the mouse is on.
class _HoverBar extends StatelessWidget {
  const _HoverBar({required this.onCopy, required this.onMore});

  final VoidCallback onCopy;
  final ValueChanged<BuildContext> onMore;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      key: const ValueKey('chat-message-hover'),
      color: scheme.surfaceContainerHigh,
      elevation: 1,
      borderRadius: BorderRadius.circular(8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            key: const ValueKey('chat-message-copy'),
            tooltip: 'Copy',
            visualDensity: VisualDensity.compact,
            iconSize: 16,
            onPressed: onCopy,
            icon: const Icon(Icons.copy_rounded),
          ),
          Builder(
            builder: (context) => IconButton(
              key: const ValueKey('chat-message-more'),
              tooltip: 'More actions',
              visualDensity: VisualDensity.compact,
              iconSize: 16,
              onPressed: () => onMore(context),
              icon: const Icon(Icons.more_horiz_rounded),
            ),
          ),
        ],
      ),
    );
  }
}

/// The message on its own page, where text can be selected with the
/// platform's handles (phones: long-press › "Select text").
Future<void> showChatSelectText(
  BuildContext context,
  ChatMessageContent content,
) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    fullscreenDialog: true,
    builder: (context) => Scaffold(
      appBar: AppBar(
        title: const Text('Select text'),
        actions: [
          IconButton(
            tooltip: 'Copy all',
            onPressed: () {
              unawaited(Clipboard.setData(ClipboardData(text: content.plain)));
              ScaffoldMessenger.maybeOf(context)
                ?..hideCurrentSnackBar()
                ..showSnackBar(const SnackBar(content: Text('Copied')));
            },
            icon: const Icon(Icons.copy_all_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          key: const ValueKey('chat-select-text'),
          padding: const EdgeInsets.all(16),
          child: SelectionArea(
            child: content.markdown
                ? ChatMarkdown(content.text)
                : Text(content.text),
          ),
        ),
      ),
    ),
  ),
);
