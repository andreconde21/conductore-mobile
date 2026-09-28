import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/features/desktop_shell/domain/shell_layout.dart';
import 'package:conduit/features/desktop_shell/domain/sidebar_tree.dart';
import 'package:conduit/features/desktop_shell/presentation/widgets/shell_sidebar.dart'
    show SidebarDrag;
import 'package:conduit/features/desktop_shell/presentation/widgets/shell_state_dot.dart';
import 'package:flutter/material.dart';

/// What a dragged tab (or pane header) carries.
@immutable
class ShellViewDrag {
  const ShellViewDrag(this.viewId, this.label, {this.fromPane});

  final String viewId;
  final String label;

  /// The pane whose header was dragged: dropped on another pane's middle,
  /// the two swap.
  final String? fromPane;
}

/// A pane header's title for a view.
@immutable
class ShellPaneTitle {
  const ShellPaneTitle(this.label, {this.leading, this.dot = SidebarDot.none});

  final String label;
  final Widget? leading;
  final SidebarDot dot;
}

/// The main area's panes: [layout] with each pane showing its view from
/// [views], resizable dividers between them, and drop zones on every pane
/// while a tab is dragged (an edge splits, the centre shows it there).
///
/// Views on no pane stay mounted offstage, so a terminal keeps its state
/// (and a web view its page) when it moves between panes or tabs.
class ShellSplitArea extends StatefulWidget {
  const ShellSplitArea({
    required this.layout,
    required this.views,
    required this.onFocusPane,
    required this.onDrop,
    required this.onResize,
    required this.onClosePane,
    this.titleFor,
    this.focusedOverlay = const [],
    this.emptyPane,
    this.onDropNode,
    this.onSwap,
    this.onFillPane,
    super.key,
  });

  final ShellLayout layout;

  /// Every open view by id, in tab order.
  final Map<String, Widget> views;
  final ValueChanged<String> onFocusPane;
  final void Function(String paneId, ShellEdge edge, String viewId) onDrop;
  final void Function(List<int> path, double ratio) onResize;
  final ValueChanged<String> onClosePane;

  /// The pane header's title (shown once the area is split).
  final ShellPaneTitle Function(String viewId)? titleFor;

  /// Stacked over the focused pane (chips and bars of the focused session).
  final List<Widget> focusedOverlay;

  /// Shown in a pane without a view.
  final Widget? emptyPane;

  /// A sidebar row (session, agent, workspace, machine) dropped on a pane:
  /// open it there, or at that edge.
  final void Function(String paneId, ShellEdge edge, SidebarDrag drag)?
  onDropNode;

  /// A pane header dropped on another pane's middle: swap their views.
  final void Function(String fromPane, String toPane)? onSwap;

  /// The "Open…" button of an empty pane: pick something to show in it.
  final ValueChanged<String>? onFillPane;

  /// Height of a pane's title row in a split.
  static const paneHeaderHeight = 26.0;

  /// Width of a divider's grab area.
  static const dividerThickness = 6.0;

  @override
  State<ShellSplitArea> createState() => _ShellSplitAreaState();
}

class _ShellSplitAreaState extends State<ShellSplitArea> {
  final Map<String, GlobalKey> _keys = {};
  final Map<String, ShellEdge> _hover = {};

  GlobalKey _keyFor(String viewId) =>
      _keys.putIfAbsent(viewId, () => GlobalKey(debugLabel: viewId));

  @override
  void didUpdateWidget(covariant ShellSplitArea oldWidget) {
    super.didUpdateWidget(oldWidget);
    _keys.removeWhere((viewId, _) => !widget.views.containsKey(viewId));
  }

