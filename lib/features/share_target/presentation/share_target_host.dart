import 'dart:async';

import 'package:conduit/core/presentation/adaptive_modal.dart';
import 'package:conduit/core/presentation/terminal_route.dart';
import 'package:conduit/features/share_target/presentation/share_target_controller.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:flutter/material.dart';

/// Renders the share-to-agent flow around the app's home page: the
/// "Shared content waiting" banner, the session picker, upload progress and
/// failures, and brings the terminal page forward once a draft is ready.
class ShareTargetHost extends StatefulWidget {
  const ShareTargetHost({
    required this.controller,
    required this.workspace,
    required this.terminalPageBuilder,
    required this.child,
    super.key,
  });

  final ShareTargetController controller;
  final TerminalWorkspaceController workspace;

  /// Builds the terminal page to push when none is showing.
  final WidgetBuilder terminalPageBuilder;
  final Widget child;

  @override
  State<ShareTargetHost> createState() => _ShareTargetHostState();
}

class _ShareTargetHostState extends State<ShareTargetHost> {
  bool _pickerOpen = false;
  bool _errorOpen = false;

  /// Set when the progress dialog is asked for, before its route builds:
  /// two notifications in one frame must not open two dialogs, the first
  /// of which nothing would ever close.
  bool _progressOpen = false;
  int _progressDialogs = 0;
  BuildContext? _progressContext;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handleChanged);
  }

  @override
  void didUpdateWidget(ShareTargetHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handleChanged);
      widget.controller.addListener(_handleChanged);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleChanged);
    super.dispose();
  }

  void _handleChanged() {
    if (!mounted) {
      return;
    }
    // Dialogs and sheets are opened after the frame so a notification
    // arriving during build never pushes a route mid-build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _react();
      }
    });
    setState(() {});
  }

  void _react() {
    final controller = widget.controller;
    final readyHostId = controller.takeReadyHostId();
    if (readyHostId != null && !controller.terminalPageAttached) {
      unawaited(
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            settings: terminalRouteSettings,
            builder: widget.terminalPageBuilder,
          ),
        ),
      );
    }
    switch (controller.phase) {
      case ShareTargetPhase.choosingSession:
        if (!_pickerOpen) {
          unawaited(_pickSession());
        }
      case ShareTargetPhase.uploading:
        if (!_progressOpen) {
          unawaited(_showProgress());
        }
      case ShareTargetPhase.failed:
        _closeProgress();
        if (!_errorOpen) {
          unawaited(_showError());
        }
      case ShareTargetPhase.idle || ShareTargetPhase.waitingForSession:
        _closeProgress();
    }
  }

  Future<void> _pickSession() async {
    _pickerOpen = true;
    try {
      final session = await showAdaptiveModal<TerminalSessionController>(
        kind: AdaptiveModalKind.dialog,
        context: context,
        useSafeArea: true,
        builder: (context) => _SessionPickerSheet(
          workspace: widget.workspace,
          summary: widget.controller.pending?.summary ?? '',
          uploads: widget.controller.pending?.files.isNotEmpty ?? false,
        ),
      );
      if (!mounted) {
        return;
      }
      if (session != null) {
        unawaited(widget.controller.deliverTo(session));
      } else if (widget.controller.phase == ShareTargetPhase.choosingSession) {
        widget.controller.discard();
      }
    } finally {
      _pickerOpen = false;
    }
  }

  Future<void> _showProgress() async {
    _progressOpen = true;
    final dialog = ++_progressDialogs;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        _progressContext = dialogContext;
        // Closed while the route was still being built.
        if (!_progressOpen) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _closeProgress());
        }
        return PopScope(
          canPop: false,
          child: ListenableBuilder(
            listenable: widget.controller,
            builder: (context, _) {
              final controller = widget.controller;
              final progress = controller.progress;
              final target = controller.targetName;
              final label = progress == null
                  ? target == null
                        ? 'Connecting…'
                        : 'Connecting to $target…'
                  : progress.count == 1
                  ? progress.fileName
                  : '${progress.fileName} (${progress.index + 1}/'
                        '${progress.count})';
              return AlertDialog(
                key: const ValueKey('share-progress'),
                title: const Text('Sending to agent'),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 12),
                    LinearProgressIndicator(value: progress?.fraction),
                    if (progress != null && progress.total > 0) ...[
                      const SizedBox(height: 8),
                      Text(
                        '${formatShareBytes(progress.sent)} of '
                        '${formatShareBytes(progress.total)}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: controller.cancel,
                    child: const Text('Cancel'),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
    // A newer dialog may already be up once this one's future completes.
    if (dialog == _progressDialogs) {
      _progressContext = null;
      _progressOpen = false;
    }
  }

  void _closeProgress() {
    _progressOpen = false;
    final dialogContext = _progressContext;
    if (dialogContext != null && dialogContext.mounted) {
      // Remove the dialog itself: the terminal page may already have been
      // pushed above it, and pop() would close that instead.
      final route = ModalRoute.of(dialogContext);
      if (route != null && route.isActive) {
        Navigator.of(dialogContext).removeRoute(route);
      }
    }
    _progressContext = null;
  }

  Future<void> _showError() async {
    _errorOpen = true;
    try {
      final canRetry = widget.controller.canRetry;
      final retry = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Could not send the shared content'),
          content: Text(widget.controller.error ?? 'Upload failed.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Discard'),
            ),
            if (canRetry)
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Retry'),
              ),
          ],
        ),
      );
      if (!mounted) {
        return;
      }
      if (retry ?? false) {
        unawaited(widget.controller.retry());
      } else {
        widget.controller.discard();
      }
    } finally {
      _errorOpen = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final waiting =
        widget.controller.phase == ShareTargetPhase.waitingForSession;
    return Stack(
      children: [
        widget.child,
        if (waiting)
          Positioned(
            left: 16,
            right: 16,
            bottom: 96,
            child: SafeArea(
              top: false,
              child: _WaitingBanner(
                summary: widget.controller.pending?.summary ?? '',
                onDiscard: widget.controller.discard,
              ),
            ),
          ),
      ],
    );
  }
}

