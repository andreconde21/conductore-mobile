import 'dart:async';

import 'package:conduit/core/platform_features.dart';
import 'package:conduit/core/presentation/adaptive_modal.dart';
import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/core/theme/app_theme.dart';
import 'package:conduit/core/theme/terminal_appearance.dart';
import 'package:conduit/features/companion_setup/presentation/companion_setup_page.dart';
import 'package:conduit/features/diff_view/domain/unified_diff.dart';
import 'package:conduit/features/diff_view/presentation/diff_view.dart';
import 'package:conduit/features/diff_view/presentation/diff_view_rows.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/review/domain/turn_review.dart';
import 'package:conduit/features/review/presentation/review_controller.dart';
import 'package:conduit/features/voice/data/platform_speech_recognizer.dart';
import 'package:conduit/features/voice/presentation/dictation_button.dart';
import 'package:conduit/features/voice/presentation/dictation_controller.dart';
import 'package:conduit/features/voice/presentation/voice_services.dart';
import 'package:conduit/features/voice/presentation/voice_settings_scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Window width from which Review uses the desktop layout: the file list
/// on the left, the diff beside it, keyboard navigation.
const reviewWideWidth = 840.0;

/// Review mode for one agent turn.
///
/// On a phone: swipeable cards, one per changed file, then a summary card.
/// Swipe a card's action bar right to accept, left to reject (or tap the
/// buttons, all within a thumb's reach at the bottom); tap a line to
/// comment on it. On a desktop (or any window at least [reviewWideWidth]
/// wide): the file list on the left, the diff on the right, and j / k
/// (files), n / p (hunks), a (accept), r (reject), c (comment), Esc.
class ReviewPage extends StatefulWidget {
  const ReviewPage({
    required this.controller,
    this.host,
    this.dictation,
    this.ownsController = true,
    super.key,
  });

  final ReviewController controller;

  /// For "Update agent hooks" when the companion predates snapshots.
  final SavedHost? host;

  /// Dictation for the feedback and comments; null hides the mic.
  final DictationController? dictation;
  final bool ownsController;

  @override
  State<ReviewPage> createState() => _ReviewPageState();
}

class _ReviewPageState extends State<ReviewPage> {
  final _pages = PageController();
  final _detailScroll = ScrollController();
  final _rows = <ReviewFile, DiffRows>{};
  final _focus = FocusNode(debugLabel: 'review');
  int _shownIndex = 0;

  ReviewController get _review => widget.controller;

  /// Made here when the opener passed no dictation (as Chat View does).
  DictationController? _ownDictation;

  DictationController? get _dictation => widget.dictation ?? _ownDictation;

  @override
  void initState() {
    super.initState();
    if (widget.dictation == null) {
      final recognizer =
          VoiceServicesScope.maybeOf(context)?.recognizer ??
          (PlatformFeatures.dictation ? PlatformSpeechRecognizer() : null);
      if (recognizer != null) {
        _ownDictation = DictationController(
          recognizer,
          language: () =>
              VoiceSettingsScope.maybeOf(context)?.speechLanguage ?? '',
        );
        unawaited(_ownDictation!.checkAvailability());
      }
    }
    _review.addListener(_onChanged);
    if (_review.phase == ReviewPhase.loading && _review.turn == null) {
      unawaited(_review.load());
    }
  }

  @override
  void dispose() {
    _review.removeListener(_onChanged);
    if (widget.ownsController) _review.dispose();
    _ownDictation?.dispose();
    _pages.dispose();
    _detailScroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    final index = _review.index;
    if (index != _shownIndex) {
      _shownIndex = index;
      if (_pages.hasClients && _pages.page?.round() != index) {
        unawaited(
          _pages.animateToPage(
            index,
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
          ),
        );
      }
      if (_detailScroll.hasClients) _detailScroll.jumpTo(0);
    }
    final message = _review.message;
    if (message != null && _review.phase == ReviewPhase.ready) {
      _tell(message);
    }
    setState(() {});
  }

  String? _lastTold;

