import 'dart:async';

import 'package:conduit/core/presentation/theme_sheet.dart';
import 'package:conduit/features/agent_attention/domain/agent_notifications.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:flutter/material.dart';

/// Settings › Agents › Notifications: "Notify me" (urgent only, urgent +
/// finished, everything, or Custom for a mix made under Advanced) and the
/// muted agents, this device only (CON-108).
class AgentNotifyChoiceCard extends StatelessWidget {
  const AgentNotifyChoiceCard({required this.controller, super.key});

  final AgentAttentionController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final preferences = controller.notificationPreferences;
        void set(AgentNotificationPreferences next) =>
            unawaited(controller.setNotificationPreferences(next));
        final choice = preferences.choice;
        final muted = preferences.mutedAgents.length;
        return SettingsCard(
          child: Column(
            children: [
              RadioGroup<AgentNotifyChoice>(
                groupValue: choice,
                onChanged: (next) {
                  if (next != null) set(preferences.withChoice(next));
                },
                child: Column(
                  children: [
                    for (final option in AgentNotifyChoice.values)
                      RadioListTile<AgentNotifyChoice>(
                        key: ValueKey('agent-notify-choice-${option.name}'),
                        value: option,
                        title: Text(option.label),
                        subtitle: Text(option.description),
                      ),
                  ],
                ),
              ),
              if (choice == null)
                const ListTile(
                  key: ValueKey('agent-notify-choice-custom'),
                  leading: Icon(Icons.tune_rounded),
                  title: Text('Custom'),
                  subtitle: Text(
                    'Your own mix, kept under Advanced › Notification '
                    'details. Pick one above to replace it.',
                  ),
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

/// Settings › Agents › Advanced › Notification details: the ongoing
/// notification, which needs notify, summary-only mode and quiet updates
/// (this device only). "Notify me" reads its choice from these.
class AgentNotificationDetailsCard extends StatelessWidget {
  const AgentNotificationDetailsCard({required this.controller, super.key});

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
        return SettingsCard(
          child: Column(
            children: [
              // Everything notifies per agent, with no ongoing summary.
              if (urgent) ...[
                SwitchListTile(
                  key: const ValueKey('agent-notify-ongoing'),
                  secondary: const Icon(Icons.view_agenda_outlined),
                  title: const Text('Ongoing notification'),
                  subtitle: const Text(
                    'One silent notification with every agent\'s progress, '
                    'beside the alerts.',
                  ),
                  value: preferences.mode.showsOngoing,
                  onChanged: (on) => set(
                    preferences.copyWith(
                      mode: on
                          ? AgentNotificationMode.ongoingAndUrgent
                          : AgentNotificationMode.urgentOnly,
                    ),
                  ),
                ),
                const Divider(height: 1),
              ],
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
            ],
          ),
        );
      },
    );
  }
}
