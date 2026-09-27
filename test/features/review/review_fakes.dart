import 'dart:convert';

import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/diff_view/domain/git_diff_source.dart';
import 'package:conduit/features/diff_view/domain/unified_diff.dart';

/// A companion that answers `turns`, `diff`, `undo`, `redo` and `digest`
/// like host/lib/review.js, recording every command.
class FakeReviewRunner implements AgentCommandRunner {
  FakeReviewRunner({
    this.files = const ['lib/a.dart', 'README.md', 'assets/logo.png'],
    this.agentState = 'waiting_input',
  });

  final List<String> files;
  String agentState;
  final commands = <String>[];

  /// Replies to use instead of the defaults, by command word.
  final overrides = <String, AgentCommandResult>{};
  bool undone = false;
  bool closed = false;

  static const sessionId = 'sess-1';

  Map<String, Object?> turnJson() => {
    'turn': 3,
    'prompt': 'Fix the date parser',
    'startedAt': DateTime.utc(2026, 9, 27, 12).millisecondsSinceEpoch,
    'endedAt': DateTime.utc(2026, 9, 27, 12, 5).millisecondsSinceEpoch,
    'running': false,
    'repo': '/home/a/api',
    'files': [
      for (final f in files)
        {'path': f, 'status': 'M', 'added': 2, 'removed': 1},
    ],
    'filesTotal': files.length,
    'added': 2 * files.length,
    'removed': files.length,
    'committed': false,
    'late': false,
    'before': {
      'ref': 'refs/conductore/snapshots/sess-1/3/before',
      'commit': 'b' * 40,
    },
    'after': {
      'ref': 'refs/conductore/snapshots/sess-1/3/after',
      'commit': 'a' * 40,
    },
    'others': <String>[],
    'undone': undone ? {'at': 1, 'kind': 'turn', 'ref': 'x'} : null,
  };

  Map<String, Object?> fileJson(String path) {
    if (path.endsWith('.png')) {
      return {
        'path': path,
        'status': 'A',
        'added': 0,
        'removed': 0,
        'binary': true,
        'patch': null,
        'oldSize': null,
        'newSize': 4096,
      };
    }
    return {
      'path': path,
      'status': 'M',
      'added': 2,
      'removed': 1,
      'binary': false,
      'patch':
          '@@ -1,3 +1,4 @@\n import x;\n-final a = 1;\n+final a = 2;\n'
          '+final b = 3;\n void main() {}\n',
    };
  }

  static AgentCommandResult ok(Object json) => AgentCommandResult(
    stdout: '${jsonEncode(json)}\n',
    stderr: '',
    exitCode: 0,
  );

  static AgentCommandResult refused(String error, {String? code}) =>
      AgentCommandResult(
        stdout: '${jsonEncode({'error': error, 'code': ?code})}\n',
        stderr: '',
        exitCode: 1,
      );

  List<String> _fileArgs(String command) => [
    for (final m in RegExp(r"--file '?([^' ]+)'?").allMatches(command)) m[1]!,
  ];

  @override
  Future<AgentCommandResult> run(
    String command, {
    required Duration timeout,
  }) async {
    commands.add(command);
    final word = RegExp(
      r'hostd (turns|diff|undo|redo|digest)',
    ).firstMatch(command)?[1];
    final override = overrides[word];
    if (override != null) return override;
    switch (word) {
      case 'turns':
        return ok({
          'sessionId': sessionId,
          'snapshots': true,
          'agent': {'state': agentState},
          'pending': 0,
          'turns': [turnJson()],
        });
      case 'diff':
        final only = _fileArgs(command);
        return ok({
          'sessionId': sessionId,
          'turn': 3,
          'prompt': 'Fix the date parser',
          'repo': '/home/a/api',
          'live': false,
          'committed': false,
          'late': false,
          'others': <String>[],
          'truncated': false,
          'files': [
            for (final f in files)
              if (only.isEmpty || only.contains(f)) fileJson(f),
          ],
        });
      case 'undo':
        if (agentState == 'working') {
          return refused(
            'the agent is working; wait for its turn to end (or interrupt '
            'it) before undoing',
            code: 'busy',
          );
        }
        final only = _fileArgs(command);
        final dry = command.contains('--dry-run');
        if (!dry && only.isEmpty) undone = true;
        return ok({
          'ok': true,
          'sessionId': sessionId,
          'turn': 3,
          'dryRun': dry,
          'restored': [
            for (final f in only.isEmpty ? files : only)
              {'path': f, 'action': 'write'},
          ],
          'skipped': <Object>[],
          'redo': dry
              ? null
              : {'ref': 'refs/conductore/snapshots/sess-1/3/undo-1'},
          'headMoved': false,
          'laterTurns': <int>[],
        });
      case 'redo':
        undone = false;
        return ok({
          'ok': true,
          'sessionId': sessionId,
          'turn': 3,
          'dryRun': false,
          'restored': [
            for (final f in files) {'path': f, 'action': 'write'},
          ],
          'skipped': <Object>[],
        });
      case 'digest':
        return ok({
          'schema': 1,
          'agents': [
            {
              'sessionId': sessionId,
              'name': 'api',
              'state': agentState,
              'facts': {
                'testRuns': 2,
                'testsPassed': 1,
                'testsFailed': 1,
                'lastTest': {'ok': true},
              },
            },
          ],
        });
    }
    return const AgentCommandResult(
      stdout: '{"error":"unknown command"}\n',
      stderr: '',
      exitCode: 1,
    );
  }

  @override
  Future<void> close() async => closed = true;
}

/// The working tree's diff, for Review on an older companion.
class FakeDiffSource implements GitDiffSource {
  @override
  Future<String> detectWorkingDirectory() async => '/home/a/api';

  @override
  Future<GitDiffSnapshot> load(String path) async => GitDiffSnapshot(
    path: path,
    repositoryRoot: path,
    unstaged: UnifiedDiff.parse(
      'diff --git a/x.txt b/x.txt\n--- a/x.txt\n+++ b/x.txt\n'
      '@@ -1 +1 @@\n-a\n+b\n',
    ),
  );

  @override
  Future<void> close() async {}
}
