import 'dart:async';
import 'dart:typed_data';

import 'package:conduit/core/platform_features.dart';
import 'package:conduit/core/presentation/multiplexer_icon.dart';
import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/features/desktop_shell/domain/project_tree.dart';
import 'package:conduit/features/desktop_shell/domain/sheprd_view.dart';
import 'package:conduit/features/desktop_shell/domain/sidebar_tree.dart';
import 'package:conduit/features/desktop_shell/presentation/desktop_shell_controller.dart';
import 'package:conduit/features/desktop_shell/presentation/project_layout_controller.dart';
import 'package:conduit/features/desktop_shell/presentation/widgets/project_view.dart';
import 'package:conduit/features/desktop_shell/presentation/widgets/shell_sidebar.dart';
import 'package:conduit/features/desktop_shell/presentation/widgets/shell_state_dot.dart';
import 'package:flutter/material.dart';

/// The sidebar's two tabs: Machines (the tree, as always) and Projects.
class SidebarTabs extends StatelessWidget {
  const SidebarTabs({required this.controller, super.key});

  final DesktopShellController controller;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    Widget tab(ShellSidebarTab tab, String label, IconData icon) {
      final selected = controller.sidebarTab == tab;
      return Expanded(
        child: Tooltip(
          message: tab == ShellSidebarTab.machines
              ? 'Machines, their workspaces and sessions'
              : 'Projects across every machine',
          child: InkWell(
            key: ValueKey('sidebar-tab-${tab.name}'),
            borderRadius: BorderRadius.circular(6),
            onTap: () => controller.sidebarTab = tab,
            child: Container(
              height: 28,
              decoration: BoxDecoration(
                color: selected
                    ? palette.accent.withValues(alpha: 0.16)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    icon,
                    size: 14,
                    color: selected ? palette.accent : palette.mutedForeground,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                      color: selected
                          ? palette.foreground
                          : palette.mutedForeground,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
      child: Row(
        children: [
          tab(ShellSidebarTab.machines, 'Machines', Icons.dns_outlined),
          const SizedBox(width: 4),
          tab(ShellSidebarTab.projects, 'Projects', Icons.folder_copy_outlined),
        ],
      ),
    );
  }
}

/// A project's icon: its favicon when the repo has one, else a monogram in
/// a colour of its own.
class ProjectIcon extends StatelessWidget {
  const ProjectIcon({required this.name, this.icon, this.size = 18, super.key});

  final String name;
  final Uint8List? icon;
  final double size;

  static const _colors = [
    Color(0xFF7FBBB3),
    Color(0xFFA7C080),
    Color(0xFFDBBC7F),
    Color(0xFFE69875),
    Color(0xFFD699B6),
    Color(0xFF83C092),
    Color(0xFFE67E80),
    Color(0xFF9DA9A0),
  ];

  /// Up to two letters: "visit-tomar" → "VT", "api" → "A".
  static String monogram(String name) {
    final words = name
        .split(RegExp(r'[^A-Za-z0-9]+|(?<=[a-z])(?=[A-Z])'))
        .where((word) => word.isNotEmpty)
        .toList();
    if (words.isEmpty) return '?';
    if (words.length == 1) return words.first[0].toUpperCase();
    return (words[0][0] + words[1][0]).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final bytes = icon;
    final radius = BorderRadius.circular(size * 0.22);
    if (bytes != null) {
      return ClipRRect(
        borderRadius: radius,
        child: Image.memory(
          bytes,
          width: size,
          height: size,
          fit: BoxFit.contain,
          gaplessPlayback: true,
          errorBuilder: (context, _, _) => _monogram(radius),
        ),
      );
    }
    return _monogram(radius);
  }

  Widget _monogram(BorderRadius radius) {
    final color = _colors[name.toLowerCase().hashCode.abs() % _colors.length];
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.22),
        borderRadius: radius,
        border: Border.all(color: color.withValues(alpha: 0.7)),
      ),
      child: Text(
        monogram(name),
        style: TextStyle(
          color: color,
          fontSize: size * 0.46,
          fontWeight: FontWeight.w800,
          height: 1,
        ),
      ),
    );
  }
}

/// Needs you / working / done counts, as small coloured numbers.
class ProjectCounts extends StatelessWidget {
  const ProjectCounts({required this.project, super.key});

  final ProjectGroup project;

