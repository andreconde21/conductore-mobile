import 'package:conduit/core/platform_features.dart';
import 'package:conduit/core/presentation/multiplexer_icon.dart';
import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/core/theme/app_theme.dart';
import 'package:conduit/features/agent_attention/presentation/widgets/agent_inbox_widgets.dart';
import 'package:conduit/features/desktop_shell/domain/sidebar_prefs.dart';
import 'package:conduit/features/desktop_shell/domain/sidebar_tree.dart';
import 'package:conduit/features/desktop_shell/presentation/desktop_shell_controller.dart';
import 'package:conduit/features/desktop_shell/presentation/widgets/shell_state_dot.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// What a dragged sidebar row carries.
@immutable
class SidebarDrag {
  const SidebarDrag(this.node, {this.pinned = false});

  final SidebarNode node;

  /// Dragged from the Pinned section (reorders pins).
  final bool pinned;
}

/// The desktop shell's left sidebar: a pinned "Needs you" group, pinned
/// rows, the user's groups and every machine with its Herdr workspaces and
/// tmux sessions, their tabs / windows and agent panes. Each row has its
/// logo, a human name, a state dot, the agent kind, whether it is open in
/// the app, and unread markers rolled up to its parents.
///
/// Rows open on click, expand with the chevron, and offer their actions on
/// right-click ([onContextMenu]). Machines, workspaces and pins reorder by
/// drag and drop; a machine dropped on a group joins it.
class ShellSidebar extends StatefulWidget {
  const ShellSidebar({
    required this.controller,
    required this.tree,
    required this.unreadKeys,
    required this.onOpen,
    required this.onContextMenu,
    required this.onGroupMenu,
    required this.onExpand,
    this.selectedKey,
    this.header,
    this.footer,
    super.key,
  });

  final DesktopShellController controller;

  /// Every machine with its rows, in the user's order.
  final List<SidebarNode> tree;

  /// Unread rows (see [DesktopShellController.unread]).
  final Set<String> unreadKeys;

  /// The row of the focused view, highlighted.
  final String? selectedKey;

  final ValueChanged<SidebarNode> onOpen;
  final void Function(SidebarNode node, Offset position) onContextMenu;
  final void Function(SidebarGroup group, Offset position) onGroupMenu;

  /// A row was opened with its chevron (tmux sessions list their windows).
  final ValueChanged<SidebarNode> onExpand;

  /// Buttons above the filter (switcher, new session, collapse).
  final Widget? header;

  /// Below the list: the usage summary slot and the settings row.
  final Widget? footer;

  @override
  State<ShellSidebar> createState() => _ShellSidebarState();
}

sealed class _Entry {
  const _Entry();
}

class _Header extends _Entry {
  const _Header(this.label, this.kind, {this.group, this.count = 0});

  final String label;
  final _HeaderKind kind;
  final SidebarGroup? group;
  final int count;
}

enum _HeaderKind { needsYou, pinned, group, machines }

class _Row extends _Entry {
  const _Row(
    this.node, {
    required this.depth,
    this.section = _HeaderKind.machines,
    this.context = '',
    this.groupId,
    this.siblings = const [],
  });

  final SidebarNode node;
  final int depth;
  final _HeaderKind section;

  /// Where the row lives, for flat sections ("workstation › api").
  final String context;
  final String? groupId;

  /// The keys of the row's siblings in order (for drag reordering).
  final List<String> siblings;
}

class _ShellSidebarState extends State<ShellSidebar> {
  late final TextEditingController _filter = TextEditingController(
    text: widget.controller.filter,
  );

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  DesktopShellController get _controller => widget.controller;