  void _tell(String text, {SnackBarAction? action}) {
    if (text == _lastTold && action == null) return;
    _lastTold = text;
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), action: action));
  }

  DiffRows _rowsFor(ReviewFile file) => _rows[file] ??= DiffRows.build(
    UnifiedDiff([file.diff]),
    isCollapsed: (_) => false,
    fileHeaders: false,
  );

  String get _fontFamily =>
      VoiceSettingsScope.maybeOf(context)?.terminalFont.fontFamily ??
      AppTheme.monoFontFamily;

  // --- actions ------------------------------------------------------------------

  Future<void> _reject(int index) async {
    final file = _review.files.elementAtOrNull(index);
    if (file == null) return;
    final ok = await _review.reject(index);
    if (!ok || !mounted) return;
    _tell(
      'Reverted ${_basename(file.path)}',
      action: SnackBarAction(label: 'Redo', onPressed: _redo),
    );
  }

  Future<void> _redo() async {
    final outcome = await _review.redo();
    if (outcome != null && mounted) {
      _tell('Put back ${_files(outcome.restored.length)}');
    }
  }

  Future<void> _comment(ReviewFile file, {DiffLine? line}) async {
    final number = line?.newLineNumber ?? line?.oldLineNumber;
    final existing = _review.commentAt(file.path, number);
    final text = await showAdaptiveModal<String>(
      context: context,
      kind: AdaptiveModalKind.dialog,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => _TextSheet(
        key: const ValueKey('review-comment-sheet'),
        title: number == null
            ? 'Comment on ${_basename(file.path)}'
            : 'Comment on ${_basename(file.path)}:$number',
        quote: line?.text.trim(),
        initial: existing?.text ?? '',
        hint: 'What should change here?',
        action: 'Save',
        dictation: _dictation,
        onDelete: existing == null ? null : () => Navigator.of(context).pop(''),
      ),
    );
    if (text == null || !mounted) return;
    if (text.trim().isEmpty) {
      if (existing != null) _review.removeComment(existing);
      return;
    }
    _review.addComment(
      ReviewComment(path: file.path, line: number, text: text.trim()),
    );
  }

  Future<void> _sendFeedback() async {
    final text = await showAdaptiveModal<String>(
      context: context,
      kind: AdaptiveModalKind.dialog,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => _TextSheet(
        key: const ValueKey('review-feedback-sheet'),
        title: 'Feedback for ${_review.agentName}',
        initial: '',
        hint: 'Tell the agent what to change',
        action: 'Send',
        allowEmpty:
            _review.comments.isNotEmpty || _review.rejectedPaths.isNotEmpty,
        dictation: _dictation,
        preview: (text) => _review.feedbackPrompt(text),
      ),
    );
    if (text == null || !mounted) return;
    if (await _review.sendFeedback(text) && mounted) {
      _tell('Sent to ${_review.agentName}');
    }
  }

  Future<void> _undoTurn() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => _UndoDialog(review: _review),
    );
    if (confirmed != true || !mounted) return;
    final outcome = await _review.undoTurn();
    if (outcome == null || !mounted) return;
    _tell(
      'Turn undone: ${_files(outcome.restored.length)} restored',
      action: outcome.redoAvailable
          ? SnackBarAction(label: 'Redo', onPressed: _redo)
          : null,
    );
  }

  void _looksGood() {
    _review.looksGood();
    Navigator.of(context).maybePop();
  }

  void _jumpHunk(int direction) {
    final file = _review.current;
    if (file == null || !_detailScroll.hasClients) return;
    final offsets = _rowsFor(file).hunkOffsets;
    if (offsets.isEmpty) return;
    final at = _detailScroll.offset;
    final target = direction > 0
        ? offsets.where((o) => o > at + 1).firstOrNull
        : offsets.reversed.where((o) => o < at - 1).firstOrNull;
    if (target == null) return;
    unawaited(
      _detailScroll.animateTo(
        target.clamp(0, _detailScroll.position.maxScrollExtent),
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
      ),
    );
  }

  Map<ShortcutActivator, VoidCallback> get _shortcuts => {
    const SingleActivator(LogicalKeyboardKey.keyJ): _review.next,
    const SingleActivator(LogicalKeyboardKey.arrowDown, alt: true):
        _review.next,
    const SingleActivator(LogicalKeyboardKey.keyK): _review.previous,
    const SingleActivator(LogicalKeyboardKey.arrowUp, alt: true):
        _review.previous,
    const SingleActivator(LogicalKeyboardKey.keyN): () => _jumpHunk(1),
    const SingleActivator(LogicalKeyboardKey.keyP): () => _jumpHunk(-1),
    const SingleActivator(LogicalKeyboardKey.keyA): () {
      if (!_review.onSummary) _review.accept(_review.index);
    },
    const SingleActivator(LogicalKeyboardKey.keyR): () {
      if (!_review.onSummary && _review.canChange) {
        unawaited(_reject(_review.index));
      }
    },
    const SingleActivator(LogicalKeyboardKey.keyC): () {
      if (_review.current case final file?) unawaited(_comment(file));
    },
    const SingleActivator(LogicalKeyboardKey.escape): () =>
        Navigator.of(context).maybePop(),
  };

  // --- build ----------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final wide = MediaQuery.sizeOf(context).width >= reviewWideWidth;
    final turn = _review.turn;
    final subtitle = _review.needsUpdate
        ? 'Uncommitted changes'
        : turn == null
        ? _review.agentName
        : 'Turn ${turn.turn}${turn.prompt.isEmpty ? '' : ' · ${turn.prompt}'}';
    return CallbackShortcuts(
      bindings: wide ? _shortcuts : const {},
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        child: Scaffold(
          key: const ValueKey('review-page'),
          appBar: AppBar(
            titleSpacing: 0,
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Review · ${_review.agentName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            actions: [
              if (wide && _review.phase == ReviewPhase.ready)
                const Tooltip(
                  message:
                      'j / k: next / previous file · n / p: next / previous '
                      'hunk · a: accept · r: reject · c: comment · Esc: close',
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12),
                    child: Icon(Icons.keyboard_outlined),
                  ),
                ),
            ],
          ),
          body: SafeArea(top: false, child: _body(context, wide)),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, bool wide) {
    switch (_review.phase) {
      case ReviewPhase.loading:
        return const _Centered(
          icon: null,
          title: 'Loading the turn…',
          child: CircularProgressIndicator(),
        );
      case ReviewPhase.failed || ReviewPhase.empty:
        return _Centered(
          icon: _review.phase == ReviewPhase.failed
              ? Icons.error_outline_rounded
              : Icons.inbox_outlined,
          title: _review.phase == ReviewPhase.failed
              ? 'Could not load the review'
              : 'Nothing to review',
          message: _review.message,
          child: Wrap(
            spacing: 8,
            alignment: WrapAlignment.center,
            children: [
              TextButton(onPressed: _review.load, child: const Text('Retry')),
              if (_review.needsUpdate || _unsupported) _updateButton(context),
            ],
          ),
        );
      case ReviewPhase.ready:
        final content = wide ? _desktop(context) : _phone(context);
        if (!_review.needsUpdate) return content;
        return Column(
          children: [
            MaterialBanner(
              key: const ValueKey('review-update-hint'),
              content: const Text(
                'Read-only: uncommitted changes of the working tree. Update '
                'the agent hooks to review each turn and undo it.',
              ),
              actions: [_updateButton(context)],
            ),
            Expanded(child: content),
          ],
        );
    }
  }

  bool get _unsupported => (_review.message ?? '').contains('predates Review');

  Widget _updateButton(BuildContext context) {
    final host = widget.host;
    return TextButton(
      onPressed: host == null ? null : () => showCompanionSetup(context, host),
      child: const Text('Update agent hooks'),
    );
  }

  Widget _progress(BuildContext context) {
    final total = _review.files.length;
    final decided = total - _review.count(FileVerdict.pending);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: total == 0 ? 1 : decided / total,
                minHeight: 4,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            _review.onSummary ? 'Summary' : '${_review.index + 1} of $total',
            key: const ValueKey('review-progress'),
            style: theme.textTheme.labelMedium,
          ),
        ],
      ),
    );
  }

  Widget _phone(BuildContext context) {
    final files = _review.files;
    return Column(
      children: [
        _progress(context),
        Expanded(
          child: PageView.builder(
            key: const ValueKey('review-cards'),
            controller: _pages,
            itemCount: files.length + 1,
            onPageChanged: (page) {
              _shownIndex = page;
              _review.goTo(page);
            },
            itemBuilder: (context, index) => Padding(
              padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
              child: index == files.length
                  ? _SummaryCard(
                      review: _review,
                      onLooksGood: _looksGood,
                      onFeedback: _sendFeedback,
                      onUndo: _undoTurn,
                      onRedo: _redo,
                    )
                  : _FileCard(
                      key: ValueKey('review-card-$index'),
                      index: index,
                      file: files[index],
                      review: _review,
                      rows: _rowsFor(files[index]),
                      fontFamily: _fontFamily,
                      onAccept: () => _review.accept(index),
                      onReject: () => _reject(index),
                      onComment: (line) => _comment(files[index], line: line),
                    ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _desktop(BuildContext context) {
    final theme = Theme.of(context);
    final files = _review.files;
    final current = _review.current;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 320,
          child: Column(
            children: [
              _progress(context),
              Expanded(
                child: ListView(
                  key: const ValueKey('review-file-list'),
                  children: [
                    for (var i = 0; i < files.length; i++)
                      _FileTile(
                        key: ValueKey('review-file-tile-$i'),
                        file: files[i],
                        selected: i == _review.index,
                        comments: _review.comments
                            .where((c) => c.path == files[i].path)
                            .length,
                        onTap: () => _review.goTo(i),
                      ),
                    ListTile(
                      key: const ValueKey('review-file-tile-summary'),
                      selected: _review.onSummary,
                      leading: const Icon(Icons.fact_check_outlined),
                      title: const Text('Summary'),
                      onTap: () => _review.goTo(files.length),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        VerticalDivider(width: 1, color: theme.dividerColor),
        Expanded(
          child: current == null
              ? Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 720),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: _SummaryCard(
                        review: _review,
                        onLooksGood: _looksGood,
                        onFeedback: _sendFeedback,
                        onUndo: _undoTurn,
                        onRedo: _redo,
                      ),
                    ),
                  ),
                )
              : _FileCard(
                  key: ValueKey('review-card-${_review.index}'),
                  index: _review.index,
                  file: current,
                  review: _review,
                  rows: _rowsFor(current),
                  fontFamily: _fontFamily,
                  scrollController: _detailScroll,
                  desktop: true,
                  onAccept: () => _review.accept(_review.index),
                  onReject: () => _reject(_review.index),
                  onComment: (line) => _comment(current, line: line),
                ),
        ),
      ],
    );
  }
}

String _basename(String path) => path.split('/').last;

String _files(int n) => n == 1 ? '1 file' : '$n files';

class _Centered extends StatelessWidget {
  const _Centered({
    required this.icon,
    required this.title,
    this.message,
    this.child,
  });

  final IconData? icon;
  final String title;
  final String? message;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null)
              Icon(icon, size: 40, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(title, style: theme.textTheme.titleMedium),
            if (message case final text?) ...[
              const SizedBox(height: 6),
              Text(
                text,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (child != null) ...[const SizedBox(height: 16), child!],
          ],
        ),
      ),
    );
  }
}

/// The verdict chip of a file.
class _VerdictChip extends StatelessWidget {
  const _VerdictChip({required this.verdict});

  final FileVerdict verdict;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final (label, color, icon) = switch (verdict) {
      FileVerdict.pending => (null, null, null),
      FileVerdict.accepted => (
        'Accepted',
        palette.success,
        Icons.check_rounded,
      ),
      FileVerdict.rejected => ('Reverted', palette.danger, Icons.undo_rounded),
    };
    if (label == null) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color!.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(color: color, fontSize: 12)),
        ],
      ),
    );
  }
}