class _WaitingBanner extends StatelessWidget {
  const _WaitingBanner({required this.summary, required this.onDiscard});

  final String summary;
  final VoidCallback onDiscard;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Material(
      key: const ValueKey('share-waiting-banner'),
      color: colorScheme.primaryContainer,
      elevation: 4,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Row(
          children: [
            Icon(Icons.share_rounded, color: colorScheme.onPrimaryContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Shared content waiting',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: colorScheme.onPrimaryContainer,
                    ),
                  ),
                  Text(
                    summary.isEmpty
                        ? 'Connect to a machine to send it to the agent.'
                        : 'Connect to a machine to send $summary to the '
                              'agent.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onPrimaryContainer,
                    ),
                  ),
                ],
              ),
            ),
            TextButton(onPressed: onDiscard, child: const Text('Discard')),
          ],
        ),
      ),
    );
  }
}

class _SessionPickerSheet extends StatelessWidget {
  const _SessionPickerSheet({
    required this.workspace,
    required this.summary,
    required this.uploads,
  });

  final TerminalWorkspaceController workspace;
  final String summary;

  /// The share carries files, which are uploaded to the chosen machine.
  final bool uploads;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: workspace,
      builder: (context, _) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                child: Text(
                  uploads
                      ? 'Upload to which machine?'
                      : 'Send to which session?',
                  style: theme.textTheme.titleMedium,
                ),
              ),
              if (summary.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Text(
                    summary,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              for (final session in workspace.sessions)
                ListTile(
                  leading: Icon(
                    session.isConnected
                        ? Icons.terminal_rounded
                        : Icons.power_off_rounded,
                  ),
                  title: Text(session.host.name),
                  subtitle: Text(
                    session.isConnected
                        ? session.host.endpoint
                        : '${session.host.endpoint} · not connected',
                  ),
                  onTap: () => Navigator.of(context).pop(session),
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }
}

/// `840 KB`, `2.3 MB`: the progress dialog's byte counts.
String formatShareBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
