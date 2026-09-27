import 'package:conduit/features/chat_view/presentation/chat_view_presenter.dart';
import 'package:conduit/features/desktop_shell/domain/shell_layout.dart';
import 'package:conduit/features/desktop_shell/domain/sidebar_tree.dart';
import 'package:conduit/features/desktop_shell/presentation/desktop_shell_controller.dart';
import 'package:conduit/features/desktop_shell/presentation/widgets/shell_sidebar.dart'
    show SidebarDrag;
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/live_preview/presentation/live_preview_tab.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:flutter/widgets.dart';

/// View id of an open terminal session (file-like tabs have their own,
/// see `TerminalFileTab.viewId`).
String sessionViewId(TerminalSessionController session) =>
    'session:${session.host.id}';

/// What a tab shows next to its name in the desktop shell.
@immutable
class ShellTabBadge {
  const ShellTabBadge({this.dot = SidebarDot.none, this.unread = false});

  final SidebarDot dot;
  final bool unread;
}

/// What the terminal page does for the desktop shell when it is embedded
/// in it (the shell reaches the page through [TerminalShellEmbedding]).
abstract interface class TerminalShellHost {
  /// Every open view in tab order.
  List<String> get viewIds;

  /// The focused view.
  String? get activeViewId;

  /// Shows [viewId] and gives it the focus.
  void activateView(String viewId);

  /// Closes [viewId] (a session asks first when closing ends a shell).
  Future<void> closeView(String viewId);

  /// Opens Chat View as a tab.
  bool presentChat(ChatViewRequest request);

  /// The live preview tab of [host], if one is open.
  LivePreviewTab? previewTabFor(SavedHost host);

  /// Opens (or shows) the focused session's live preview.
  Future<void> openPreviewForFocused();

  /// The focused terminal session, if the focus is on one.
  TerminalSessionController? get focusedSession;

  /// Shows [viewId] in a new pane at [edge] of the focused one.
  void splitView(String viewId, ShellEdge edge);

  /// The next view that opens goes into a new pane at [edge].
  void requestSplit(ShellEdge edge);

  /// Shows open view [viewId] in pane [paneId], or at its [edge].
  void placeView(String paneId, ShellEdge edge, String viewId);

  /// Forgets a [requestSplit] no new view answered.
  void cancelSplit();
}

/// How the terminal page runs inside the desktop shell: no route of its
/// own, the shell's tabs and panes, and a way back to the dashboard.
class TerminalShellEmbedding {
  TerminalShellEmbedding({
    required this.controller,
    required this.onShowHome,
    required this.isVisible,
    this.badgeFor,
    this.onFullscreenChanged,
    this.onViewsChanged,
    this.headerActions,
    this.onToggleAgents,
    this.onOpenPalette,
    this.onDropNode,
    this.onFillPane,
  });

  /// The switcher button and keys: the shell's command palette instead.
  final VoidCallback? onOpenPalette;

  /// A sidebar row dropped on a pane (see `ShellSplitArea.onDropNode`).
  final void Function(String paneId, ShellEdge edge, SidebarDrag drag)?
  onDropNode;

  /// An empty pane's "Open…" button.
  final ValueChanged<String>? onFillPane;

  /// Extra buttons for the terminal row (the right panel toggles).
  final List<Widget> Function()? headerActions;

  /// The Agents button: the shell's right panel instead of a side sheet.
  final VoidCallback? onToggleAgents;

  final DesktopShellController controller;

  /// The header's home button: the dashboard.
  final VoidCallback onShowHome;

  /// Whether the main area shows the terminal (not the dashboard); the
  /// page's shortcuts only act then.
  final bool Function() isVisible;

  /// Agent state and unread marker per view id.
  final ShellTabBadge Function(String viewId)? badgeFor;

  /// F11: the shell hides the sidebar and the right panel too.
  final ValueChanged<bool>? onFullscreenChanged;

  /// Views opened, closed or focused (the shell tracks what is on screen
  /// for the unread markers).
  final VoidCallback? onViewsChanged;

  /// The embedded page, while it is mounted.
  TerminalShellHost? host;
}

