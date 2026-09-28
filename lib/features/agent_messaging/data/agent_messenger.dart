import 'dart:async';
import 'dart:convert';

import 'package:conduit/features/agent_attention/data/conductore_host_attention_provider.dart';
import 'package:conduit/features/agent_attention/data/remote_tool_command.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/agent_messaging/domain/agent_message.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/live/domain/live_host_model.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';

/// Sends a message through Talkbawt from [from] to an agent on another
/// machine (the Talkbawt client provides it); throws when it did not go.
typedef TalkbawtAgentRelay =
    Future<void> Function({
      required SavedHost from,
      required String fromLabel,
      required AgentMessageTarget target,
      required String text,
    });

/// Messages between agents: "Send to another agent", "Ask and wait",
/// "Relay the answer" and "Send to several", over each machine's companion
/// (`agent-send`, docs/herdr-live.md).
///
/// Same machine: the companion types it (Herdr's `agent prompt`, which
/// refuses a blocked agent, or its own prompt relay). Another machine: the
/// relay setting decides; the phone relay (default) sends through that
/// machine's companion what the phone read here, the Talkbawt route hands
/// it to [talkbawtRelay].
class AgentMessenger {
  AgentMessenger({
    required this.attention,
    AgentRelayRoute Function()? relayRoute,
    TalkbawtAgentRelay? talkbawtRelay,
  }) : relayRoute = relayRoute ?? routeSetting,
       talkbawtRelay = talkbawtRelay ?? talkbawt;

  /// The app's relay setting, wired once at start (the Talkbawt client's
  /// settings hold it); the phone relay until then.
  static AgentRelayRoute Function() routeSetting = () => defaultAgentRelayRoute;

  /// The Talkbawt route, wired once at start by the Talkbawt client.
  static TalkbawtAgentRelay? talkbawt;

  final AgentAttentionController attention;

  /// The relay setting (Settings › Agents); the phone relay unless set.
  final AgentRelayRoute Function() relayRoute;

  /// The Talkbawt route, when the app has the Talkbawt client.
  final TalkbawtAgentRelay? talkbawtRelay;

  static const _sendTimeout = Duration(seconds: 30);

  /// Every agent a message can go to on the monitored machines whose
  /// companion takes messages, one entry per machine and agent, leaving
  /// out [excludeAgentId] on [excludeHostId] (the sender).
  List<AgentMessageTarget> targets({
    String? excludeHostId,
    String? excludeAgentId,
  }) {
    final here = excludeHostId == null ? null : baseHostId(excludeHostId);
    final seen = <AgentMessageTarget>{};
    final out = <AgentMessageTarget>[];
    for (final host in attention.monitoredHosts) {
      if (!attention.companionSupports(host.id, agentMessagingCapability)) {
        continue;
      }
      for (final agent
          in attention.statusFor(host.id)?.agents ?? const <AgentInfo>[]) {
        final ended =
            agent.state == AgentAttentionState.finished &&
            !isHerdrOnlyAgent(agent);
        if (ended) continue;
        if (agent.id == excludeAgentId && baseHostId(host.id) == here) {
          continue;
        }
        final target = AgentMessageTarget(host: host, agent: agent);
        if (seen.add(target)) out.add(target);
      }
    }
    return out;
  }

  /// Whether sending from [from] to [to] crosses machines.
  static bool crossesMachines(SavedHost? from, AgentMessageTarget to) =>
      from != null && baseHostId(from.id) != to.machine;

  /// The exact text each target receives: framed as context when it
  /// relays another agent's output ([contextFrom] names that agent).
  static String textFor(String text, {String? contextFrom}) =>
      contextFrom == null || contextFrom.trim().isEmpty
      ? text
      : frameAgentContext(contextFrom.trim(), text);

