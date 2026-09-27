import 'dart:convert';

import 'package:conduit/features/diff_view/domain/unified_diff.dart';

DateTime? _time(Object? raw) =>
    raw is num ? DateTime.fromMillisecondsSinceEpoch(raw.toInt()) : null;

int _int(Object? raw) => raw is num ? raw.toInt() : 0;

String? _text(Object? raw) =>
    raw is String && raw.trim().isNotEmpty ? raw.trim() : null;

Map<Object?, Object?>? _lastJson(String stdout) {
  final lines = stdout.trim().split('\n');
  if (lines.isEmpty || lines.last.trim().isEmpty) return null;
  try {
    final decoded = jsonDecode(lines.last);
    return decoded is Map ? decoded : null;
  } on FormatException {
    return null;
  }
}

/// One snapshot of a turn (before or after), or why there is none.
class TurnSnapshot {
  const TurnSnapshot({this.commit, this.skipped, this.fromNext = false});

  final String? commit;

  /// Why no snapshot was taken ("repo too large", "not a git repo", ...).
  final String? skipped;

  /// The turn was interrupted: its end is the next turn's start.
  final bool fromNext;

  bool get ok => commit != null;

  static TurnSnapshot? fromJson(Object? raw) {
    if (raw is! Map) return null;
    return TurnSnapshot(
      commit: _text(raw['commit']),
      skipped: _text(raw['skipped']),
      fromNext: raw['fromNext'] == true,
    );
  }
}

/// How one path changed in a turn.
enum TurnFileStatus {
  added('A'),
  modified('M'),
  deleted('D'),
  typeChanged('T');

  const TurnFileStatus(this.code);

  final String code;

  static TurnFileStatus parse(Object? raw) => TurnFileStatus.values.firstWhere(
    (s) => s.code == raw,
    orElse: () => TurnFileStatus.modified,
  );
}

/// One path of a turn's file list (`turns`).
class TurnFileSummary {
  const TurnFileSummary({
    required this.path,
    required this.status,
    this.added = 0,
    this.removed = 0,
    this.binary = false,
  });

  final String path;
  final TurnFileStatus status;
  final int added;
  final int removed;
  final bool binary;

  static TurnFileSummary? fromJson(Object? raw) {
    if (raw is! Map || _text(raw['path']) == null) return null;
    return TurnFileSummary(
      path: raw['path'] as String,
      status: TurnFileStatus.parse(raw['status']),
      added: _int(raw['added']),
      removed: _int(raw['removed']),
      binary: raw['binary'] == true,
    );
  }
}

/// One agent turn as `conductore-hostd turns` lists it.
class AgentTurn {
  const AgentTurn({
    required this.turn,
    this.prompt = '',
    this.startedAt,
    this.endedAt,
    this.running = false,
    this.repo,
    this.files = const [],
    this.filesTotal,
    this.added,
    this.removed,
    this.committed = false,
    this.late = false,
    this.before,
    this.after,
    this.others = const [],
    this.undoneAt,
    this.undoneWholeTurn = false,
  });

  final int turn;

  /// The prompt's first line.
  final String prompt;
  final DateTime? startedAt;
  final DateTime? endedAt;
  final bool running;
  final String? repo;

  /// The changed paths (at most 50; [filesTotal] counts all), null until
  /// both snapshots are in.
  final List<TurnFileSummary> files;
  final int? filesTotal;
  final int? added;
  final int? removed;

  /// HEAD moved during the turn (the agent committed).
  final bool committed;

  /// An edit may have landed before the "before" snapshot.
  final bool late;
  final TurnSnapshot? before;
  final TurnSnapshot? after;

  /// Other sessions working in the same repo meanwhile.
  final List<String> others;

  /// The last undo of this turn, while it is not redone.
  final DateTime? undoneAt;
  final bool undoneWholeTurn;

  bool get canReview => before?.ok ?? false;
  bool get undone => undoneAt != null;
  int get fileCount => filesTotal ?? files.length;

  static AgentTurn? fromJson(Object? raw) {
    if (raw is! Map || raw['turn'] is! num) return null;
    final files = raw['files'];
    final others = raw['others'];
    final undone = raw['undone'];
    return AgentTurn(
      turn: _int(raw['turn']),
      prompt: _text(raw['prompt']) ?? '',
      startedAt: _time(raw['startedAt']),
      endedAt: _time(raw['endedAt']),
      running: raw['running'] == true,
      repo: _text(raw['repo']),
      files: [
        if (files is List)
          for (final file in files) ?TurnFileSummary.fromJson(file),
      ],
      filesTotal: raw['filesTotal'] is num ? _int(raw['filesTotal']) : null,
      added: raw['added'] is num ? _int(raw['added']) : null,
      removed: raw['removed'] is num ? _int(raw['removed']) : null,
      committed: raw['committed'] == true,
      late: raw['late'] == true,
      before: TurnSnapshot.fromJson(raw['before']),
      after: TurnSnapshot.fromJson(raw['after']),
      others: [
        if (others is List)
          for (final other in others)
            if (other is String) other,
      ],
      undoneAt: undone is Map ? _time(undone['at']) : null,
      undoneWholeTurn: undone is Map && undone['kind'] == 'turn',
    );
  }
}

