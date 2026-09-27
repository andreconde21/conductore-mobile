import 'dart:convert';

import 'package:conduit/core/app_failure.dart';
import 'package:conduit/features/agent_attention/data/remote_tool_command.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/diff_view/domain/git_diff_source.dart';
import 'package:conduit/features/diff_view/domain/git_status.dart';
import 'package:conduit/features/diff_view/domain/unified_diff.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';

/// Quotes [value] for the shell, always in quotes (see
/// [shellQuoteArgument], which fish reads back unchanged too).
String shellQuote(String value) {
  final quoted = shellQuoteArgument(value);
  return quoted == value ? "'$value'" : quoted;
}

/// Double-quotes [value] for use inside a single-quoted `sh -c` script,
/// so the script itself stays readable (no nested single-quote escapes).
String _doubleQuote(String value) {
  final escaped = value
      .replaceAll(r'\', r'\\')
      .replaceAll(r'$', r'\$')
      .replaceAll('`', r'\`')
      .replaceAll('"', r'\"');
  return '"$escaped"';
}

/// Runs `git` on the host over an [AgentCommandRunner] (a separate SSH exec
/// connection, so nothing is typed into the user's PTY).
class SshGitDiffSource implements GitDiffSource {
  SshGitDiffSource(this._runner, this._host);

  final AgentCommandRunner _runner;
  final SavedHost _host;

  static const _commandTimeout = Duration(seconds: 30);

  /// `tmux display -p '#{pane_current_path}'` reports the directory of the
  /// active pane. Without a client attached to the exec channel, tmux uses
  /// the most recently active session; the host's configured session is
  /// tried first when it starts tmux on connect. Falls back to the tmux
  /// start directory, then `$HOME`.
  static String detectWorkingDirectoryCommand(SavedHost host) {
    const format = '-F "#{pane_current_path}" 2>/dev/null';
    final buffer = StringBuffer('p=""; ');
    if (host.startTmuxOnConnect && host.tmuxSessionName.trim().isNotEmpty) {
      final session = _doubleQuote(host.tmuxSessionName.trim());
      buffer.write('p=\$(tmux display-message -p -t $session $format); ');
    }
    buffer.write('[ -n "\$p" ] || p=\$(tmux display-message -p $format); ');
    final startDirectory = host.tmuxStartDirectory.trim();
    if (startDirectory.isNotEmpty) {
      final directory = _doubleQuote(startDirectory);
      buffer.write('[ -n "\$p" ] || [ ! -d $directory ] || p=$directory; ');
    }
    buffer.write('[ -n "\$p" ] || p=\$HOME; printf %s "\$p"');
    return 'sh -c ${shellQuote(buffer.toString())}';
  }

  static String repositoryRootCommand(String path) =>
      'git -C ${shellQuote(path)} rev-parse --show-toplevel';

  static String diffCommand(String path, {required bool staged}) =>
      'git -C ${shellQuote(path)} diff --no-color${staged ? ' --staged' : ''} '
      '| head -c ${gitDiffMaxBytes + 1}';

  static String statusCommand(String path) =>
      'git -C ${shellQuote(path)} status --porcelain=v2 --branch';

  @override
  Future<String> detectWorkingDirectory() async {
    final result = await _runner.run(
      detectWorkingDirectoryCommand(_host),
      timeout: _commandTimeout,
    );
    final path = result.stdout.trim();
    if (path.isEmpty) {
      throw AppFailure(
        'Could not find the working directory on ${_host.name}.',
        result.stderr.trim(),
      );
    }
    return path;
  }

  @override
  Future<GitDiffSnapshot> load(String path) async {
    final trimmed = path.trim();
    if (trimmed.isEmpty) {
      throw const AppFailure('Enter a directory to diff.');
    }
    final root = await _runner.run(
      repositoryRootCommand(trimmed),
      timeout: _commandTimeout,
    );
    if (root.exitCode != 0) {
      final stderr = root.stderr.trim();
      if (root.exitCode == 127 || stderr.contains('git: not found')) {
        throw AppFailure('Git is not installed on ${_host.name}.', stderr);
      }
      if (stderr.contains('not a git repository')) {
        return GitDiffSnapshot(path: trimmed, repositoryRoot: null);
      }
      if (stderr.contains('cannot change to') ||
          stderr.contains('No such file or directory')) {
        throw AppFailure('No such directory: $trimmed', stderr);
      }
      throw AppFailure('git failed in $trimmed.', stderr);
    }
    final repositoryRoot = root.stdout.trim();

    final unstaged = await _diff(trimmed, staged: false);
    final staged = await _diff(trimmed, staged: true);
    final statusResult = await _runner.run(
      statusCommand(trimmed),
      timeout: _commandTimeout,
    );
    final status = statusResult.exitCode == 0
        ? GitStatus.parse(statusResult.stdout)
        : null;
    return GitDiffSnapshot(
      path: trimmed,
      repositoryRoot: repositoryRoot,
      status: status,
      unstaged: unstaged.$1,
      unstagedTruncated: unstaged.$2,
      staged: staged.$1,
      stagedTruncated: staged.$2,
    );
  }

  Future<(UnifiedDiff, bool)> _diff(String path, {required bool staged}) async {
    final result = await _runner.run(
      diffCommand(path, staged: staged),
      timeout: _commandTimeout,
    );
    // The pipe through `head` hides git's exit status; a failure shows up
    // as a `fatal:` line on stderr instead.
    final stderr = result.stderr.trim();
    if (stderr.startsWith('fatal:') || stderr.startsWith('error:')) {
      throw AppFailure('git diff failed in $path.', stderr);
    }
    var text = result.stdout;
    final truncated = utf8.encode(text).length > gitDiffMaxBytes;
    if (truncated) {
      // Drop the partial trailing line so the parser sees whole records.
      final lastNewline = text.lastIndexOf('\n');
      text = lastNewline >= 0 ? text.substring(0, lastNewline + 1) : '';
    }
    return (UnifiedDiff.parse(text), truncated);
  }

  @override
  Future<void> close() => _runner.close();
}
