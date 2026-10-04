import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/features/desktop_shell/domain/project_tree.dart';
import 'package:conduit/features/desktop_shell/domain/sheprd_view.dart';
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
              child: Text(
                text,
                style: style,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        );
    final active = controller.activeOnly;
    final notice = controller.markNotice;
    final bar = Padding(
      padding: EdgeInsets.fromLTRB(dense ? 6 : 0, 0, 0, dense ? 2 : 4),
      child: Row(
        children: [
          Icon(
            active ? Icons.radio_button_checked : Icons.radio_button_off,
            size: 13,
            color: active ? palette.accent : palette.mutedForeground,
          ),
          Flexible(
            child: label(
              active ? 'active' : 'all agents',
              active
                  ? 'Showing what is working, needs you, or changed in the '
                        'last ${controller.recentHours} h. Tap for all.'
                  : 'Showing everything. Tap for active only.',
              () => controller.setActiveOnly(!active),
              const ValueKey('project-filter-toggle'),
            ),
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
          Flexible(
            child: label(
              controller.compact ? 'compact' : 'detailed',
              controller.compact
                  ? 'One line per workspace. Tap for one row per agent.'
                  : 'One row per agent. Tap for one line per workspace.',
              () => controller.setCompact(!controller.compact),
              const ValueKey('project-view-toggle'),
            ),
          ),
          _ViewMenu(controller: controller, hiddenCount: hiddenCount),
        ],
      ),
    );
    if (notice == null) return bar;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        bar,
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(
            key: const ValueKey('project-mark-notice'),
            children: [
              Icon(
                Icons.sync_problem_rounded,
                size: 14,
                color: palette.mutedForeground,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  notice,
                  style: TextStyle(
                    fontSize: 12,
                    color: palette.mutedForeground,
                  ),
                ),
              ),
              IconButton(
                key: const ValueKey('project-mark-notice-close'),
                tooltip: 'Dismiss',
                iconSize: 14,
                visualDensity: VisualDensity.compact,
                onPressed: controller.clearMarkNotice,
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A mark sent to sheprd and not confirmed yet: a small spinner.
class SheprdPendingMark extends StatelessWidget {
  const SheprdPendingMark({this.size = 10, super.key});

  final double size;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'Waiting for sheprd to apply this',
    child: SizedBox(
      key: const ValueKey('sheprd-mark-pending'),
      width: size,
      height: size,
      child: CircularProgressIndicator(
        strokeWidth: 1.5,
        color: AppPalette.of(context).mutedForeground,
      ),
    ),
  );
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
      padding: EdgeInsets.zero,
      child: const Padding(
        padding: EdgeInsets.all(4),
        child: Icon(Icons.more_vert_rounded, size: 17),
      ),
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
        if (controller.canEditLayout)
          const PopupMenuItem(
            value: _ViewChoice.add,
            child: Text('New project…'),
          ),
        if (controller.sheprdSync)
          PopupMenuItem(
            key: const ValueKey('project-view-sheprd-status'),
            enabled: false,
            child: Text(sheprdSyncStatus(controller)),
          ),
        if (controller.canEditLayout &&
            !controller.followsMachines &&
            controller.hasMachineLayout)
          const PopupMenuItem(
            value: _ViewChoice.follow,
            child: Text("Use the machines' sidebar.toml again"),
          ),
        if (controller.canEditLayout &&
            controller.followsMachines &&
            controller.hasMachineLayout)
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

/// The view menu's line while "Sync with sheprd" is on.
String sheprdSyncStatus(ProjectLayoutController controller) {
  final view = controller.sheprdView;
  if (view == null) {
    return controller.hasMachineLayout
        ? 'Synced with sheprd: its sidebar.toml (no view state yet)'
        : 'Synced with sheprd: waiting for its view';
  }
  return view.stale
      ? 'Synced with sheprd: not running, view may be old'
      : 'Synced with sheprd';
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

/// What a row of the project view can do: its project (the app's own
/// layout), or, while synced with sheprd, its agents' marks.
enum ProjectEntryAction {
  moveTo,
  moveToOther,
  hide,
  markRead,
  markUnread,
  keep,
  unkeep,
  dismiss;

  /// The sheprd mark this action sends, if it is one.
  SheprdMark? get mark => switch (this) {
    ProjectEntryAction.markRead => SheprdMark.read,
    ProjectEntryAction.markUnread => SheprdMark.unread,
    ProjectEntryAction.keep => SheprdMark.keep,
    ProjectEntryAction.unkeep => SheprdMark.unkeep,
    ProjectEntryAction.dismiss => SheprdMark.dismiss,
    _ => null,
  };

  static ProjectEntryAction of(SheprdMark mark) => switch (mark) {
    SheprdMark.read => ProjectEntryAction.markRead,
    SheprdMark.unread => ProjectEntryAction.markUnread,
    SheprdMark.keep => ProjectEntryAction.keep,
    SheprdMark.unkeep => ProjectEntryAction.unkeep,
    SheprdMark.dismiss => ProjectEntryAction.dismiss,
  };

  IconData get icon => switch (this) {
    ProjectEntryAction.moveTo => Icons.drive_file_move_outline,
    ProjectEntryAction.moveToOther => Icons.move_down_rounded,
    ProjectEntryAction.hide => Icons.visibility_off_outlined,
    ProjectEntryAction.markRead => Icons.mark_email_read_outlined,
    ProjectEntryAction.markUnread => Icons.markunread_outlined,
    ProjectEntryAction.keep => Icons.push_pin_outlined,
    ProjectEntryAction.unkeep => Icons.push_pin_rounded,
    ProjectEntryAction.dismiss => Icons.do_not_disturb_on_outlined,
  };
}

/// The agent rows of [entry] a mark on [row] goes to: [row] when sheprd
/// knows it as an agent, else (a compact workspace row) each of its agents.
List<SidebarNode> sheprdTargets(ProjectEntry entry, SidebarNode row) {
  if (entry.sheprdKeys.containsKey(row.key)) return [row];
  return [
    for (final agent in entry.agentRows)
      if (entry.sheprdKeys.containsKey(agent.key)) agent,
  ];
}

/// What [row] of [entry] offers: sheprd's marks while synced (nothing for
/// a row without a Herdr agent), else the project moves and Hide.
List<ProjectEntryAction> projectEntryActions(
  ProjectLayoutController? controller,
  ProjectEntry entry, {
  required ProjectGroup project,
  SidebarNode? row,
}) {
  if (controller != null && controller.sheprdSync) {
    final targets = sheprdTargets(entry, row ?? entry.node);
    if (targets.isEmpty) return const [];
    return [
      for (final mark in SheprdMark.choicesFor(entry.sheprdOf(targets.first)))
        ProjectEntryAction.of(mark),
    ];
  }
  return [
    ProjectEntryAction.moveTo,
    if (!project.isOther) ProjectEntryAction.moveToOther,
    ProjectEntryAction.hide,
  ];
}

String projectEntryActionLabel(ProjectEntryAction action, ProjectEntry entry) =>
    switch (action) {
      ProjectEntryAction.moveTo => 'Move to project…',
      ProjectEntryAction.moveToOther => 'Move to Other',
      ProjectEntryAction.hide => entry.hidden ? 'Show again' : 'Hide',
      _ => action.mark!.label,
    };

/// The items of a row's menu: see [projectEntryActions].
List<PopupMenuEntry<T>> projectEntryMenuItems<T>(
  ProjectEntry entry, {
  required ProjectGroup project,
  required T Function(ProjectEntryAction action) value,
  ProjectLayoutController? controller,
  SidebarNode? row,
}) => [
  for (final action in projectEntryActions(
    controller,
    entry,
    project: project,
    row: row,
  ))
    PopupMenuItem<T>(
      value: value(action),
      child: _MenuLine(
        action == ProjectEntryAction.hide && entry.hidden
            ? Icons.visibility_outlined
            : action.icon,
        projectEntryActionLabel(action, entry),
      ),
    ),
];

/// Runs a row's [action]; a mark goes to sheprd for [row] (else the
/// row's agents), and a failure shows in a snack bar.
Future<void> runProjectEntryAction(
  BuildContext context,
  ProjectLayoutController controller,
  ProjectEntry entry,
  ProjectEntryAction action, {
  required ProjectGroup project,
  SidebarNode? row,
}) async {
  if (action.mark case final mark?) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    for (final target in sheprdTargets(entry, row ?? entry.node)) {
      final error = await controller.mark(entry, target, mark);
      if (error != null) {
        messenger?.showSnackBar(SnackBar(content: Text(error)));
        return;
      }
    }
    return;
  }
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
    default:
      break;
  }
}

/// The phone's long-press on a row ([row]: an agent row of [entry], else
/// the entry itself): its actions in a sheet, then [more] (the row's own
/// actions) when given.
Future<void> showProjectEntrySheet(
  BuildContext context,
  ProjectLayoutController controller,
  ProjectEntry entry, {
  required ProjectGroup project,
  SidebarNode? row,
  VoidCallback? more,
}) async {
  final actions = projectEntryActions(
    controller,
    entry,
    project: project,
    row: row,
  );
  final picked = await showModalBottomSheet<ProjectEntryAction>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            title: Text(
              (row ?? entry.node).label,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            subtitle: Text(project.name),
          ),
          for (final action in actions)
            ListTile(
              key: ValueKey(switch (action) {
                ProjectEntryAction.moveTo => 'project-entry-move',
                ProjectEntryAction.moveToOther => 'project-entry-other',
                _ => 'project-entry-${action.name}',
              }),
              leading: Icon(
                action == ProjectEntryAction.hide && entry.hidden
                    ? Icons.visibility_outlined
                    : action.icon,
              ),
              title: Text(projectEntryActionLabel(action, entry)),
              onTap: () => Navigator.pop(context, action),
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
    row: row,
  );
}

/// What a project's header menu can do.
enum ProjectGroupAction { pin, rules, remove }

/// None while synced with sheprd ([editable] false): its layout wins.
List<PopupMenuEntry<T>> projectGroupMenuItems<T>(
  ProjectGroup project, {
  required T Function(ProjectGroupAction action) value,
  bool editable = true,
}) => project.isOther || !editable
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
