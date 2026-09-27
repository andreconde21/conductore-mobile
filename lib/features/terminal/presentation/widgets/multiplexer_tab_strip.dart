import 'dart:async';

import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/core/theme/app_theme.dart';
import 'package:conduit/core/theme/terminal_appearance.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/terminal/domain/multiplexer_tabs.dart';
import 'package:conduit/features/terminal/presentation/multiplexer_tabs_controller.dart';
import 'package:conduit/features/terminal/presentation/widgets/multiplexer_tab_actions.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// How the terminal shows a session's multiplexer tabs.
enum MultiplexerTabsLayout {
  /// A row of chips under the top row.
  strip,

  /// No extra row: the session tab names the current one (phones).
  compact,

  hidden,
}

/// A desktop always gets the strip (unless the setting is off); a phone or
/// tablet follows [mode], compact by default.
MultiplexerTabsLayout multiplexerTabsLayout(
  MultiplexerTabsMode mode, {
  required bool desktop,
}) => switch (mode) {
  MultiplexerTabsMode.off => MultiplexerTabsLayout.hidden,
  MultiplexerTabsMode.strip => MultiplexerTabsLayout.strip,
  MultiplexerTabsMode.compact =>
    desktop ? MultiplexerTabsLayout.strip : MultiplexerTabsLayout.compact,
};

/// Keeps [controller] polling while this sits on screen: the route is not
/// covered (tickers on), the app is in front, and [active]. Draws [child].
class MultiplexerTabsPoller extends StatefulWidget {
  const MultiplexerTabsPoller({
    required this.controller,
    this.active = true,
    this.interval = const Duration(seconds: 2),
    this.child = const SizedBox.shrink(),
    super.key,
  });

  final MultiplexerTabsController controller;
  final bool active;

  /// How often to list the tabs while polling.
  final Duration interval;
  final Widget child;

  @override
  State<MultiplexerTabsPoller> createState() => _MultiplexerTabsPollerState();
}

