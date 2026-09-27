import 'dart:async';

import 'package:conduit/core/presentation/terminal_route.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/chat_view/data/attention_host_runner.dart';
import 'package:conduit/features/chat_view/data/conductore_chat_client.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_launcher.dart';
import 'package:conduit/features/diff_view/data/ssh_git_diff_source.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/review/data/review_client.dart';
import 'package:conduit/features/review/presentation/review_controller.dart';
import 'package:conduit/features/review/presentation/review_page.dart';
import 'package:conduit/features/voice/presentation/dictation_controller.dart';
import 'package:flutter/material.dart';

/// Whether Review can open for [host]'s agents: their companion's
/// snapshots, or (an older companion) the working tree's diff.
bool reviewAvailable(AgentAttentionController attention, SavedHost host) =>
    chatViewAvailable(attention, host);

/// Whether an agent in [agent]'s state has a turn to review now (not in
/// the middle of one).
bool agentCanBeReviewed(AgentInfo agent) =>
    agent.state != AgentAttentionState.working;

/// Opens Review for [agent] on [host] ([turn]: that turn, else the newest
/// one with a snapshot). [send] types the feedback into the agent; by
/// default the companion's `send`. Resolves when Review closes.
Future<void> openReview({
  required BuildContext context,
  required AgentAttentionController attention,
  required SavedHost host,
  required AgentInfo agent,
  int? turn,
  Future<void> Function(String text)? send,
  DictationController? dictation,
}) {
  final runner = AttentionHostRunner(attention, host);
  final snapshots = attention.supportsSnapshots(host.id);
  final cwd = agent.workspace?.trim();
  final controller = ReviewController(
    client: ConductoreReviewClient(runner),
    sessionId: agent.id,
    agentName: agent.projectLabel ?? agent.name,
    turnNumber: turn,
    snapshots: snapshots,
    fallback: snapshots ? null : SshGitDiffSource(runner, host),
    fallbackPath: cwd != null && cwd.startsWith('/') ? cwd : null,
    send: send ?? (text) => ConductoreChatClient(runner).send(agent.id, text),
    onClose: runner.close,
  );
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      settings: reviewRouteSettings(hostId: host.id, agentId: agent.id),
      builder: (context) =>
          ReviewPage(controller: controller, host: host, dictation: dictation),
    ),
  );
}

/// Opens Review for the agent [agentId] on the monitored [host] when the
/// monitor knows it; false when it does not.
bool openReviewFor({
  required BuildContext context,
  required AgentAttentionController attention,
  required SavedHost host,
  required String agentId,
  Future<void> Function(String text)? send,
  DictationController? dictation,
}) {
  final agent = attention
      .statusFor(host.id)
      ?.agents
      .where((a) => a.id == agentId)
      .firstOrNull;
  if (agent == null) return false;
  unawaited(
    openReview(
      context: context,
      attention: attention,
      host: host,
      agent: agent,
      send: send,
      dictation: dictation,
    ),
  );
  return true;
}
