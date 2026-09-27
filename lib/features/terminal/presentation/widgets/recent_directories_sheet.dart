import 'package:conduit/core/presentation/adaptive_modal.dart';
import 'package:conduit/features/terminal/domain/recent_directories.dart';
import 'package:flutter/material.dart';

/// What choosing a recent directory does.
enum RecentDirectoryAction {
  cd('cd here', Icons.subdirectory_arrow_right_rounded),
  tmuxWindow('New tmux window here', Icons.add_box_rounded),
  herdrTab('New Herdr tab here', Icons.tab_rounded);

  const RecentDirectoryAction(this.label, this.icon);

  final String label;
  final IconData icon;
}

class RecentDirectoryPick {
  const RecentDirectoryPick(this.directory, this.action);

  final String directory;
  final RecentDirectoryAction action;

  @override
  bool operator ==(Object other) =>
      other is RecentDirectoryPick &&
      other.directory == directory &&
      other.action == action;

  @override
  int get hashCode => Object.hash(directory, action);
}

/// The "cd to…" sheet: the host's recent directories. A tap runs the first
/// of [actions] (the one that fits the session: a Herdr tab inside Herdr,
/// a tmux window inside tmux, else `cd`); the ⋮ menu offers all of them.
Future<RecentDirectoryPick?> showRecentDirectoriesSheet({
  required BuildContext context,
  required String hostName,
  required List<String> directories,
  required List<RecentDirectoryAction> actions,
  String? currentDirectory,
}) {
  return showAdaptiveModal<RecentDirectoryPick>(
    kind: AdaptiveModalKind.dialog,
    context: context,
    // The whole panel on desktop: nothing to drag there.
    desktopFill: true,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) => RecentDirectoriesSheet(
      hostName: hostName,
      directories: directories,
      actions: actions,
      currentDirectory: currentDirectory,
    ),
  );
}

class RecentDirectoriesSheet extends StatelessWidget {
  const RecentDirectoriesSheet({
    required this.hostName,
    required this.directories,
    required this.actions,
    this.currentDirectory,
    super.key,
  });

  final String hostName;
  final List<String> directories;
  final List<RecentDirectoryAction> actions;
  final String? currentDirectory;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: adaptiveSheetFraction(context, 0.6),
      minChildSize: adaptiveSheetFraction(context, 0.3),
      maxChildSize: adaptiveSheetFraction(context, 0.92),
      builder: (context, scrollController) => ListView(
        controller: scrollController,
        padding: EdgeInsets.fromLTRB(
          8,
          0,
          8,
          16 + MediaQuery.viewPaddingOf(context).bottom,
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('cd to…', style: theme.textTheme.titleLarge),
                Text(
                  'Recent directories on $hostName · tap: '
                  '${actions.first.label.toLowerCase()}',
                  style: theme.textTheme.bodySmall?.copyWith(color: muted),
                ),
              ],
            ),
          ),
          if (directories.isEmpty)
            Padding(
              padding: const EdgeInsets.all(20),
              child: Text(
                'No directories yet. They are collected from shells that '
                'report their directory (OSC 7), from tmux when you detach, '
                'and from the companion\'s agents.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(color: muted),
              ),
            )
          else
            for (final directory in directories)
              ListTile(
                key: ValueKey('recent-dir-$directory'),
                leading: Icon(
                  directory == currentDirectory
                      ? Icons.folder_special_rounded
                      : Icons.folder_outlined,
                ),
                title: Text(
                  directoryBasename(directory),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  directory,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
                onTap: () => Navigator.of(
                  context,
                ).pop(RecentDirectoryPick(directory, actions.first)),
                trailing: actions.length < 2
                    ? null
                    : PopupMenuButton<RecentDirectoryAction>(
                        tooltip: 'More',
                        onSelected: (action) => Navigator.of(
                          context,
                        ).pop(RecentDirectoryPick(directory, action)),
                        itemBuilder: (context) => [
                          for (final action in actions)
                            PopupMenuItem(
                              value: action,
                              child: ListTile(
                                leading: Icon(action.icon),
                                title: Text(action.label),
                              ),
                            ),
                        ],
                      ),
              ),
        ],
      ),
    );
  }
}