class _FileTile extends StatelessWidget {
  const _FileTile({
    required this.file,
    required this.selected,
    required this.comments,
    required this.onTap,
    super.key,
  });

  final ReviewFile file;
  final bool selected;
  final int comments;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final path = file.path;
    final slash = path.lastIndexOf('/');
    return ListTile(
      dense: true,
      selected: selected,
      onTap: onTap,
      leading: Icon(
        switch (file.verdict) {
          FileVerdict.accepted => Icons.check_circle_rounded,
          FileVerdict.rejected => Icons.undo_rounded,
          FileVerdict.pending => fileStatusIcon(file.diff),
        },
        size: 20,
        color: switch (file.verdict) {
          FileVerdict.accepted => palette.success,
          FileVerdict.rejected => palette.danger,
          FileVerdict.pending => fileStatusColor(file.diff, palette),
        },
      ),
      title: Text(
        _basename(path),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: slash <= 0
          ? null
          : Text(
              path.substring(0, slash),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (comments > 0) ...[
            Icon(Icons.mode_comment_outlined, size: 14, color: palette.accent),
            Text(' $comments  '),
          ],
          DiffCountsLabel(
            additions: file.change.added,
            deletions: file.change.removed,
            palette: palette,
          ),
        ],
      ),
    );
  }
}

