import 'package:conduit/features/voice_guide/presentation/guide_controller.dart';
import 'package:flutter/material.dart';

/// The guide's only UI while it runs: a small card at the bottom of every
/// screen with what it heard or says, and a stop button. Nothing is
/// needed from it; it is there for a glance. It sits in the app's
/// builder, above the navigator (so it stays across routes).
class GuideOverlay extends StatelessWidget {
  const GuideOverlay({required this.controller, super.key});

  final GuideController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (!controller.active) return const SizedBox.shrink();
        final theme = Theme.of(context);
        final scheme = theme.colorScheme;
        final strings = controller.strings;
        final (icon, text) = switch (controller.phase) {
          GuidePhase.listening => (
            Icons.mic_rounded,
            controller.heard.isNotEmpty
                ? controller.heard
                : controller.confirming
                ? strings.sayYesOrNo
                : strings.listening,
          ),
          GuidePhase.thinking => (
            Icons.hourglass_top_rounded,
            controller.heard.isNotEmpty ? controller.heard : strings.thinking,
          ),
          GuidePhase.speaking => (
            Icons.volume_up_rounded,
            controller.said ?? '',
          ),
          GuidePhase.paused => (Icons.mic_off_rounded, strings.micBusy),
          GuidePhase.off => (Icons.mic_none_rounded, ''),
        };
        return SafeArea(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Material(
                  key: const ValueKey('guide-overlay'),
                  elevation: 6,
                  color: scheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(22),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
                    child: Row(
                      children: [
                        Icon(icon, color: scheme.primary),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            text,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                        // No tooltip: the card sits above the navigator,
                        // outside any Overlay.
                        IconButton(
                          key: const ValueKey('guide-stop'),
                          icon: const Icon(
                            Icons.close_rounded,
                            semanticLabel: 'Stop the guide',
                          ),
                          onPressed: controller.stop,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
