import 'package:conduit/core/theme/app_theme.dart';
import 'package:conduit/features/agent_attention/domain/agent_kinds.dart';
import 'package:conduit/features/chat_view/presentation/widgets/chat_working_indicator.dart';
import 'package:conduit/features/voice/presentation/talk_controller.dart';
import 'package:flutter/material.dart';

/// Replaces the composer while the Talk loop runs: what the loop is doing,
/// what was heard, the send countdown with Cancel, and Stop.
class TalkPanel extends StatelessWidget {
  const TalkPanel({
    required this.controller,
    required this.onStop,
    this.agentName,
    super.key,
  });

  /// The agent's name for people; null when its kind is not known.
  final String? agentName;

  final TalkController controller;

  /// Ends the loop (Cancel in the countdown also ends it, keeping the
  /// text in the composer).
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final phase = controller.phase;
        final target = controller.target;
        final title = switch (phase) {
          TalkPhase.listening => switch (target) {
            TalkApproval(:final request) => 'Allow ${request.toolName}?',
            TalkQuestion() => 'Which option?',
            TalkPrompt() => 'Listening…',
          },
          TalkPhase.confirming =>
            'Sending in ${(controller.countdown.inMilliseconds / 1000).ceil()}s',
          TalkPhase.sending => 'Sending…',
          TalkPhase.waiting => '${agentSubject(agentName)} is working…',
          TalkPhase.speaking => 'Speaking…',
          TalkPhase.off => '',
        };
        final detail = controller.transcript.isNotEmpty
            ? controller.transcript
            : controller.message ??
                  (phase == TalkPhase.listening
                      ? 'Speak; a pause sends it.'
                      : phase == TalkPhase.waiting
                      ? 'The answer is read when '
                            '${agentObject(agentName)} is done.'
                      : '');
        final icon = switch (phase) {
          TalkPhase.listening => Icons.mic_rounded,
          TalkPhase.speaking => Icons.volume_up_rounded,
          TalkPhase.waiting => null,
          _ => Icons.send_rounded,
        };
        return Material(
          key: const ValueKey('talk-panel'),
          color: colorScheme.surfaceContainer,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      SizedBox(
                        width: 32,
                        child: icon == null
                            ? TypingDots(color: colorScheme.primary)
                            : Icon(icon, color: colorScheme.primary),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              title,
                              key: const ValueKey('talk-title'),
                              style: theme.textTheme.labelLarge?.copyWith(
                                color: colorScheme.primary,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            if (detail.isNotEmpty)
                              Text(
                                detail,
                                key: const ValueKey('talk-detail'),
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyMedium,
                              ),
                          ],
                        ),
                      ),
                      if (phase == TalkPhase.confirming) ...[
                        TextButton(
                          key: const ValueKey('talk-cancel'),
                          onPressed: onStop,
                          child: const Text('Cancel'),
                        ),
                        IconButton(
                          key: const ValueKey('talk-send-now'),
                          tooltip: 'Send now',
                          onPressed: controller.sendNow,
                          icon: const Icon(Icons.send_rounded),
                        ),
                      ] else
                        IconButton(
                          key: const ValueKey('talk-stop'),
                          tooltip: 'Stop talking',
                          onPressed: onStop,
                          icon: Icon(
                            Icons.stop_circle_rounded,
                            color: colorScheme.error,
                          ),
                        ),
                    ],
                  ),
                  if (phase == TalkPhase.confirming)
                    Padding(
                      padding: const EdgeInsets.only(top: 6, right: 8),
                      child: ClipRRect(
                        borderRadius: const BorderRadius.all(
                          Radius.circular(AppTheme.radius),
                        ),
                        child: LinearProgressIndicator(
                          key: const ValueKey('talk-countdown'),
                          value:
                              controller.countdown.inMilliseconds /
                              controller.cancelWindow.inMilliseconds,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