/// One file: its header, its diff (tap a line to comment) and the actions.
class _FileCard extends StatefulWidget {
  const _FileCard({
    required this.index,
    required this.file,
    required this.review,
    required this.rows,
    required this.fontFamily,
    required this.onAccept,
    required this.onReject,
    required this.onComment,
    this.scrollController,
    this.desktop = false,
    super.key,
  });

  final int index;
  final ReviewFile file;
  final ReviewController review;
  final DiffRows rows;
  final String fontFamily;
  final VoidCallback onAccept;
  final VoidCallback onReject;
  final void Function(DiffLine? line) onComment;

  /// The desktop's detail scroll (for n / p); null: the card's own.
  final ScrollController? scrollController;
  final bool desktop;

  @override
  State<_FileCard> createState() => _FileCardState();
}

class _FileCardState extends State<_FileCard> {
  ScrollController? _own;

  ScrollController get _scroll =>
      widget.scrollController ?? (_own ??= ScrollController());

  @override
  void dispose() {
    _own?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    final brightness = theme.brightness;
    final file = widget.file;
    final change = file.change;
    final review = widget.review;
    final path = change.path;
    final slash = path.lastIndexOf('/');
    final fileComments = review.comments.where((c) => c.path == path).length;
    final Widget body;
    if (change.omitted) {
      body = const _Centered(
        icon: Icons.unfold_less_rounded,
        title: 'Too large to show here',
        message: 'The turn changed more than fits in one review.',
      );
    } else if (change.binary || change.submodule) {
      body = _Centered(
        icon: Icons.memory_rounded,
        title: change.submodule ? 'Submodule changed' : 'Binary file changed',
        message: [
          if (change.oldSize != null) 'before ${change.oldSize} bytes',
          if (change.newSize != null) 'after ${change.newSize} bytes',
        ].join(' · '),
      );
    } else {
      body = DiffRowsList(
        rows: widget.rows,
        scrollController: _scroll,
        palette: palette,
        brightness: brightness,
        fontFamily: widget.fontFamily,
        fontSize: 12.5,
        truncated: change.truncated,
        onToggleFile: (_) {},
        isCollapsed: (_) => false,
        syntax: true,
        onTapLine: (_, line) => widget.onComment(line),
        isLineMarked: (_, line) =>
            review.commentAt(path, line.newLineNumber ?? line.oldLineNumber) !=
            null,
      );
    }
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 8),
      child: Row(
        children: [
          Icon(
            fileStatusIcon(file.diff),
            size: 20,
            color: fileStatusColor(file.diff, palette),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _basename(path),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (slash > 0)
                  Text(
                    path.substring(0, slash),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (fileComments > 0) ...[
            Icon(Icons.mode_comment_outlined, size: 16, color: palette.accent),
            Text(' $fileComments  '),
          ],
          DiffCountsLabel(
            additions: change.added,
            deletions: change.removed,
            palette: palette,
          ),
          const SizedBox(width: 8),
          _VerdictChip(verdict: file.verdict),
        ],
      ),
    );
    final actions = _DecisionBar(
      index: widget.index,
      busy: file.busy,
      canReject: review.canChange && file.verdict != FileVerdict.rejected,
      canAccept: file.verdict != FileVerdict.accepted,
      swipe: !widget.desktop,
      onAccept: widget.onAccept,
      onReject: widget.onReject,
      onComment: () => widget.onComment(null),
    );
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        const Divider(height: 1),
        Expanded(child: body),
        const Divider(height: 1),
        actions,
      ],
    );
    if (widget.desktop) return content;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: content,
    );
  }
}

