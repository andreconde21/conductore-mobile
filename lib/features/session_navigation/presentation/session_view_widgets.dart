import 'package:conduit/core/presentation/adaptive_modal.dart';
import 'package:conduit/core/theme/app_theme.dart';
import 'package:conduit/features/session_navigation/domain/session_view_preferences.dart';
import 'package:conduit/features/session_navigation/presentation/session_view_controller.dart';
import 'package:flutter/material.dart';

/// One line naming what [sessionHostId] opens in, for menus.
String sessionViewSummary(
  SessionViewController controller,
  String sessionHostId,
) {
  final override = controller.overrideFor(sessionHostId);
  return override == null
      ? 'Default (${controller.defaultView.label})'
      : 'Always ${override.label}';
}

/// Long-press › Open in: always Chat View, always the terminal, or the
/// default from Settings, for the Claude session in [sessionHostId].
Future<void> showSessionViewPicker(
  BuildContext context, {
  required SessionViewController controller,
  required String sessionHostId,
  required String title,
}) async {
  final current = controller.overrideFor(sessionHostId);
  final picked = await showAdaptiveModal<_Choice>(
    kind: AdaptiveModalKind.menu,
    context: context,
    useSafeArea: true,
    builder: (context) {
      final theme = Theme.of(context);
      Widget option(_Choice choice, IconData icon, String label) => ListTile(
        key: ValueKey('session-view-${choice.name}'),
        leading: Icon(icon),
        title: Text(label),
        trailing: choice.view == current
            ? Icon(Icons.check_rounded, color: theme.colorScheme.primary)
            : null,
        onTap: () => Navigator.of(context).pop(choice),
      );
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              subtitle: const Text(
                'Where this session opens when its pane runs a coding agent. '
                'Other panes always open in the terminal.',
              ),
            ),
            const Divider(height: 1),
            option(
              _Choice.chat,
              Icons.forum_outlined,
              'Always open in Chat View',
            ),
            option(
              _Choice.terminal,
              Icons.terminal_rounded,
              'Always open in Terminal',
            ),
            option(
              _Choice.useDefault,
              Icons.settings_suggest_outlined,
              'Use default (${controller.defaultView.label})',
            ),
          ],
        ),
      );
    },
  );
  if (picked == null) return;
  await controller.setOverride(sessionHostId, picked.view);
}

enum _Choice {
  chat(SessionView.chat),
  terminal(SessionView.terminal),
  useDefault(null);

  const _Choice(this.view);

  final SessionView? view;
}

/// Settings › Terminal: "Open Claude sessions in: Chat View / Terminal".
/// Shows nothing when the app has no [SessionViewScope]; otherwise it
/// brings its own bottom gap, like the tiles above it.
class SessionViewSettingsTile extends StatelessWidget {
  const SessionViewSettingsTile({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = SessionViewScope.maybeOf(context, listen: true);
    if (controller == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Material(
        key: const ValueKey('session-view-setting'),
        color: colorScheme.surface,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: colorScheme.outlineVariant),
          borderRadius: AppTheme.borderRadius,
        ),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.forum_outlined,
                    color: colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      'Open agent sessions in',
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.only(left: 40),
                child: Text(
                  'Sessions whose pane runs a coding agent open here. '
                  'Long-press a '
                  'session to choose for it alone. Other panes always open in '
                  'the terminal.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.only(left: 40),
                child: SegmentedButton<SessionView>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(
                      value: SessionView.chat,
                      label: Text('Chat View'),
                    ),
                    ButtonSegment(
                      value: SessionView.terminal,
                      label: Text('Terminal'),
                    ),
                  ],
                  selected: {controller.defaultView},
                  onSelectionChanged: (selection) =>
                      controller.setDefaultView(selection.single),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