/// Keeps the terminal page's focused view (active session or file tab)
/// and the shell's split layout in step:
///
/// * a view the page activates (a tab click, Ctrl+Tab, a new session) is
///   revealed: focused where it is on screen, else shown in the focused
///   pane — or in a new split when one was asked for ([requestSplit]);
/// * a pane the user focuses (a click, Alt+arrows) activates its view;
/// * a closed view's pane closes, and the pane that takes the focus
///   activates its own view instead of pulling another one in.
class TerminalShellSync {
  TerminalShellSync({
    required this.controller,
    required this.viewIds,
    required this.activeViewId,
    required this.activate,
  }) {
    controller.layout.addListener(_fromLayout);
  }

  final DesktopShellController controller;
  final List<String> Function() viewIds;
  final String? Function() activeViewId;
  final void Function(String viewId) activate;

  Set<String> _known = const {};
  String? _lastActive;
  ShellEdge? _pendingSplit;
  bool _syncing = false;

  /// Most recently focused views first.
  final List<String> recent = [];

  /// The layout as the page renders it now: panes of views that are gone
  /// drop out, and an empty focused pane shows the focused view (the
  /// saved layout is still held, or nothing was saved yet).
  ShellLayout get rendered {
    final layout = controller.layout.value.pruned(viewIds().toSet());
    final active = activeViewId();
    if (layout.focusedView == null &&
        active != null &&
        !layout.visibleViews.contains(active)) {
      return layout.reveal(active);
    }
    return layout;
  }

  /// The next view opened goes into a new pane at [edge] of the focused one.
  void requestSplit(ShellEdge edge) => _pendingSplit = edge;

  bool get splitPending => _pendingSplit != null;

  void clearSplit() => _pendingSplit = null;

  /// A view on no pane, most recently used first (for splitting).
  String? get hiddenView {
    final visible = rendered.visibleViews;
    final views = viewIds();
    for (final view in [...recent, ...views]) {
      if (views.contains(view) && !visible.contains(view)) return view;
    }
    return null;
  }

  /// The page's views or focus changed.
  void fromPage() {
    final views = viewIds().toSet();
    final active = activeViewId();
    final removed = _known.difference(views);
    final added = views.difference(_known);
    final lastActive = _lastActive;
    _known = views;
    _lastActive = active;
    if (active != null) {
      recent
        ..remove(active)
        ..insert(0, active);
    }
    recent.removeWhere((view) => !views.contains(view));
    // Activations made from the layout only update the bookkeeping. When
    // every view is gone at once (the app locked, which closes all
    // sessions), the layout stays for the sessions that come back.
    if (_syncing || controller.layoutHeld || views.isEmpty) return;

    _syncing = true;
    try {
      final pending = _pendingSplit;
      if (pending != null && active != null && added.contains(active)) {
        _pendingSplit = null;
        final focused = rendered.focusedPane.id;
        controller.editLayout(
          views,
          (layout) => layout.split(focused, pending, active),
        );
        return;
      }
      if (lastActive != null && removed.contains(lastActive)) {
        // The focused view closed: its pane went away with it; the pane
        // that took the focus keeps what it shows.
        final pruned = controller.layout.value.pruned(views);
        final survivor = pruned.focusedView;
        controller.editLayout(views, (layout) => layout);
        if (survivor != null && survivor != active) {
          _lastActive = survivor;
          activate(survivor);
          return;
        }
      }
      if (active != null) {
        controller.editLayout(views, (layout) => layout.reveal(active));
      } else if (removed.isNotEmpty) {
        controller.editLayout(views, (layout) => layout);
      }
    } finally {
      _syncing = false;
    }
  }

  void _fromLayout() {
    if (_syncing) return;
    final focused = rendered.focusedView;
    if (focused == null || focused == activeViewId()) return;
    _syncing = true;
    try {
      _lastActive = focused;
      activate(focused);
    } finally {
      _syncing = false;
    }
  }

  /// After the held layout is released: the saved focus wins.
  void afterRelease() {
    _known = viewIds().toSet();
    final focused = rendered.focusedView;
    if (focused != null && focused != activeViewId()) {
      _syncing = true;
      try {
        _lastActive = focused;
        activate(focused);
      } finally {
        _syncing = false;
      }
    }
    fromPage();
  }

  void dispose() {
    controller.layout.removeListener(_fromLayout);
  }
}