class _MultiplexerTabsPollerState extends State<MultiplexerTabsPoller>
    with WidgetsBindingObserver {
  bool _routeVisible = true;
  bool _appResumed = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _routeVisible = TickerMode.valuesOf(context).enabled;
    _sync();
  }

  @override
  void didUpdateWidget(covariant MultiplexerTabsPoller oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.setVisible(false);
    }
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appResumed = state == AppLifecycleState.resumed;
    _sync();
  }

  void _sync() {
    widget.controller
      ..setPollInterval(widget.interval)
      ..setVisible(widget.active && _routeVisible && _appResumed);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.setVisible(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The multiplexer's own tabs under the terminal's top row (desktops, and
/// phones set to Strip): one chip per Herdr tab of the focused workspace
/// or tmux window of the session, the active one highlighted and kept in
/// view, a dot for an agent's state or for news since the tab was last
/// shown, and "+" for a new one.
///
/// Tap switches; long-press offers rename, move and close; on a desktop
/// the chips of a tmux session can be dragged into a new order, and a
/// right-click opens the same menu, a double-click renames, a middle-click
/// or the hover close button closes.
class MultiplexerTabStrip extends StatefulWidget {
  const MultiplexerTabStrip({
    required this.controller,
    required this.palette,
    required this.brightness,
    required this.desktop,
    this.onChanged,
    super.key,
  });

  static const height = 32.0;

  final MultiplexerTabsController controller;
  final AppPalette palette;
  final Brightness brightness;
  final bool desktop;

  /// After an action from the strip, so the page can refocus the terminal.
  final VoidCallback? onChanged;

  @override
  State<MultiplexerTabStrip> createState() => _MultiplexerTabStripState();
}

class _MultiplexerTabStripState extends State<MultiplexerTabStrip> {
  final _activeKey = GlobalKey();
  final _scroll = ScrollController();
  String? _lastActive;

  // The last click on a chip, to tell a desktop double-click (rename)
  // without delaying the single click that switches.
  String? _lastTapId;
  DateTime _lastTapAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_revealActive);
    _revealActive();
  }

  @override
  void didUpdateWidget(covariant MultiplexerTabStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_revealActive);
      widget.controller.addListener(_revealActive);
      _lastActive = null;
      _revealActive();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_revealActive);
    _scroll.dispose();
    super.dispose();
  }

  void _revealActive() {
    final active = widget.controller.active?.id;
    if (active == null || active == _lastActive) return;
    _lastActive = active;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _activeKey.currentContext;
      if (!mounted || target == null) return;
      unawaited(
        Scrollable.ensureVisible(
          target,
          alignment: 0.5,
          duration: MediaQuery.maybeDisableAnimationsOf(context) ?? false
              ? Duration.zero
              : const Duration(milliseconds: 180),
        ),
      );
    });
  }

  Future<void> _select(MultiplexerTab tab) async {
    await widget.controller.select(tab);
    widget.onChanged?.call();
  }

  void _tap(MultiplexerTab tab) {
    if (widget.desktop) {
      final now = DateTime.now();
      final isDouble =
          _lastTapId == tab.id &&
          now.difference(_lastTapAt) <= kDoubleTapTimeout;
      _lastTapId = isDouble ? null : tab.id;
      _lastTapAt = now;
      if (isDouble) {
        unawaited(
          renameMultiplexerTab(
            context,
            widget.controller,
            tab,
            onDone: widget.onChanged,
          ),
        );
        return;
      }
    }
    unawaited(_select(tab));
  }

  Future<void> _create() async {
    await widget.controller.create();
    widget.onChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        final tabs = controller.tabs;
        if (!controller.loaded || tabs.isEmpty) {
          return const SizedBox.shrink();
        }
        final palette = widget.palette;
        final brightness = widget.brightness;
        final reorderable = controller.canReorder && widget.desktop;

        Widget chip(MultiplexerTab tab) => _TabChip(
          key: tab.active ? _activeKey : null,
          tab: tab,
          showIndex: controller.kind == MultiplexerTabsKind.tmux,
          palette: palette,
          brightness: brightness,
          onTap: () => _tap(tab),
          onLongPress: () => unawaited(
            showMultiplexerTabActions(
              context,
              controller,
              tab,
              onDone: widget.onChanged,
            ),
          ),
          onSecondaryTapUp: widget.desktop
              ? (details) => unawaited(
                  showMultiplexerTabActions(
                    context,
                    controller,
                    tab,
                    onDone: widget.onChanged,
                    anchorPosition: details.globalPosition,
                  ),
                )
              : null,
          onClose: widget.desktop
              ? () => unawaited(
                  closeMultiplexerTab(
                    context,
                    controller,
                    tab,
                    onDone: widget.onChanged,
                  ),
                )
              : null,
          closeTooltip: 'Close ${multiplexerTabNoun(controller)}',
        );

        final list = reorderable
            ? ReorderableListView.builder(
                key: const ValueKey('mux-tabs-reorderable'),
                scrollController: _scroll,
                scrollDirection: Axis.horizontal,
                buildDefaultDragHandles: false,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                itemCount: tabs.length,
                onReorderItem: (from, to) =>
                    unawaited(controller.reorder(from, to)),
                itemBuilder: (context, index) => ReorderableDragStartListener(
                  key: ValueKey('mux-tab-${tabs[index].id}'),
                  index: index,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: chip(tabs[index]),
                  ),
                ),
              )
            : ListView.separated(
                controller: _scroll,
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                itemCount: tabs.length,
                separatorBuilder: (_, _) => const SizedBox(width: 4),
                itemBuilder: (context, index) => KeyedSubtree(
                  key: ValueKey('mux-tab-${tabs[index].id}'),
                  child: chip(tabs[index]),
                ),
              );
        return Container(
          key: const ValueKey('multiplexer-tab-strip'),
          height: MultiplexerTabStrip.height,
          decoration: BoxDecoration(
            color: palette.canvasFor(brightness),
            border: Border(
              bottom: BorderSide(color: palette.hairlineFor(brightness)),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Align(alignment: Alignment.centerLeft, child: list),
              ),
              IconButton(
                key: const ValueKey('mux-tab-new'),
                tooltip: 'New ${multiplexerTabNoun(controller)}',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: 34,
                  height: MultiplexerTabStrip.height,
                ),
                iconSize: 18,
                color: palette.foregroundFor(brightness),
                icon: const Icon(Icons.add_rounded),
                onPressed: () => unawaited(_create()),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _TabChip extends StatefulWidget {
  const _TabChip({
    required this.tab,
    required this.showIndex,
    required this.palette,
    required this.brightness,
    required this.onTap,
    required this.onLongPress,
    this.onSecondaryTapUp,
    this.onClose,
    this.closeTooltip = 'Close',
    super.key,
  });

  final MultiplexerTab tab;
  final bool showIndex;
  final AppPalette palette;
  final Brightness brightness;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  /// Desktop only: the right-click menu.
  final GestureTapUpCallback? onSecondaryTapUp;

  /// Desktop only: the hover close button and the middle-click.
  final VoidCallback? onClose;
  final String closeTooltip;

  @override
  State<_TabChip> createState() => _TabChipState();
}

class _TabChipState extends State<_TabChip> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final tab = widget.tab;
    final palette = widget.palette;
    final brightness = widget.brightness;
    final showIndex = widget.showIndex;
    final onClose = widget.onClose;
    final accent = palette.accent;
    final foreground = palette.foregroundFor(brightness);
    final muted = palette.mutedForegroundFor(brightness);
    final chip = Center(
      child: Semantics(
        selected: tab.active,
        button: true,
        label: [
          tab.label,
          if (tab.unread) 'new activity',
          if (tab.status case final status?
              when status != AgentAttentionState.idle &&
                  status != AgentAttentionState.unknown)
            status.label,
        ].join(', '),
        excludeSemantics: true,
        child: Material(
          color: tab.active
              ? Color.alphaBlend(
                  accent.withValues(alpha: 0.16),
                  palette.panelFor(brightness),
                )
              : Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTheme.radius),
            side: BorderSide(
              color: tab.active
                  ? accent.withValues(alpha: 0.55)
                  : palette.hairlineFor(brightness),
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: widget.onTap,
            onLongPress: widget.onLongPress,
            onSecondaryTapUp: widget.onSecondaryTapUp,
            onHover: onClose == null
                ? null
                : (hovered) => setState(() => _hovered = hovered),
            child: Container(
              height: 24,
              constraints: const BoxConstraints(maxWidth: 168),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (showIndex) ...[
                    Text(
                      '${tab.index}',
                      style: TextStyle(
                        color: muted,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 5),
                  ],
                  Flexible(
                    child: Text(
                      tab.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: tab.active || tab.unread ? foreground : muted,
                        fontSize: 12,
                        fontWeight: tab.active
                            ? FontWeight.w800
                            : FontWeight.w600,
                      ),
                    ),
                  ),
                  if (multiplexerTabDot(context, tab) != null) ...[
                    const SizedBox(width: 5),
                    MultiplexerTabDot(tab: tab),
                  ],
                  if (onClose != null) ...[
                    const SizedBox(width: 3),
                    // Space kept while hidden, so chips don't jump.
                    Visibility(
                      visible: _hovered,
                      maintainSize: true,
                      maintainAnimation: true,
                      maintainState: true,
                      child: IconButton(
                        key: ValueKey('mux-tab-close-button-${tab.id}'),
                        tooltip: widget.closeTooltip,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints.tightFor(
                          width: 18,
                          height: 18,
                        ),
                        iconSize: 13,
                        color: muted,
                        icon: const Icon(Icons.close_rounded),
                        onPressed: onClose,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (onClose == null) return chip;
    // A middle-click closes, like a browser tab.
    return Listener(
      onPointerDown: (event) {
        if (event.kind == PointerDeviceKind.mouse &&
            event.buttons & kMiddleMouseButton != 0) {
          onClose();
        }
      },
      child: chip,
    );
  }
}