/// Reject / comment / accept, at the bottom where a thumb reaches. On a
/// phone the bar also swipes: right accepts, left rejects.
class _DecisionBar extends StatelessWidget {
  const _DecisionBar({
    required this.index,
    required this.busy,
    required this.canReject,
    required this.canAccept,
    required this.swipe,
    required this.onAccept,
    required this.onReject,
    required this.onComment,
  });

  final int index;
  final bool busy;
  final bool canReject;
  final bool canAccept;
  final bool swipe;
  final VoidCallback onAccept;
  final VoidCallback onReject;
  final VoidCallback onComment;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final bar = Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              key: const ValueKey('review-reject'),
              style: OutlinedButton.styleFrom(
                foregroundColor: palette.danger,
                minimumSize: const Size.fromHeight(48),
              ),
              onPressed: busy || !canReject ? null : onReject,
              icon: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.undo_rounded),
              label: const Text('Reject'),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.outlined(
            key: const ValueKey('review-comment'),
            tooltip: 'Comment on this file',
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            onPressed: onComment,
            icon: const Icon(Icons.add_comment_outlined),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: FilledButton.icon(
              key: const ValueKey('review-accept'),
              style: FilledButton.styleFrom(
                backgroundColor: palette.success,
                minimumSize: const Size.fromHeight(48),
              ),
              onPressed: busy || !canAccept ? null : onAccept,
              icon: const Icon(Icons.check_rounded),
              label: const Text('Accept'),
            ),
          ),
        ],
      ),
    );
    if (!swipe || busy) return bar;
    Widget hint(Alignment alignment, Color color, IconData icon, String text) =>
        Container(
          color: color.withValues(alpha: 0.18),
          alignment: alignment,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color),
              const SizedBox(width: 6),
              Text(text, style: TextStyle(color: color)),
            ],
          ),
        );
    return Dismissible(
      key: ValueKey('review-swipe-$index'),
      direction: canReject
          ? DismissDirection.horizontal
          : DismissDirection.startToEnd,
      dismissThresholds: const {
        DismissDirection.startToEnd: 0.3,
        DismissDirection.endToStart: 0.3,
      },
      background: hint(
        Alignment.centerLeft,
        palette.success,
        Icons.check_rounded,
        'Accept',
      ),
      secondaryBackground: hint(
        Alignment.centerRight,
        palette.danger,
        Icons.undo_rounded,
        'Reject',
      ),
      // The bar springs back: the card stays, its verdict changes.
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.startToEnd) {
          onAccept();
        } else {
          onReject();
        }
        return false;
      },
      child: bar,
    );
  }
}

