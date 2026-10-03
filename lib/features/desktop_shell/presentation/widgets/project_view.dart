import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/features/desktop_shell/domain/project_tree.dart';
import 'package:conduit/features/desktop_shell/domain/sidebar_tree.dart';
import 'package:conduit/features/desktop_shell/presentation/project_layout_controller.dart';
import 'package:conduit/features/desktop_shell/presentation/widgets/shell_state_dot.dart';
import 'package:flutter/material.dart';

/// The project view's header, sheprd's: the filter (all agents / active)
/// on the left, the needs-you counter, the view (detailed / compact) on
/// the right, and a menu with the rest (recent hours, hidden workspaces,
/// new project, back to sidebar.toml). Shared by the desktop sidebar, the
/// phone home and the agents dashboard.
class ProjectViewBar extends StatelessWidget {
  const ProjectViewBar({
    required this.controller,
    required this.needsYou,
    this.onNeedsYou,
    this.hiddenCount = 0,
    this.dense = false,
    super.key,
  });

  final ProjectLayoutController controller;
  final int needsYou;

  /// The counter's tap: jump to the first agent that needs you.
  final VoidCallback? onNeedsYou;

  /// Hidden workspaces, for the menu's "Show hidden".
  final int hiddenCount;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final style = TextStyle(
      fontSize: dense ? 12 : 13,
      fontWeight: FontWeight.w700,
      color: palette.mutedForeground,
    );
    Widget label(String text, String tooltip, VoidCallback onTap, Key key) =>
        Tooltip(
          message: tooltip,
          child: InkWell(
            key: key,
            borderRadius: BorderRadius.circular(6),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Text(text, style: style),
            ),
          ),
        );
    final active = controller.activeOnly;
    return Padding(
      padding: EdgeInsets.fromLTRB(dense ? 6 : 0, 0, 0, dense ? 2 : 4),
      child: Row(
        children: [
          Icon(
            active ? Icons.radio_button_checked : Icons.radio_button_off,
            size: 13,
            color: active ? palette.accent : palette.mutedForeground,
          ),
          label(
            active ? 'active' : 'all agents',
            active
                ? 'Showing what is working, needs you, or changed in the '
                      'last ${controller.recentHours} h. Tap for all.'
                : 'Showing everything. Tap for active only.',
            () => controller.setActiveOnly(!active),
            const ValueKey('project-filter-toggle'),
          ),
          if (needsYou > 0)
            Tooltip(
              message: '$needsYou need you',
              child: InkWell(
                key: const ValueKey('project-needs-you'),
                borderRadius: BorderRadius.circular(6),
                onTap: onNeedsYou,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 4,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const ShellStateDot(dot: SidebarDot.needsYou),
                      const SizedBox(width: 4),
                      Text(
                        '$needsYou',
                        style: style.copyWith(color: palette.foreground),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          const Spacer(),
          label(
            controller.compact ? 'compact' : 'detailed',
            controller.compact
                ? 'One line per workspace. Tap for one row per agent.'
                : 'One row per agent. Tap for one line per workspace.',
            () => controller.setCompact(!controller.compact),
            const ValueKey('project-view-toggle'),
          ),
          _ViewMenu(controller: controller, hiddenCount: hiddenCount),
        ],
      ),
    );
  }
}

enum _ViewChoice { hours, hidden, add, follow }

class _ViewMenu extends StatelessWidget {
  const _ViewMenu({required this.controller, required this.hiddenCount});

  final ProjectLayoutController controller;
  final int hiddenCount;

  @override
  Widget build(BuildContext context) {
    final errors = controller.machineErrors.values.toList();
    return PopupMenuButton<_ViewChoice>(
      key: const ValueKey('project-view-menu'),
      tooltip: 'Project view',
      iconSize: 17,
      padding: EdgeInsets.zero,
      icon: const Icon(Icons.more_vert_rounded),
      onSelected: (choice) async {
        switch (choice) {
          case _ViewChoice.hours:
            final hours = await _askRecentHours(
              context,
              controller.recentHours,
            );
            if (hours != null) await controller.setRecentHours(hours);
          case _ViewChoice.hidden:
            await controller.setShowHidden(!controller.showHidden);
          case _ViewChoice.add:
            if (!context.mounted) return;
            final name = await askProjectName(context, title: 'New project');
            if (name != null && name.isNotEmpty) {
              await controller.addProject(name, rules: [name]);
            }
          case _ViewChoice.follow:
            await controller.followMachineLayout();
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: _ViewChoice.hours,
          child: Text('Active means the last ${controller.recentHours} h…'),
        ),
        if (hiddenCount > 0 || controller.showHidden)
          CheckedPopupMenuItem(
            value: _ViewChoice.hidden,
            checked: controller.showHidden,
            child: Text('Show hidden ($hiddenCount)'),
          ),
        const PopupMenuItem(
          value: _ViewChoice.add,
          child: Text('New project…'),
        ),
        if (!controller.followsMachines && controller.hasMachineLayout)
          const PopupMenuItem(
            value: _ViewChoice.follow,
            child: Text("Use the machines' sidebar.toml again"),
          ),
        if (controller.followsMachines && controller.hasMachineLayout)
          const PopupMenuItem(
            enabled: false,
            child: Text("Following sheprd's sidebar.toml"),
          ),
        for (final error in errors)
          PopupMenuItem(enabled: false, child: Text(error)),
      ],
    );
  }
}

/// A project's header row: chevron, pin star, name, and when collapsed the
/// worst status and how many rows it holds; today's tokens when known.
class ProjectHeaderTile extends StatelessWidget {
  const ProjectHeaderTile({
    required this.project,
    required this.collapsed,
    required this.count,
    required this.onToggle,
    this.onMenu,
    this.leading,
    this.tokensToday,
    this.trailing,
    super.key,
  });

  final ProjectGroup project;
  final bool collapsed;

  /// Rows shown under it (with the filter applied).
  final int count;
  final VoidCallback onToggle;
  final ValueChanged<Offset?>? onMenu;
  final Widget? leading;
  final int? tokensToday;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final muted = TextStyle(color: palette.mutedForeground, fontSize: 11.5);
    return GestureDetector(
      onSecondaryTapUp: onMenu == null
          ? null
          : (details) => onMenu!(details.globalPosition),
      onLongPressStart: onMenu == null
          ? null
          : (details) => onMenu!(details.globalPosition),
      child: InkWell(
        key: ValueKey('project-header-${project.key}'),
        borderRadius: BorderRadius.circular(6),
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 6, 2, 6),
          child: Row(
            children: [
              Icon(
                collapsed
                    ? Icons.chevron_right_rounded
                    : Icons.expand_more_rounded,
                size: 16,
                color: palette.mutedForeground,
              ),
              const SizedBox(width: 2),
              if (project.pinned)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Icon(
                    Icons.star_rounded,
                    size: 13,
                    color: palette.accent,
                  ),
                ),
              if (leading != null) ...[leading!, const SizedBox(width: 6)],
              Expanded(
                child: Text(
                  project.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: project.isOther
                        ? palette.mutedForeground
                        : palette.foreground,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              if (tokensToday case final tokens? when tokens > 0)
                Tooltip(
                  message: "Today's tokens (input, output, cache writes)",
                  child: Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Text(formatProjectTokens(tokens), style: muted),
                  ),
                ),
              if (collapsed && count > 0) ...[
                const SizedBox(width: 6),
                if (project.dot != SidebarDot.none)
                  ShellStateDot(dot: project.dot),
                const SizedBox(width: 4),
                Text(
                  '$count',
                  key: ValueKey('project-count-${project.key}'),
                  style: muted.copyWith(fontWeight: FontWeight.w700),
                ),
              ],
              ?trailing,
            ],
          ),
        ),
      ),
    );
  }
}

