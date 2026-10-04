import 'dart:async';

import 'package:conduit/core/presentation/theme_sheet.dart';
import 'package:conduit/features/agent_attention/domain/agent_notifications.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:flutter/material.dart';

/// Settings › Agents › Notifications: the mode ("Ongoing + urgent",
/// "Everything", "Urgent only"), which events notify, summary-only mode,
/// quiet updates and muted agents (this device only).
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

        final urgent = preferences.mode.urgentOnlyAlerts;
        final muted = preferences.mutedAgents.length;
        return SettingsCard(
          child: Column(
            children: [
              RadioGroup<AgentNotificationMode>(
                groupValue: preferences.mode,
                onChanged: (mode) {
                  if (mode != null) set(preferences.copyWith(mode: mode));
                },
                child: Column(
                  children: [
                    for (final mode in AgentNotificationMode.values)
                      RadioListTile<AgentNotificationMode>(
                        key: ValueKey('agent-notify-mode-${mode.name}'),
                        value: mode,
                        title: Text(mode.label),
                        subtitle: Text(switch (mode) {
                          AgentNotificationMode.ongoingAndUrgent =>
                            'One silent notification with every agent\'s '
                                'progress. Alerts only when an agent needs '
                                'you, fails or looks stuck.',
                          AgentNotificationMode.everything =>
                            'A notification for each agent that needs you '
                                'or finishes.',
                          AgentNotificationMode.urgentOnly =>
                            'Alerts only when an agent needs you, fails or '
                                'looks stuck. No ongoing notification.',
                        }),
                      ),
                  ],
                ),
              ),
              const Divider(height: 1),
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
              if (urgent)
                tile(
                  id: 'finished-alerts',
                  icon: Icons.task_alt_rounded,
                  title: 'Also alert when an agent finishes',
                  subtitle:
                      'Off: a finished turn only updates the ongoing '
                      'notification.',
                  value: preferences.finishedAlerts,
                  change: (value) =>
                      preferences.copyWith(finishedAlerts: value),
                )
              else
                tile(
                  id: 'finished',
                  icon: Icons.task_alt_rounded,
                  title: 'Notify when an agent finishes',
                  subtitle:
                      'Its turn ended. Replaces its earlier notification.',
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
              if (urgent)
                tile(
                  id: 'stuck',
                  icon: Icons.sync_problem_rounded,
                  title: 'Stuck or looping',
                  subtitle:
                      'The agents dashboard sees no progress, the same '
                      'failure again and again, or a repeated command.',
                  value: preferences.stuck,
                  change: (value) => preferences.copyWith(stuck: value),
                ),
              const Divider(height: 1),
              tile(
                id: 'summary-only',
                icon: Icons.notes_rounded,
                title: 'Summary only',
                subtitle:
                    'No Allow, Deny, answer or Reply buttons. Tap the '
                    'notification to answer in the app.',
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
              if (muted > 0) ...[
                const Divider(height: 1),
                ListTile(
                  key: const ValueKey('agent-notify-muted'),
                  leading: const Icon(Icons.notifications_off_outlined),
                  title: Text(
                    muted == 1 ? '1 muted agent' : '$muted muted agents',
                  ),
                  subtitle: const Text(
                    'Long-press an agent in the Agents panel to mute or '
                    'unmute it.',
                  ),
                  trailing: TextButton(
                    key: const ValueKey('agent-notify-unmute-all'),
                    onPressed: () =>
                        set(preferences.copyWith(mutedAgents: const {})),
                    child: const Text('Unmute all'),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