  List<_Entry> _entries() {
    final controller = _controller;
    final prefs = controller.prefs;
    final query = controller.filter;
    final filtering = query.trim().isNotEmpty;
    final tree = filtering
        ? SidebarTreeBuilder.filter(widget.tree, query)
        : widget.tree;
    final entries = <_Entry>[];
    final names = {for (final node in widget.tree) node.machineId: node.label};

    void subtree(
      SidebarNode node,
      int depth,
      List<String> siblings, {
      String? groupId,
    }) {
      entries.add(
        _Row(node, depth: depth, groupId: groupId, siblings: siblings),
      );
      final open = filtering || controller.isExpanded(node);
      if (!open) return;
      final keys = [for (final child in node.children) child.key];
      for (final child in node.children) {
        subtree(child, depth + 1, keys);
      }
    }

    if (!filtering) {
      final needsYou = SidebarTreeBuilder.needsYou(tree);
      if (needsYou.isNotEmpty) {
        entries.add(
          _Header('Needs you', _HeaderKind.needsYou, count: needsYou.length),
        );
        for (final node in needsYou) {
          entries.add(
            _Row(
              node,
              depth: 0,
              section: _HeaderKind.needsYou,
              context: names[node.machineId] ?? '',
            ),
          );
        }
      }
      final pinned = [
        for (final key in prefs.pinned) ?SidebarTreeBuilder.find(tree, key),
      ];
      if (pinned.isNotEmpty) {
        entries.add(const _Header('Pinned', _HeaderKind.pinned));
        final keys = [for (final node in pinned) node.key];
        for (final node in pinned) {
          entries.add(
            _Row(
              node,
              depth: 0,
              section: _HeaderKind.pinned,
              context: node.kind == SidebarNodeKind.machine
                  ? ''
                  : names[node.machineId] ?? '',
              siblings: keys,
            ),
          );
        }
      }
    }

    final byId = {for (final node in tree) node.machineId: node};
    final grouped = <String>{};
    for (final group in prefs.groups) {
      final members = [for (final id in group.machineIds) ?byId[id]];
      grouped.addAll(members.map((node) => node.machineId));
      if (filtering && members.isEmpty) continue;
      entries.add(
        _Header(
          group.name,
          _HeaderKind.group,
          group: group,
          count: members.length,
        ),
      );
      if (!filtering && !prefs.isExpanded('g/${group.id}', byDefault: true)) {
        continue;
      }
      final ids = [for (final node in members) node.machineId];
      for (final node in members) {
        subtree(node, 0, ids, groupId: group.id);
      }
    }
    final rest = [
      for (final node in tree)
        if (!grouped.contains(node.machineId)) node,
    ];
    if (rest.isNotEmpty || prefs.groups.isNotEmpty) {
      entries.add(const _Header('Machines', _HeaderKind.machines));
      final ids = [for (final node in rest) node.machineId];
      for (final node in rest) {
        subtree(node, 0, ids);
      }
    }
    return entries;
  }

