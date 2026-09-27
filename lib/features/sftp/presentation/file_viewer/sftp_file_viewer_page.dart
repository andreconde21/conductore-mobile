import 'package:conduit/core/presentation/conduit_brand.dart';
import 'package:conduit/core/presentation/system_navigation_insets.dart';
import 'package:conduit/core/theme/terminal_appearance.dart';
import 'package:conduit/core/theme/theme_controller.dart';
import 'package:conduit/features/sftp/domain/remote_file_kind.dart';
import 'package:conduit/features/sftp/presentation/file_viewer/discard_changes_dialog.dart';
import 'package:conduit/features/sftp/presentation/file_viewer/sftp_file_viewer.dart';
import 'package:flutter/material.dart';

/// Full-screen wrapper around [SftpFileViewer] for the SFTP browser.
///
/// Pops with `true` when the file was written back to the server, so the
/// caller can refresh its listing.
class SftpFileViewerPage extends StatefulWidget {
  const SftpFileViewerPage({
    required this.path,
    required this.themeController,
    required this.read,
    required this.write,
    super.key,
  });

  final String path;
  final ThemeController themeController;
  final SftpFileRead read;
  final SftpFileWrite? write;

  @override
  State<SftpFileViewerPage> createState() => _SftpFileViewerPageState();
}

class _SftpFileViewerPageState extends State<SftpFileViewerPage> {
  final _viewerKey = GlobalKey<SftpFileViewerState>();

  Future<void> _handlePop(bool didPop) async {
    if (didPop) return;
    final navigator = Navigator.of(context);
    final viewer = _viewerKey.currentState;
    if (viewer?.isDirty ?? false) {
      final discard = await confirmDiscardChanges(
        context,
        fileName: remoteFileName(widget.path),
      );
      if (!discard || !mounted) return;
    }
    navigator.pop(viewer?.hasSaved ?? false);
  }

  @override
  Widget build(BuildContext context) {
    final palette = widget.themeController.palette;
    final brightness = Theme.of(context).brightness;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) => _handlePop(didPop),
      child: Scaffold(
        body: ConduitBackdrop(
          palette: palette,
          child: SafeArea(
            bottom: shouldApplyBottomSafeArea(context),
            child: Column(
              children: [
                Row(
                  children: [
                    IconButton(
                      tooltip: 'Back',
                      onPressed: () => _handlePop(false),
                      icon: const Icon(Icons.arrow_back_rounded),
                    ),
                    Expanded(
                      child: Text(
                        widget.path,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12.5,
                          color: palette.mutedForegroundFor(brightness),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                  ],
                ),
                Expanded(
                  child: SftpFileViewer(
                    key: _viewerKey,
                    path: widget.path,
                    palette: palette,
                    brightness: brightness,
                    fontFamily: widget.themeController.terminalFont.fontFamily,
                    read: widget.read,
                    write: widget.write,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
