import 'dart:convert';

import 'package:conduit/core/app_failure.dart';
import 'package:conduit/features/agent_attention/data/companion_reply.dart';
import 'package:conduit/features/agent_attention/data/conductore_host_attention_provider.dart';
import 'package:conduit/features/agent_attention/data/remote_tool_command.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/chat_view/domain/chat_transcript.dart';
import 'package:conduit/features/voice/domain/speech_summary.dart';

/// Why the chat view cannot run on a host.
enum ChatUnsupportedKind {
  /// `conductore-hostd` is not installed.
  notInstalled,

  /// The companion predates the chat commands.
  outdated,
}

/// Thrown when the host's companion is missing, or too old to know the
/// chat commands.
class ChatUnsupported implements Exception {
  const ChatUnsupported(
    this.message, {
    this.kind = ChatUnsupportedKind.notInstalled,
  });

  final String message;
  final ChatUnsupportedKind kind;

  @override
  String toString() => message;
}

/// Thrown by [ConductoreChatClient.transcript] when the session has no
/// transcript yet, which is normal before its first turn: the chat is
/// empty, not broken.
class ChatTranscriptNotYet implements Exception {
  const ChatTranscriptNotYet(this.detail);

  final String detail;

  @override
  String toString() => detail;
}

/// The chat view's side of the companion contract (`host/README.md`):
/// `transcript`, `send` and `interrupt`, each run over an exec channel
/// through the same PATH wrapper as the attention provider.
class ConductoreChatClient {
  const ConductoreChatClient(this._runner);

  final AgentCommandRunner _runner;

  static const _timeout = Duration(seconds: 15);

  /// How much of a long transcript the first load reads.
  static const defaultTailBytes = 256 * 1024;

  static const installHint =
      'Install the Conductore companion on this machine: run host/install.sh '
      'from the Conductore Mobile repository there, then check with '
      '"conductore-hostd doctor".';

  static String transcriptCommand(
    String sessionId, {
    int? since,
    int? before,
    int? tailBytes,
    int? maxBytes,
    String? cursor,
    String? beforeCursor,
  }) {
    final args = [
      'transcript',
      shellQuoteArgument(sessionId),
      if (since != null) '--since $since',
      if (before != null) '--before $before',
      // Neutral pages (every agent but Claude Code) page by opaque cursor.
      if (cursor != null) '--cursor ${shellQuoteArgument(cursor)}',
      if (beforeCursor != null)
        '--before-cursor ${shellQuoteArgument(beforeCursor)}',
      if (tailBytes != null) '--tail-bytes $tailBytes',
      if (maxBytes != null) '--max-bytes $maxBytes',
      // Last: an older companion would read a word after it as its value.
      companionGzipFlag,
    ];
    return ConductoreHostAttentionProvider.remoteCommand(args.join(' '));
  }

  /// `send` with the text on stdin, what [send] uses when the runner can
  /// feed stdin: a long prompt in the command line hits the host's 128 KiB
  /// single-argument limit (E2BIG). Every companion that has `send` reads
  /// stdin when no text flag is given; it strips one trailing newline, so
  /// [sendStdin] adds one.
  static String sendStdinCommand(String sessionId, {bool enter = true}) =>
      ConductoreHostAttentionProvider.remoteCommand(
        'send ${shellQuoteArgument(sessionId)}${enter ? '' : ' --no-enter'}',
      );

  /// The stdin for [sendStdinCommand]: [text] exactly, after the newline
  /// the companion strips.
  static String sendStdin(String text) => '$text\n';

  /// For a runner without stdin: the text travels base64-encoded in the
  /// command line so no quoting or newline quirk of the exec channel's
  /// shell can alter it (up to about 96 KB).
  static String sendCommand(
    String sessionId,
    String text, {
    bool enter = true,
  }) {
    final encoded = base64.encode(utf8.encode(text));
    return ConductoreHostAttentionProvider.remoteCommand(
      'send ${shellQuoteArgument(sessionId)} --text-b64 $encoded'
      '${enter ? '' : ' --no-enter'}',
    );
  }

  /// Longest summary asked for, in words.
  static const summaryWords = 45;

  /// How long the companion may take over a summary.
  static const summaryTimeout = Duration(seconds: 20);

  /// The answer travels on stdin (never in the command line).
  static final summarizeCommand = ConductoreHostAttentionProvider.remoteCommand(
    'summarize --max-words $summaryWords '
    '--timeout-ms ${summaryTimeout.inMilliseconds}',
  );

  static String interruptCommand(String sessionId) =>
      ConductoreHostAttentionProvider.remoteCommand(
        'interrupt ${shellQuoteArgument(sessionId)}',
      );

  Future<TranscriptPage> transcript(
    String sessionId, {
    int? since,
    int? before,
    int? tailBytes,
    int? maxBytes,
    String? cursor,
    String? beforeCursor,
  }) async {
    final result = await _runner.run(
      transcriptCommand(
        sessionId,
        since: since,
        before: before,
        tailBytes: tailBytes,
        maxBytes: maxBytes,
        cursor: cursor,
        beforeCursor: beforeCursor,
      ),
      timeout: _timeout,
    );
    if (notYetDetail(result) case final detail?) {
      throw ChatTranscriptNotYet(detail);
    }
    _check(result);
    try {
      return TranscriptParser.parsePage(result.stdout);
    } on FormatException {
      throw const AppFailure(
        'The Conductore companion returned a transcript in an unexpected '
        'shape.',
      );
    }
  }

