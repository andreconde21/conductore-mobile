import 'dart:async';

import 'package:conduit/core/presentation/multiplexer_icon.dart';
import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/core/theme/app_theme.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/desktop_shell/domain/project_tree.dart';
import 'package:conduit/features/desktop_shell/domain/sheprd_view.dart';
import 'package:conduit/features/desktop_shell/domain/sidebar_prefs.dart';
import 'package:conduit/features/desktop_shell/domain/sidebar_tree.dart';
import 'package:conduit/features/desktop_shell/presentation/project_layout_controller.dart';
import 'package:conduit/features/desktop_shell/presentation/widgets/project_view.dart';
import 'package:conduit/features/desktop_shell/presentation/widgets/shell_state_dot.dart';
import 'package:conduit/features/hosts/domain/home_search.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/hosts/presentation/home_board_controller.dart';
import 'package:conduit/features/hosts/presentation/widgets/home_session_grid.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/sessions/presentation/session_grid_page.dart'
    show summarizeAgentState;
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:conduit/features/usage/presentation/usage_widgets.dart';
import 'package:flutter/material.dart';

/// The phone home's Projects mode (CON-065, CON-105): every workspace,
/// tmux session and open session of the shown machines in its project
/// (the same layout as the desktop sidebar and sheprd), then Other, one
/// box per project, under the project view's header (filter, needs-you
/// counter, view). A workspace open in the app is its one row, marked
/// open. A row opens on tap (an open one goes to its session); a long
/// press offers "Move to project…", "Move to Other" and "Hide". [search]
/// keeps the rows it matches, and the projects with any.
class HomeProjectsList extends StatelessWidget {
  const HomeProjectsList({
    required this.controller,
    required this.hosts,
    required this.sessions,
    required this.attention,
    required this.onOpen,
    this.boards,
    this.herdrWorkspaceOf,
    this.search,
    super.key,
  });

  final ProjectLayoutController controller;

  /// The machines shown (the home's machine filter). On-device shells
  /// among [sessions] join as machines of their own.
  final List<SavedHost> hosts;
  final List<TerminalSessionController> sessions;
  final AgentAttentionController attention;
  final HomeBoards? boards;

  /// The Herdr workspace an open session shows.
  final String? Function(TerminalSessionController session)? herdrWorkspaceOf;
  final ValueChanged<SidebarTarget> onOpen;

  /// The home's workspace search; null shows every row.
  final HomeSearch? search;

  /// The shown machines by project with the current layout (also what
  /// Open / Closed mode's search reads project names from).
  List<ProjectGroup> projectGroups() => _groups(_tree());

  List<ProjectGroup> _groups(List<SidebarNode> tree) => controller.build(
    tree,
    agentsByMachine: {for (final host in hosts) host.id: _agentsOf(host)},
    hosts: hosts,
  );