/// What a row of the project view can do with its project.
enum ProjectEntryAction { moveTo, moveToOther, hide }

/// The project items of a row's menu.
List<PopupMenuEntry<T>> projectEntryMenuItems<T>(
  ProjectEntry entry, {
  required ProjectGroup project,
  required T Function(ProjectEntryAction action) value,
}) => [
  PopupMenuItem<T>(
    value: value(ProjectEntryAction.moveTo),
    child: const _MenuLine(Icons.drive_file_move_outline, 'Move to project…'),
  ),
  if (!project.isOther)
    PopupMenuItem<T>(
      value: value(ProjectEntryAction.moveToOther),
      child: const _MenuLine(Icons.move_down_rounded, 'Move to Other'),
    ),
  PopupMenuItem<T>(
    value: value(ProjectEntryAction.hide),
    child: _MenuLine(
      entry.hidden ? Icons.visibility_outlined : Icons.visibility_off_outlined,
      entry.hidden ? 'Show again' : 'Hide',
    ),
  ),
];

/// Runs a row's project [action].
Future<void> runProjectEntryAction(
  BuildContext context,
  ProjectLayoutController controller,
  ProjectEntry entry,
  ProjectEntryAction action, {
  required ProjectGroup project,
}) async {
  switch (action) {
    case ProjectEntryAction.moveTo:
      final name = await showMoveToProjectDialog(
        context,
        names: controller.projectNames,
        current: project.isOther ? null : project.name,
        label: entry.node.label,
      );
      if (name != null) await controller.moveTo(entry, name);
    case ProjectEntryAction.moveToOther:
      await controller.moveTo(entry, '');
    case ProjectEntryAction.hide:
      await controller.toggleHidden(entry);
  }
}