/// The last card: counts, tests, notes, and the whole-turn actions.
class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.review,
    required this.onLooksGood,
    required this.onFeedback,
    required this.onUndo,
    required this.onRedo,
  });

  final ReviewController review;
  final VoidCallback onLooksGood;
  final VoidCallback onFeedback;
  final VoidCallback onUndo;
  final VoidCallback onRedo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    final turn = review.turn;
    final diff = review.diff;
    final facts = review.facts;
    final total = review.files.length;
    final accepted = review.count(FileVerdict.accepted);
    final rejected = review.count(FileVerdict.rejected);
    final pending = review.count(FileVerdict.pending);
    final added = review.files.fold(0, (n, f) => n + f.change.added);
    final removed = review.files.fold(0, (n, f) => n + f.change.removed);
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final String tests;
    final Color? testsColor;
    if (!review.factsLoaded) {
      tests = 'Tests: loading…';
      testsColor = null;
    } else if (facts == null || facts.testRuns == 0) {
      tests = 'No test runs during this turn';
      testsColor = null;
    } else {
      final last = switch (facts.lastTestPassed) {
        true => ' · last run passed',
        false => ' · last run failed',
        null => '',
      };
      tests =
          'Tests: ${facts.testRuns} ${facts.testRuns == 1 ? 'run' : 'runs'}, '
          '${facts.testsPassed} passed, ${facts.testsFailed} failed$last';
      testsColor = facts.lastTestPassed == false
          ? palette.danger
          : facts.lastTestPassed == true
          ? palette.success
          : null;
    }
    final notes = <String>[
      if (turn?.running ?? diff?.live ?? false)
        'The turn is still running: this is the work tree now.',
      if (diff?.committed ?? turn?.committed ?? false)
        'The agent committed during this turn. Undo restores files only and '
            'refuses while HEAD has moved.',
      if (diff?.late ?? false)
        'An edit may have landed before the snapshot was taken.',
      if ((diff?.others ?? const []).isNotEmpty)
        'Another agent worked in this repository meanwhile; undoing the turn '
            'also reverts its changes.',
      if (diff?.truncated ?? false) 'Some files were too large to show fully.',
      if (review.undone) 'This turn is undone.',
    ];
    final wholeTurn = review.snapshots && review.turn != null;
    return Card(
      key: const ValueKey('review-summary'),
      margin: EdgeInsets.zero,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
        children: [
          Text(
            review.done
                ? (review.feedbackSent ? 'Feedback sent' : 'Reviewed')
                : 'Summary',
            style: theme.textTheme.titleLarge,
          ),
          if (turn != null && turn.prompt.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text('“${turn.prompt}”', style: muted),
          ],
          const SizedBox(height: 14),
          Text(
            total == 0
                ? 'No files changed.'
                : '${_files(total)} · +$added −$removed',
            style: theme.textTheme.titleSmall,
          ),
          if (total > 0) ...[
            const SizedBox(height: 4),
            Text(
              '$accepted accepted · $rejected reverted · $pending to review',
              key: const ValueKey('review-counts'),
              style: muted,
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(Icons.science_outlined, size: 18, color: testsColor),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  tests,
                  key: const ValueKey('review-tests'),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: testsColor,
                  ),
                ),
              ),
            ],
          ),
          if (review.comments.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              '${review.comments.length} '
              '${review.comments.length == 1 ? 'comment' : 'comments'} '
              'go with the feedback',
              style: muted,
            ),
          ],
          for (final note in notes) ...[
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline_rounded, size: 16, color: muted?.color),
                const SizedBox(width: 6),
                Expanded(child: Text(note, style: muted)),
              ],
            ),
          ],
          const SizedBox(height: 20),
          FilledButton.icon(
            key: const ValueKey('review-looks-good'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(50),
            ),
            onPressed: review.undoing ? null : onLooksGood,
            icon: const Icon(Icons.thumb_up_alt_outlined),
            label: const Text('Looks good'),
          ),
          const SizedBox(height: 10),
          FilledButton.tonalIcon(
            key: const ValueKey('review-send-feedback'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(50),
            ),
            onPressed: review.sending ? null : onFeedback,
            icon: const Icon(Icons.rate_review_outlined),
            label: Text(review.sending ? 'Sending…' : 'Send feedback'),
          ),
          if (wholeTurn) ...[
            const SizedBox(height: 10),
            if (review.redoAvailable)
              OutlinedButton.icon(
                key: const ValueKey('review-redo'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(50),
                ),
                onPressed: review.undoing ? null : onRedo,
                icon: const Icon(Icons.redo_rounded),
                label: const Text('Redo (put the changes back)'),
              ),
            if (review.redoAvailable && !review.undone)
              const SizedBox(height: 10),
            if (!review.undone)
              OutlinedButton.icon(
                key: const ValueKey('review-undo-turn'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: palette.danger,
                  minimumSize: const Size.fromHeight(50),
                ),
                onPressed: review.undoing ? null : onUndo,
                icon: review.undoing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.undo_rounded),
                label: const Text('Undo this turn'),
              ),
          ],
        ],
      ),
    );
  }
}

