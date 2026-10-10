import 'dart:async';

import 'package:conduit/core/presentation/multiplexer_icon.dart';
import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/desktop_shell/domain/project_tree.dart';
import 'package:conduit/features/desktop_shell/domain/sheprd_view.dart';
import 'package:conduit/features/desktop_shell/domain/sidebar_prefs.dart';
import 'package:conduit/features/desktop_shell/domain/sidebar_tree.dart';
import 'package:conduit/features/desktop_shell/presentation/project_layout_controller.dart';
import 'package:conduit/features/desktop_shell/presentation/widgets/project_view.dart';
import 'package:conduit/features/desktop_shell/presentation/widgets/shell_state_dot.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/hosts/presentation/home_board_controller.dart';
import 'package:conduit/features/hosts/presentation/widgets/home_session_grid.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/sessions/presentation/session_grid_page.dart'
    show summarizeAgentState;
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:conduit/features/usage/presentation/usage_widgets.dart';
import 'package:flutter/material.dart';

/// The phone home grouped by project (CON-065): every workspace, tmux
/// session and open session of the shown machines in its project (the
/// same layout as the desktop sidebar and sheprd), then Other, under the
/// project view's header (filter, needs-you counter, view). A row opens on
/// tap; a long press offers "Move to project…", "Move to Other" and
/// "Hide".
class HomeProjectsList extends StatelessWidget {
  const HomeProjectsList({
    required this.controller,
    required this.hosts,
    required this.sessions,
    required this.attention,
    required this.onOpen,
    this.boards,
    this.herdrWorkspaceOf,
    super.key,
  });

  final ProjectLayoutController controller;

  /// The machines shown (the home's machine filter).
  final List<SavedHost> hosts;
  final List<TerminalSessionController> sessions;
  final AgentAttentionController attention;
  final HomeBoards? boards;

  /// The Herdr workspace an open session shows.
  final String? Function(TerminalSessionController session)? herdrWorkspaceOf;
  final ValueChanged<SidebarTarget> onOpen;

  /// Every shown machine as the sidebar's tree.
  List<SidebarNode> _tree() => SidebarTreeBuilder.build([
    for (final host in hosts)
      if (!host.isLocal)
        SidebarMachineInput(
          host: host,
          board: boards?[host.id]?.state,
          openSessions: [
            for (final session in sessions)
              if (baseHostId(session.host.id) == host.id)
                SidebarOpenSession(
                  sessionHostId: session.host.id,
                  title: session.title,
                  herdrWorkspaceId:
                      ConnectTarget.fromSessionHostId(session.host.id)?.kind ==
                          ConnectTargetKind.herdr
                      ? (herdrWorkspaceOf?.call(session) ??
                            ConnectTarget.fromSessionHostId(
                              session.host.id,
                            )!.name)
                      : null,
                  tmuxSession: HomeSessionInfo.tmuxSessionOf(session),
                  agentState: summarizeAgentState(
                    attention.statusFor(session.host.id),
                    session.host.id,
                  ),
                ),
          ],
          agents: _agentsOf(host),
        ),
  ], const SidebarPrefs());

  List<AgentInfo> _agentsOf(SavedHost host) {
    final agents = <String, AgentInfo>{};
    for (final monitored in attention.monitoredHosts) {
      if (baseHostId(monitored.id) != host.id) continue;
      for (final agent
          in attention.statusFor(monitored.id)?.agents ?? const <AgentInfo>[]) {
        agents[agent.id] = agent;
      }
    }
    return agents.values.toList();
  }

