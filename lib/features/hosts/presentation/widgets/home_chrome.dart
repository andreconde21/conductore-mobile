import 'package:conduit/core/presentation/conduit_brand.dart';
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

  /// Opens the agents dashboard; null hides its button.
  final VoidCallback? onAgents;

  /// Agents waiting on the user, shown on the dashboard button.
  final int agentsBadge;

  /// The machine chip (absent before any machine is saved).
  final Widget? machine;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 6, 6, 4),
      child: Row(
        children: [
          const SizedBox(width: 8),
          Expanded(
            child: Center(child: machine ?? const ConduitGlyph(size: 24)),
          ),
          const SizedBox(width: 4),
          if (onAgents != null)
            IconButton(
              key: const ValueKey('home-agents-dashboard'),
              tooltip: 'Agents dashboard',
              iconSize: 24,
              color: colorScheme.onSurface,
              icon: Badge(
                isLabelVisible: agentsBadge > 0,
                label: Text('$agentsBadge'),
                child: const Icon(Icons.space_dashboard_outlined),
              ),
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