  Future<void> send(String sessionId, String text, {bool enter = true}) async {
    final runner = _runner;
    final result = runner is StdinAgentCommandRunner
        ? await runner.runWithStdin(
            sendStdinCommand(sessionId, enter: enter),
            stdin: sendStdin(text),
            timeout: _timeout,
          )
        : await runner.run(
            sendCommand(sessionId, text, enter: enter),
            timeout: _timeout,
          );
    _check(result);
  }

  /// How long typing an answer into the terminal may take: the companion
  /// reads the screen after every key (up to a few seconds each).
  static const terminalAnswerTimeout = Duration(seconds: 60);

  static String terminalAnswerStdinCommand(String sessionId) =>
      ConductoreHostAttentionProvider.remoteCommand(
        'terminal-answer ${shellQuoteArgument(sessionId)} -',
      );

  static String terminalAnswerCommand(
    String sessionId,
    Map<String, Object?> payload,
  ) => ConductoreHostAttentionProvider.remoteCommand(
    'terminal-answer ${shellQuoteArgument(sessionId)} --json-b64 '
    '${base64.encode(utf8.encode(jsonEncode(payload)))}',
  );

  /// Answers Claude Code's own dialog in the agent's pane (capability
  /// `terminal-answers`, CON-096): [payload] is `{questions, answers}`,
  /// `{requestId, answers}` or `{requestId, decision}`. The companion
  /// checks the screen before every key and fails without typing on when
  /// it does not show that dialog.
  Future<void> terminalAnswer(
    String sessionId,
    Map<String, Object?> payload,
  ) async {
    final runner = _runner;
    final result = runner is StdinAgentCommandRunner
        ? await runner.runWithStdin(
            terminalAnswerStdinCommand(sessionId),
            stdin: jsonEncode(payload),
            timeout: terminalAnswerTimeout,
          )
        : await runner.run(
            terminalAnswerCommand(sessionId, payload),
            timeout: terminalAnswerTimeout,
          );
    _check(result);
  }

  Future<void> interrupt(String sessionId) async {
    final result = await _runner.run(
      interruptCommand(sessionId),
      timeout: _timeout,
    );
    _check(result);
  }

  /// A short spoken summary of [text] by Claude on the machine. Never
  /// throws: every failure (an older companion, a runner that cannot pass
  /// stdin, a dropped connection) is a [SpeechSummaryFailed]. Completing
  /// [cancel] stops waiting (throwing [AgentCommandCancelled]); the remote
  /// command may finish on its own, within `--timeout-ms`, unheard.
  Future<SpeechSummaryResult> summarize(
    String text, {
    Future<void>? cancel,
  }) async {
    final runner = _runner;
    if (runner is! StdinAgentCommandRunner) {
      return const SpeechSummaryFailed(SpeechSummaryFailed.unsupported);
    }
    try {
      final result = await runner.runWithStdin(
        summarizeCommand,
        stdin: text,
        // A little longer than the companion's own limit, so its timeout
        // reply wins.
        timeout: summaryTimeout + const Duration(seconds: 5),
        cancel: cancel,
      );
      return SpeechSummaryResult.parse(
        stdout: result.stdout,
        stderr: result.stderr,
        exitCode: result.exitCode,
      );
    } on AgentCommandCancelled {
      rethrow;
    } catch (error) {
      return SpeechSummaryFailed(
        SpeechSummaryFailed.unreachable,
        message: error is AppFailure ? error.userMessage : '$error',
      );
    }
  }

  /// The companion's "no transcript yet" error, or null. Companions since
  /// CON-071 mark it `notYet: true`; older ones are recognised by the
  /// message (Claude Code's and Codex's adapters).
  static String? notYetDetail(AgentCommandResult result) {
    if (result.exitCode == null || result.exitCode == 0) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(result.stdout.trim());
    } catch (_) {
      return null;
    }
    if (decoded is! Map || decoded['error'] is! String) return null;
    final error = decoded['error'] as String;
    if (decoded['notYet'] == true || _notYetMessage.hasMatch(error)) {
      return error;
    }
    return null;
  }

  static final _notYetMessage = RegExp(
    r'^(no (transcript|session file) recorded for |'
    r'(transcript|session file) not found: )',
  );

  static void _check(AgentCommandResult result) {
    final stderr = result.stderr.trim();
    if (result.exitCode == 127 ||
        stderr.contains('command not found') ||
        stderr.contains('conductore-hostd: not found')) {
      throw const ChatUnsupported(
        'The Conductore companion is not installed on this machine. '
        '$installHint',
      );
    }
    if (result.exitCode != null && result.exitCode != 0) {
      final failure = ConductoreHostAttentionProvider.failureFrom(
        result.stdout,
        stderr,
      );
      final cause = failure.cause;
      if (cause is String && cause.startsWith('unknown command')) {
        throw const ChatUnsupported(
          'The Conductore companion on this machine is too old for the chat '
          'view. Update it by running host/install.sh again.',
          kind: ChatUnsupportedKind.outdated,
        );
      }
      throw failure;
    }
  }
}
