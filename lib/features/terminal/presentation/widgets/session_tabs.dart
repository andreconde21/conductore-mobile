import 'package:conduit/core/presentation/multiplexer_icon.dart';
import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/core/theme/app_theme.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/terminal/presentation/multiplexer_tabs_controller.dart';
import 'package:conduit/features/terminal/presentation/terminal_file_tabs_controller.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:conduit/features/terminal/presentation/widgets/multiplexer_tab_compact.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Compact, horizontally scrolling tabs for the open sessions and file
/// viewers, sized to sit inside the terminal's single chrome row.
///
/// Each tab shows a connection dot (or a file icon) and a short name; the
/// active tab is highlighted and carries the close button, so the row stays
/// narrow. Closing a file tab goes through [onFileTabClosed], which asks
/// before discarding unsaved edits.
class SessionTabs extends StatefulWidget {
  const SessionTabs({
    required this.workspace,
    required this.activeSession,
    required this.palette,
    required this.brightness,
    required this.onChanged,
    required this.fileTabs,
    required this.activeFileTab,
    required this.onFileTabSelected,
    required this.onFileTabClosed,
    this.onSessionActivated,
    this.onSessionLongPress,
    this.touchScrolls = true,
    this.multiplexerTabsFor,
    this.onOpenMultiplexerTabs,
    super.key,
  });

  final TerminalWorkspaceController workspace;
  final TerminalSessionController? activeSession;
  final AppPalette palette;
  final Brightness brightness;
  final VoidCallback onChanged;
  final List<TerminalFileTab> fileTabs;
  final TerminalFileTab? activeFileTab;
  final ValueChanged<TerminalFileTab> onFileTabSelected;
  final ValueChanged<TerminalFileTab> onFileTabClosed;

  /// Called after a tap on another session's tab made it the active one (a
  /// user choice, as opposed to a close moving the focus).
  final ValueChanged<TerminalSessionController>? onSessionActivated;

  /// Long-press on a session's tab; null leaves long-press to the tooltip.
  final ValueChanged<TerminalSessionController>? onSessionLongPress;

  /// Whether a touch drag scrolls the strip. Off while a horizontal swipe
  /// on the row switches sessions: the strip then follows the active tab,
  /// and a mouse or trackpad still scrolls it.
  final bool touchScrolls;

  /// The multiplexer tabs to name inside a session's (active) tab, the
  /// phone's compact mode; null names none.
  final MultiplexerTabsController? Function(TerminalSessionController)?
  multiplexerTabsFor;

  /// A tap on that name: the list of the multiplexer's tabs.
  final ValueChanged<TerminalSessionController>? onOpenMultiplexerTabs;

  /// Height of one tab chip.
  static const tabHeight = 30.0;

  /// Short display name for [session]: the project or agent part of a
  /// derived title ("Host: Infrastructure" shows "Infrastructure"), so a
  /// narrow tab never ends in the machine's name. The full title stays when
  /// another open session on a different machine has the same target.
  static String labelFor(
    TerminalSessionController session,
    List<TerminalSessionController> sessions,
  ) {
    final title = session.title;
    final cut = title.lastIndexOf(': ');
    if (ConnectTarget.keyFromSessionHostId(session.host.id) == null ||
        cut <= 0 ||
        cut + 2 >= title.length) {
      return title;
    }
    final target = title.substring(cut + 2);
    final machine = baseHostId(session.host.id);
    final clash = sessions.any(
      (other) =>
          baseHostId(other.host.id) != machine &&
          other.title.endsWith(': $target'),
    );
    return clash ? title : target;
  }

  @override
  State<SessionTabs> createState() => _SessionTabsState();
}

class _SessionTabsState extends State<SessionTabs> {
  final _activeKey = GlobalKey();
  Object? _lastActive;

  @override
  void didUpdateWidget(covariant SessionTabs oldWidget) {
    super.didUpdateWidget(oldWidget);
    _revealActive();
  }

  @override
  void initState() {
    super.initState();
    _revealActive();
  }