/// `turns <sessionId>`: newest first.
class TurnList {
  const TurnList({
    required this.sessionId,
    this.turns = const [],
    this.agentState,
    this.pending = 0,
  });

  final String sessionId;
  final List<AgentTurn> turns;

  /// `working`, `waiting_input`, `needs_permission`, `ended`, or null
  /// when the companion no longer knows the agent.
  final String? agentState;

  /// Snapshots still queued on the machine.
  final int pending;

  /// The newest turn that can be reviewed.
  AgentTurn? get latest => turns.where((t) => t.canReview).firstOrNull;

  AgentTurn? turn(int n) => turns.where((t) => t.turn == n).firstOrNull;

  bool get agentBusy =>
      agentState == 'working' || agentState == 'needs_permission';

  static TurnList? parse(String stdout) {
    final raw = _lastJson(stdout);
    if (raw == null || raw['error'] != null || raw['turns'] is! List) {
      return null;
    }
    final agent = raw['agent'];
    return TurnList(
      sessionId: _text(raw['sessionId']) ?? '',
      turns: [
        for (final turn in raw['turns'] as List) ?AgentTurn.fromJson(turn),
      ],
      agentState: agent is Map ? _text(agent['state']) : null,
      pending: _int(raw['pending']),
    );
  }
}

/// One file of a turn's diff (`diff`): its card in Review.
class TurnFileDiff {
  const TurnFileDiff({
    required this.path,
    required this.status,
    this.added = 0,
    this.removed = 0,
    this.binary = false,
    this.submodule = false,
    this.patch,
    this.truncated = false,
    this.omitted = false,
    this.oldSize,
    this.newSize,
  });

  final String path;
  final TurnFileStatus status;
  final int added;
  final int removed;
  final bool binary;
  final bool submodule;

  /// The hunks (from the first `@@`), or null for binaries, submodules and
  /// files left out by the size cap ([omitted]).
  final String? patch;
  final bool truncated;
  final bool omitted;
  final int? oldSize;
  final int? newSize;

  static TurnFileDiff? fromJson(Object? raw) {
    if (raw is! Map || _text(raw['path']) == null) return null;
    return TurnFileDiff(
      path: raw['path'] as String,
      status: TurnFileStatus.parse(raw['status']),
      added: _int(raw['added']),
      removed: _int(raw['removed']),
      binary: raw['binary'] == true,
      submodule: raw['submodule'] == true,
      patch: raw['patch'] is String ? raw['patch'] as String : null,
      truncated: raw['truncated'] == true,
      omitted: raw['omitted'] == true,
      oldSize: raw['oldSize'] is num ? _int(raw['oldSize']) : null,
      newSize: raw['newSize'] is num ? _int(raw['newSize']) : null,
    );
  }

  /// The file as the diff view renders it: the patch under a synthetic
  /// `diff --git` header, so [UnifiedDiff.parse] numbers the lines.
  DiffFile toDiffFile() {
    final header = StringBuffer('diff --git a/$path b/$path\n');
    if (status == TurnFileStatus.added) header.write('new file mode 100644\n');
    if (status == TurnFileStatus.deleted) {
      header.write('deleted file mode 100644\n');
    }
    header
      ..write(
        status == TurnFileStatus.added ? '--- /dev/null\n' : '--- a/$path\n',
      )
      ..write(
        status == TurnFileStatus.deleted ? '+++ /dev/null\n' : '+++ b/$path\n',
      );
    final parsed = UnifiedDiff.parse('$header${patch ?? ''}').files;
    final file = parsed.isEmpty
        ? DiffFile(
            oldPath: path,
            newPath: path,
            status: DiffFileStatus.modified,
            hunks: const [],
          )
        : parsed.first;
    if (!binary && !submodule) return file;
    return DiffFile(
      oldPath: file.oldPath,
      newPath: file.newPath,
      status: file.status,
      hunks: const [],
      binary: true,
    );
  }
}

/// `diff <sessionId> <turn>`.
class TurnDiff {
  const TurnDiff({
    required this.turn,
    this.prompt = '',
    this.repo,
    this.live = false,
    this.committed = false,
    this.late = false,
    this.others = const [],
    this.files = const [],
    this.truncated = false,
    this.startedAt,
    this.endedAt,
  });