  /// Every shown machine as the sidebar's tree.
  List<SidebarNode> _tree() => SidebarTreeBuilder.build([
    for (final host in [
      for (final host in hosts)
        if (!host.isLocal) host,
      ..._localHosts(),
    ])
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

  /// The on-device shells open now, once each.
  List<SavedHost> _localHosts() {
    final seen = <String>{};
    return [
      for (final session in sessions)
        if (session.host.isLocal && seen.add(baseHostId(session.host.id)))
          session.host.copyWith(id: baseHostId(session.host.id)),
    ];
  }

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
        final projects = _groups(tree);
        final search = this.search ?? HomeSearch.none;
        final tokens = usage == null
            ? const <String, int>{}
            : controller.tokensToday(projects, usage.summary);
        final names = {for (final node in tree) node.machineId: node.label};
        final shown = [
          for (final project in controller.visibleGroups(projects))
            if (_projectRows(
                  context,
                  project,
                  names,
                  tokens[project.key],
                  search,
                )
                case final rows?)
              (project, rows),
        ];
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Column(
            key: const ValueKey('home-projects'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Its ⋮ lines up with the boxes' ⋯ (box border and padding,
              // then the centre of a 32 dp button).
              Padding(
                padding: const EdgeInsets.only(right: 21.5),
                child: ProjectViewBar(
                  controller: controller,
                  needsYou: ProjectLayoutController.needsYouCount(projects),
                  onNeedsYou: () => _openFirstNeedingYou(projects),
                  hiddenCount: projects.fold(
                    0,
                    (sum, project) =>
                        sum + project.entries.where((e) => e.hidden).length,
                  ),
                ),
              ),
              if (shown.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    key: const ValueKey('home-projects-empty'),
                    !search.isEmpty
                        ? 'No workspace matches the search.'
                        : controller.activeOnly
                        ? 'Nothing active in the last '
                              '${controller.recentHours} h.'
                        : 'No workspaces listed yet.',
                    style: TextStyle(
                      color: AppPalette.of(context).mutedForeground,
                    ),
                  ),
                ),
              for (final (project, rows) in shown)
                _ProjectBox(
                  key: ValueKey('home-project-box-${project.key}'),
                  children: rows,
                ),
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

  /// [project]'s header and rows; null when [search] matches none of
  /// them. While searching, a collapsed project shows its matches too.
  List<Widget>? _projectRows(
    BuildContext context,
    ProjectGroup project,
    Map<String, String> names,
    int? tokens,
    HomeSearch search,
  ) {
    final entries = controller.visibleEntries(project);
    final collapsed = controller.isCollapsed(project);
    // The project's own name matches: all of it.
    final all = search.isEmpty || search.matches([project.name]);
    final rows = <Widget>[];
    for (final entry in entries) {
      final machine = names[entry.node.machineId] ?? '';
      if (controller.compact || entry.agentRows.isEmpty) {
        final text = _entryText(entry, project, names);
        if (!all &&
            !search.matches([
              text.title,
              text.subtitle,
              entry.node.label,
              machine,
              for (final agent in entry.agentRows) ...[
                agent.label,
                ..._agentFields(_agentText(entry, agent, project, names)),
              ],
            ])) {
          continue;
        }
        rows.add(
          _HomeProjectRow(
            key: ValueKey('home-project-row-${entry.node.key}'),
            node: entry.node,
            open: entry.node.openInApp,
            dot: entry.dot,
            sheprd: entry.sheprdOf(entry.node),
            title: text.title,
            detail: text.subtitle,
            faded: !entry.active || entry.hidden,
            onTap: () => _open(entry, entry.node),
            onLongPress: () => showProjectEntrySheet(
              context,
              controller,
              entry,
              project: project,
            ),
          ),
        );
        continue;
      }
      for (final agent in entry.agentRows) {
        if (controller.removedFromActive(entry, agent)) continue;
        final text = _agentText(entry, agent, project, names);
        if (!all &&
            !search.matches([
              ..._agentFields(text),
              agent.label,
              entry.node.label,
              machine,
            ])) {
          continue;
        }
        rows.add(
          _HomeProjectRow(
            key: ValueKey('home-project-agent-${agent.key}'),
            node: agent,
            open: entry.node.openInApp || agent.openInApp,
            dot: entry.dotOf(agent),
            sheprd: entry.sheprdOf(agent),
            title: text.title,
            detail: text.subtitle,
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
        );
      }
    }
    if (!search.isEmpty && rows.isEmpty) return null;
    final menuless =
        project.isOther ||
        (!controller.canEditLayout && controller.sheprdEditsPaused == null);
    return [
      ProjectHeaderTile(
        project: project,
        collapsed: collapsed,
        count: entries.length,
        tokensToday: tokens,
        pending: controller.groupPending(project),
        onToggle: () => controller.toggleCollapsed(project),
        onMenu: menuless
            ? null
            : (position) => _projectMenu(context, project, position),
        trailing: menuless
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
      if (!collapsed || !search.isEmpty) ...rows,
    ];
  }

  /// A row's text as search fields: the pane title, then the tab,
  /// workspace and machine of the subtitle one by one.
  static List<String> _agentFields(AgentRowText text) => [
    text.title,
    ...text.subtitle.split(' · '),
  ];

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
    this.open = false,
    this.title,
    this.dot,
    this.sheprd,
    super.key,
  });

  final SidebarNode node;

  /// Its workspace or session is open in the app: marked "open".
  final bool open;

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
        padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
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
            if (open)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: _OpenMark(
                  key: ValueKey('home-project-open-${node.key}'),
                  palette: palette,
                ),
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

/// A project's box in Projects mode: its header and rows on the session
/// tiles' panel, radius and hairline.
class _ProjectBox extends StatelessWidget {
  const _ProjectBox({required this.children, super.key});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final brightness = Theme.of(context).brightness;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: palette.panelFor(brightness),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radius),
          side: BorderSide(color: palette.hairlineFor(brightness)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ),
    );
  }
}

/// "open": the row's workspace or session is open in the app; a tap goes
/// to it.
class _OpenMark extends StatelessWidget {
  const _OpenMark({required this.palette, super.key});

  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(5, 1, 7, 1),
      decoration: BoxDecoration(
        color: palette.accent.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(AppTheme.radius),
        border: Border.all(color: palette.accent.withValues(alpha: 0.6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.tab_rounded, size: 12, color: palette.accent),
          const SizedBox(width: 3),
          Text(
            'open',
            style: TextStyle(
              color: palette.accent,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              height: 1.2,
            ),
          ),
        ],
      ),
    );
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
