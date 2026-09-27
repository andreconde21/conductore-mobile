import 'package:conduit/core/platform_features.dart';
import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/features/terminal/presentation/desktop_shortcuts.dart';
import 'package:conduit/features/terminal/presentation/gestures/terminal_gesture_recognizers.dart';
import 'package:conduit/features/terminal/presentation/multiplexer_tabs_controller.dart';
import 'package:conduit/features/terminal/presentation/terminal_file_tabs_controller.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:conduit/features/terminal/presentation/widgets/session_tabs.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Per-session tools that open as tabs beside the session: the git diff of
/// the working directory and a live preview of a web app on the host.
enum SessionTool { gitDiff, livePreview }

/// Actions in the terminal row's overflow menu.
enum TerminalHeaderAction {
  chatView,
  gitDiff,
  livePreview,
  reconnect,
  fullscreen,
  newSession,
  settings,
  closeSession,
  keyboardShortcuts,
  quickActions,
  composePrompt,
  recentDirectories,
}

/// "Label (keys)" on desktop, where a keyboard shortcut exists; the bare
/// label on phones.
String _withKeys(String label, String keys) =>
    PlatformFeatures.isDesktop ? '$label ($keys)' : label;

/// The terminal's single chrome row (~40 dp): back, the scrollable session
/// and file tabs, then the session grid, the agents badge and ONE overflow
/// menu: chat view and the session tools (git diff, live preview), then
/// reconnect, fullscreen and new session, then close session.
///
/// Swipes on the row, like an app switcher: up or down opens the quick
/// switcher (the grid button's action, and the swipe from the terminal's
/// top strip), left or right moves to the next or previous open session.
class TerminalHeader extends StatelessWidget {
  const TerminalHeader({
    required this.workspace,
    required this.activeSession,
    required this.palette,
    required this.brightness,
    required this.onBack,
    required this.onTabsChanged,
    required this.fileTabs,
    required this.activeFileTab,
    required this.onFileTabSelected,
    required this.onFileTabClosed,
    this.onReconnect,
    this.onToggleFullscreen,
    this.onNewSession,
    this.onShowShortcuts,
    this.onQuickActions,
    this.onComposePrompt,
    this.onRecentDirectories,
    this.onOpenChatView,
    this.onOpenSettings,
    this.attentionCount = 0,
    this.onOpenAgentAttention,
    this.onOpenSessionTool,
    this.onOpenSessionGrid,
    this.swipeDownOpensSessionGrid = true,
    this.onSwipeSession,
    this.onSessionActivated,
    this.onSessionLongPress,
    this.multiplexerTabsFor,
    this.onOpenMultiplexerTabs,
    this.tabs,
    this.backIcon = Icons.chevron_left_rounded,
    this.backTooltip = 'Machines',
    this.leavesWhenEmpty = true,
    this.extraActions = const [],
    super.key,
  });

  /// Buttons before the overflow menu (the desktop shell's panel toggles).
  final List<Widget> extraActions;

  static const height = 40.0;

  /// Replaces the session and file tabs (the desktop shell's own strip).
  final Widget? tabs;

  /// The back button's icon and tooltip (the desktop shell: Home).
  final IconData backIcon;
  final String backTooltip;

  /// Whether closing the last session from the menu leaves the page (a
  /// pushed route); the desktop shell stays and shows its dashboard.
  final bool leavesWhenEmpty;

  final TerminalWorkspaceController workspace;
  final TerminalSessionController? activeSession;
  final AppPalette palette;
  final Brightness brightness;
  final VoidCallback onBack;

  /// Called after a tab switch or close so the page can refocus.
  final VoidCallback onTabsChanged;
  final List<TerminalFileTab> fileTabs;
  final TerminalFileTab? activeFileTab;
  final ValueChanged<TerminalFileTab> onFileTabSelected;
  final ValueChanged<TerminalFileTab> onFileTabClosed;

  /// Reconnects the active session; null hides the menu entry.
  final VoidCallback? onReconnect;

