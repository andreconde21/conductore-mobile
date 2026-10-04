import 'dart:convert';

/// What `conductore-hostd summarize` (companion 0.7.0+) made of a final
/// answer, or why there is no summary.
sealed class SpeechSummaryResult {
  const SpeechSummaryResult();

  /// Parses the command's one JSON line (the exit code is always 0 on a
  /// companion that knows the command). An older companion answers
  /// "unknown command"; none at all is "not found" (127).
  static SpeechSummaryResult parse({
    required String stdout,
    required String stderr,
    int? exitCode,
  }) {
    final output = '$stdout\n$stderr';
    if (exitCode == 127 ||
        output.contains('command not found') ||
        output.contains('conductore-hostd: not found')) {
      return const SpeechSummaryFailed(SpeechSummaryFailed.missing);
    }
    if (output.contains('unknown command')) {
      return const SpeechSummaryFailed(SpeechSummaryFailed.outdated);
    }
    for (final line in stdout.trim().split('\n').reversed) {
      final trimmed = line.trim();
      if (!trimmed.startsWith('{')) continue;
      try {
        final json = jsonDecode(trimmed);
        if (json is! Map) break;
        final summary = json['summary'];
        if (summary is String && summary.trim().isNotEmpty) {
          return SpeechSummary(
            summary.trim(),
            passthrough: json['passthrough'] == true,
          );
        }
        final error = json['error'];
        if (error is String) {
          return SpeechSummaryFailed(
            error,
            message: json['message'] is String
                ? json['message'] as String
                : null,
          );
        }
      } on FormatException {
        // Not the reply line.
      }
      break;
    }
    return const SpeechSummaryFailed(SpeechSummaryFailed.failed);
  }
}

class SpeechSummary extends SpeechSummaryResult {
  const SpeechSummary(this.text, {this.passthrough = false});

  final String text;

  /// The answer was already short and came back as it was.
  final bool passthrough;
}

class SpeechSummaryFailed extends SpeechSummaryResult {
  const SpeechSummaryFailed(this.reason, {this.message});

  // The companion's error codes.
  static const claudeMissing = 'claude-missing';
  static const agentMissing = 'agent-missing';
  static const notLoggedIn = 'not-logged-in';
  static const timeout = 'timeout';
  static const busy = 'busy';
  static const failed = 'failed';

  // The app's own.
  static const outdated = 'outdated';
  static const missing = 'missing';
  static const unsupported = 'unsupported';
  static const unreachable = 'unreachable';

  final String reason;
  final String? message;

  /// Why a brief version is read instead, for a one-time note. (Short
  /// answers come back as a passthrough summary, never as a failure.)
  String? get note => switch (reason) {
    outdated =>
      'Summaries need the Conductore companion 0.7.0 or later on '
          'this machine. Reading a brief version instead.',
    missing || unsupported =>
      'Summaries need the Conductore companion on this machine. '
          'Reading a brief version instead.',
    claudeMissing || agentMissing =>
      'No coding agent is installed on this machine, so there is no '
          'summary. Reading a brief version instead.',
    notLoggedIn =>
      'The coding agent is not logged in on this machine, so there is no '
          'summary. '
          'Reading a brief version instead.',
    timeout => 'The summary took too long. Reading a brief version instead.',
    busy =>
      'The machine is busy with another summary. Reading a brief version '
          'instead.',
    _ =>
      'The summary failed${message == null ? '' : ' ($message)'}. Reading '
          'a brief version instead.',
  };
}
