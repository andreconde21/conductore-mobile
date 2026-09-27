import 'dart:async';
import 'dart:math' as math;

import 'package:conduit/features/chat_view/domain/chat_items.dart';
import 'package:conduit/features/chat_view/domain/chat_outgoing.dart';
import 'package:conduit/features/chat_view/domain/chat_search_text.dart';
import 'package:conduit/features/chat_view/domain/chat_tool_activity.dart';
import 'package:conduit/features/chat_view/presentation/chat_forward.dart';
import 'package:conduit/features/chat_view/presentation/chat_message_content.dart';
import 'package:conduit/features/chat_view/presentation/chat_search.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_page.dart';
import 'package:conduit/features/chat_view/presentation/widgets/chat_find_bar.dart';
import 'package:conduit/features/chat_view/presentation/widgets/chat_message_actions.dart';
import 'package:conduit/features/chat_view/presentation/widgets/chat_search_highlight.dart';
import 'package:conduit/features/chat_view/presentation/widgets/chat_thread_items.dart';
import 'package:conduit/features/voice/domain/voice_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Chat View's message actions (copy, share, send to another agent,
/// quote in reply) and its find bar, for the page's state. The page wraps
/// its rows with [decorateRow] / [decorateOutgoing], its thread with
/// [wrapThread], itself with [wrapShortcuts], and feeds [searchThread]
/// what the thread shows.
mixin ChatThreadExtras on State<ChatViewPage> {
  /// The composer's text (quotes go there).
  TextEditingController get composerText;

  /// The thread's scroll position (the find bar scrolls to matches).
  ScrollController get threadScroll;

  final search = ChatSearch();

  /// The composer's focus ("Quote in reply" moves it there).
  final composerFocus = FocusNode(debugLabel: 'chat-composer');
  final _pageFocus = FocusNode(debugLabel: 'chat-page');
  final _findText = TextEditingController();
  final _findFocus = FocusNode(debugLabel: 'chat-find');

  /// The rows on screen (built by the list), by item id.
  final Map<String, BuildContext> _anchors = {};

  /// Each shown item's index in the thread's rows (a grouped tool row:
  /// its group's).
  Map<String, int> _rowOf = const {};

  /// How many older pages one "search earlier" may load.
  static const _maxEarlierPages = 10;

  @override
  void dispose() {
    search.dispose();
    composerFocus.dispose();
    _pageFocus.dispose();
    _findText.dispose();
    _findFocus.dispose();
    super.dispose();
  }

  // --- Find in conversation ------------------------------------------------

  void openSearch() {
    search.open();
    _findText.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _findText.text.length,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _findFocus.requestFocus();
    });
  }

  void closeSearch() {
    search.close();
    _findText.clear();
    _pageFocus.requestFocus();
  }

  /// The header's search button.
  Widget searchButton() => IconButton(
    key: const ValueKey('chat-search'),
    tooltip: 'Find in conversation',
    onPressed: openSearch,
    icon: const Icon(Icons.search_rounded),
  );

  /// The find bar while search is open.
  Widget? findBar() {
    if (!search.isOpen) return null;
    final chat = widget.controller;
    return ChatFindBar(
      search: search,
      controller: _findText,
      focusNode: _findFocus,
      onOlder: () => unawaited(findOlder()),
      onNewer: search.next,
      onClose: closeSearch,
      canSearchEarlier: chat.hasOlder,
      earlierInTerminal: chat.olderOnlyInTerminal,
    );
  }

  /// Ctrl+F / Cmd+F opens the find bar anywhere in the page.
  Widget wrapShortcuts(Widget child) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.keyF, control: true): openSearch,
      const SingleActivator(LogicalKeyboardKey.keyF, meta: true): openSearch,
    },
    child: Focus(focusNode: _pageFocus, autofocus: true, child: child),
  );

  /// The next older match; past the oldest loaded one, older transcript
  /// pages are loaded until one has a match.
  Future<void> findOlder() async {
    if (!search.active) return;
    if (search.atOldest && widget.controller.hasOlder) {
      await _searchEarlier();
      return;
    }
    search.previous();
  }

  Future<void> _searchEarlier() async {
    if (search.searchingEarlier) return;
    final chat = widget.controller;
    final before = search.matches.length;
    search
      ..noEarlier = false
      ..searchingEarlier = true;
    try {
      for (var page = 0; page < _maxEarlierPages && chat.hasOlder; page++) {
        await chat.loadOlder();
        if (!mounted) return;
        // The next build searches the older rows too.
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted || search.matches.length > before) break;
      }
    } finally {
      if (mounted) search.searchingEarlier = false;
    }
    if (!mounted) return;
    final found = search.matches.length - before;
    if (found > 0) {
      // Older rows come first: the newest of them is right before the
      // match that was the oldest.
      search.select(found - 1);
    } else {
      search.noEarlier = true;
    }
  }

  /// Searches the thread as shown: [items] up to [shownCount], arranged
  /// for [mode] (hidden tool rows are not searched). Runs in build.
  void searchThread(List<ChatItem> items, int shownCount, ToolActivity mode) {
    search.update(
      (identityHashCode(items), items.length, shownCount, mode),
      () => [
        for (final entry in ChatToolActivity.arrange(
          items.sublist(0, shownCount),
          mode,
        ))
          ...switch (entry) {
            ChatItemEntry(:final item) => [item],
            ChatToolGroup(:final items) => items,
          },
      ],
    );
    if (search.takeReveal()) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => unawaited(_revealCurrent()),
      );
    }
  }

  /// Whether [group] opens for the search (it holds a match).
  bool searchOpens(ChatToolGroup group) =>
      search.active && group.items.any((item) => search.hasMatch(item.id));

  /// Notes which row each item is in, so a match off screen can be
  /// scrolled to.
  void noteRows(List<Widget> rows) {
    final rowOf = <String, int>{};
    for (var i = 0; i < rows.length; i++) {
      switch (rows[i]) {
        case _ChatAnchor(:final id):
          rowOf[id] = i;
        case ChatToolGroupRow(:final group):
          for (final item in group.items) {
            rowOf[item.id] = i;
          }
      }
    }
    _rowOf = rowOf;
  }

  /// Scrolls the current match into view. The list builds only what is
  /// near the screen, so it steps towards the row until it is built.
  Future<void> _revealCurrent() async {
    for (var step = 0; step < 60 && mounted; step++) {
      final match = search.currentMatch;
      if (match == null) return;
      final anchor = _anchors[match.itemId];
      if (anchor != null && anchor.mounted) {
        await Scrollable.ensureVisible(
          anchor,
          alignment: 0.5,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
        return;
      }
      final target = _rowOf[match.itemId];
      if (target == null || !threadScroll.hasClients) return;
      final built = [for (final id in _anchors.keys) ?_rowOf[id]];
      if (built.isEmpty) return;
      // Newest first: a higher row is older, further up the screen.
      final older = target > built.reduce(math.max);
      final newer = target < built.reduce(math.min);
      if (!older && !newer) return;
      final position = threadScroll.position;
      final move = position.viewportDimension * 0.8;
      final to = (position.pixels + (older ? move : -move)).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      if (to == position.pixels) return;
      threadScroll.jumpTo(to);
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  // --- Message actions -----------------------------------------------------

  /// Row [child] of [item] with its actions and search marks.
  Widget decorateRow(ChatItem item, Widget child) {
    final content = ChatMessageContent.of(item);
    final matched = search.active && search.hasMatch(item.id);
    return _ChatAnchor(
      // Not the row widget's own key, which tests look rows up by.
      key: ValueKey(('chat-row', item.id)),
      id: item.id,
      anchors: _anchors,
      child: ChatSearchHighlight(
        itemId: item.id,
        query: matched ? search.query : '',
        current: matched ? search.currentIn(item.id) : null,
        child: content == null
            ? child
            : ChatMessageActions(
                content: content,
                // Mouse selection (desktop only): replies, plans and the
                // user's own prompts.
                selectable:
                    item is ChatAssistantText ||
                    item is ChatPlan ||
                    item is ChatUserMessage,
                child: child,
              ),
      ),
    );
  }

  /// A prompt sent from here, not in the transcript yet.
  Widget decorateOutgoing(ChatOutgoing outgoing, Widget child) =>
      ChatMessageActions(
        key: ValueKey(outgoing.id),
        content: ChatMessageContent.outgoing(outgoing),
        selectable: true,
        child: child,
      );

  /// The thread with what its rows' menus can do.
  Widget wrapThread(Widget thread) => ChatMessageActionsScope(
    onQuote: quoteInReply,
    onForward: _canForward ? (text) => unawaited(forwardMessage(text)) : null,
    share: widget.share,
    child: thread,
  );

  /// Puts [text] in the composer as a quote, under what is there.
  void quoteInReply(String text) {
    final quote = chatQuote(text);
    final current = composerText.text.trimRight();
    final value = current.isEmpty ? '$quote\n\n' : '$current\n\n$quote\n\n';
    composerText.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
    composerFocus.requestFocus();
  }

  bool get _canForward =>
      widget.forwardTargets != null || widget.attention != null;

  List<ChatForwardTarget> _targets() {
    final attention = widget.attention;
    return widget.forwardTargets?.call() ??
        (attention == null
            ? const []
            : chatForwardTargets(
                attention,
                sessionId: widget.controller.sessionId,
                hostId: widget.hostId,
              ));
  }

  /// Asks which agent to send [text] to, then sends it there quoted with
  /// where it comes from.
  Future<void> forwardMessage(String text) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final targets = _targets();
    if (targets.isEmpty) {
      messenger?.showSnackBar(
        const SnackBar(
          content: Text('No other agent is running on a monitored machine.'),
        ),
      );
      return;
    }
    final target = await pickChatForwardTarget(context, targets);
    if (target == null || !mounted) return;
    final prompt = chatForwardPrompt(
      text,
      from: widget.controller.name,
      host: widget.hostName,
    );
    final attention = widget.attention;
    final forward =
        widget.onForward ??
        (attention == null
            ? null
            : (ChatForwardTarget target, String prompt) =>
                  forwardToAgentChat(context, attention, target, prompt));
    if (forward == null) return;
    try {
      await forward(target, prompt);
    } catch (error) {
      messenger?.showSnackBar(
        SnackBar(
          content: Text('Could not send to ${target.agent.name}: $error'),
        ),
      );
    }
  }
}

/// A thread row that the find bar can scroll to: registered in [anchors]
/// while built.
class _ChatAnchor extends StatefulWidget {
  const _ChatAnchor({
    required this.id,
    required this.anchors,
    required this.child,
    super.key,
  });

  final String id;
  final Map<String, BuildContext> anchors;
  final Widget child;

  @override
  State<_ChatAnchor> createState() => _ChatAnchorState();
}

class _ChatAnchorState extends State<_ChatAnchor> {
  @override
  void initState() {
    super.initState();
    widget.anchors[widget.id] = context;
  }

  @override
  void didUpdateWidget(_ChatAnchor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.id != widget.id || oldWidget.anchors != widget.anchors) {
      _forget(oldWidget);
      widget.anchors[widget.id] = context;
    }
  }

  void _forget(_ChatAnchor from) {
    if (from.anchors[from.id] == context) from.anchors.remove(from.id);
  }

  @override
  void dispose() {
    _forget(widget);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
