import 'package:conduit/features/home_widget/domain/agent_status_widget_channel.dart';
import 'package:flutter/material.dart';

/// Settings entry that asks Android 13+ to add the agent quick-settings
/// tile; on older versions it explains how to add it by hand.
class QuickSettingsTileControls extends StatefulWidget {
  const QuickSettingsTileControls({required this.channel, super.key});

  final AgentStatusWidgetChannel channel;

  /// The snackbar text shown for each outcome.
  static String messageFor(AddTileResult result) => switch (result) {
    AddTileResult.added => 'Tile added to quick settings.',
    AddTileResult.alreadyAdded => 'The tile is already in quick settings.',
    AddTileResult.declined => 'Tile not added.',
    AddTileResult.unsupported =>
      'Open quick settings, tap edit, and drag the Agents tile in.',
    AddTileResult.failed => 'Could not add the tile. Try again later.',
  };

  @override
  State<QuickSettingsTileControls> createState() =>
      _QuickSettingsTileControlsState();
}

class _QuickSettingsTileControlsState extends State<QuickSettingsTileControls> {
  bool _requesting = false;

  Future<void> _request() async {
    if (_requesting) {
      return;
    }
    setState(() => _requesting = true);
    final messenger = ScaffoldMessenger.maybeOf(context);
    AddTileResult result;
    try {
      result = await widget.channel.requestAddTile();
    } catch (_) {
      result = AddTileResult.failed;
    }
    if (!mounted) {
      return;
    }
    setState(() => _requesting = false);
    messenger?.showSnackBar(
      SnackBar(content: Text(QuickSettingsTileControls.messageFor(result))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Material(
      color: colorScheme.surface,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(14),
      ),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        leading: const Icon(Icons.dashboard_customize_rounded),
        title: const Text('Add quick-settings tile'),
        subtitle: Text(
          'Shows how many agents need you or are stuck; tap it to open the '
          'dashboard. '
          'A resizable home-screen widget is in the launcher\'s widget picker.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        trailing: _requesting
            ? const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.add_rounded),
        onTap: _requesting ? null : _request,
      ),
    );
  }
}