/// "Undo this turn?" with what it changes (a dry run).
class _UndoDialog extends StatefulWidget {
  const _UndoDialog({required this.review});

  final ReviewController review;

  @override
  State<_UndoDialog> createState() => _UndoDialogState();
}

class _UndoDialogState extends State<_UndoDialog> {
  late final Future<UndoOutcome?> _preview = widget.review.previewUndo();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Undo this turn?'),
      content: FutureBuilder<UndoOutcome?>(
        future: _preview,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const SizedBox(
              height: 60,
              child: Center(child: CircularProgressIndicator()),
            );
          }
          final preview = snapshot.data;
          if (preview == null) {
            return Text(
              widget.review.message ?? 'Could not check what would change.',
            );
          }
          final restored = preview.restored;
          return ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 320),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    restored.isEmpty
                        ? 'Nothing differs from before the turn.'
                        : 'The files go back to how they were before the '
                              'turn. Commits, branches and the index are not '
                              'touched, and the current state is saved so you '
                              'can redo.',
                  ),
                  if (preview.laterTurns.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Later turns (${preview.laterTurns.join(', ')}) are '
                      'undone too.',
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ],
                  const SizedBox(height: 8),
                  for (final file in restored.take(12))
                    Text(
                      '${file.deleted ? 'delete' : 'restore'} ${file.path}',
                      style: theme.textTheme.bodySmall,
                    ),
                  if (restored.length > 12)
                    Text(
                      '… and ${restored.length - 12} more',
                      style: theme.textTheme.bodySmall,
                    ),
                ],
              ),
            ),
          );
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FutureBuilder<UndoOutcome?>(
          future: _preview,
          builder: (context, snapshot) => FilledButton(
            key: const ValueKey('review-undo-confirm'),
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.error,
              foregroundColor: theme.colorScheme.onError,
            ),
            onPressed:
                snapshot.connectionState == ConnectionState.done &&
                    (snapshot.data?.restored.isNotEmpty ?? false)
                ? () => Navigator.of(context).pop(true)
                : null,
            child: const Text('Undo'),
          ),
        ),
      ],
    );
  }
}