  @override
  Widget build(BuildContext context) {
    unawaited(controller.refresh());
    final usage = UsageScope.maybeOf(context);
    return ListenableBuilder(
      listenable: Listenable.merge([controller, ?usage]),
      builder: (context, _) {
        final tree = _tree();
        final projects = controller.build(
          tree,
          agentsByMachine: {for (final host in hosts) host.id: _agentsOf(host)},
          hosts: hosts,
        );
        final tokens = usage == null
            ? const <String, int>{}
            : controller.tokensToday(projects, usage.summary);
        final names = {for (final node in tree) node.machineId: node.label};
        final shown = controller.visibleGroups(projects);
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Column(
            key: const ValueKey('home-projects'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ProjectViewBar(
                controller: controller,
                needsYou: ProjectLayoutController.needsYouCount(projects),
                onNeedsYou: () => _openFirstNeedingYou(projects),
                hiddenCount: projects.fold(
                  0,
                  (sum, project) =>
                      sum + project.entries.where((e) => e.hidden).length,
                ),
              ),
              if (shown.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    controller.activeOnly
                        ? 'Nothing active in the last '
                              '${controller.recentHours} h.'
                        : 'No workspaces listed yet.',
                    style: TextStyle(
                      color: AppPalette.of(context).mutedForeground,
                    ),
                  ),
                ),
              for (final project in shown)
                ..._projectRows(context, project, names, tokens[project.key]),
            ],
          ),
        );
      },
    );
  }

  void _openFirstNeedingYou(List<ProjectGroup> projects) {
    for (final project in projects) {
      for (final entry in project.entries) {
        if (entry.hidden) continue;
        for (final node in [...entry.agentRows, entry.node]) {
          if (node.dot == SidebarDot.needsYou) {
            onOpen(node.target);
            return;
          }
        }
      }
    }
  }

  List<Widget> _projectRows(
    BuildContext context,
    ProjectGroup project,
    Map<String, String> names,
    int? tokens,
  ) {
    final entries = controller.visibleEntries(project);
    final collapsed = controller.isCollapsed(project);
    return [
      ProjectHeaderTile(
        project: project,
        collapsed: collapsed,
        count: entries.length,
        tokensToday: tokens,
        pending: controller.groupPending(project),
        onToggle: () => controller.toggleCollapsed(project),
        onMenu:
            project.isOther ||
                (!controller.canEditLayout &&
                    controller.sheprdEditsPaused == null)
            ? null
            : (position) => _projectMenu(context, project, position),
        trailing:
            project.isOther ||
                (!controller.canEditLayout &&
                    controller.sheprdEditsPaused == null)
            ? null
            : IconButton(
                key: ValueKey('home-project-menu-${project.key}'),
                tooltip: 'Quick actions and more',
                iconSize: 18,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: 32,
                  height: 32,
                ),
                color: AppPalette.of(context).mutedForeground,
                onPressed: () => _projectMenu(context, project, null),
                icon: const Icon(Icons.more_horiz_rounded),
              ),
      ),
      if (!collapsed)
        for (final entry in entries)
          if (controller.compact || entry.agentRows.isEmpty)
            _HomeProjectRow(
              key: ValueKey('home-project-row-${entry.node.key}'),
              node: entry.node,
              dot: entry.dot,
              sheprd: entry.sheprdOf(entry.node),
              title: _entryText(entry, project, names).title,
              detail: _entryText(entry, project, names).subtitle,
              faded: !entry.active || entry.hidden,
              onTap: () => _open(entry, entry.node),
              onLongPress: () => showProjectEntrySheet(
                context,
                controller,
                entry,
                project: project,
              ),
            )
          else
            for (final agent in entry.agentRows)
              if (!controller.removedFromActive(entry, agent))
                _HomeProjectRow(
                  key: ValueKey('home-project-agent-${agent.key}'),
                  node: agent,
                  dot: entry.dotOf(agent),
                  sheprd: entry.sheprdOf(agent),
                  title: _agentText(entry, agent, project, names).title,
                  detail: _agentText(entry, agent, project, names).subtitle,
                  faded:
                      !entry.active ||
                      entry.hidden ||
                      (entry.sheprdOf(agent)?.dismissed ?? false),
                  onTap: () => _open(entry, agent),
                  onLongPress: () => showProjectEntrySheet(
                    context,
                    controller,
                    entry,
                    project: project,
                    row: agent,
                  ),
                ),
    ];
  }

  static AgentRowText _entryText(
    ProjectEntry entry,
    ProjectGroup project,
    Map<String, String> names,
  ) => AgentRowText.ofEntry(
    entry,
    projectName: project.name,
    machine: names[entry.node.machineId] ?? '',
  );

  static AgentRowText _agentText(
    ProjectEntry entry,
    SidebarNode agent,
    ProjectGroup project,
    Map<String, String> names,
  ) => AgentRowText.of(
    agent,
    workspace: entry.node.label,
    projectName: project.name,
    machine: names[entry.node.machineId] ?? '',
  );

  /// Opens [row]; with sheprd synced, an unread agent is read from then on
  /// (sheprd does the same when an agent gets focus).
  void _open(ProjectEntry entry, SidebarNode row) {
    onOpen(row.target);
    if (controller.mirroring &&
        entry.sheprdOf(row)?.presence == SheprdPresence.unread) {
      unawaited(controller.mark(entry, row, SheprdMark.read));
    }
  }

  Future<void> _projectMenu(
    BuildContext context,
    ProjectGroup project,
    Offset? position,
  ) async {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final at = position ?? overlay.size.center(Offset.zero);
    final picked = await showMenu<ProjectGroupAction>(
      context: context,
      position: RelativeRect.fromRect(
        at & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: projectGroupMenuItems(
        project,
        value: (action) => action,
        editable: controller.canEditLayout,
        controller: controller,
      ),
    );
    if (picked == null || !context.mounted) return;
    await runProjectGroupAction(context, controller, project, picked);
  }
}