  final int turn;
  final String prompt;
  final String? repo;

  /// Compared with the work tree now (the turn is still running).
  final bool live;
  final bool committed;
  final bool late;
  final List<String> others;
  final List<TurnFileDiff> files;
  final bool truncated;
  final DateTime? startedAt;
  final DateTime? endedAt;

  int get added => files.fold(0, (n, f) => n + f.added);
  int get removed => files.fold(0, (n, f) => n + f.removed);

  static TurnDiff? parse(String stdout) {
    final raw = _lastJson(stdout);
    if (raw == null || raw['error'] != null || raw['files'] is! List) {
      return null;
    }
    final others = raw['others'];
    return TurnDiff(
      turn: _int(raw['turn']),
      prompt: _text(raw['prompt']) ?? '',
      repo: _text(raw['repo']),
      live: raw['live'] == true,
      committed: raw['committed'] == true,
      late: raw['late'] == true,
      others: [
        if (others is List)
          for (final other in others)
            if (other is String) other,
      ],
      files: [
        for (final file in raw['files'] as List) ?TurnFileDiff.fromJson(file),
      ],
      truncated: raw['truncated'] == true,
      startedAt: _time(raw['startedAt']),
      endedAt: _time(raw['endedAt']),
    );
  }
}

/// One path an undo (or redo) wrote or deleted.
class RestoredFile {
  const RestoredFile({required this.path, required this.deleted});

  final String path;
  final bool deleted;
}

/// What `undo` / `redo` did (or, dry, would do).
class UndoOutcome {
  const UndoOutcome({
    this.restored = const [],
    this.skipped = const [],
    this.dryRun = false,
    this.redoAvailable = false,
    this.staged = const [],
    this.laterTurns = const [],
    this.headMoved = false,
  });

  final List<RestoredFile> restored;

  /// Paths left alone, with why ("submodule", ...).
  final List<({String path, String reason})> skipped;
  final bool dryRun;

  /// The state before the undo was saved; `redo` puts it back.
  final bool redoAvailable;

  /// Restored files the index still stages changes to.
  final List<String> staged;

  /// Later turns the whole-turn undo also rolled back.
  final List<int> laterTurns;
  final bool headMoved;

  static UndoOutcome? parse(String stdout) {
    final raw = _lastJson(stdout);
    if (raw == null || raw['ok'] != true) return null;
    final restored = raw['restored'];
    final skipped = raw['skipped'];
    final staged = raw['staged'];
    final later = raw['laterTurns'];
    return UndoOutcome(
      restored: [
        if (restored is List)
          for (final r in restored)
            if (r is Map && r['path'] is String)
              RestoredFile(
                path: r['path'] as String,
                deleted: r['action'] == 'delete',
              ),
      ],
      skipped: [
        if (skipped is List)
          for (final s in skipped)
            if (s is Map && s['path'] is String)
              (path: s['path'] as String, reason: _text(s['reason']) ?? ''),
      ],
      dryRun: raw['dryRun'] == true,
      redoAvailable: raw['redo'] is Map,
      staged: [
        if (staged is List)
          for (final s in staged)
            if (s is String) s,
      ],
      laterTurns: [
        if (later is List)
          for (final n in later)
            if (n is num) n.toInt(),
      ],
      headMoved: raw['headMoved'] == true,
    );
  }
}

/// A comment on one line (or the whole file when [line] is null) of a
/// reviewed file, for the feedback prompt.
class ReviewComment {
  const ReviewComment({required this.path, required this.text, this.line});

  final String path;

  /// The line in the new version (the old one for a deleted line).
  final int? line;
  final String text;
}

/// The prompt "Send feedback" types into the agent: what was rejected
/// (and so reverted), the line comments, and the typed or dictated text.
String reviewFeedbackPrompt({
  required String text,
  List<ReviewComment> comments = const [],
  List<String> rejected = const [],
}) {
  final out = StringBuffer();
  final general = text.trim();
  if (general.isNotEmpty) out.writeln(general);
  if (rejected.isNotEmpty) {
    if (out.isNotEmpty) out.writeln();
    out.writeln(
      rejected.length == 1
          ? 'I reverted your change to ${rejected.single}.'
          : 'I reverted your changes to: ${rejected.join(', ')}.',
    );
  }
  if (comments.isNotEmpty) {
    if (out.isNotEmpty) out.writeln();
    out.writeln('Review comments:');
    for (final c in comments) {
      final where = c.line == null ? c.path : '${c.path}:${c.line}';
      out.writeln('- $where: ${c.text.trim()}');
    }
  }
  return out.toString().trim();
}
