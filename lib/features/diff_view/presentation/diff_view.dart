import 'package:conduit/core/platform_features.dart';
import 'package:conduit/core/presentation/adaptive_modal.dart';
import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/features/diff_view/domain/git_diff_source.dart';
import 'package:conduit/features/diff_view/domain/git_status.dart';
import 'package:conduit/features/diff_view/domain/unified_diff.dart';
import 'package:conduit/features/diff_view/presentation/diff_view_controller.dart';
import 'package:conduit/features/diff_view/presentation/diff_view_rows.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Git diff for one working directory, rendered as a unified diff with
/// collapsible files, a staged/unstaged toggle and a file list for jumping.
class DiffView extends StatefulWidget {
  const DiffView({
    required this.controller,
    required this.palette,
    required this.brightness,
    required this.fontFamily,
    this.onOpenFile,
    super.key,
  });

  final DiffViewController controller;
  final AppPalette palette;
  final Brightness brightness;
  final String fontFamily;

  /// Opens an absolute remote path in a file viewer tab; null disables it.
  final ValueChanged<String>? onOpenFile;

  @override
  State<DiffView> createState() => _DiffViewState();
}

class _DiffViewState extends State<DiffView> {
  static const _fontSize = 12.5;

  final _scrollController = ScrollController();
  final _keysFocus = FocusNode(debugLabel: 'diff-view-keys');
  DiffRows? _rows;
  Object? _rowsSource;
  bool _rowsStaged = false;
  int _rowsRevision = -1;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handleControllerChanged);
  }

  @override
  void didUpdateWidget(covariant DiffView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handleControllerChanged);
      widget.controller.addListener(_handleControllerChanged);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleControllerChanged);
    _scrollController.dispose();
    _keysFocus.dispose();
    super.dispose();
  }

  void _handleControllerChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  DiffRows _rowsFor(UnifiedDiff diff) {
    final controller = widget.controller;
    final revision = controller.collapseRevision;
    if (_rows != null &&
        identical(_rowsSource, diff) &&
        _rowsStaged == controller.showStaged &&
        _rowsRevision == revision) {
      return _rows!;
    }
    final rows = DiffRows.build(diff, isCollapsed: controller.isCollapsed);
    _rows = rows;
    _rowsSource = diff;
    _rowsStaged = controller.showStaged;
    _rowsRevision = revision;
    return rows;
  }

  Future<void> _editPath() async {
    final controller = widget.controller;
    final result = await showDialog<String>(
      context: context,
      builder: (context) => _DirectoryDialog(
        initialPath: controller.path,
        fontFamily: widget.fontFamily,
      ),
    );
    if (result != null && result.trim().isNotEmpty) {
      await controller.load(result.trim());
    }
  }

  Future<void> _showFileList(UnifiedDiff diff, DiffRows rows) async {
    final palette = widget.palette;
    final brightness = widget.brightness;
    final status = widget.controller.snapshot?.status;
    final untracked =
        status?.entries
            .where((entry) => entry.kind == GitStatusEntryKind.untracked)
            .toList() ??
        const <GitStatusEntry>[];
    await showAdaptiveModal<void>(
      kind: AdaptiveModalKind.dialog,
      context: context,
      backgroundColor: palette.panelElevatedFor(brightness),
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                '${diff.files.length} changed '
                '${diff.files.length == 1 ? 'file' : 'files'}',
                style: TextStyle(
                  color: palette.foregroundFor(brightness),
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            for (final file in diff.files)
              ListTile(
                dense: true,
                leading: Icon(
                  fileStatusIcon(file),
                  size: 18,
                  color: fileStatusColor(file, palette),
                ),
                title: Text(
                  file.displayPath,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: widget.fontFamily,
                    fontSize: 12.5,
                    color: palette.foregroundFor(brightness),
                  ),
                ),
                trailing: DiffCountsLabel(
                  additions: file.additions,
                  deletions: file.deletions,
                  palette: palette,
                ),
                onTap: () {
                  Navigator.of(context).pop();
                  _jumpTo(rows, file);
                },
              ),
            if (untracked.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                child: Text(
                  '${untracked.length} untracked',
                  style: TextStyle(
                    color: palette.mutedForegroundFor(brightness),
                    fontWeight: FontWeight.w700,
                    fontSize: 12.5,
                  ),
                ),
              ),
              for (final entry in untracked)
                ListTile(
                  dense: true,
                  leading: Icon(
                    Icons.help_outline_rounded,
                    size: 18,
                    color: palette.mutedForegroundFor(brightness),
                  ),
                  title: Text(
                    entry.path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: widget.fontFamily,
                      fontSize: 12.5,
                      color: palette.mutedForegroundFor(brightness),
                    ),
                  ),
                  onTap: widget.onOpenFile == null
                      ? null
                      : () {
                          Navigator.of(context).pop();
                          _openRelative(entry.path);
                        },
                ),
            ],
          ],
        ),
      ),
    );
  }

  void _jumpTo(DiffRows rows, DiffFile file) {
    final offset = rows.offsetOfFile(file);
    if (offset == null || !_scrollController.hasClients) {
      return;
    }
    final max = _scrollController.position.maxScrollExtent;
    _scrollController.animateTo(
      offset.clamp(0, max),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  void _openRelative(String relativePath) {
    final root = widget.controller.snapshot?.repositoryRoot;
    if (root == null) {
      return;
    }
    widget.onOpenFile?.call(
      root.endsWith('/') ? '$root$relativePath' : '$root/$relativePath',
    );
  }

  void _openFile(DiffFile file) {
    final path = widget.controller.absolutePathFor(file);
    if (path != null) {
      widget.onOpenFile?.call(path);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final palette = widget.palette;
    final brightness = widget.brightness;
    final snapshot = controller.snapshot;
    final diff = controller.diff;
    final rows = diff == null ? null : _rowsFor(diff);
    return Container(
      color: palette.canvasFor(brightness),
      child: Column(
        children: [
          _Toolbar(
            palette: palette,
            brightness: brightness,
            fontFamily: widget.fontFamily,
            path: controller.path,
            loading: controller.isLoading,
            onEditPath: _editPath,
            onRefresh: controller.isLoading ? null : controller.refresh,
            onShowFiles: diff == null || diff.isEmpty || rows == null
                ? null
                : () => _showFileList(diff, rows),
          ),
          if (snapshot != null && snapshot.isGitRepository)
            _ModeBar(
              palette: palette,
              brightness: brightness,
              snapshot: snapshot,
              showStaged: controller.showStaged,
              onChanged: controller.setShowStaged,
            ),
          if (controller.isLoading)
            LinearProgressIndicator(
              minHeight: 2,
              color: palette.accent,
              backgroundColor: Colors.transparent,
            ),
          Expanded(child: _body(controller, snapshot, diff, rows)),
        ],
      ),
    );
  }

  Widget _body(
    DiffViewController controller,
    GitDiffSnapshot? snapshot,
    UnifiedDiff? diff,
    DiffRows? rows,
  ) {
    final palette = widget.palette;
    final brightness = widget.brightness;
    if (controller.phase == DiffViewPhase.failed) {
      return _Notice(
        icon: Icons.error_outline_rounded,
        title: 'Could not load the diff',
        message: controller.error ?? '',
        palette: palette,
        brightness: brightness,
        action: TextButton(
          onPressed: controller.path.isEmpty ? _editPath : controller.refresh,
          child: Text(controller.path.isEmpty ? 'Choose directory' : 'Retry'),
        ),
      );
    }
    if (snapshot == null || diff == null || rows == null) {
      return const SizedBox.shrink();
    }
    if (!snapshot.isGitRepository) {
      return _Notice(
        icon: Icons.folder_off_outlined,
        title: 'Not a git repository',
        message: snapshot.path,
        palette: palette,
        brightness: brightness,
        action: TextButton(
          onPressed: _editPath,
          child: const Text('Change directory'),
        ),
      );
    }
    if (diff.isEmpty) {
      final status = snapshot.status;
      final untracked = status?.untrackedCount ?? 0;
      final otherSide = controller.showStaged
          ? snapshot.unstaged.files.length
          : snapshot.staged.files.length;
      final hints = <String>[
        if (otherSide > 0)
          '$otherSide ${controller.showStaged ? 'unstaged' : 'staged'} '
              '${otherSide == 1 ? 'file' : 'files'}',
        if (untracked > 0)
          '$untracked untracked ${untracked == 1 ? 'file' : 'files'}',
      ];
      return _Notice(
        icon: Icons.check_circle_outline_rounded,
        title: controller.showStaged ? 'Nothing staged' : 'No unstaged changes',
        message: hints.join(' · '),
        palette: palette,
        brightness: brightness,
      );
    }
    final list = DiffRowsList(
      rows: rows,
      scrollController: _scrollController,
      palette: palette,
      brightness: brightness,
      fontFamily: widget.fontFamily,
      fontSize: _fontSize,
      truncated: controller.diffTruncated,
      onToggleFile: controller.toggleCollapsed,
      isCollapsed: controller.isCollapsed,
      onOpenFile: widget.onOpenFile == null ? null : _openFile,
    );
    if (!PlatformFeatures.isDesktop) return list;
    return _keyboard(diff, rows, list);
  }

  /// Desktop: j / k jump to the next / previous file, n / p to the next /
  /// previous hunk, like Review. The keys work once the diff was clicked
  /// (it never takes the focus on its own, the terminal keeps it).
  Widget _keyboard(UnifiedDiff diff, DiffRows rows, Widget child) {
    List<double> fileOffsets() => [
      for (final file in diff.files) ?rows.offsetOfFile(file),
    ];
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyJ): () =>
            _step(fileOffsets(), 1),
        const SingleActivator(LogicalKeyboardKey.keyK): () =>
            _step(fileOffsets(), -1),
        const SingleActivator(LogicalKeyboardKey.keyN): () =>
            _step(rows.hunkOffsets, 1),
        const SingleActivator(LogicalKeyboardKey.keyP): () =>
            _step(rows.hunkOffsets, -1),
      },
      child: Focus(
        focusNode: _keysFocus,
        child: Listener(
          onPointerDown: (_) {
            if (!_keysFocus.hasFocus) _keysFocus.requestFocus();
          },
          child: child,
        ),
      ),
    );
  }

  /// Scrolls to the first of [offsets] after (or, with a negative
  /// [direction], before) the current scroll position.
  void _step(List<double> offsets, int direction) {
    if (!_scrollController.hasClients || offsets.isEmpty) return;
    final position = _scrollController.position;
    final current = position.pixels;
    double? target;
    if (direction > 0) {
      for (final offset in offsets) {
        if (offset > current + 1) {
          target = offset;
          break;
        }
      }
    } else {
      for (final offset in offsets.reversed) {
        if (offset < current - 1) {
          target = offset;
          break;
        }
      }
    }
    if (target == null) return;
    _scrollController.animateTo(
      target.clamp(0, position.maxScrollExtent),
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOutCubic,
    );
  }
}