/// A text field with dictation, for a comment or the feedback prompt.
class _TextSheet extends StatefulWidget {
  const _TextSheet({
    required this.title,
    required this.initial,
    required this.hint,
    required this.action,
    this.quote,
    this.dictation,
    this.onDelete,
    this.preview,
    this.allowEmpty = false,
    super.key,
  });

  final String title;
  final String initial;
  final String hint;
  final String action;

  /// The line commented on.
  final String? quote;
  final DictationController? dictation;
  final VoidCallback? onDelete;

  /// What will be sent for the text (the feedback prompt).
  final String Function(String text)? preview;

  /// Sending with no text is fine (there are comments or reverts).
  final bool allowEmpty;

  @override
  State<_TextSheet> createState() => _TextSheetState();
}

class _TextSheetState extends State<_TextSheet> {
  late final _text = TextEditingController(text: widget.initial);
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _text.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dictation = widget.dictation;
    final canSend = widget.allowEmpty || _text.text.trim().isNotEmpty;
    final preview = widget.preview?.call(_text.text) ?? '';
    return Padding(
      padding: EdgeInsets.only(
        left: 18,
        right: 18,
        top: 16,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.title, style: theme.textTheme.titleMedium),
          if (widget.quote case final quote? when quote.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              quote,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: AppTheme.monoFontFamily,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('review-text-field'),
                  controller: _text,
                  focusNode: _focus,
                  autofocus: dictation == null,
                  minLines: 2,
                  maxLines: 6,
                  textInputAction: TextInputAction.newline,
                  decoration: InputDecoration(
                    hintText: widget.hint,
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
              if (dictation != null) ...[
                const SizedBox(width: 6),
                DictationButton(
                  controller: dictation,
                  textController: _text,
                  focusNode: _focus,
                ),
              ],
            ],
          ),
          if (preview.isNotEmpty && preview != _text.text.trim()) ...[
            const SizedBox(height: 10),
            Text('The agent gets:', style: theme.textTheme.labelMedium),
            const SizedBox(height: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 140),
              child: SingleChildScrollView(
                child: Text(
                  preview,
                  key: const ValueKey('review-feedback-preview'),
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              if (widget.onDelete case final delete?)
                TextButton(onPressed: delete, child: const Text('Delete')),
              const Spacer(),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                key: const ValueKey('review-text-submit'),
                onPressed: canSend
                    ? () => Navigator.of(context).pop(_text.text)
                    : null,
                child: Text(widget.action),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
