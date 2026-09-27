import 'dart:convert';

import 'package:conduit/core/app_failure.dart';
import 'package:conduit/features/agent_attention/data/conductore_host_attention_provider.dart';
import 'package:conduit/features/agent_attention/data/remote_tool_command.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/agents_digest/domain/agents_digest.dart';
import 'package:conduit/features/review/domain/turn_review.dart';

/// A companion refusal with its `code` (`busy`: the agent works;
/// `head-moved`: HEAD moved since the turn started).
class ReviewRefused extends AppFailure {
  const ReviewRefused(super.message, {this.code});

  final String? code;

  bool get busy => code == 'busy';
  bool get headMoved => code == 'head-moved';
}

/// The companion on this machine predates snapshots (`unknown command`).
class ReviewUnsupported implements Exception {
  const ReviewUnsupported();

  @override
  String toString() =>
      'The Conductore companion on this machine predates Review. Update the '
      'agent hooks (run host/install.sh again) to review and undo turns.';
}

/// Review mode's side of the companion contract (`host/README.md`, "Turn
/// snapshots"): `turns`, `diff`, `undo`, `redo`, and a `digest` limited to
/// one turn for the test results.
class ConductoreReviewClient {
  const ConductoreReviewClient(this._runner);

  final AgentCommandRunner _runner;

  static const _listTimeout = Duration(seconds: 15);

  /// `diff` and `undo` first wait (up to 25 s) for the turn's queued
  /// snapshots.
  static const _diffTimeout = Duration(seconds: 50);
  static const _undoTimeout = Duration(seconds: 70);

  static String _q(String value) => shellQuoteArgument(value);

  static String _files(List<String> files) =>
      files.map((f) => ' --file ${_q(f)}').join();

  static String turnsCommand(String sessionId, {int limit = 20}) =>
      ConductoreHostAttentionProvider.remoteCommand(
        'turns ${_q(sessionId)} --limit $limit',
      );

  static String diffCommand(
    String sessionId,
    int turn, {
    List<String> files = const [],
  }) => ConductoreHostAttentionProvider.remoteCommand(
    'diff ${_q(sessionId)} $turn${_files(files)}',
  );

  static String undoCommand(
    String sessionId,
    int turn, {
    List<String> files = const [],
    bool dryRun = false,
  }) => ConductoreHostAttentionProvider.remoteCommand(
    'undo ${_q(sessionId)} $turn${_files(files)}${dryRun ? ' --dry-run' : ''}',
  );

  static String redoCommand(String sessionId, int turn) =>
      ConductoreHostAttentionProvider.remoteCommand(
        'redo ${_q(sessionId)} $turn',
      );

  static String digestCommand(DateTime since) =>
      ConductoreHostAttentionProvider.remoteCommand(
        'digest --since ${since.millisecondsSinceEpoch}',
      );

  Future<TurnList> turns(String sessionId, {int limit = 20}) async {
    final out = await _run(turnsCommand(sessionId, limit: limit), _listTimeout);
    return TurnList.parse(out) ?? (throw _shape('turn list'));
  }

  Future<TurnDiff> diff(
    String sessionId,
    int turn, {
    List<String> files = const [],
  }) async {
    final out = await _run(
      diffCommand(sessionId, turn, files: files),
      _diffTimeout,
    );
    return TurnDiff.parse(out) ?? (throw _shape('diff'));
  }

  /// Restores the work tree (or [files]) to before [turn].
  Future<UndoOutcome> undo(
    String sessionId,
    int turn, {
    List<String> files = const [],
    bool dryRun = false,
  }) async {
    final out = await _run(
      undoCommand(sessionId, turn, files: files, dryRun: dryRun),
      _undoTimeout,
    );
    return UndoOutcome.parse(out) ?? (throw _shape('undo'));
  }

  Future<UndoOutcome> redo(String sessionId, int turn) async {
    final out = await _run(redoCommand(sessionId, turn), _undoTimeout);
    return UndoOutcome.parse(out) ?? (throw _shape('redo'));
  }

  /// The agent's facts since [since] (its tests); null when the companion
  /// has no `digest` or the agent is not in it.
  Future<DigestFacts?> facts(String sessionId, DateTime since) async {
    try {
      final result = await _runner.run(
        digestCommand(since),
        timeout: _listTimeout,
      );
      final report = parseDigestReport(result.stdout, hostId: '', hostName: '');
      return report?.agents
          .where((a) => a.sessionId == sessionId)
          .firstOrNull
          ?.facts;
    } on Object {
      return null;
    }
  }

  static AppFailure _shape(String what) => AppFailure(
    'The Conductore companion returned a $what in an unexpected shape.',
  );

  Future<String> _run(String command, Duration timeout) async {
    final result = await _runner.run(command, timeout: timeout);
    final stderr = result.stderr.trim();
    if (result.exitCode == 127 ||
        stderr.contains('command not found') ||
        stderr.contains('conductore-hostd: not found')) {
      throw const AppFailure(
        'The Conductore companion is not installed on this machine.',
      );
    }
    if (result.exitCode != null && result.exitCode != 0) {
      final (error, code) = _error(result.stdout);
      if (error != null && error.startsWith('unknown command')) {
        throw const ReviewUnsupported();
      }
      if (error != null) throw ReviewRefused(error, code: code);
      throw ConductoreHostAttentionProvider.failureFrom(result.stdout, stderr);
    }
    return result.stdout;
  }

  static (String?, String?) _error(String stdout) {
    final lines = stdout.trim().split('\n');
    try {
      final decoded = jsonDecode(lines.first);
      if (decoded is Map && decoded['error'] is String) {
        final code = decoded['code'];
        return (decoded['error'] as String, code is String ? code : null);
      }
    } on FormatException {
      // Not JSON: the caller reports stderr.
    }
    return (null, null);
  }
}