class _DirectoryDialog extends StatefulWidget {
  const _DirectoryDialog({required this.initialPath, required this.fontFamily});

  final String initialPath;
  final String fontFamily;

  @override
  State<_DirectoryDialog> createState() => _DirectoryDialogState();
}

class _DirectoryDialogState extends State<_DirectoryDialog> {
  late final TextEditingController _text = TextEditingController(
    text: widget.initialPath,
  );

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Directory to diff'),
      content: TextField(
        controller: _text,
        autofocus: true,
        autocorrect: false,
        enableSuggestions: false,
        keyboardType: TextInputType.url,
        style: TextStyle(fontFamily: widget.fontFamily, fontSize: 13),
        decoration: const InputDecoration(
          hintText: '/home/user/project',
          border: OutlineInputBorder(),
        ),
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_text.text),
          child: const Text('Load'),
        ),
      ],
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.palette,
    required this.brightness,
    required this.fontFamily,
    required this.path,
    required this.loading,
    required this.onEditPath,
    required this.onRefresh,
    required this.onShowFiles,
  });

  final AppPalette palette;
  final Brightness brightness;
  final String fontFamily;
  final String path;
  final bool loading;
  final VoidCallback onEditPath;
  final VoidCallback? onRefresh;
  final VoidCallback? onShowFiles;

  @override
  Widget build(BuildContext context) {
    final muted = palette.mutedForegroundFor(brightness);
    return Container(
      height: 44,
      color: palette.canvasFor(brightness),
      padding: const EdgeInsets.only(left: 12),
      child: Row(
        children: [
          Icon(Icons.difference_outlined, size: 18, color: muted),
          const SizedBox(width: 8),
          Expanded(
            child: Tooltip(
              message: 'Change directory',
              child: InkWell(
                onTap: onEditPath,
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text(
                    path.isEmpty ? 'Detecting directory…' : path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: fontFamily,
                      color: palette.foregroundFor(brightness),
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Changed files',
            iconSize: 19,
            color: muted,
            icon: const Icon(Icons.list_rounded),
            onPressed: onShowFiles,
          ),
          IconButton(
            tooltip: 'Refresh',
            iconSize: 19,
            color: muted,
            icon: const Icon(Icons.refresh_rounded),
            onPressed: onRefresh,
          ),
        ],
      ),
    );
  }
}

class _ModeBar extends StatelessWidget {
  const _ModeBar({
    required this.palette,
    required this.brightness,
    required this.snapshot,
    required this.showStaged,
    required this.onChanged,
  });

  final AppPalette palette;
  final Brightness brightness;
  final GitDiffSnapshot snapshot;
  final bool showStaged;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final muted = palette.mutedForegroundFor(brightness);
    final status = snapshot.status;
    final branchParts = <String>[
      if (status?.branch != null)
        status!.branch!
      else if (status?.detached ?? false)
        'detached HEAD',
      if ((status?.ahead ?? 0) > 0) '↑${status!.ahead}',
      if ((status?.behind ?? 0) > 0) '↓${status!.behind}',
    ];
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      color: palette.canvasFor(brightness),
      child: Row(
        children: [
          SegmentedButton<bool>(
            showSelectedIcon: false,
            style: const ButtonStyle(
              visualDensity: VisualDensity.compact,
              textStyle: WidgetStatePropertyAll(
                TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
              ),
            ),
            segments: [
              ButtonSegment(
                value: false,
                label: Text('Unstaged ${snapshot.unstaged.files.length}'),
              ),
              ButtonSegment(
                value: true,
                label: Text('Staged ${snapshot.staged.files.length}'),
              ),
            ],
            selected: {showStaged},
            onSelectionChanged: (selection) => onChanged(selection.first),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (branchParts.isNotEmpty) ...[
                  Icon(Icons.call_split_rounded, size: 14, color: muted),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      branchParts.join(' '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        color: muted,
                        fontSize: 11.5,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({
    required this.icon,
    required this.title,
    required this.message,
    required this.palette,
    required this.brightness,
    this.action,
  });

  final IconData icon;
  final String title;
  final String message;
  final AppPalette palette;
  final Brightness brightness;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final muted = palette.mutedForegroundFor(brightness);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 36, color: muted),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: palette.foregroundFor(brightness),
                fontWeight: FontWeight.w800,
                fontSize: 15,
              ),
            ),
            if (message.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(color: muted, fontSize: 12.5),
              ),
            ],
            if (action != null) ...[const SizedBox(height: 8), action!],
          ],
        ),
      ),
    );
  }
}