/// The phone's long-press on a row: the project actions in a sheet, then
/// [more] (the row's own actions) when given.
Future<void> showProjectEntrySheet(
  BuildContext context,
  ProjectLayoutController controller,
  ProjectEntry entry, {
  required ProjectGroup project,
  VoidCallback? more,
}) async {
  final picked = await showModalBottomSheet<ProjectEntryAction>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            title: Text(
              entry.node.label,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            subtitle: Text(project.name),
          ),
          ListTile(
            key: const ValueKey('project-entry-move'),
            leading: const Icon(Icons.drive_file_move_outline),
            title: const Text('Move to project…'),
            onTap: () => Navigator.pop(context, ProjectEntryAction.moveTo),
          ),
          if (!project.isOther)
            ListTile(
              key: const ValueKey('project-entry-other'),
              leading: const Icon(Icons.move_down_rounded),
              title: const Text('Move to Other'),
              onTap: () =>
                  Navigator.pop(context, ProjectEntryAction.moveToOther),
            ),
          ListTile(
            leading: Icon(
              entry.hidden
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined,
            ),
            title: Text(entry.hidden ? 'Show again' : 'Hide'),
            onTap: () => Navigator.pop(context, ProjectEntryAction.hide),
          ),
          if (more != null)
            ListTile(
              leading: const Icon(Icons.more_horiz_rounded),
              title: const Text('More actions'),
              onTap: () {
                Navigator.pop(context);
                more();
              },
            ),
        ],
      ),
    ),
  );
  if (picked == null || !context.mounted) return;
  await runProjectEntryAction(
    context,
    controller,
    entry,
    picked,
    project: project,
  );
}

/// What a project's header menu can do.
enum ProjectGroupAction { pin, rules, remove }

List<PopupMenuEntry<T>> projectGroupMenuItems<T>(
  ProjectGroup project, {
  required T Function(ProjectGroupAction action) value,
}) => project.isOther
    ? const []
    : [
        PopupMenuItem<T>(
          value: value(ProjectGroupAction.pin),
          child: _MenuLine(
            project.pinned ? Icons.star_rounded : Icons.star_outline_rounded,
            project.pinned ? 'Unpin' : 'Pin to top',
          ),
        ),
        PopupMenuItem<T>(
          value: value(ProjectGroupAction.rules),
          child: const _MenuLine(Icons.rule_rounded, 'Auto-match rules…'),
        ),
        if (project.inLayout)
          PopupMenuItem<T>(
            value: value(ProjectGroupAction.remove),
            child: const _MenuLine(Icons.delete_outline_rounded, 'Delete'),
          ),
      ];

