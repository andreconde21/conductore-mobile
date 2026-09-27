import 'package:conduit/core/presentation/conduit_brand.dart';
import 'package:flutter/material.dart';

/// Slim Moshi-style bar of the home page: lock on the left, the machine
/// chip in the middle, the settings gear on the right.
class HomeTopBar extends StatelessWidget {
  const HomeTopBar({
    required this.onLock,
    required this.onSettings,
    this.machine,
    this.onSwitcher,
    this.onGuide,
    super.key,
  });

  final VoidCallback onLock;
  final VoidCallback onSettings;

  /// Opens the quick switcher; null hides its button.
  final VoidCallback? onSwitcher;

  /// Starts the voice guide; null hides its button.
  final VoidCallback? onGuide;

  /// The machine chip (absent before any machine is saved).
  final Widget? machine;

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
          const SizedBox(width: 4),
          Expanded(
            child: Center(child: machine ?? const ConduitGlyph(size: 24)),
          ),
          const SizedBox(width: 4),
          if (onGuide != null)
            IconButton(
              key: const ValueKey('home-voice-guide'),
              tooltip: 'Voice guide',
              iconSize: 24,
              color: colorScheme.onSurface,
              icon: const Icon(Icons.headset_mic_outlined),
              onPressed: onGuide,
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