  /// Enters fullscreen (which hides this row); null hides the entry.
  final VoidCallback? onToggleFullscreen;

  /// Opens a new session through the connect flow; null hides the entry.
  final VoidCallback? onNewSession;

  /// Opens the desktop keyboard shortcuts sheet; null (phones) hides the
  /// entry.
  final VoidCallback? onShowShortcuts;

  /// The session's project quick actions; null hides the entry.
  final VoidCallback? onQuickActions;

  /// Desktop: the prompt composer and recent folders, which phones reach
  /// from the on-screen keys.
  final VoidCallback? onComposePrompt;
  final VoidCallback? onRecentDirectories;

  /// Opens the chat view of the active session's Claude agent; null hides
  /// the entry.
  final VoidCallback? onOpenChatView;

  /// Opens the Settings page (the ⋮ menu's "Settings"); null hides it.
  final VoidCallback? onOpenSettings;

  /// Number of monitored agents currently needing attention (badge).
  final int attentionCount;

  /// Opens the Agent Attention dashboard; null hides the button.
  final VoidCallback? onOpenAgentAttention;

  /// Opens a session tool (git diff, live preview) for the active session;
  /// null hides those entries.
  final ValueChanged<SessionTool>? onOpenSessionTool;

  /// Opens the session overview (the quick switcher); null hides the
  /// button.
  final VoidCallback? onOpenSessionGrid;

  /// Whether swipes on the row work: up or down opens the overview, left
  /// or right switches sessions.
  final bool swipeDownOpensSessionGrid;

  /// Switches to the next (1) or previous (-1) open session after a
  /// horizontal swipe on the row; null turns that swipe off.
  final ValueChanged<int>? onSwipeSession;

  /// A tap on a session's tab made it active.
  final ValueChanged<TerminalSessionController>? onSessionActivated;

  /// Long-press on a session's tab (its "Open in" choice).
  final ValueChanged<TerminalSessionController>? onSessionLongPress;

  /// See [SessionTabs.multiplexerTabsFor] (the phone's compact mode).
  final MultiplexerTabsController? Function(TerminalSessionController)?
  multiplexerTabsFor;

  /// See [SessionTabs.onOpenMultiplexerTabs].
  final ValueChanged<TerminalSessionController>? onOpenMultiplexerTabs;