/// `+n −m` counts in the palette's success/danger colours.
class DiffCountsLabel extends StatelessWidget {
  const DiffCountsLabel({
    required this.additions,
    required this.deletions,
    required this.palette,
    this.fontSize = 11.5,
    super.key,
  });

  final int additions;
  final int deletions;
  final AppPalette palette;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: fontSize,
          fontWeight: FontWeight.w700,
        ),
        children: [
          TextSpan(
            text: '+$additions',
            style: TextStyle(color: palette.success),
          ),
          const TextSpan(text: ' '),
          TextSpan(
            text: '−$deletions',
            style: TextStyle(color: palette.danger),
          ),
        ],
      ),
    );
  }
}

IconData fileStatusIcon(DiffFile file) {
  if (file.binary) {
    return Icons.memory_rounded;
  }
  return switch (file.status) {
    DiffFileStatus.added => Icons.add_circle_outline_rounded,
    DiffFileStatus.deleted => Icons.remove_circle_outline_rounded,
    DiffFileStatus.renamed => Icons.drive_file_rename_outline_rounded,
    DiffFileStatus.copied => Icons.file_copy_outlined,
    DiffFileStatus.modified => Icons.edit_outlined,
  };
}

Color fileStatusColor(DiffFile file, AppPalette palette) {
  return switch (file.status) {
    DiffFileStatus.added => palette.success,
    DiffFileStatus.deleted => palette.danger,
    DiffFileStatus.renamed || DiffFileStatus.copied => palette.warning,
    DiffFileStatus.modified => palette.accent,
  };
}