  @override
  Widget build(BuildContext context) {
    Widget count(int value, SidebarDot dot, String label) => Tooltip(
      message: '$value ${label.toLowerCase()}',
      child: Padding(
        padding: const EdgeInsets.only(left: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ShellStateDot(dot: dot, size: 7),
            const SizedBox(width: 3),
            Text(
              '$value',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: AppPalette.of(context).mutedForeground,
              ),
            ),
          ],
        ),
      ),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (project.needsYou > 0)
          count(project.needsYou, SidebarDot.needsYou, 'Need you'),
        if (project.working > 0)
          count(project.working, SidebarDot.working, 'Working'),
        if (project.done > 0) count(project.done, SidebarDot.done, 'Done'),
      ],
    );
  }
}

/// The Projects tab: each project (favicon, name, counts), opening to its
/// workspaces and sessions on every machine. Rows open, drag onto panes
/// and have the same right-click menu as in the Machines tab; a project's
/// own right-click (or its ⋯) lists its quick actions.
///
/// With a [layout] (CON-065) it is sheprd's sidebar: the layout's projects
/// (pinned first), then Other; the all / active filter, the needs-you
/// counter and the detailed / compact view in a header; collapsed
/// projects show their worst state and a count.
class ProjectSidebar extends StatefulWidget {
  const ProjectSidebar({
    required this.controller,
    required this.projects,
    required this.machineNames,
    required this.iconFor,
    required this.onOpen,
    required this.onContextMenu,
    required this.onProjectMenu,
    this.selectedKey,
    this.header,
    this.footer,
    this.layout,
    this.tokensToday = const {},
    this.onNeedsYou,
    this.onEntryMenu,
    super.key,
  });

  /// A row's right-click in the layout view: its project actions (or
  /// sheprd's marks) with the usual ones, for [row] (an agent row of the
  /// entry, or the entry's own). Null uses [onContextMenu].
  final void Function(
    ProjectEntry entry,
    ProjectGroup project,
    Offset at,
    SidebarNode row,
  )?
  onEntryMenu;

  final ProjectLayoutController? layout;

  /// Today's tokens per project key, when the usage reports tell.
  final Map<String, int> tokensToday;

  /// The needs-you counter's tap.
  final VoidCallback? onNeedsYou;

  final DesktopShellController controller;
  final List<ProjectGroup> projects;
  final Map<String, String> machineNames;
  final Uint8List? Function(ProjectGroup project) iconFor;
  final ValueChanged<SidebarNode> onOpen;
  final void Function(SidebarNode node, Offset position) onContextMenu;
  final void Function(ProjectGroup project, Offset? position) onProjectMenu;
  final String? selectedKey;
  final Widget? header;
  final Widget? footer;

  static String expandKey(ProjectGroup project) => 'project/${project.key}';

  @override
  State<ProjectSidebar> createState() => _ProjectSidebarState();
}

class _ProjectSidebarState extends State<ProjectSidebar> {
  late final _filter = TextEditingController(text: widget.controller.filter);

