// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:conduit/core/app_failure.dart';
import 'package:conduit/features/agents_digest/domain/agents_digest.dart';
import 'package:conduit/features/diff_view/domain/git_diff_source.dart';
import 'package:conduit/features/diff_view/domain/unified_diff.dart';
import 'package:conduit/features/review/data/review_client.dart';
import 'package:conduit/features/review/domain/turn_review.dart';
import 'package:flutter/foundation.dart';

/// Where Review is.
enum ReviewPhase {
  loading,
  ready,

  /// Nothing to review: no turn with a snapshot yet (see [message]).
  empty,
  failed,
}

/// The user's call on one file.
enum FileVerdict { pending, accepted, rejected }

/// One file card.
class ReviewFile {
  ReviewFile(this.change, this.diff);

  final TurnFileDiff change;

  /// The card's diff, as the diff view renders it.
  final DiffFile diff;
  FileVerdict verdict = FileVerdict.pending;

  /// A reject (per-file undo) is on its way.
  bool busy = false;

  String get path => change.path;
}

/// Sends the feedback prompt to the agent (Chat View's send, or the
/// companion's `send`).
typedef ReviewSend = Future<void> Function(String text);

/// Review mode for one agent turn: a card per changed file (accept, or
/// reject = revert that file), line comments, and for the whole turn
/// "Looks good", "Undo this turn" (with redo) and "Send feedback".
///
/// With a companion that has no `snapshots` ([snapshots] false) it shows
/// the working tree's `git diff` instead ([fallback]), read-only: nothing
/// can be undone and [needsUpdate] says so.
class ReviewController extends ChangeNotifier {
  ReviewController({
    required ConductoreReviewClient client,
    required this.sessionId,
    required this.agentName,
    required ReviewSend send,
    this.turnNumber,
    this.snapshots = true,
    this.fallback,
    this.fallbackPath,
    Future<void> Function()? onClose,
  }) : _client = client,
       _send = send,
       _onClose = onClose;

  final ConductoreReviewClient _client;
  final ReviewSend _send;
  final Future<void> Function()? _onClose;
  final String sessionId;
  final String agentName;

  /// The turn to review; null: the newest one with a snapshot.
  final int? turnNumber;

  /// The companion reports the `snapshots` capability.
  final bool snapshots;

  /// The working tree's diff for an older companion, at [fallbackPath].
  final GitDiffSource? fallback;
  final String? fallbackPath;

  ReviewPhase _phase = ReviewPhase.loading;
  String? _message;
  AgentTurn? _turn;
  TurnDiff? _diff;
  List<ReviewFile> _files = const [];
  DigestFacts? _facts;
  bool _factsLoaded = false;
  int _index = 0;
  final List<ReviewComment> _comments = [];
  bool _undoing = false;
  bool _undone = false;
  bool _redoAvailable = false;
  bool _sending = false;
  bool _feedbackSent = false;
  bool _done = false;
  bool _disposed = false;

  ReviewPhase get phase => _phase;

  /// Why Review is empty or failed, or the last action's problem.
  String? get message => _message;

  /// Read-only fallback: the companion predates snapshots.
  bool get needsUpdate => !snapshots;
  AgentTurn? get turn => _turn;
  TurnDiff? get diff => _diff;
  List<ReviewFile> get files => _files;

  /// The digest's facts for the turn's time (its tests); null unknown.
  DigestFacts? get facts => _facts;
  bool get factsLoaded => _factsLoaded;

  /// The card on screen: 0 to files.length - 1, files.length = summary.
  int get index => _index;
  bool get onSummary => _index >= _files.length;
  ReviewFile? get current => onSummary ? null : _files[_index];

  List<ReviewComment> get comments => List.unmodifiable(_comments);
  bool get undoing => _undoing;

  /// The whole turn was undone here.
  bool get undone => _undone;
  bool get redoAvailable => _redoAvailable;
  bool get sending => _sending;
  bool get feedbackSent => _feedbackSent;

  /// "Looks good" or feedback sent: the review is finished.
  bool get done => _done;

  /// Accept, reject and undo need the companion's snapshots.
  bool get canChange => snapshots && _diff != null && !_undone;

  int count(FileVerdict verdict) =>
      _files.where((f) => f.verdict == verdict).length;
  List<String> get rejectedPaths => [
    for (final f in _files)
      if (f.verdict == FileVerdict.rejected) f.path,
  ];

