import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/core/theme/app_theme.dart';
import 'package:conduit/features/hosts/presentation/widgets/home_session_grid.dart';
import 'package:flutter/material.dart';

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

/// The desktop home when no view is open (or Home is picked): the main
/// column next to the sidebar, which keeps "Needs you" and usage.
///
/// * recent sessions as live previews at fixed sizes;
/// * other workspaces (tmux sessions and Herdr workspaces not open), per
///   machine.
class ShellDashboard extends StatelessWidget {
  const ShellDashboard({
    required this.sessions,
    required this.otherGroups,
    required this.onNewSession,
    this.agents,
    this.actions = const [],
    this.notice,
    super.key,
  });

  /// A one-row notice above the columns (the privacy notice).
  final Widget? notice;

  /// Live previews of the open sessions, most recently active first.
  final List<Widget> sessions;
  final List<DashboardWorkspaceGroup> otherGroups;
  final VoidCallback onNewSession;

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

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return ColoredBox(
      color: palette.canvas,
      child: LayoutBuilder(
        builder: (context, constraints) {
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
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  constraints.maxWidth >= 980 ? 20 : 16,
                  4,
                  constraints.maxWidth >= 980 ? 20 : 16,
                  28,
                ),
                sliver: SliverToBoxAdapter(child: main),
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
  const _SectionTitle(this.label, {this.detail, this.icon});

  final String label;
  final String? detail;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final color = palette.mutedForeground;
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

class _Quiet extends StatelessWidget {
  const _Quiet({required this.icon, required this.text});

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