  DesktopShellController get controller => widget.controller;
  List<ProjectGroup> get projects => widget.projects;

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final filter = controller.filter.trim().toLowerCase();
    final layout = widget.layout;
    final all = layout == null ? projects : layout.visibleGroups(projects);
    final shown = filter.isEmpty
        ? all
        : [
            for (final project in all)
              if (project.name.toLowerCase().contains(filter) ||
                  project.members.any(
                    (node) => node.label.toLowerCase().contains(filter),
                  ))
                project,
          ];
    return Material(
      color: palette.panel,
      child: Column(
        children: [
          ?widget.header,
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
            child: SizedBox(
              height: 32,
              child: TextField(
                key: const ValueKey('project-filter'),
                controller: _filter,
                onChanged: (value) => controller.filter = value,
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Filter projects',
                  prefixIcon: const Icon(Icons.search_rounded, size: 17),
                  prefixIconConstraints: const BoxConstraints(minWidth: 32),
                  contentPadding: const EdgeInsets.symmetric(vertical: 6),
                  filled: true,
                  fillColor: palette.canvas,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: BorderSide(color: palette.hairline),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: BorderSide(color: palette.hairline),
                  ),
                ),
              ),
            ),
          ),
          if (layout != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 0),
              child: ProjectViewBar(
                controller: layout,
                needsYou: ProjectLayoutController.needsYouCount(projects),
                onNeedsYou: widget.onNeedsYou,
                hiddenCount: projects.fold(
                  0,
                  (sum, project) =>
                      sum + project.entries.where((e) => e.hidden).length,
                ),
                dense: true,
              ),
            ),
          Expanded(
            child: shown.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      projects.isEmpty
                          ? 'No projects yet: open a workspace or start an '
                                'agent in a repo.'
                          : 'Nothing matches “${controller.filter}”.',
                      style: TextStyle(
                        color: palette.mutedForeground,
                        fontSize: 12.5,
                      ),
                    ),
                  )
                : ListView(
                    key: const ValueKey('project-list'),
                    padding: const EdgeInsets.only(bottom: 8),
                    children: [
                      for (final project in shown) ..._rows(context, project),
                    ],
                  ),
          ),
          ?widget.footer,
        ],
      ),
    );
  }

  List<Widget> _rows(BuildContext context, ProjectGroup project) {
    final layout = widget.layout;
    if (layout != null) return _layoutRows(context, layout, project);
    final expanded =
        controller.filter.trim().isNotEmpty ||
        controller.prefs.isExpanded(
          ProjectSidebar.expandKey(project),
          byDefault: false,
        );
    return [
      _ProjectRow(
        key: ValueKey('project-row-${project.key}'),
        project: project,
        icon: widget.iconFor(project),
        expanded: expanded,
        machines: project.machineIds.length,
        onToggle: () => controller.updatePrefs(
          (prefs) =>
              prefs.setExpanded(ProjectSidebar.expandKey(project), !expanded),
        ),
        onMenu: (position) => widget.onProjectMenu(project, position),
      ),
      if (expanded)
        for (final node in project.members)
          _MemberRow(
            key: ValueKey('project-member-${project.key}-${node.key}'),
            node: node,
            machineName: widget.machineNames[node.machineId] ?? '',
            selected: node.key == widget.selectedKey,
            onOpen: () => widget.onOpen(node),
            onContextMenu: (position) => widget.onContextMenu(node, position),
          ),
    ];
  }

  void _entryMenu(
    ProjectEntry entry,
    ProjectGroup project,
    Offset at, [
    SidebarNode? row,
  ]) {
    final menu = widget.onEntryMenu;
    if (menu != null) {
      menu(entry, project, at, row ?? entry.node);
    } else {
      widget.onContextMenu(row ?? entry.node, at);
    }
  }

  /// Opens [row]; with sheprd synced, an unread agent is read from then on
  /// (sheprd does the same when an agent gets focus).
  void _open(
    ProjectLayoutController layout,
    ProjectEntry entry,
    SidebarNode row,
  ) {
    widget.onOpen(row);
    if (layout.sheprdSync &&
        entry.sheprdOf(row)?.presence == SheprdPresence.unread) {
      unawaited(layout.mark(entry, row, SheprdMark.read));
    }
  }

  /// sheprd's rows: the header (worst state and count when collapsed),
  /// then one row per workspace (compact) or per agent (detailed).
  List<Widget> _layoutRows(
    BuildContext context,
    ProjectLayoutController layout,
    ProjectGroup project,
  ) {
    final entries = layout.visibleEntries(project);
    final collapsed =
        controller.filter.trim().isEmpty && layout.isCollapsed(project);
    final names = widget.machineNames;
    return [
      ProjectHeaderTile(
        key: ValueKey('project-row-${project.key}'),
        project: project,
        collapsed: collapsed,
        count: entries.length,
        tokensToday: widget.tokensToday[project.key],
        leading: project.isOther
            ? null
            : ProjectIcon(
                name: project.name,
                icon: widget.iconFor(project),
                size: 16,
              ),
        onToggle: () => layout.toggleCollapsed(project),
        onMenu: (position) => widget.onProjectMenu(project, position),
        trailing: project.isOther
            ? null
            : IconButton(
                key: ValueKey('project-menu-${project.key}'),
                tooltip: 'Quick actions and more',
                iconSize: 16,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: 26,
                  height: 26,
                ),
                color: AppPalette.of(context).mutedForeground,
                onPressed: () => widget.onProjectMenu(project, null),
                icon: const Icon(Icons.more_horiz_rounded),
              ),
      ),
      if (!collapsed)
        for (final entry in entries)
          if (layout.compact || entry.agentRows.isEmpty)
            _MemberRow(
              key: ValueKey('project-member-${project.key}-${entry.node.key}'),
              node: entry.node,
              dot: entry.dot,
              sheprd: entry.sheprdOf(entry.node),
              machineName: names[entry.node.machineId] ?? '',
              selected: entry.node.key == widget.selectedKey,
              faded: !entry.active || entry.hidden,
              onOpen: () => _open(layout, entry, entry.node),
              onContextMenu: (position) => _entryMenu(entry, project, position),
            )
          else
            for (final agent in entry.agentRows)
              if (!layout.activeOnly ||
                  entry.active &&
                      (entry.dotOf(agent) != SidebarDot.idle ||
                          (entry.sheprdOf(agent)?.kept ?? false) ||
                          entry.node.openInApp))
                _MemberRow(
                  key: ValueKey('project-agent-${project.key}-${agent.key}'),
                  node: agent,
                  dot: entry.dotOf(agent),
                  sheprd: entry.sheprdOf(agent),
                  machineName: [
                    if (entry.node.label.toLowerCase() !=
                        project.name.toLowerCase())
                      entry.node.label,
                    names[entry.node.machineId] ?? '',
                  ].where((part) => part.isNotEmpty).join(' · '),
                  selected: agent.key == widget.selectedKey,
                  faded:
                      !entry.active ||
                      entry.hidden ||
                      (entry.sheprdOf(agent)?.dismissed ?? false),
                  onOpen: () => _open(layout, entry, agent),
                  onContextMenu: (position) =>
                      _entryMenu(entry, project, position, agent),
                ),
    ];
  }
}