  // --- loading ----------------------------------------------------------------

  Future<void> load() async {
    _phase = ReviewPhase.loading;
    _message = null;
    _notify();
    try {
      if (!snapshots) {
        await _loadFallback();
        return;
      }
      final list = await _client.turns(sessionId);
      final turn = turnNumber == null ? list.latest : list.turn(turnNumber!);
      if (turn == null) {
        _phase = ReviewPhase.empty;
        _message = _emptyReason(list);
        _notify();
        return;
      }
      _turn = turn;
      _undone = turn.undone && turn.undoneWholeTurn;
      _redoAvailable = turn.undone;
      final diff = await _client.diff(sessionId, turn.turn);
      _setDiff(diff);
      unawaited(_loadFacts(turn));
    } on ReviewUnsupported {
      _phase = ReviewPhase.failed;
      _message = const ReviewUnsupported().toString();
      _notify();
    } on Object catch (error) {
      _phase = ReviewPhase.failed;
      _message = _describe(error);
      _notify();
    }
  }

  static String _emptyReason(TurnList list) {
    final newest = list.turns.firstOrNull;
    if (newest == null) {
      return 'No turns recorded yet. Snapshots start with the next prompt.';
    }
    final skipped = newest.before?.skipped;
    if (skipped != null) return 'No snapshot for the last turn: $skipped.';
    return 'The last turn has no snapshot yet.';
  }

  void _setDiff(TurnDiff diff) {
    _diff = diff;
    _files = [for (final f in diff.files) ReviewFile(f, f.toDiffFile())];
    _index = 0;
    _phase = _files.isEmpty && diff.live
        ? ReviewPhase.empty
        : ReviewPhase.ready;
    if (_files.isEmpty && diff.live) _message = 'No changes yet.';
    _notify();
  }

  Future<void> _loadFacts(AgentTurn turn) async {
    final since = turn.startedAt;
    if (since != null) {
      _facts = await _client.facts(sessionId, since);
    }
    _factsLoaded = true;
    _notify();
  }

  Future<void> _loadFallback() async {
    final source = fallback;
    final path = fallbackPath;
    if (source == null || path == null || path.isEmpty) {
      _phase = ReviewPhase.failed;
      _message = const ReviewUnsupported().toString();
      _notify();
      return;
    }
    final snapshot = await source.load(path);
    if (!snapshot.isGitRepository) {
      _phase = ReviewPhase.empty;
      _message = 'Not a git repository: $path';
      _notify();
      return;
    }
    // Staged and unstaged together, one card per path.
    final byPath = <String, DiffFile>{};
    for (final file in [...snapshot.staged.files, ...snapshot.unstaged.files]) {
      byPath[file.displayPath] = file;
    }
    _files = [
      for (final file in byPath.values)
        ReviewFile(
          TurnFileDiff(
            path: file.displayPath,
            status: switch (file.status) {
              DiffFileStatus.added => TurnFileStatus.added,
              DiffFileStatus.deleted => TurnFileStatus.deleted,
              _ => TurnFileStatus.modified,
            },
            added: file.additions,
            removed: file.deletions,
            binary: file.binary,
          ),
          file,
        ),
    ];
    _phase = _files.isEmpty ? ReviewPhase.empty : ReviewPhase.ready;
    if (_files.isEmpty) _message = 'No uncommitted changes.';
    _factsLoaded = true;
    _notify();
  }

  // --- navigation -------------------------------------------------------------

  void goTo(int index) {
    final next = index.clamp(0, _files.length);
    if (next == _index) return;
    _index = next;
    _notify();
  }

  void next() => goTo(_index + 1);
  void previous() => goTo(_index - 1);

  /// The next card still pending after [from], else the summary.
  int _nextPending(int from) {
    for (var i = from + 1; i < _files.length; i++) {
      if (_files[i].verdict == FileVerdict.pending) return i;
    }
    return _files.length;
  }

  // --- per file ------------------------------------------------------------------

  /// Marks the file reviewed and moves on.
  void accept(int index) {
    final file = _files.elementAtOrNull(index);
    if (file == null || file.busy) return;
    file.verdict = FileVerdict.accepted;
    _index = _nextPending(index);
    _notify();
  }