Future<void> runProjectGroupAction(
  BuildContext context,
  ProjectLayoutController controller,
  ProjectGroup project,
  ProjectGroupAction action,
) async {
  switch (action) {
    case ProjectGroupAction.pin:
      await controller.setPinned(project, !project.pinned);
    case ProjectGroupAction.rules:
      final current =
          controller.layout.byName(project.name)?.match ??
          [project.name.toLowerCase()];
      final rules = await askProjectName(
        context,
        title: 'Auto-match rules for ${project.name}',
        initial: current.join(', '),
        hint: 'storefront, shop-api',
        help:
            'A workspace whose name or folder contains one of these joins '
            'the project. Separate them with commas.',
      );
      if (rules == null) return;
      await controller.setRules(project, rules.split(','));
    case ProjectGroupAction.remove:
      await controller.removeProject(project);
  }
}

/// "Move to project…": the projects to pick from, or a new name. Returns
/// the name, '' for Other, null when cancelled.
Future<String?> showMoveToProjectDialog(
  BuildContext context, {
  required List<String> names,
  required String label,
  String? current,
}) => showDialog<String>(
  context: context,
  builder: (context) =>
      _MoveDialog(names: names, current: current, label: label),
);

class _MoveDialog extends StatefulWidget {
  const _MoveDialog({
    required this.names,
    required this.current,
    required this.label,
  });

  final List<String> names;
  final String? current;
  final String label;

  @override
  State<_MoveDialog> createState() => _MoveDialogState();
}

class _MoveDialogState extends State<_MoveDialog> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Move ${widget.label}'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final name in widget.names)
                    ListTile(
                      key: ValueKey('move-to-$name'),
                      dense: true,
                      leading: const Icon(Icons.folder_outlined),
                      title: Text(name),
                      selected: name == widget.current,
                      enabled: name != widget.current,
                      onTap: () => Navigator.pop(context, name),
                    ),
                  ListTile(
                    key: const ValueKey('move-to-other'),
                    dense: true,
                    leading: const Icon(Icons.move_down_rounded),
                    title: const Text('Other'),
                    enabled: widget.current != null,
                    onTap: () => Navigator.pop(context, ''),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('move-to-new'),
              controller: _text,
              autofocus: widget.names.isEmpty,
              decoration: const InputDecoration(
                labelText: 'New project',
                isDense: true,
              ),
              onSubmitted: (value) {
                if (value.trim().isNotEmpty) {
                  Navigator.pop(context, value.trim());
                }
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('move-to-create'),
          onPressed: () {
            final value = _text.text.trim();
            if (value.isNotEmpty) Navigator.pop(context, value);
          },
          child: const Text('Move'),
        ),
      ],
    );
  }
}

/// One line of text (a project name, rules), or null when cancelled.
Future<String?> askProjectName(
  BuildContext context, {
  required String title,
  String initial = '',
  String hint = 'storefront',
  String? help,
}) => showDialog<String>(
  context: context,
  builder: (context) =>
      _TextDialog(title: title, initial: initial, hint: hint, help: help),
);

Future<int?> _askRecentHours(BuildContext context, int current) async {
  final text = await askProjectName(
    context,
    title: 'Active view',
    initial: '$current',
    hint: '24',
    help:
        'Idle agents stay in the active view this many hours after their '
        'last change.',
  );
  final hours = int.tryParse(text?.trim() ?? '');
  return hours != null && hours > 0 ? hours : null;
}

class _TextDialog extends StatefulWidget {
  const _TextDialog({
    required this.title,
    required this.initial,
    required this.hint,
    this.help,
  });

  final String title;
  final String initial;
  final String hint;
  final String? help;

  @override
  State<_TextDialog> createState() => _TextDialogState();
}

class _TextDialogState extends State<_TextDialog> {
  late final _text = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.help != null) ...[
          Text(widget.help!),
          const SizedBox(height: 8),
        ],
        TextField(
          key: const ValueKey('project-text-field'),
          controller: _text,
          autofocus: true,
          decoration: InputDecoration(hintText: widget.hint),
          onSubmitted: (value) => Navigator.pop(context, value.trim()),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const ValueKey('project-text-ok'),
        onPressed: () => Navigator.pop(context, _text.text.trim()),
        child: const Text('OK'),
      ),
    ],
  );
}

class _MenuLine extends StatelessWidget {
  const _MenuLine(this.icon, this.label);

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [Icon(icon, size: 18), const SizedBox(width: 10), Text(label)],
  );
}
