import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/core/theme/app_theme.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/domain/agent_kinds.dart';
import 'package:conduit/features/agent_attention/presentation/widgets/agent_inbox_widgets.dart';
import 'package:conduit/features/desktop_shell/domain/sidebar_tree.dart';
import 'package:conduit/features/desktop_shell/presentation/widgets/shell_state_dot.dart';
import 'package:conduit/features/hosts/presentation/widgets/home_session_grid.dart';
import 'package:flutter/material.dart';

/// One "Needs you" card: a row of the sidebar that waits on the user, with
/// what the agent said and its approvals when the companion reports them.
@immutable
class DashboardNeedsYou {
  const DashboardNeedsYou({
    required this.node,
    required this.where,
    this.agent,
    this.hostId,
  });

  final SidebarNode node;

  /// "workstation › api".
  final String where;

  /// The companion's agent behind the row, for its message and approvals.
  final AgentInfo? agent;

  /// The monitored session host the agent belongs to (for decisions).
  final String? hostId;
}

/// Other workspaces of one machine: tiles, and why some cannot be listed.
@immutable
class DashboardWorkspaceGroup {
  const DashboardWorkspaceGroup({
    required this.machineName,
    required this.tiles,
    this.notice,
  });

  final String machineName;
  final List<Widget> tiles;
  final Widget? notice;
}

/// The desktop home when no view is open (or Home is picked): real columns
/// next to the sidebar instead of the phone's stretched list.
///
/// * "Needs you": agents waiting on the user, with their approvals;
/// * the usage slot (filled by the usage feature when it lands);
/// * recent sessions as live previews at fixed sizes;
/// * other workspaces (tmux sessions and Herdr workspaces not open), per
///   machine.
class ShellDashboard extends StatelessWidget {
  const ShellDashboard({
    required this.needsYou,
    required this.sessions,
    required this.otherGroups,
    required this.onOpenNeedsYou,
    required this.onNewSession,
    this.onChat,
    this.onDecide,
    this.isDeciding,
    this.usage,
    this.agents,
    this.actions = const [],
    this.notice,
    super.key,
  });

  /// A one-row notice above the columns (the privacy notice).
  final Widget? notice;

  final List<DashboardNeedsYou> needsYou;

  /// Live previews of the open sessions, most recently active first.
  final List<Widget> sessions;
  final List<DashboardWorkspaceGroup> otherGroups;
  final ValueChanged<DashboardNeedsYou> onOpenNeedsYou;

  /// Opens the agent's Chat View; null hides the button.
  final ValueChanged<DashboardNeedsYou>? onChat;

  /// Answers an approval from the card.
  final void Function(
    DashboardNeedsYou item,
    PendingPermissionRequest request,
    PermissionVerdict verdict,
  )?
  onDecide;
  final bool Function(String requestId)? isDeciding;
  final VoidCallback onNewSession;

  /// The usage summary; null keeps the slot with a note.
  final Widget? usage;

  /// The agents dashboard (facts and summaries per agent), above the
  /// sessions; null leaves it out.
  final Widget? agents;

  /// Buttons on the dashboard's title row (panel toggles).
  final List<Widget> actions;

  /// Width of a live preview tile: two fit next to the side column in a
  /// 1280 px window.
  static const sessionTileWidth = 270.0;

  /// Height of a live preview tile: a 4:5 screen plus its two labels, as
  /// on the phone's grid.
  static const sessionTileHeight =
      sessionTileWidth * 1.25 + HomeGridMetrics.labelHeight;

  /// Width and height of an other-workspace tile.
  static const workspaceTileWidth = 250.0;
  static const workspaceTileHeight = 118.0;

