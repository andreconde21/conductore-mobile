import 'package:conduit/core/presentation/conduit_brand.dart';
import 'package:conduit/features/agent_attention/presentation/widgets/agents_icon.dart';
import 'package:conduit/features/hosts/presentation/widgets/home_session_grid.dart';
import 'package:flutter/material.dart';

/// Slim bar of the home page, four controls at most: the machine chip,
/// the agents dashboard, the switcher's search and the settings gear.
class HomeTopBar extends StatelessWidget {
  const HomeTopBar({
    required this.onSettings,
    this.machine,
    this.onSearch,
    this.onAgents,
    this.agentsBadge = 0,
    super.key,
  });

  final VoidCallback onSettings;

  /// Opens the quick switcher to search, keyboard up; null hides its
  /// button.
  final VoidCallback? onSearch;

  /// Opens the Agents screen; null hides its button.
  final VoidCallback? onAgents;

  /// Agents waiting on the user, shown on the dashboard button.
  final int agentsBadge;

  /// The machine chip (absent before any machine is saved).
  final Widget? machine;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      // The chip starts at the list's left gutter; the icons sit right.
      padding: const EdgeInsets.fromLTRB(
        HomeGridMetrics.horizontalPadding,
        6,
        6,
        4,
      ),
      child: Row(
        children: [
          Expanded(
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: machine ?? const ConduitGlyph(size: 24),
            ),
          ),
          const SizedBox(width: 4),
          if (onAgents != null)
            IconButton(
              key: const ValueKey('home-agents-dashboard'),
              tooltip: 'Agents',
              iconSize: 24,
              color: colorScheme.onSurface,
              icon: AgentsIcon(count: agentsBadge),
              onPressed: onAgents,
            ),
          if (onSearch != null)
            IconButton(
              key: const ValueKey('home-search'),
              tooltip: 'Switch to…',
              iconSize: 24,
              color: colorScheme.onSurface,
              icon: const Icon(Icons.search_rounded),
              onPressed: onSearch,
            ),
          IconButton(
            tooltip: 'Settings',
            iconSize: 26,
            color: colorScheme.onSurface,
            icon: const Icon(Icons.settings_outlined),
            onPressed: onSettings,
          ),
        ],
      ),
    );
  }
}
