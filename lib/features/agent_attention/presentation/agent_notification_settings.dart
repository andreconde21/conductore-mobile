import 'dart:async';

import 'package:conduit/core/presentation/theme_sheet.dart';
import 'package:conduit/features/agent_attention/domain/agent_notifications.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:flutter/material.dart';

/// Settings › Agents › Notifications: which events notify, summary-only
/// mode and quiet updates (this device only).
class AgentNotificationSettingsCard extends StatelessWidget {
  const AgentNotificationSettingsCard({required this.controller, super.key});

  final AgentAttentionController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final preferences = controller.notificationPreferences;
        void set(AgentNotificationPreferences next) =>
            unawaited(controller.setNotificationPreferences(next));
        Widget tile({
          required String id,
          required IconData icon,
          required String title,
          required String subtitle,
          required bool value,
          required AgentNotificationPreferences Function(bool) change,
        }) {
          return SwitchListTile(
            key: ValueKey('agent-notify-$id'),
            secondary: Icon(icon),
            title: Text(title),
            subtitle: Text(subtitle),
            value: value,
            onChanged: (value) => set(change(value)),
          );
        }

        return SettingsCard(
          child: Column(
            children: [
              tile(
                id: 'approvals',
                icon: Icons.verified_user_outlined,
                title: 'Approvals',
                subtitle: 'An agent asks to run a tool.',
                value: preferences.approvals,
                change: (value) => preferences.copyWith(approvals: value),
              ),
              tile(
                id: 'questions',
                icon: Icons.help_outline_rounded,
                title: 'Questions',
                subtitle: 'An agent waits for your answer.',
                value: preferences.questions,
                change: (value) => preferences.copyWith(questions: value),
              ),
              tile(
                id: 'finished',
                icon: Icons.task_alt_rounded,
                title: 'Notify when an agent finishes',
                subtitle: 'Its turn ended. Replaces its earlier notification.',
                value: preferences.finished,
                change: (value) => preferences.copyWith(finished: value),
              ),
              tile(
                id: 'errors',
                icon: Icons.error_outline_rounded,
                title: 'Errors',
                subtitle: 'An agent stopped on something else.',
                value: preferences.errors,
                change: (value) => preferences.copyWith(errors: value),
              ),
              const Divider(height: 1),
              tile(
                id: 'summary-only',
                icon: Icons.notes_rounded,
                title: 'Summary only',
                subtitle:
                    'No Allow or Deny buttons. Tap the notification to '
                    'answer in the app.',
                value: preferences.summaryOnly,
                change: (value) => preferences.copyWith(summaryOnly: value),
              ),
              tile(
                id: 'quiet-updates',
                icon: Icons.notifications_paused_outlined,
                title: 'Quiet updates',
                subtitle:
                    'More requests from an agent that already needs you '
                    'update its notification silently. Off: each new '
                    'request alerts.',
                value: preferences.quietUpdates,
                change: (value) => preferences.copyWith(quietUpdates: value),
              ),
            ],
          ),
        );
      },
    );
  }
}