  @override
  Widget build(BuildContext context) {
    final foreground = palette.foregroundFor(brightness);
    final session = activeSession;
    final swipeSessions =
        swipeDownOpensSessionGrid &&
        onSwipeSession != null &&
        workspace.sessions.length > 1;
    return TopRowSwipeArea(
      enabled: swipeDownOpensSessionGrid,
      onSwipeVertical: onOpenSessionGrid,
      onSwipeHorizontal: swipeSessions ? onSwipeSession : null,
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: palette.canvasFor(brightness),
          border: Border(
            bottom: BorderSide(color: palette.hairlineFor(brightness)),
          ),
        ),
        child: Row(
          children: [
            _RowButton(
              key: const ValueKey('terminal-header-back'),
              tooltip: backTooltip,
              color: foreground,
              icon: Icon(
                backIcon,
                size: backIcon == Icons.chevron_left_rounded ? 26 : 20,
              ),
              onPressed: onBack,
            ),
            Expanded(
              child:
                  tabs ??
                  SessionTabs(
                    workspace: workspace,
                    activeSession: session,
                    palette: palette,
                    brightness: brightness,
                    onChanged: onTabsChanged,
                    fileTabs: fileTabs,
                    activeFileTab: activeFileTab,
                    onFileTabSelected: onFileTabSelected,
                    onFileTabClosed: onFileTabClosed,
                    onSessionActivated: onSessionActivated,
                    onSessionLongPress: onSessionLongPress,
                    multiplexerTabsFor: multiplexerTabsFor,
                    onOpenMultiplexerTabs: onOpenMultiplexerTabs,
                    touchScrolls: !swipeSessions,
                  ),
            ),
            if (onOpenSessionGrid != null)
              _RowButton(
                tooltip: _withKeys('Sessions', quickSwitcherKeys),
                key: const ValueKey('terminal-open-switcher'),
                color: foreground,
                icon: const Icon(Icons.grid_view_rounded, size: 19),
                onPressed: onOpenSessionGrid!,
              ),
            if (onOpenAgentAttention != null)
              _RowButton(
                tooltip: 'Agents',
                color: foreground,
                icon: Badge.count(
                  count: attentionCount,
                  isLabelVisible: attentionCount > 0,
                  child: const Icon(Icons.monitor_heart_outlined, size: 20),
                ),
                onPressed: onOpenAgentAttention!,
              ),
            ...extraActions,
            _OverflowMenu(
              session: session,
              color: foreground,
              onReconnect: onReconnect,
              onToggleFullscreen: onToggleFullscreen,
              onNewSession: onNewSession,
              onShowShortcuts: onShowShortcuts,
              onQuickActions: onQuickActions,
              onComposePrompt: onComposePrompt,
              onRecentDirectories: onRecentDirectories,
              onOpenChatView: onOpenChatView,
              onOpenSettings: onOpenSettings,
              onOpenSessionTool: onOpenSessionTool,
              onClose: session == null
                  ? null
                  : () async {
                      await workspace.close(session);
                      onTabsChanged();
                      if (!context.mounted || !leavesWhenEmpty) return;
                      if (!workspace.hasSessions && fileTabs.isEmpty) {
                        Navigator.of(context).pop();
                      }
                    },
            ),
          ],
        ),
      ),
    );
  }
}

/// The terminal row's swipes. A vertical swipe either way runs
/// [onSwipeVertical]; a horizontal one runs [onSwipeHorizontal] with 1 for
/// a swipe to the left (the next session, like turning a page) and -1 for
/// one to the right. Only touch and stylus swipe: a mouse drags and
/// scrolls as usual.
class TopRowSwipeArea extends StatefulWidget {
  const TopRowSwipeArea({
    required this.child,
    this.onSwipeVertical,
    this.onSwipeHorizontal,
    this.enabled = true,
    super.key,
  });

  final VoidCallback? onSwipeVertical;
  final ValueChanged<int>? onSwipeHorizontal;
  final bool enabled;
  final Widget child;

  /// Travel that makes a swipe, in logical pixels.
  static const minimumDistance = TerminalSwipeRecognizer.minimumDistance;

  /// A quick flick counts from half the distance.
  static const flickVelocity = 400.0;

  static const _devices = {
    PointerDeviceKind.touch,
    PointerDeviceKind.stylus,
    PointerDeviceKind.invertedStylus,
    PointerDeviceKind.unknown,
  };

  @override
  State<TopRowSwipeArea> createState() => _TopRowSwipeAreaState();
}

class _TopRowSwipeAreaState extends State<TopRowSwipeArea> {
  double _travel = 0;

  bool _isSwipe(double travel, double velocity) =>
      travel.abs() >= TopRowSwipeArea.minimumDistance ||
      (travel.abs() >= TopRowSwipeArea.minimumDistance / 2 &&
          velocity.abs() >= TopRowSwipeArea.flickVelocity &&
          velocity.sign == travel.sign);

  @override
  Widget build(BuildContext context) {
    final vertical = widget.onSwipeVertical;
    final horizontal = widget.onSwipeHorizontal;
    if (!widget.enabled || (vertical == null && horizontal == null)) {
      return widget.child;
    }
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      supportedDevices: TopRowSwipeArea._devices,
      onVerticalDragStart: vertical == null ? null : (_) => _travel = 0,
      onVerticalDragUpdate: vertical == null
          ? null
          : (details) => _travel += details.delta.dy,
      onVerticalDragEnd: vertical == null
          ? null
          : (details) {
              if (_isSwipe(_travel, details.velocity.pixelsPerSecond.dy)) {
                vertical();
              }
              _travel = 0;
            },
      onHorizontalDragStart: horizontal == null ? null : (_) => _travel = 0,
      onHorizontalDragUpdate: horizontal == null
          ? null
          : (details) => _travel += details.delta.dx,
      onHorizontalDragEnd: horizontal == null
          ? null
          : (details) {
              if (_isSwipe(_travel, details.velocity.pixelsPerSecond.dx)) {
                horizontal(_travel < 0 ? 1 : -1);
              }
              _travel = 0;
            },
      child: widget.child,
    );
  }
}