  /// The side column's width.
  static const sideColumnWidth = 340.0;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return ColoredBox(
      color: palette.canvas,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 980;
          final side = _SideColumn(dashboard: this);
          final main = _MainColumn(dashboard: this);
          return CustomScrollView(
            key: const ValueKey('shell-dashboard'),
            slivers: [
              SliverToBoxAdapter(child: _TitleRow(dashboard: this)),
              if (notice case final notice?)
                SliverPadding(
                  padding: const EdgeInsets.only(top: 10),
                  sliver: SliverToBoxAdapter(child: notice),
                ),
              if (wide)
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
                  sliver: SliverToBoxAdapter(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(width: sideColumnWidth, child: side),
                        const SizedBox(width: 24),
                        Expanded(child: main),
                      ],
                    ),
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
                  sliver: SliverList.list(
                    children: [side, const SizedBox(height: 20), main],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _TitleRow extends StatelessWidget {
  const _TitleRow({required this.dashboard});

  final ShellDashboard dashboard;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final theme = Theme.of(context);
    return Container(
      height: 40,
      padding: const EdgeInsets.only(left: 20, right: 6),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: palette.hairline)),
      ),
      child: Row(
        children: [
          Icon(Icons.space_dashboard_outlined, size: 18, color: palette.accent),
          const SizedBox(width: 8),
          Text(
            'Home',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const Spacer(),
          TextButton.icon(
            key: const ValueKey('dashboard-new-session'),
            onPressed: dashboard.onNewSession,
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('New session'),
          ),
          ...dashboard.actions,
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.label, {this.detail, this.color, this.icon});

  final String label;
  final String? detail;
  final Color? color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final color = this.color ?? palette.mutedForeground;
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 14, 2, 8),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 6),
          ],
          Text(
            label.toUpperCase(),
            style: TextStyle(
              color: color,
              fontSize: 11.5,
              letterSpacing: 1.2,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (detail != null) ...[
            const SizedBox(width: 8),
            Text(
              detail!,
              style: TextStyle(color: palette.mutedForeground, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}

class _SideColumn extends StatelessWidget {
  const _SideColumn({required this.dashboard});

  final ShellDashboard dashboard;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final items = dashboard.needsYou;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionTitle(
          'Needs you',
          detail: items.isEmpty ? null : '${items.length}',
          color: items.isEmpty ? null : palette.attention,
          icon: Icons.front_hand_rounded,
        ),
        if (items.isEmpty)
          const _Quiet(
            key: ValueKey('dashboard-needs-you-empty'),
            icon: Icons.check_circle_outline_rounded,
            text: 'No agent is waiting on you.',
          )
        else
          for (final item in items) ...[
            _NeedsYouCard(item: item, dashboard: dashboard),
            const SizedBox(height: 8),
          ],
        const _SectionTitle('Usage', icon: Icons.data_usage_rounded),
        KeyedSubtree(
          key: const ValueKey('dashboard-usage-slot'),
          child:
              dashboard.usage ??
              const _Quiet(
                icon: Icons.insights_outlined,
                text:
                    'Usage at a glance appears here once the companion '
                    'reports it.',
              ),
        ),
      ],
    );
  }
}

class _Quiet extends StatelessWidget {
  const _Quiet({required this.icon, required this.text, super.key});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: palette.panel,
        borderRadius: BorderRadius.circular(AppTheme.radius),
        border: Border.all(color: palette.hairline),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: palette.mutedForeground),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: palette.mutedForeground, fontSize: 12.5),
            ),
          ),
        ],
      ),
    );
  }
}

class _NeedsYouCard extends StatelessWidget {
  const _NeedsYouCard({required this.item, required this.dashboard});