  /// Scrolls the active tab into view whenever it changes.
  void _revealActive() {
    final active = widget.activeFileTab ?? widget.activeSession;
    if (identical(active, _lastActive)) return;
    _lastActive = active;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = _activeKey.currentContext;
      if (!mounted || context == null) return;
      Scrollable.ensureVisible(
        context,
        alignment: 0.5,
        duration: const Duration(milliseconds: 180),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final sessions = widget.workspace.sessions;
    final fileTabs = widget.fileTabs;
    final tabCount = sessions.length + fileTabs.length;
    final list = SizedBox(
      height: SessionTabs.tabHeight,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 2),
        itemCount: tabCount,
        separatorBuilder: (context, index) => const SizedBox(width: 4),
        itemBuilder: (context, index) {
          if (index >= sessions.length) {
            final tab = fileTabs[index - sessions.length];
            final selected = tab == widget.activeFileTab;
            final dirty = tab.viewerKey.currentState?.isDirty ?? false;
            // Tool tabs (git diff, live preview) retitle themselves as
            // their state changes, so the label listens to the tab.
            return ListenableBuilder(
              key: selected ? _activeKey : ValueKey(tab),
              listenable: tab.listenable ?? _inertListenable,
              builder: (context, _) => _Tab(
                label: tab.title,
                tooltip: tab.tooltip,
                leading: Icon(
                  tab.icon,
                  size: 13,
                  color: selected
                      ? widget.palette.accent
                      : widget.palette.mutedForegroundFor(widget.brightness),
                ),
                dirty: dirty,
                selected: selected,
                palette: widget.palette,
                brightness: widget.brightness,
                onTap: () => widget.onFileTabSelected(tab),
                onClose: () => widget.onFileTabClosed(tab),
              ),
            );
          }
          final session = sessions[index];
          final selected =
              widget.activeFileTab == null && session == widget.activeSession;
          final muxTabs = selected
              ? widget.multiplexerTabsFor?.call(session)
              : null;
          return _Tab(
            key: selected ? _activeKey : ValueKey(session),
            label: SessionTabs.labelFor(session, sessions),
            inline: muxTabs == null
                ? null
                : MultiplexerTabInlineLabel(
                    controller: muxTabs,
                    color: widget.palette.foregroundFor(widget.brightness),
                    mutedColor: widget.palette.mutedForegroundFor(
                      widget.brightness,
                    ),
                    onTap: () => widget.onOpenMultiplexerTabs?.call(session),
                  ),
            tooltip: '${session.title}\n${session.host.endpoint}',
            leading: SessionTabLeading(session: session),
            selected: selected,
            palette: widget.palette,
            brightness: widget.brightness,
            onTap: () {
              widget.workspace.activate(session);
              widget.onChanged();
              if (!selected) widget.onSessionActivated?.call(session);
            },
            onLongPress: widget.onSessionLongPress == null
                ? null
                : () => widget.onSessionLongPress!(session),
            onClose: () async {
              await widget.workspace.close(session);
              widget.onChanged();
              if (!context.mounted) return;
              if (!widget.workspace.hasSessions && widget.fileTabs.isEmpty) {
                Navigator.of(context).pop();
              }
            },
          );
        },
      ),
    );
    if (widget.touchScrolls) return list;
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(
        dragDevices: const {
          PointerDeviceKind.mouse,
          PointerDeviceKind.trackpad,
        },
      ),
      child: list,
    );
  }
}

final Listenable _inertListenable = ChangeNotifier();

/// A session tab's connection dot, followed by the tmux or Herdr logo when the
/// session runs in one.
class SessionTabLeading extends StatelessWidget {
  const SessionTabLeading({required this.session, super.key});

  final TerminalSessionController session;

  MultiplexerKind? get _multiplexer {
    final kind = ConnectTarget.fromSessionHostId(session.host.id)?.kind;
    return switch (kind) {
      ConnectTargetKind.herdr => MultiplexerKind.herdr,
      ConnectTargetKind.tmux => MultiplexerKind.tmux,
      null when session.host.startTmuxOnConnect && !session.host.isLocal =>
        MultiplexerKind.tmux,
      _ => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    final multiplexer = _multiplexer;
    final dot = _StatusDot(status: session.status);
    if (multiplexer == null) return dot;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        dot,
        const SizedBox(width: 5),
        MultiplexerIcon(multiplexer, size: 13, semanticLabel: ''),
      ],
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.label,
    required this.tooltip,
    required this.leading,
    required this.selected,
    required this.palette,
    required this.brightness,
    required this.onTap,
    required this.onClose,
    this.onLongPress,
    this.inline,
    this.dirty = false,
    super.key,
  });

  final String label;
  final String tooltip;
  final Widget leading;
  final bool selected;
  final bool dirty;
  final AppPalette palette;
  final Brightness brightness;
  final VoidCallback onTap;
  final VoidCallback onClose;
  final VoidCallback? onLongPress;

  /// Tappable extra after the label (the current multiplexer tab).
  final Widget? inline;

  @override
  Widget build(BuildContext context) {
    final accent = palette.accent;
    final foreground = palette.foregroundFor(brightness);
    final muted = palette.mutedForegroundFor(brightness);
    final background = selected
        ? Color.alphaBlend(
            accent.withValues(alpha: 0.16),
            palette.panelFor(brightness),
          )
        : Colors.transparent;
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 600),
      // Long-press belongs to the tab's menu when it has one (hover still
      // shows the tooltip).
      triggerMode: onLongPress == null ? null : TooltipTriggerMode.manual,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppTheme.radius),
          onTap: onTap,
          onLongPress: onLongPress,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            constraints: BoxConstraints(maxWidth: inline == null ? 176 : 280),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(AppTheme.radius),
              border: Border.all(
                color: selected
                    ? accent.withValues(alpha: 0.55)
                    : palette.hairlineFor(brightness),
              ),
            ),
            padding: EdgeInsets.only(left: 8, right: selected ? 0 : 9),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                leading,
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: selected ? foreground : muted,
                      fontSize: 12.5,
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                    ),
                  ),
                ),
                if (inline != null) Flexible(child: inline!),
                if (dirty)
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Container(
                      key: const ValueKey('dirty-dot'),
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: accent,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                if (selected)
                  SizedBox(
                    width: 26,
                    height: 26,
                    child: IconButton(
                      tooltip: 'Close',
                      iconSize: 14,
                      padding: EdgeInsets.zero,
                      color: muted,
                      onPressed: onClose,
                      icon: const Icon(Icons.close_rounded),
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

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.status});

  final TerminalConnectionStatus status;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      TerminalConnectionStatus.connected => const Color(0xFF22C55E),
      TerminalConnectionStatus.connecting => const Color(0xFFEAB308),
      TerminalConnectionStatus.failed => Theme.of(context).colorScheme.error,
      TerminalConnectionStatus.idle ||
      TerminalConnectionStatus.disconnected => const Color(0xFF64748B),
    };
    return Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}