  /// Reverts this file only (the companion's `undo --file`), then moves on.
  Future<bool> reject(int index) async {
    final file = _files.elementAtOrNull(index);
    final turn = _turn;
    if (file == null || file.busy || turn == null || !canChange) return false;
    file.busy = true;
    _message = null;
    _notify();
    try {
      await _client.undo(sessionId, turn.turn, files: [file.path]);
      file.verdict = FileVerdict.rejected;
      _redoAvailable = true;
      if (_index == index) _index = _nextPending(index);
      return true;
    } on Object catch (error) {
      _message = _describe(error);
      return false;
    } finally {
      file.busy = false;
      _notify();
    }
  }

  void addComment(ReviewComment comment) {
    if (comment.text.trim().isEmpty) return;
    _comments.removeWhere(
      (c) => c.path == comment.path && c.line == comment.line,
    );
    _comments.add(comment);
    _notify();
  }

  void removeComment(ReviewComment comment) {
    _comments.remove(comment);
    _notify();
  }

  ReviewComment? commentAt(String path, int? line) =>
      _comments.where((c) => c.path == path && c.line == line).firstOrNull;

  // --- the whole turn -------------------------------------------------------------

  /// "Looks good": every pending file accepted; the review is done.
  void looksGood() {
    for (final f in _files) {
      if (f.verdict == FileVerdict.pending) f.verdict = FileVerdict.accepted;
    }
    _done = true;
    _index = _files.length;
    _notify();
  }

  /// What "Undo this turn" would change (a dry run), for the confirmation.
  Future<UndoOutcome?> previewUndo() async {
    final turn = _turn;
    if (turn == null || !snapshots) return null;
    try {
      return await _client.undo(sessionId, turn.turn, dryRun: true);
    } on Object catch (error) {
      _message = _describe(error);
      _notify();
      return null;
    }
  }

  /// Restores the work tree to before the turn. The companion saved the
  /// current state first, so [redo] can put it back.
  Future<UndoOutcome?> undoTurn() async {
    final turn = _turn;
    if (turn == null || !snapshots || _undoing) return null;
    _undoing = true;
    _message = null;
    _notify();
    try {
      final outcome = await _client.undo(sessionId, turn.turn);
      _undone = true;
      _redoAvailable = outcome.redoAvailable;
      for (final f in _files) {
        f.verdict = FileVerdict.rejected;
      }
      _index = _files.length;
      return outcome;
    } on Object catch (error) {
      _message = _describe(error);
      return null;
    } finally {
      _undoing = false;
      _notify();
    }
  }

  /// Puts back what the last undo of this turn changed.
  Future<UndoOutcome?> redo() async {
    final turn = _turn;
    if (turn == null || !snapshots || _undoing) return null;
    _undoing = true;
    _message = null;
    _notify();
    try {
      final outcome = await _client.redo(sessionId, turn.turn);
      _undone = false;
      _redoAvailable = false;
      final back = {for (final r in outcome.restored) r.path};
      for (final f in _files) {
        if (back.contains(f.path)) f.verdict = FileVerdict.pending;
      }
      return outcome;
    } on Object catch (error) {
      _message = _describe(error);
      return null;
    } finally {
      _undoing = false;
      _notify();
    }
  }

  /// The prompt [sendFeedback] would type for [text].
  String feedbackPrompt(String text) => reviewFeedbackPrompt(
    text: text,
    comments: _comments,
    rejected: rejectedPaths,
  );

  /// Types the feedback (with the files and lines commented on) into the
  /// agent as its next prompt.
  Future<bool> sendFeedback(String text) async {
    final prompt = feedbackPrompt(text);
    if (prompt.isEmpty || _sending) return false;
    _sending = true;
    _message = null;
    _notify();
    try {
      await _send(prompt);
      _feedbackSent = true;
      _done = true;
      _comments.clear();
      return true;
    } on Object catch (error) {
      _message = 'Could not send: ${_describe(error)}';
      return false;
    } finally {
      _sending = false;
      _notify();
    }
  }

  static String _describe(Object error) => switch (error) {
    AppFailure(:final userMessage) => userMessage,
    _ => '$error',
  };

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    final close = _onClose;
    if (close != null) unawaited(close());
    super.dispose();
  }
}