  final DashboardNeedsYou item;
  final ShellDashboard dashboard;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final node = item.node;
    final agent = item.agent;
    final message = agent?.lastMessage?.trim();
    final pending = agent?.pendingRequests ?? const [];
    final onDecide = dashboard.onDecide;
    return Material(
      key: ValueKey('dashboard-needs-you-${node.key}'),
      color: palette.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radius),
        side: BorderSide(color: palette.attention.withValues(alpha: 0.55)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTheme.radius),
        onTap: () => dashboard.onOpenNeedsYou(item),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  AgentKindBadge(
                    kind: node.agentKind ?? agent?.kind ?? '',
                    size: 26,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          agent?.name ?? node.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: palette.foreground,
                            fontWeight: FontWeight.w800,
                            fontSize: 13.5,
                          ),
                        ),
                        Text(
                          [
                            item.where,
                            if (agent == null && node.detail.isNotEmpty)
                              node.detail,
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: palette.mutedForeground,
                            fontSize: 11.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const ShellStateDot(dot: SidebarDot.needsYou),
                ],
              ),
              if (message != null && message.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  message,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: palette.foreground, fontSize: 12.5),
                ),
              ],
              if (onDecide != null)
                for (final request in pending) ...[
                  const SizedBox(height: 8),
                  PendingRequestCard(
                    request: request,
                    agentName: agentKindLabel(agent!.kind),
                    busy: dashboard.isDeciding?.call(request.id) ?? false,
                    onDecide: (verdict) => onDecide(item, request, verdict),
                    onAnswer: (answers) => onDecide(
                      item,
                      request.withAnswers(answers),
                      PermissionVerdict.allow,
                    ),
                  ),
                ],
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  // Chat View reads the companion's transcript.
                  if (dashboard.onChat != null &&
                      agent != null &&
                      item.hostId != null)
                    TextButton.icon(
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: () => dashboard.onChat!(item),
                      icon: const Icon(Icons.forum_outlined, size: 16),
                      label: const Text('Chat'),
                    ),
                  FilledButton.tonalIcon(
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      minimumSize: const Size(0, 32),
                    ),
                    onPressed: () => dashboard.onOpenNeedsYou(item),
                    icon: const Icon(Icons.terminal_rounded, size: 16),
                    label: const Text('Open'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MainColumn extends StatelessWidget {
  const _MainColumn({required this.dashboard});

  final ShellDashboard dashboard;

  @override
  Widget build(BuildContext context) {
    final sessions = dashboard.sessions;
    final groups = dashboard.otherGroups;
    final count = groups.fold(0, (sum, group) => sum + group.tiles.length);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (dashboard.agents case final agents?) ...[
          const _SectionTitle('Agents', icon: Icons.space_dashboard_outlined),
          KeyedSubtree(key: const ValueKey('dashboard-agents'), child: agents),
        ],
        _SectionTitle(
          'Recent sessions',
          detail: sessions.isEmpty ? 'none open' : '${sessions.length} open',
          icon: Icons.terminal_rounded,
        ),
        if (sessions.isEmpty)
          const _Quiet(
            icon: Icons.terminal_rounded,
            text:
                'No session is open. Pick a workspace in the sidebar or '
                'start a new session.',
          )
        else
          Wrap(
            key: const ValueKey('dashboard-sessions'),
            spacing: 14,
            runSpacing: 14,
            children: [
              for (final tile in sessions)
                SizedBox(
                  width: ShellDashboard.sessionTileWidth,
                  height: ShellDashboard.sessionTileHeight,
                  child: tile,
                ),
            ],
          ),
        if (groups.isNotEmpty) ...[
          _SectionTitle(
            'Other workspaces',
            detail: count == 0 ? null : '$count not open',
            icon: Icons.layers_outlined,
          ),
          for (final group in groups) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(2, 6, 2, 6),
              child: Row(
                children: [
                  Icon(
                    Icons.dns_outlined,
                    size: 14,
                    color: AppPalette.of(context).mutedForeground,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    group.machineName,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
            if (group.notice case final notice?) ...[
              notice,
              const SizedBox(height: 8),
            ],
            if (group.tiles.isNotEmpty)
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final tile in group.tiles)
                    SizedBox(
                      width: ShellDashboard.workspaceTileWidth,
                      height: ShellDashboard.workspaceTileHeight,
                      child: tile,
                    ),
                ],
              ),
            const SizedBox(height: 8),
          ],
        ],
      ],
    );
  }
}