class _RowButton extends StatelessWidget {
  const _RowButton({
    required this.tooltip,
    required this.color,
    required this.icon,
    required this.onPressed,
    super.key,
  });

  final String tooltip;
  final Color color;
  final Widget icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      color: color,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 38, height: 40),
      icon: icon,
      onPressed: onPressed,
    );
  }
}

class _OverflowMenu extends StatelessWidget {
  const _OverflowMenu({
    required this.session,
    required this.color,
    required this.onReconnect,
    required this.onToggleFullscreen,
    required this.onNewSession,
    required this.onClose,
    this.onShowShortcuts,
    this.onQuickActions,
    this.onComposePrompt,
    this.onRecentDirectories,
    this.onOpenChatView,
    this.onOpenSessionTool,
    this.onOpenSettings,
  });

  final TerminalSessionController? session;
  final Color color;
  final VoidCallback? onReconnect;
  final VoidCallback? onToggleFullscreen;
  final VoidCallback? onNewSession;
  final VoidCallback? onClose;
  final VoidCallback? onShowShortcuts;

  /// The session's project quick actions; null hides the entry.
  final VoidCallback? onQuickActions;

  /// Desktop: the prompt composer and recent folders, which phones reach
  /// from the on-screen keys.
  final VoidCallback? onComposePrompt;
  final VoidCallback? onRecentDirectories;
  final VoidCallback? onOpenChatView;
  final ValueChanged<SessionTool>? onOpenSessionTool;
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final session = this.session;
    final tools = onOpenSessionTool;
    return PopupMenuButton<TerminalHeaderAction>(
      tooltip: 'More',
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 200),
      iconColor: color,
      icon: const Icon(Icons.more_vert_rounded, size: 20),
      style: IconButton.styleFrom(
        minimumSize: const Size(34, 40),
        maximumSize: const Size(34, 40),
        padding: EdgeInsets.zero,
      ),
      onSelected: (action) => switch (action) {
        TerminalHeaderAction.chatView => onOpenChatView?.call(),
        TerminalHeaderAction.gitDiff => tools?.call(SessionTool.gitDiff),
        TerminalHeaderAction.livePreview => tools?.call(
          SessionTool.livePreview,
        ),
        TerminalHeaderAction.reconnect => onReconnect?.call(),
        TerminalHeaderAction.fullscreen => onToggleFullscreen?.call(),
        TerminalHeaderAction.newSession => onNewSession?.call(),
        TerminalHeaderAction.settings => onOpenSettings?.call(),
        TerminalHeaderAction.closeSession => onClose?.call(),
        TerminalHeaderAction.keyboardShortcuts => onShowShortcuts?.call(),
        TerminalHeaderAction.quickActions => onQuickActions?.call(),
        TerminalHeaderAction.composePrompt => onComposePrompt?.call(),
        TerminalHeaderAction.recentDirectories => onRecentDirectories?.call(),
      },
      itemBuilder: (context) {
        final theme = Theme.of(context);
        // Grouped: agent and session tools, session control, close.
        final groups = [
          <PopupMenuEntry<TerminalHeaderAction>>[
            if (onOpenChatView != null)
              const PopupMenuItem(
                value: TerminalHeaderAction.chatView,
                child: _MenuRow(Icons.forum_outlined, 'Open chat view'),
              ),
            if (onQuickActions != null)
              const PopupMenuItem(
                key: ValueKey('terminal-menu-quick-actions'),
                value: TerminalHeaderAction.quickActions,
                child: _MenuRow(Icons.bolt_rounded, 'Quick actions'),
              ),
            if (onComposePrompt != null)
              const PopupMenuItem(
                key: ValueKey('terminal-menu-compose'),
                value: TerminalHeaderAction.composePrompt,
                child: _MenuRow(Icons.edit_note_rounded, 'Compose a prompt…'),
              ),
            if (onRecentDirectories != null)
              const PopupMenuItem(
                key: ValueKey('terminal-menu-recent-dirs'),
                value: TerminalHeaderAction.recentDirectories,
                child: _MenuRow(Icons.folder_open_outlined, 'Recent folders…'),
              ),
            if (tools != null) ...const [
              PopupMenuItem(
                value: TerminalHeaderAction.gitDiff,
                child: _MenuRow(Icons.difference_outlined, 'Git diff'),
              ),
              PopupMenuItem(
                value: TerminalHeaderAction.livePreview,
                child: _MenuRow(Icons.public_rounded, 'Live preview'),
              ),
            ],
          ],
          <PopupMenuEntry<TerminalHeaderAction>>[
            if (onReconnect != null)
              PopupMenuItem(
                value: TerminalHeaderAction.reconnect,
                child: _MenuRow(
                  Icons.refresh_rounded,
                  // A local shell starts over; there is no connection.
                  session?.runsOnThisComputer ?? false
                      ? 'Restart'
                      : 'Reconnect',
                ),
              ),
            if (onToggleFullscreen != null)
              const PopupMenuItem(
                value: TerminalHeaderAction.fullscreen,
                child: _MenuRow(
                  Icons.fullscreen_rounded,
                  'Fullscreen',
                  action: DesktopAction.toggleFullscreen,
                ),
              ),
            if (onNewSession != null)
              const PopupMenuItem(
                value: TerminalHeaderAction.newSession,
                child: _MenuRow(Icons.add_rounded, 'New session'),
              ),
            if (onOpenSettings != null)
              const PopupMenuItem(
                key: ValueKey('terminal-menu-settings'),
                value: TerminalHeaderAction.settings,
                child: _MenuRow(Icons.settings_outlined, 'Settings'),
              ),
            if (onShowShortcuts != null)
              const PopupMenuItem(
                value: TerminalHeaderAction.keyboardShortcuts,
                child: _MenuRow(
                  Icons.keyboard_outlined,
                  'Keyboard shortcuts',
                  action: DesktopAction.showShortcuts,
                ),
              ),
          ],
          <PopupMenuEntry<TerminalHeaderAction>>[
            if (onClose != null)
              const PopupMenuItem(
                value: TerminalHeaderAction.closeSession,
                child: _MenuRow(
                  Icons.close_rounded,
                  'Close session',
                  action: DesktopAction.closeSession,
                ),
              ),
          ],
        ].where((group) => group.isNotEmpty).toList();
        return [
          if (session != null)
            PopupMenuItem<TerminalHeaderAction>(
              enabled: false,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    session.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: theme.colorScheme.onSurface,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Text(
                    session.host.endpoint,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),
            ),
          for (final (index, group) in groups.indexed) ...[
            if (index > 0 || session != null) const PopupMenuDivider(),
            ...group,
          ],
        ];
      },
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow(this.icon, this.label, {this.action});

  final IconData icon;
  final String label;

  /// Shows this action's keyboard shortcut at the end of the row, on
  /// desktop only.
  final DesktopAction? action;

  @override
  Widget build(BuildContext context) {
    final action = this.action;
    return Row(
      children: [
        Icon(icon, size: 18),
        const SizedBox(width: 10),
        Text(label),
        if (action != null && PlatformFeatures.isDesktop) ...[
          const Spacer(),
          const SizedBox(width: 16),
          Text(
            desktopShortcutKeys(action),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}
