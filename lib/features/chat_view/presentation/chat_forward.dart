import 'dart:async';

import 'package:conduit/core/presentation/adaptive_modal.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_launcher.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/session_navigation/domain/session_view_preferences.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:flutter/material.dart';

/// Another agent a message can be sent to: a live Claude session on a
/// machine whose chat view works.
class ChatForwardTarget {
  const ChatForwardTarget({required this.host, required this.agent});

  final SavedHost host;
  final AgentInfo agent;
}

/// Sends [prompt] to [target] (see [forwardToAgentChat]).
typedef ChatForward =
    Future<void> Function(ChatForwardTarget target, String prompt);

/// The other live Claude sessions across every monitored machine, one
/// entry per session (a machine open in several sessions counts once),
/// leaving out [sessionId] on [hostId] (this chat).
List<ChatForwardTarget> chatForwardTargets(
  AgentAttentionController attention, {
  required String sessionId,
  String? hostId,
}) {
  final here = hostId == null ? null : baseHostId(hostId);
  final seen = <String>{};
  return [
    for (final host in attention.monitoredHosts)
      if (chatViewAvailable(attention, host))
        for (final agent
            in attention.statusFor(host.id)?.agents ?? const <AgentInfo>[])
          if (agent.state != AgentAttentionState.finished &&
              isClaudeAgent(agent) &&
              !(agent.id == sessionId && baseHostId(host.id) == here) &&
              seen.add('${baseHostId(host.id)}\n${agent.id}'))
            ChatForwardTarget(host: host, agent: agent),
  ];
}

/// Asks which of [targets] to send to; null when dismissed.
Future<ChatForwardTarget?> pickChatForwardTarget(
  BuildContext context,
  List<ChatForwardTarget> targets,
) => showAdaptiveModal<ChatForwardTarget>(
  context: context,
  kind: AdaptiveModalKind.dialog,
  useSafeArea: true,
  isScrollControlled: true,
  builder: (context) => SafeArea(
    child: ListView(
      shrinkWrap: true,
      children: [
        const ListTile(
          key: ValueKey('chat-forward-title'),
          title: Text('Send to another agent'),
          subtitle: Text(
            'It arrives as a prompt, quoted, with where it is from.',
          ),
        ),
        for (final target in targets)
          ListTile(
            key: ValueKey('chat-forward-${target.host.id}-${target.agent.id}'),
            leading: const Icon(Icons.smart_toy_outlined),
            title: Text(target.agent.name),
            subtitle: Text(
              [
                target.host.name,
                target.agent.state.label,
                ?target.agent.workspace,
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => Navigator.of(context).pop(target),
          ),
      ],
    ),
  ),
);

/// Opens [target]'s chat and sends [prompt] there through its composer's
/// path, so it shows as that chat's pending bubble until the transcript
/// has it.
Future<void> forwardToAgentChat(
  BuildContext context,
  AgentAttentionController attention,
  ChatForwardTarget target,
  String prompt,
) => openChatView(
  context: context,
  attention: attention,
  host: target.host,
  agent: target.agent,
  initialSend: prompt,
  onOpenTerminal: () =>
      unawaited(attention.focusAgent(target.host.id, target.agent)),
);
