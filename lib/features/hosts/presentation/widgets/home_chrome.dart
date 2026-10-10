import 'package:conduit/core/presentation/conduit_brand.dart';
import 'package:conduit/features/hosts/domain/home_preferences.dart';
import 'package:flutter/material.dart';

/// Slim Moshi-style bar of the home page: lock and the mode switch on the
/// left, the machine chip in the middle, the settings gear on the right.
class HomeTopBar extends StatelessWidget {
  const HomeTopBar({
    required this.onLock,
    required this.onSettings,
    this.machine,
    this.onSwitcher,
    this.onSearch,
    this.onGuide,
    this.onAgents,
    this.agentsBadge = 0,
    this.mode,
    this.onMode,
    super.key,
  });

  final VoidCallback onLock;
  final VoidCallback onSettings;

  /// Opens the quick switcher; null hides its button.
  final VoidCallback? onSwitcher;

  /// Opens the quick switcher to search, keyboard up; null hides its
  /// button.
  final VoidCallback? onSearch;

  /// Starts the voice guide; null hides its button.
  final VoidCallback? onGuide;

  /// Opens the agents dashboard; null hides its button.
  final VoidCallback? onAgents;

  /// Agents waiting on the user, shown on the dashboard button.
  final int agentsBadge;

  /// The machine chip (absent before any machine is saved).
  final Widget? machine;

  /// The home mode shown (CON-105); null, or no [onMode], hides the
  /// switch.
  final HomeMode? mode;

  /// Switches to the other mode.
  final ValueChanged<HomeMode>? onMode;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 6, 6, 4),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Lock',
            iconSize: 26,
            color: colorScheme.onSurface,
            icon: const Icon(Icons.lock_outline_rounded),
            onPressed: onLock,
          ),
          if (mode case final mode? when onMode != null)
            IconButton(
              key: const ValueKey('home-mode-switch'),
              tooltip: mode == HomeMode.projects
                  ? 'Projects: switch to Open / Closed'
                  : 'Open / Closed: switch to Projects',
              iconSize: 24,
              color: colorScheme.onSurface,
              icon: Icon(
                mode == HomeMode.projects
                    ? Icons.folder_copy_outlined
                    : Icons.grid_view_rounded,
              ),
              onPressed: () => onMode!(
                mode == HomeMode.projects
                    ? HomeMode.openClosed
                    : HomeMode.projects,
              ),
            ),
          const SizedBox(width: 4),
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
          if (onGuide != null)
            IconButton(
              key: const ValueKey('home-voice-guide'),
              tooltip: 'Voice guide',
              iconSize: 24,
              color: colorScheme.onSurface,
              icon: const Icon(Icons.headset_mic_outlined),
              onPressed: onGuide,
            ),
          if (onSearch != null)
            IconButton(
              key: const ValueKey('home-search'),
              tooltip: 'Search workspaces, sessions and agents',
              iconSize: 24,
              color: colorScheme.onSurface,
              icon: const Icon(Icons.search_rounded),
              onPressed: onSearch,
            ),
          if (onSwitcher != null)
            IconButton(
              key: const ValueKey('home-open-switcher'),
              tooltip: 'Switch sessions',
              iconSize: 24,
              color: colorScheme.onSurface,
              icon: const Icon(Icons.view_carousel_outlined),
              onPressed: onSwitcher,
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
