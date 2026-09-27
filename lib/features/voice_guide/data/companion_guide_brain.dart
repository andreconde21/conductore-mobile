import 'dart:async';
import 'dart:convert';

import 'package:conduit/core/app_failure.dart';
import 'package:conduit/features/agent_attention/data/conductore_host_attention_provider.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/voice_guide/domain/guide_brain.dart';

/// The brain on a machine: `conductore-hostd guide` over the machine's
/// command channel, the request on stdin (never in the command line).
///
/// [candidates] lists the machines that may answer, best first: the one
/// picked in Settings, else every connected machine with the companion.
/// A machine whose companion is too old (or missing) is remembered and
/// skipped; the next one is asked instead.
class CompanionGuideBrain implements GuideBrain {
  CompanionGuideBrain({required this.candidates, required this.runnerFor});

  final List<SavedHost> Function() candidates;

  /// A runner for [host] and whether the caller owns (closes) it.
  final (AgentCommandRunner, {bool owned}) Function(SavedHost host) runnerFor;

  /// How long the companion may take (it enforces this itself).
  static const timeout = Duration(seconds: 15);

  static final command = ConductoreHostAttentionProvider.remoteCommand(
    'guide --timeout-ms ${timeout.inMilliseconds}',
  );

  /// Saved host ids whose companion has no `guide`, until the app restarts.
  final Set<String> _unsupported = {};

  @override
  Future<GuideBrainReply> ask(
    String utterance,
    Map<String, Object?> context, {
    Future<void>? cancel,
  }) async {
    final stdin = jsonEncode({'utterance': utterance, 'context': context});
    GuideBrainFailed? last;
    for (final host in candidates()) {
      if (_unsupported.contains(host.id)) continue;
      final reply = await _ask(host, stdin, cancel);
      if (reply is GuideBrainFailed &&
          (reply.reason == GuideBrainFailed.outdated ||
              reply.reason == GuideBrainFailed.missing)) {
        _unsupported.add(host.id);
        last = reply;
        continue;
      }
      return reply;
    }
    return last ?? const GuideBrainFailed(GuideBrainFailed.noBrain);
  }

  Future<GuideBrainReply> _ask(
    SavedHost host,
    String stdin,
    Future<void>? cancel,
  ) async {
    final (runner, :owned) = runnerFor(host);
    try {
      if (runner is! StdinAgentCommandRunner) {
        return const GuideBrainFailed(GuideBrainFailed.missing);
      }
      final result = await runner.runWithStdin(
        command,
        stdin: stdin,
        // A little longer than the companion's own limit, so its timeout
        // reply wins.
        timeout: timeout + const Duration(seconds: 5),
        cancel: cancel,
      );
      return GuideBrainReply.parse(
        stdout: result.stdout,
        stderr: result.stderr,
        exitCode: result.exitCode,
      );
    } on AgentCommandCancelled {
      return const GuideBrainFailed(GuideBrainFailed.failed);
    } catch (error) {
      return GuideBrainFailed(
        GuideBrainFailed.unreachable,
        message: error is AppFailure ? error.userMessage : '$error',
      );
    } finally {
      if (owned) unawaited(runner.close());
    }
  }
}