  /// `agent-send` for [targets] of one machine. The text goes on stdin
  /// when the runner can (never in the command line), else as base64.
  static String sendCommand(
    List<String> targets, {
    String? contextFrom,
    bool wait = false,
    Duration timeout = const Duration(minutes: 2),
    String? textB64,
  }) {
    return ConductoreHostAttentionProvider.remoteCommand(
      [
        'agent-send',
        for (final target in targets) '--to ${shellQuoteArgument(target)}',
        if (contextFrom != null && contextFrom.trim().isNotEmpty)
          '--context-from ${shellQuoteArgument(contextFrom.trim())}',
        if (wait) '--wait --timeout ${timeout.inSeconds}',
        if (textB64 != null) '--text-b64 ${shellQuoteArgument(textB64)}',
      ].join(' '),
    );
  }

  /// Sends [text] to every one of [to], machine by machine, one target
  /// after the other. With [wait] each call returns when its agent settled
  /// (or at [timeout], which is never retried). Never throws: failures
  /// are results.
  Future<List<AgentSendResult>> send({
    required List<AgentMessageTarget> to,
    required String text,
    SavedHost? from,
    String? contextFrom,
    bool wait = false,
    Duration timeout = const Duration(minutes: 2),
  }) async {
    final results = <AgentSendResult>[];
    final byMachine = <String, List<AgentMessageTarget>>{};
    for (final target in to) {
      byMachine.putIfAbsent(target.machine, () => []).add(target);
    }
    for (final group in byMachine.values) {
      final host = group.first.host;
      final crossing = crossesMachines(from, group.first);
      if (crossing && relayRoute() == AgentRelayRoute.talkbawt) {
        results.addAll(
          await _viaTalkbawt(
            group,
            textFor(text, contextFrom: contextFrom),
            from: from!,
            fromLabel: contextFrom ?? 'you via Conductore',
          ),
        );
        continue;
      }
      results.addAll(
        await _sendOn(
          host,
          [for (final t in group) t.target],
          text,
          contextFrom: contextFrom,
          wait: wait,
          timeout: timeout,
        ),
      );
    }
    return results;
  }

  Future<List<AgentSendResult>> _viaTalkbawt(
    List<AgentMessageTarget> group,
    String text, {
    required SavedHost from,
    required String fromLabel,
  }) async {
    final relay = talkbawtRelay;
    final results = <AgentSendResult>[];
    for (final target in group) {
      if (relay == null) {
        results.add(
          AgentSendResult(
            target: target.target,
            ok: false,
            error:
                'The relay setting is Talkbawt, but this build has no '
                'Talkbawt client. Choose the phone relay in Settings.',
          ),
        );
        continue;
      }
      try {
        await relay(
          from: from,
          fromLabel: fromLabel,
          target: target,
          text: text,
        );
        results.add(AgentSendResult(target: target.target, ok: true));
      } catch (error) {
        results.add(
          AgentSendResult(
            target: target.target,
            ok: false,
            error: 'Not sent through Talkbawt: $error',
          ),
        );
      }
    }
    return results;
  }

  Future<List<AgentSendResult>> _sendOn(
    SavedHost host,
    List<String> targets,
    String text, {
    String? contextFrom,
    required bool wait,
    required Duration timeout,
  }) async {
    final (runner, :owned) = attention.runnerFor(host);
    try {
      final deadline = wait ? timeout + _sendTimeout : _sendTimeout;
      final AgentCommandResult result;
      if (runner is StdinAgentCommandRunner) {
        result = await runner.runWithStdin(
          sendCommand(
            targets,
            contextFrom: contextFrom,
            wait: wait,
            timeout: timeout,
          ),
          stdin: text,
          timeout: deadline,
        );
      } else {
        result = await runner.run(
          sendCommand(
            targets,
            contextFrom: contextFrom,
            wait: wait,
            timeout: timeout,
            textB64: base64Encode(utf8.encode(text)),
          ),
          timeout: deadline,
        );
      }
      if (result.exitCode == 127) {
        return [
          for (final target in targets)
            AgentSendResult(
              target: target,
              ok: false,
              error: 'The Conductore companion is not installed there.',
            ),
        ];
      }
      return AgentSendResult.parseReply(result.stdout, targets);
    } catch (error) {
      // The connection failed: whether the prompt arrived is unknown.
      return [
        for (final target in targets)
          AgentSendResult(
            target: target,
            ok: false,
            error: '$error',
            maybeDelivered: true,
          ),
      ];
    } finally {
      if (owned) unawaited(runner.close());
    }
  }
}
