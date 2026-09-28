import 'dart:async';

import 'package:conduit/core/theme/theme_controller.dart';
import 'package:conduit/features/quick_actions/domain/quick_action.dart';
import 'package:conduit/features/quick_actions/presentation/quick_action_form.dart';
import 'package:flutter/material.dart';

/// Settings › Terminal › Quick actions: your own actions, for every
/// project or one, synced with the appearance settings. Repo actions live
/// in each repo's `.code-workspace` file instead.
class PersonalQuickActionsCard extends StatelessWidget {
  const PersonalQuickActionsCard({required this.theme, super.key});

  final ThemeController theme;

  Future<void> _add(BuildContext context) async {
    final draft = await showQuickActionForm(
      context,
      projectName: 'every project',
      takenIds: theme.quickActions.map((action) => action.id),
    );
    if (draft == null) return;
    // "Only for every project" means no project.
    final action = draft.action.project == 'every project'
        ? QuickAction.fromJson({...draft.action.toJson()..remove('project')})!
        : draft.action;
    await theme.setQuickActions([...theme.quickActions, action]);
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final actions = theme.quickActions;
    return Padding(
      key: const ValueKey('settings-quick-actions'),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Quick actions', style: textTheme.titleSmall),
              ),
              TextButton.icon(
                key: const ValueKey('settings-quick-actions-add'),
                onPressed: () => unawaited(_add(context)),
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('Add'),
              ),
            ],
          ),
          Text(
            'Your own commands, prompts and links, shown with each '
            "project's actions (the repo's .code-workspace ones). Synced "
            'to your devices.',
            style: textTheme.bodySmall,
          ),
          for (final action in actions)
            ListTile(
              key: ValueKey('settings-quick-action-${action.id}'),
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: Icon(quickActionIcon(action)),
              title: Text(action.label),
              subtitle: Text(
                [
                  action.command,
                  if (action.project case final project?) 'only $project',
                ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: IconButton(
                tooltip: 'Delete ${action.label}',
                icon: const Icon(Icons.delete_outline_rounded),
                onPressed: () => unawaited(
                  theme.setQuickActions([
                    for (final other in actions)
                      if (other != action) other,
                  ]),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