class _ProjectRow extends StatelessWidget {
  const _ProjectRow({
    required this.project,
    required this.icon,
    required this.expanded,
    required this.machines,
    required this.onToggle,
    required this.onMenu,
    super.key,
  });

  final ProjectGroup project;
  final Uint8List? icon;
  final bool expanded;
  final int machines;
  final VoidCallback onToggle;
  final ValueChanged<Offset?> onMenu;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return GestureDetector(
      onSecondaryTapUp: (details) => onMenu(details.globalPosition),
      onLongPressStart: (details) => onMenu(details.globalPosition),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 5, 2, 5),
          child: Row(
            children: [
              Icon(
                expanded
                    ? Icons.expand_more_rounded
                    : Icons.chevron_right_rounded,
                size: 16,
                color: palette.mutedForeground,
              ),
              const SizedBox(width: 4),
              ProjectIcon(name: project.name, icon: icon),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      project.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.foreground,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      [
                        '${project.members.length} '
                            '${project.members.length == 1 ? 'workspace' : 'workspaces'}',
                        if (machines > 1) 'on $machines machines',
                      ].join(' '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.mutedForeground,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              ProjectCounts(project: project),
              IconButton(
                key: ValueKey('project-menu-${project.key}'),
                tooltip: 'Quick actions and more',
                iconSize: 16,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: 26,
                  height: 26,
                ),
                color: palette.mutedForeground,
                onPressed: () => onMenu(null),
                icon: const Icon(Icons.more_horiz_rounded),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MemberRow extends StatelessWidget {
  const _MemberRow({
    required this.node,
    required this.machineName,
    required this.selected,
    required this.onOpen,
    required this.onContextMenu,
    this.faded = false,
    this.dot,
    this.sheprd,
    super.key,
  });

  final SidebarNode node;

  /// The dot to show: sheprd's presence when synced; null uses [node]'s.
  final SidebarDot? dot;

  /// sheprd's view of the agent, while synced: a pin when kept.
  final SheprdAgentView? sheprd;
  final String machineName;
  final bool selected;

  /// Idle for long, or hidden: dimmed, like sheprd's "all agents" view.
  final bool faded;
  final VoidCallback onOpen;
  final ValueChanged<Offset> onContextMenu;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final kind = node.multiplexer;
    final tile = GestureDetector(
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
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(32, 3, 8, 3),
            child: Row(
              children: [
                SizedBox(
                  width: 18,
                  child: Center(
                    child: kind == null
                        ? Icon(
                            Icons.terminal_rounded,
                            size: 14,
                            color: palette.mutedForeground,
                          )
                        : MultiplexerIcon(kind, size: 14, semanticLabel: ''),
                  ),
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: node.label,
                          style: TextStyle(
                            color: palette.foreground,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        TextSpan(
                          text: '  $machineName',
                          style: TextStyle(
                            color: palette.mutedForeground,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (node.openInApp)
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Icon(
                      Icons.tab_rounded,
                      size: 12,
                      color: palette.accent,
                    ),
                  ),
                if (sheprd?.pending != null)
                  const Padding(
                    padding: EdgeInsets.only(left: 6),
                    child: SheprdPendingMark(),
                  ),
                if (sheprd?.kept ?? false)
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Tooltip(
                      message: 'Kept in active (sheprd)',
                      child: Icon(
                        Icons.push_pin_rounded,
                        size: 11,
                        color: palette.mutedForeground,
                      ),
                    ),
                  ),
                if ((dot ?? node.dot) != SidebarDot.none) ...[
                  const SizedBox(width: 7),
                  ShellStateDot(dot: dot ?? node.dot),
                ],
              ],
            ),
          ),
        ),
      ),
    );
    return Draggable<SidebarDrag>(
      data: SidebarDrag(node),
      affinity: PlatformFeatures.isDesktop ? null : Axis.horizontal,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: palette.panelElevated,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: palette.accent),
          ),
          child: Text(
            node.label,
            style: TextStyle(
              color: palette.foreground,
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
      child: faded ? Opacity(opacity: 0.5, child: tile) : tile,
    );
  }
}