  int _unreadUnder(SidebarNode node) =>
      _controller.unreadCount(node, widget.unreadKeys);

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final entries = _entries();
    return Material(
      color: palette.panel,
      child: Column(
        children: [
          ?widget.header,
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 4, 10, 6),
            child: SizedBox(
              height: 32,
              child: CallbackShortcuts(
                bindings: {
                  const SingleActivator(LogicalKeyboardKey.escape): () {
                    _filter.clear();
                    _controller.filter = '';
                    FocusScope.of(context).unfocus();
                  },
                },
                child: TextField(
                  key: const ValueKey('sidebar-filter'),
                  controller: _filter,
                  onChanged: (value) => _controller.filter = value,
                  // Enter opens the first match; Esc clears the filter.
                  onSubmitted: (_) {
                    final rows = _entries().whereType<_Row>();
                    final first =
                        rows
                            .where(
                              (row) => row.node.kind != SidebarNodeKind.machine,
                            )
                            .firstOrNull ??
                        rows.firstOrNull;
                    if (first != null) widget.onOpen(first.node);
                  },
                  style: const TextStyle(fontSize: 13),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'Filter',
                    prefixIcon: const Icon(Icons.search_rounded, size: 17),
                    prefixIconConstraints: const BoxConstraints(minWidth: 32),
                    suffixIcon: _filter.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Clear filter',
                            iconSize: 15,
                            padding: EdgeInsets.zero,
                            onPressed: () {
                              _filter.clear();
                              _controller.filter = '';
                            },
                            icon: const Icon(Icons.close_rounded),
                          ),
                    contentPadding: const EdgeInsets.symmetric(vertical: 6),
                    filled: true,
                    fillColor: palette.canvas,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppTheme.radius),
                      borderSide: BorderSide(color: palette.hairline),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppTheme.radius),
                      borderSide: BorderSide(color: palette.hairline),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: entries.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      _controller.filter.isEmpty
                          ? 'No machines yet.'
                          : 'Nothing matches “${_controller.filter}”.',
                      style: TextStyle(
                        color: palette.mutedForeground,
                        fontSize: 12.5,
                      ),
                    ),
                  )
                : ListView.builder(
                    key: const ValueKey('sidebar-list'),
                    padding: const EdgeInsets.only(bottom: 8),
                    itemCount: entries.length,
                    itemBuilder: (context, index) =>
                        _buildEntry(context, entries[index]),
                  ),
          ),
          ?widget.footer,
        ],
      ),
    );
  }

  Widget _buildEntry(BuildContext context, _Entry entry) {
    return switch (entry) {
      _Header() => _buildHeader(context, entry),
      _Row() => _buildRow(context, entry),
    };
  }

  Widget _buildHeader(BuildContext context, _Header header) {
    final palette = AppPalette.of(context);
    final group = header.group;
    final expandedKey = group == null ? null : 'g/${group.id}';
    final expanded =
        expandedKey == null ||
        _controller.prefs.isExpanded(expandedKey, byDefault: true);
    final attention = header.kind == _HeaderKind.needsYou;
    Widget content = Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 3),
      child: Row(
        children: [
          if (group != null)
            InkWell(
              key: ValueKey('sidebar-group-toggle-${group.id}'),
              onTap: () => _controller.updatePrefs(
                (prefs) => prefs.setExpanded(expandedKey!, !expanded),
              ),
              child: Icon(
                expanded
                    ? Icons.expand_more_rounded
                    : Icons.chevron_right_rounded,
                semanticLabel: expanded ? 'Collapse' : 'Expand',
                size: 15,
                color: palette.mutedForeground,
              ),
            ),
          if (attention) ...[
            Icon(Icons.front_hand_rounded, size: 13, color: palette.attention),
            const SizedBox(width: 5),
          ],
          if (header.kind == _HeaderKind.pinned) ...[
            Icon(
              Icons.push_pin_outlined,
              size: 13,
              color: palette.mutedForeground,
            ),
            const SizedBox(width: 5),
          ],
          Expanded(
            child: Text(
              header.label.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: attention ? palette.attention : palette.mutedForeground,
                fontSize: 11,
                letterSpacing: 1.1,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (header.count > 0 && header.kind != _HeaderKind.group)
            Text(
              '${header.count}',
              style: TextStyle(
                color: attention ? palette.attention : palette.mutedForeground,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          if (group != null)
            Builder(
              builder: (context) => Tooltip(
                message: 'Group actions',
                child: InkWell(
                  key: ValueKey('sidebar-group-menu-${group.id}'),
                  borderRadius: BorderRadius.circular(4),
                  onTapUp: (details) =>
                      widget.onGroupMenu(group, details.globalPosition),
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: Icon(
                      Icons.more_horiz_rounded,
                      size: 16,
                      color: palette.mutedForeground,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
    content = GestureDetector(
      key: ValueKey('sidebar-header-${header.kind.name}-${group?.id ?? ''}'),
      behavior: HitTestBehavior.opaque,
      onSecondaryTapUp: group == null
          ? null
          : (details) => widget.onGroupMenu(group, details.globalPosition),
      child: content,
    );
    // Drops: a machine onto a group (or Machines) moves it there; any row
    // onto Pinned pins it.
    if (header.kind == _HeaderKind.needsYou) return content;
    return DragTarget<SidebarDrag>(
      onWillAcceptWithDetails: (details) {
        final node = details.data.node;
        if (header.kind == _HeaderKind.pinned) return !details.data.pinned;
        return node.kind == SidebarNodeKind.machine;
      },
      onAcceptWithDetails: (details) {
        final node = details.data.node;
        switch (header.kind) {
          case _HeaderKind.pinned:
            _controller.updatePrefs(
              (prefs) =>
                  prefs.isPinned(node.key) ? prefs : prefs.togglePin(node.key),
            );
          case _HeaderKind.group:
            _controller.updatePrefs(
              (prefs) => prefs.moveMachine(
                node.machineId,
                visibleOrder: _machineOrder(),
                groupId: group!.id,
              ),
            );
          case _HeaderKind.machines:
            _controller.updatePrefs(
              (prefs) => prefs.moveMachine(
                node.machineId,
                visibleOrder: _machineOrder(),
              ),
            );
          case _HeaderKind.needsYou:
            break;
        }
      },
      builder: (context, candidates, _) => DecoratedBox(
        decoration: BoxDecoration(
          color: candidates.isEmpty
              ? null
              : palette.accent.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(6),
        ),
        child: content,
      ),
    );
  }

  List<String> _machineOrder() => [
    for (final node in widget.tree) node.machineId,
  ];

  Widget _buildRow(BuildContext context, _Row row) {
    final node = row.node;
    final flat = row.section != _HeaderKind.machines;
    final expanded = !flat && _controller.isExpanded(node);
    final canExpand = !flat && node.hasChildren;
    // Collapsed rows (and machines, always) show their subtree's count.
    final rolled = _unreadUnder(node);
    final self = widget.unreadKeys.contains(node.key);
    final count = expanded && node.kind != SidebarNodeKind.machine
        ? (self ? 1 : 0)
        : rolled;
    final tile = _SidebarRowTile(
      key: ValueKey('sidebar-row-${row.section.name}-${node.key}'),
      node: node,
      depth: row.depth,
      context: row.context,
      expanded: canExpand ? expanded : null,
      selected: node.key == widget.selectedKey,
      unread: rolled > 0,
      unreadCount: count,
      pinned: row.section == _HeaderKind.pinned,
      onTap: () => widget.onOpen(node),
      onToggle: canExpand
          ? () {
              if (!expanded) widget.onExpand(node);
              _controller.toggleExpanded(node);
            }
          : null,
      onContextMenu: (position) => widget.onContextMenu(node, position),
    );

    final draggable =
        row.section == _HeaderKind.pinned ||
        (row.section == _HeaderKind.machines &&
            (node.kind == SidebarNodeKind.machine || node.isReorderableChild));
    final drag = SidebarDrag(node, pinned: row.section == _HeaderKind.pinned);
    // Every row can be dragged onto a pane (or the Pinned header); only
    // some reorder among their siblings.
    if (!draggable) {
      return Draggable<SidebarDrag>(
        data: drag,
        affinity: PlatformFeatures.isDesktop ? null : Axis.horizontal,
        dragAnchorStrategy: pointerDragAnchorStrategy,
        feedback: _RowFeedback(label: node.label),
        child: tile,
      );
    }
    return DragTarget<SidebarDrag>(
      onWillAcceptWithDetails: (details) => _accepts(row, details.data),
      onAcceptWithDetails: (details) => _drop(row, details.data),
      builder: (context, candidates, _) => Draggable<SidebarDrag>(
        data: drag,
        // With touch (tablets) a vertical drag scrolls the list: rows
        // start moving on a sideways drag.
        affinity: PlatformFeatures.isDesktop ? null : Axis.horizontal,
        dragAnchorStrategy: pointerDragAnchorStrategy,
        feedback: _RowFeedback(label: node.label),
        childWhenDragging: Opacity(opacity: 0.4, child: tile),
        child: Stack(
          children: [
            tile,
            if (candidates.isNotEmpty)
              Positioned(
                left: 8,
                right: 8,
                top: 0,
                child: Container(
                  key: const ValueKey('sidebar-drop-line'),
                  height: 2,
                  color: AppPalette.of(context).accent,
                ),
              ),
          ],
        ),
      ),
    );
  }

  bool _accepts(_Row row, SidebarDrag drag) {
    final target = row.node;
    final node = drag.node;
    if (node.key == target.key) return false;
    if (row.section == _HeaderKind.pinned) return true;
    if (drag.pinned) return false;
    if (node.kind == SidebarNodeKind.machine) {
      return target.kind == SidebarNodeKind.machine;
    }
    return node.isReorderableChild &&
        target.isReorderableChild &&
        node.machineId == target.machineId;
  }

  void _drop(_Row row, SidebarDrag drag) {
    final target = row.node;
    final node = drag.node;
    if (row.section == _HeaderKind.pinned) {
      _controller.updatePrefs((prefs) {
        final pinned = prefs.isPinned(node.key)
            ? prefs
            : prefs.togglePin(node.key);
        return pinned.movePin(node.key, target.key);
      });
      return;
    }
    if (node.kind == SidebarNodeKind.machine) {
      _controller.updatePrefs(
        (prefs) => prefs.moveMachine(
          node.machineId,
          visibleOrder: _machineOrder(),
          beforeId: target.machineId,
          groupId: row.groupId,
        ),
      );
      return;
    }
    _controller.updatePrefs(
      (prefs) => prefs.moveChild(
        node.machineId,
        node.key,
        visibleOrder: row.siblings,
        beforeKey: target.key,
      ),
    );
  }
}

/// One row: chevron, logo, name (bold when unread) and detail, then the
/// open-in-app mark, the state dot and the unread count.
class _SidebarRowTile extends StatelessWidget {
  const _SidebarRowTile({
    required this.node,
    required this.depth,
    required this.context,
    required this.expanded,
    required this.selected,
    required this.unread,
    required this.unreadCount,
    required this.pinned,
    required this.onTap,
    required this.onToggle,
    required this.onContextMenu,
    super.key,
  });

  final SidebarNode node;
  final int depth;
  final String context;

  /// Null: nothing to expand.
  final bool? expanded;
  final bool selected;
  final bool unread;
  final int unreadCount;
  final bool pinned;
  final VoidCallback onTap;
  final VoidCallback? onToggle;
  final ValueChanged<Offset> onContextMenu;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final machine = node.kind == SidebarNodeKind.machine;
    final detail = [
      if (this.context.isNotEmpty) this.context,
      if (node.detail.isNotEmpty) node.detail,
    ].join(' · ');
    final label = Text(
      node.label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: palette.foreground,
        fontSize: machine ? 13.5 : 13,
        fontWeight: unread || machine ? FontWeight.w800 : FontWeight.w500,
      ),
    );
    return Semantics(
      button: true,
      selected: selected,
      label: [
        node.label,
        if (node.dot != SidebarDot.none) node.dot.label,
        if (unread) 'unread',
      ].join(', '),
      child: GestureDetector(
        onSecondaryTapUp: (details) => onContextMenu(details.globalPosition),
        onLongPressStart: (details) => onContextMenu(details.globalPosition),
        child: Material(
          color: selected
              ? Color.alphaBlend(
                  palette.accent.withValues(alpha: 0.16),
                  palette.panel,
                )
              : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: onTap,
            child: Padding(
              padding: EdgeInsets.fromLTRB(4.0 + depth * 14, 3, 8, 3),
              child: Row(
                children: [
                  SizedBox(
                    width: 18,
                    child: expanded == null
                        ? null
                        : InkWell(
                            key: ValueKey('sidebar-chevron-${node.key}'),
                            borderRadius: BorderRadius.circular(4),
                            onTap: onToggle,
                            child: Icon(
                              expanded!
                                  ? Icons.expand_more_rounded
                                  : Icons.chevron_right_rounded,
                              size: 16,
                              color: palette.mutedForeground,
                            ),
                          ),
                  ),
                  const SizedBox(width: 2),
                  SizedBox(
                    width: 20,
                    child: Center(child: _NodeIcon(node: node)),
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: detail.isEmpty
                        ? label
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              label,
                              Text(
                                detail,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: palette.mutedForeground,
                                  fontSize: 11,
                                  height: 1.25,
                                ),
                              ),
                            ],
                          ),
                  ),
                  if (unreadCount > 0) ...[
                    const SizedBox(width: 6),
                    ShellUnreadBadge(count: unreadCount),
                  ],
                  if (pinned)
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: Icon(
                        Icons.push_pin_rounded,
                        size: 11,
                        color: palette.mutedForeground,
                      ),
                    ),
                  if (node.openInApp && !machine)
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: Tooltip(
                        message: 'Open in the app',
                        child: Icon(
                          Icons.tab_rounded,
                          key: ValueKey('sidebar-open-${node.key}'),
                          size: 12,
                          color: palette.accent,
                        ),
                      ),
                    ),
                  if (node.dot != SidebarDot.none) ...[
                    const SizedBox(width: 7),
                    ShellStateDot(dot: node.dot),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NodeIcon extends StatelessWidget {
  const _NodeIcon({required this.node});

  final SidebarNode node;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final muted = palette.mutedForeground;
    final agentKind = node.agentKind;
    switch (node.kind) {
      case SidebarNodeKind.machine:
        final local = node.target.host.isThisComputer;
        return Icon(
          local ? Icons.computer_rounded : Icons.dns_outlined,
          size: 16,
          color: palette.foreground,
        );
      case SidebarNodeKind.herdrWorkspace:
      case SidebarNodeKind.tmuxSession:
        return MultiplexerIcon(node.multiplexer!, size: 15, semanticLabel: '');
      case SidebarNodeKind.openSession:
        final kind = node.multiplexer;
        return kind == null
            ? Icon(Icons.terminal_rounded, size: 15, color: muted)
            : MultiplexerIcon(kind, size: 15, semanticLabel: '');
      case SidebarNodeKind.agentPane:
        return AgentKindBadge(kind: agentKind ?? '', size: 17);
      case SidebarNodeKind.herdrTab:
      case SidebarNodeKind.tmuxWindow:
        if (agentKind != null && agentKind.isNotEmpty) {
          return AgentKindBadge(kind: agentKind, size: 17);
        }
        return Icon(
          node.kind == SidebarNodeKind.herdrTab
              ? Icons.tab_outlined
              : Icons.web_asset_outlined,
          size: 14,
          color: muted,
        );
    }
  }
}

class _RowFeedback extends StatelessWidget {
  const _RowFeedback({required this.label});

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

/// The collapsed sidebar: one icon per machine (with its state and unread
/// count), the needs-you count on top.
class CollapsedShellSidebar extends StatelessWidget {
  const CollapsedShellSidebar({
    required this.tree,
    required this.unreadCount,
    required this.needsYouCount,
    required this.onExpand,
    required this.onMachine,
    required this.onNeedsYou,
    this.footer,
    this.onContextMenu,
    super.key,
  });

  /// Right-click on a machine: the same menu as in the full sidebar.
  final void Function(SidebarNode node, Offset position)? onContextMenu;

  final List<SidebarNode> tree;
  final int Function(SidebarNode node) unreadCount;
  final int needsYouCount;
  final VoidCallback onExpand;
  final ValueChanged<SidebarNode> onMachine;
  final VoidCallback onNeedsYou;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Material(
      color: palette.panel,
      child: Column(
        children: [
          const SizedBox(height: 6),
          IconButton(
            key: const ValueKey('sidebar-expand'),
            tooltip: 'Show the sidebar',
            icon: const Icon(Icons.keyboard_double_arrow_right_rounded),
            onPressed: onExpand,
          ),
          if (needsYouCount > 0)
            IconButton(
              tooltip: 'Needs you: $needsYouCount',
              onPressed: onNeedsYou,
              icon: Badge.count(
                count: needsYouCount,
                backgroundColor: palette.attention,
                child: Icon(Icons.front_hand_rounded, color: palette.attention),
              ),
            ),
          const Divider(height: 12, indent: 10, endIndent: 10),
          Expanded(
            child: ListView(
              children: [
                for (final node in tree)
                  Tooltip(
                    message: node.label,
                    child: GestureDetector(
                      onSecondaryTapUp: onContextMenu == null
                          ? null
                          : (details) =>
                                onContextMenu!(node, details.globalPosition),
                      child: InkWell(
                        key: ValueKey('sidebar-collapsed-${node.key}'),
                        onTap: () => onMachine(node),
                        child: SizedBox(
                          height: 40,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              Icon(
                                node.target.host.isThisComputer
                                    ? Icons.computer_rounded
                                    : Icons.dns_outlined,
                                size: 20,
                                color: palette.foreground,
                              ),
                              Positioned(
                                right: 12,
                                top: 8,
                                child: ShellStateDot(dot: node.dot, size: 7),
                              ),
                              Positioned(
                                right: 8,
                                bottom: 6,
                                child: ShellUnreadBadge(
                                  count: unreadCount(node),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          ?footer,
        ],
      ),
    );
  }
}