  @override
  Widget build(BuildContext context) {
    final visible = widget.layout.visibleViews;
    final hidden = [
      for (final viewId in widget.views.keys)
        if (!visible.contains(viewId)) viewId,
    ];
    return Stack(
      children: [
        Positioned.fill(child: _node(context, widget.layout.root, const [])),
        // Offstage, still laid out at full size like the phone's
        // IndexedStack, so hidden terminals keep their size.
        Positioned.fill(
          child: Offstage(
            child: TickerMode(
              enabled: false,
              child: Stack(
                children: [
                  for (final viewId in hidden)
                    Positioned.fill(
                      child: KeyedSubtree(
                        key: _keyFor(viewId),
                        child: widget.views[viewId]!,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _node(BuildContext context, ShellNode node, List<int> path) {
    return switch (node) {
      ShellPane() => _pane(context, node),
      ShellSplit() => _split(context, node, path),
    };
  }

  Widget _split(BuildContext context, ShellSplit split, List<int> path) {
    final horizontal = split.axis == ShellSplitAxis.horizontal;
    return LayoutBuilder(
      builder: (context, constraints) {
        final extent = horizontal
            ? constraints.maxWidth
            : constraints.maxHeight;
        final available = (extent - ShellSplitArea.dividerThickness).clamp(
          1.0,
          double.infinity,
        );
        final firstExtent = available * split.ratio;
        final children = <Widget>[
          SizedBox(
            width: horizontal ? firstExtent : null,
            height: horizontal ? null : firstExtent,
            child: _node(context, split.first, [...path, 0]),
          ),
          _Divider(
            key: ValueKey('shell-divider-${path.join()}'),
            horizontal: horizontal,
            onDrag: (delta) =>
                widget.onResize(path, split.ratio + delta / available),
          ),
          Expanded(child: _node(context, split.second, [...path, 1])),
        ];
        return horizontal
            ? Row(children: children)
            : Column(children: children);
      },
    );
  }

  Widget _pane(BuildContext context, ShellPane pane) {
    final palette = AppPalette.of(context);
    final split = widget.layout.isSplit;
    final focused = pane.id == widget.layout.focusedPane.id;
    final view = pane.view;
    final content = view == null || !widget.views.containsKey(view)
        ? (widget.emptyPane ??
              _EmptyPane(
                key: ValueKey('shell-empty-pane-${pane.id}'),
                focused: focused && split,
                onOpen: widget.onFillPane == null
                    ? null
                    : () => widget.onFillPane!(pane.id),
              ))
        : KeyedSubtree(key: _keyFor(view), child: widget.views[view]!);
    final title = view == null ? null : widget.titleFor?.call(view);
    return Listener(
      key: ValueKey('shell-pane-${pane.id}'),
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) {
        if (!focused) widget.onFocusPane(pane.id);
      },
      child: Builder(
        builder: (paneContext) => DragTarget<Object>(
          onWillAcceptWithDetails: (details) {
            final data = details.data;
            if (data is ShellViewDrag) return data.fromPane != pane.id;
            return data is SidebarDrag && widget.onDropNode != null;
          },
          onMove: (details) {
            final box = paneContext.findRenderObject();
            if (box is! RenderBox) return;
            final edge = _edgeAt(box, details.offset);
            if (_hover[pane.id] != edge) setState(() => _hover[pane.id] = edge);
          },
          onLeave: (_) => setState(() => _hover.remove(pane.id)),
          onAcceptWithDetails: (details) {
            final edge = _hover.remove(pane.id) ?? ShellEdge.center;
            setState(() {});
            switch (details.data) {
              case ShellViewDrag(:final fromPane?)
                  when edge == ShellEdge.center && widget.onSwap != null:
                widget.onSwap!(fromPane, pane.id);
              case ShellViewDrag(:final viewId):
                widget.onDrop(pane.id, edge, viewId);
              case final SidebarDrag drag:
                widget.onDropNode?.call(pane.id, edge, drag);
            }
          },
          builder: (context, candidates, _) {
            final hover = candidates.isEmpty ? null : _hover[pane.id];
            return DecoratedBox(
              position: DecorationPosition.foreground,
              decoration: BoxDecoration(
                border: split
                    ? Border.all(
                        color: focused
                            ? palette.accent.withValues(alpha: 0.85)
                            : palette.hairline,
                        width: focused ? 1.5 : 1,
                      )
                    : null,
              ),
              child: Column(
                children: [
                  if (split)
                    _draggableHeader(
                      pane,
                      _PaneHeader(
                        key: ValueKey('shell-pane-header-${pane.id}'),
                        title: title,
                        focused: focused,
                        onClose: () => widget.onClosePane(pane.id),
                      ),
                      title?.label,
                    ),
                  Expanded(
                    child: Stack(
                      children: [
                        Positioned.fill(child: content),
                        if (focused) ...widget.focusedOverlay,
                        if (hover != null)
                          Positioned.fill(
                            child: IgnorePointer(
                              child: _DropHighlight(
                                edge:
                                    widget.layout.canSplit ||
                                        hover == ShellEdge.center
                                    ? hover
                                    : ShellEdge.center,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  /// A pane's header, dragged onto another pane to swap them or onto an
  /// edge to move the view there.
  Widget _draggableHeader(ShellPane pane, Widget header, String? label) {
    final view = pane.view;
    if (view == null) return header;
    return Draggable<ShellViewDrag>(
      data: ShellViewDrag(view, label ?? '', fromPane: pane.id),
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: _HeaderFeedback(label: label ?? ''),
      child: MouseRegion(cursor: SystemMouseCursors.grab, child: header),
    );
  }

  /// The drop zone under [global]: the nearest edge within a quarter of
  /// the pane, else the centre.
  static ShellEdge _edgeAt(RenderBox box, Offset global) {
    final local = box.globalToLocal(global);
    final size = box.size;
    if (size.isEmpty) return ShellEdge.center;
    final x = (local.dx / size.width).clamp(0.0, 1.0);
    final y = (local.dy / size.height).clamp(0.0, 1.0);
    final distances = {
      ShellEdge.left: x,
      ShellEdge.right: 1 - x,
      ShellEdge.top: y,
      ShellEdge.bottom: 1 - y,
    };
    final nearest = distances.entries.reduce(
      (a, b) => a.value <= b.value ? a : b,
    );
    return nearest.value <= 0.25 ? nearest.key : ShellEdge.center;
  }
}

class _PaneHeader extends StatelessWidget {
  const _PaneHeader({
    required this.title,
    required this.focused,
    required this.onClose,
    super.key,
  });

  final ShellPaneTitle? title;
  final bool focused;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final title = this.title;
    return Container(
      height: ShellSplitArea.paneHeaderHeight,
      padding: const EdgeInsets.only(left: 8),
      decoration: BoxDecoration(
        color: focused ? palette.accentSoft : palette.panel,
        border: Border(bottom: BorderSide(color: palette.hairline)),
      ),
      child: Row(
        children: [
          if (title?.leading case final leading?) ...[
            leading,
            const SizedBox(width: 6),
          ],
          if (title != null && title.dot != SidebarDot.none) ...[
            ShellStateDot(dot: title.dot, size: 7),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: Text(
              title?.label ?? 'Empty pane',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: focused ? FontWeight.w700 : FontWeight.w500,
                color: focused ? palette.foreground : palette.mutedForeground,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Close pane',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 26, height: 26),
            iconSize: 14,
            color: palette.mutedForeground,
            icon: const Icon(Icons.close_rounded),
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

class _Divider extends StatefulWidget {
  const _Divider({required this.horizontal, required this.onDrag, super.key});

  final bool horizontal;
  final ValueChanged<double> onDrag;

  @override
  State<_Divider> createState() => _DividerState();
}

class _DividerState extends State<_Divider> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final horizontal = widget.horizontal;
    return MouseRegion(
      cursor: horizontal
          ? SystemMouseCursors.resizeColumn
          : SystemMouseCursors.resizeRow,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: horizontal
            ? (details) => widget.onDrag(details.delta.dx)
            : null,
        onVerticalDragUpdate: horizontal
            ? null
            : (details) => widget.onDrag(details.delta.dy),
        child: SizedBox(
          width: horizontal ? ShellSplitArea.dividerThickness : null,
          height: horizontal ? null : ShellSplitArea.dividerThickness,
          child: Center(
            child: Container(
              width: horizontal ? (_hovered ? 3 : 1) : null,
              height: horizontal ? null : (_hovered ? 3 : 1),
              color: _hovered ? palette.accent : palette.hairline,
            ),
          ),
        ),
      ),
    );
  }
}

class _DropHighlight extends StatelessWidget {
  const _DropHighlight({required this.edge});

  final ShellEdge edge;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final alignment = switch (edge) {
      ShellEdge.left => Alignment.centerLeft,
      ShellEdge.right => Alignment.centerRight,
      ShellEdge.top => Alignment.topCenter,
      ShellEdge.bottom => Alignment.bottomCenter,
      ShellEdge.center => Alignment.center,
    };
    final half = edge != ShellEdge.center;
    return Align(
      alignment: alignment,
      child: FractionallySizedBox(
        widthFactor: half && (edge == ShellEdge.left || edge == ShellEdge.right)
            ? 0.5
            : 1,
        heightFactor:
            half && (edge == ShellEdge.top || edge == ShellEdge.bottom)
            ? 0.5
            : 1,
        child: Container(
          key: ValueKey('drop-highlight-${edge.name}'),
          margin: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: palette.accent.withValues(alpha: 0.18),
            border: Border.all(color: palette.accent, width: 2),
            borderRadius: BorderRadius.circular(6),
          ),
        ),
      ),
    );
  }
}

class _HeaderFeedback extends StatelessWidget {
  const _HeaderFeedback({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: palette.panelElevated,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: palette.accent),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: palette.foreground,
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

/// An empty pane of a layout preset: where to drop a session, or pick one.
class _EmptyPane extends StatelessWidget {
  const _EmptyPane({required this.focused, this.onOpen, super.key});

  final bool focused;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final muted = palette.mutedForeground;
    return ColoredBox(
      color: palette.canvas,
      child: Center(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.dashboard_customize_outlined,
                  size: 28,
                  color: muted,
                ),
                const SizedBox(height: 8),
                Text(
                  'Drag a session, agent or workspace here',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: muted, fontSize: 12.5),
                ),
                if (focused)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'or open one: it lands in this pane',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: muted, fontSize: 11.5),
                    ),
                  ),
                if (onOpen != null) ...[
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: onOpen,
                    icon: const Icon(Icons.add_rounded, size: 16),
                    label: const Text('Open…'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