class _HomeProjectRow extends StatelessWidget {
  const _HomeProjectRow({
    required this.node,
    required this.detail,
    required this.faded,
    required this.onTap,
    required this.onLongPress,
    this.title,
    this.dot,
    this.sheprd,
    super.key,
  });

  final SidebarNode node;

  /// The prominent text; null uses [node]'s label.
  final String? title;

  /// The dot to show: sheprd's presence when synced; null uses [node]'s.
  final SidebarDot? dot;

  /// sheprd's view of the agent, while synced: a pin when kept.
  final SheprdAgentView? sheprd;
  final String detail;
  final bool faded;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final kind = node.multiplexer;
    final row = InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(26, 9, 8, 9),
        child: Row(
          children: [
            SizedBox(
              width: 20,
              child: Center(
                child: kind == null
                    ? Icon(
                        node.kind == SidebarNodeKind.agentPane ||
                                node.kind == SidebarNodeKind.herdrTab
                            ? Icons.smart_toy_outlined
                            : Icons.terminal_rounded,
                        size: 16,
                        color: palette.mutedForeground,
                      )
                    : MultiplexerIcon(kind, size: 16, semanticLabel: ''),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title ?? node.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: palette.foreground,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (detail.isNotEmpty)
                    Text(
                      detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.mutedForeground,
                        fontSize: 12.5,
                      ),
                    ),
                ],
              ),
            ),
            if (node.openInApp)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Icon(Icons.tab_rounded, size: 14, color: palette.accent),
              ),
            if (sheprd?.pending != null)
              const Padding(
                padding: EdgeInsets.only(left: 6),
                child: SheprdPendingMark(size: 11),
              ),
            if (sheprd?.kept ?? false)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Icon(
                  Icons.push_pin_rounded,
                  key: const ValueKey('home-project-kept'),
                  size: 13,
                  color: palette.mutedForeground,
                ),
              ),
            if ((dot ?? node.dot) != SidebarDot.none) ...[
              const SizedBox(width: 8),
              ShellStateDot(dot: dot ?? node.dot, size: 9),
            ],
          ],
        ),
      ),
    );
    return faded ? Opacity(opacity: 0.5, child: row) : row;
  }
}

/// A machine's home-board notice ("Can't reach omarchy", "Could not list
/// workspaces") as one line above the projects, with its action (Retry,
/// List, Start Herdr); a tap shows the whole notice with its details.
class HomeNoticeLine extends StatelessWidget {
  const HomeNoticeLine({
    required this.machine,
    required this.notice,
    required this.palette,
    this.onAction,
    super.key,
  });

  final String machine;
  final HomeBoardNotice notice;
  final AppPalette palette;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final muted = palette.mutedForeground;
    final title = notice.title.contains(machine)
        ? notice.title
        : '$machine: ${notice.title}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => showDialog<void>(
          context: context,
          builder: (dialogContext) => Dialog(
            child: HomeBoardNoticeTile(
              notice: notice,
              palette: palette,
              brightness: Theme.of(context).brightness,
              onAction: onAction == null
                  ? null
                  : () {
                      Navigator.pop(dialogContext);
                      onAction!();
                    },
            ),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Row(
            children: [
              Icon(notice.icon, size: 16, color: muted),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: muted, fontSize: 13),
                ),
              ),
              if (notice.actionLabel case final label? when onAction != null)
                TextButton(
                  onPressed: notice.busy ? null : onAction,
                  child: Text(label),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
