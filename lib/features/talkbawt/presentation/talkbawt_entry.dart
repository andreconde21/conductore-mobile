import 'dart:async';

import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_launcher.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/session_navigation/domain/session_view_preferences.dart';
import 'package:conduit/features/share_target/domain/shared_payload.dart';
import 'package:conduit/features/talkbawt/domain/talkbawt_link.dart';
import 'package:conduit/features/talkbawt/domain/talkbawt_safety.dart';
import 'package:conduit/features/talkbawt/presentation/handoff_page.dart';
import 'package:conduit/features/talkbawt/presentation/open_link_page.dart';
import 'package:conduit/features/talkbawt/presentation/talkbawt_controller.dart';
import 'package:conduit/features/talkbawt/presentation/talkbawt_threads_page.dart';
import 'package:flutter/material.dart';

/// Where Talkbawt meets the rest of the app: the machines that can read
/// links, "Hand off" for an agent, shared links, notification taps.

/// The prefix of a notification's host id that marks a Talkbawt notice
/// (the rest is the machine, the agent id is the thread).
const talkbawtNotificationPrefix = 'talkbawt:';

/// The monitored machines whose companion can act as the Talkbawt client,
/// and their live Claude agents.
TalkbawtMachines talkbawtMachinesFor(AgentAttentionController attention) =>
    TalkbawtMachines(
      hosts: () => [
        for (final host in attention.monitoredHosts)
          if (chatViewAvailable(attention, host)) host,
      ],
      agentsOn: (hostId) => [
        for (final agent
            in attention.statusFor(hostId)?.agents ?? const <AgentInfo>[])
          if (agent.state != AgentAttentionState.finished &&
              isClaudeAgent(agent))
            agent,
      ],
    );

/// "Hand off…" for [agent] on [host]; null when the machine's companion
/// cannot do it.
VoidCallback? handOffAction(
  BuildContext context,
  TalkbawtController? talkbawt,
  AgentAttentionController attention,
  SavedHost host,
  AgentInfo agent,
) {
  if (talkbawt == null || !chatViewAvailable(attention, host)) return null;
  return () => unawaited(
    showHandoffFlow(context, controller: talkbawt, host: host, agent: agent),
  );
}

/// The Talkbawt link a share carries, when that is all it carries (text
/// only, no files): shared links open the preview instead of the upload
/// flow.
TalkbawtLink? talkbawtLinkIn(SharedPayload payload) {
  if (payload.files.isNotEmpty) return null;
  final text = payload.text;
  if (text == null) return null;
  try {
    return TalkbawtLink.find(text);
  } on TalkbawtAddressError {
    return null;
  }
}

/// The Talkbawt hub (Settings › Agents › Talkbawt).
Future<void> showTalkbawtHub(
  BuildContext context, {
  required TalkbawtController controller,
  required AgentAttentionController attention,
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => TalkbawtHubPage(
      controller: controller,
      machines: talkbawtMachinesFor(attention),
    ),
  ),
);

/// Opens the owned thread a notification points at: its preview, nothing
/// else (no one-tap "send to agent" from a notification).
Future<void> openTalkbawtNotification(
  NavigatorState navigator,
  TalkbawtController controller,
  String threadId,
) async {
  await controller.load();
  await navigator.push(
    MaterialPageRoute<void>(
      builder: (_) =>
          TalkbawtThreadPage(controller: controller, threadId: threadId),
    ),
  );
}

/// Opens links shared into the app and reply notifications. Mount it
/// inside the unlocked app, so neither ever opens over the lock screen.
class TalkbawtLinkListener extends StatefulWidget {
  const TalkbawtLinkListener({
    required this.controller,
    required this.attention,
    required this.child,
    super.key,
  });

  final TalkbawtController controller;
  final AgentAttentionController attention;
  final Widget child;

  @override
  State<TalkbawtLinkListener> createState() => _TalkbawtLinkListenerState();
}

class _TalkbawtLinkListenerState extends State<TalkbawtLinkListener> {
  bool _open = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_check);
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  @override
  void dispose() {
    widget.controller.removeListener(_check);
    super.dispose();
  }

  void _check() {
    if (!mounted || _open || widget.controller.pendingSharedLink == null) {
      return;
    }
    final link = widget.controller.takeSharedLink();
    if (link == null) return;
    _open = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      try {
        await showOpenTalkbawtLink(
          context,
          controller: widget.controller,
          machines: talkbawtMachinesFor(widget.attention),
          initialText: link,
        );
      } finally {
        _open = false;
      }
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// "Send to another agent" on another machine with the relay setting on
/// Talkbawt: confirms the exact text and route, then relays it as a
/// one-reader, passphrase-protected handoff (see
/// [TalkbawtController.relayViaTalkbawt]). The phone relay stays the
/// chat's own forward (the default).
Future<void> relayThroughTalkbawt(
  BuildContext context, {
  required TalkbawtController controller,
  required SavedHost from,
  required String fromLabel,
  required TalkbawtRelayTarget target,
  required String text,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final safety = agentModeSafety(target.agent.permissionMode);
  if (safety == AgentModeSafety.unsafe) {
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          'Not sent: ${target.agent.name} runs in an auto-approve mode.',
        ),
      ),
    );
    return;
  }
  var confirmedUnknown = false;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        key: const ValueKey('talkbawt-relay-confirm'),
        title: Text('Send to ${target.agent.name} on ${target.host.name}'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Through ${Uri.parse(controller.settings.server).host}: a '
                'one-reader, passphrase-protected handoff that expires in an '
                'hour and is revoked once delivered. It arrives as data in a '
                'file, not as your instruction.',
              ),
              const SizedBox(height: 8),
              SelectableText(
                text,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
              ),
              if (safety == AgentModeSafety.unknown)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: confirmedUnknown,
                  onChanged: (v) =>
                      setState(() => confirmedUnknown = v ?? false),
                  title: Text(
                    '${target.agent.name} has not reported its permission '
                    'mode. I checked: it is not in an auto-approve mode.',
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('talkbawt-relay-send'),
            onPressed: safety == AgentModeSafety.unknown && !confirmedUnknown
                ? null
                : () => Navigator.of(context).pop(true),
            child: const Text('Send'),
          ),
        ],
      ),
    ),
  );
  if (!(ok ?? false)) return;
  try {
    await controller.relayViaTalkbawt(
      from: from,
      fromLabel: fromLabel,
      to: target,
      text: text,
      confirmedUnknownMode: confirmedUnknown,
    );
    messenger?.showSnackBar(
      SnackBar(content: Text('Sent to ${target.agent.name} via Talkbawt')),
    );
  } on Object catch (error) {
    messenger?.showSnackBar(
      SnackBar(content: Text('Not sent to ${target.agent.name}: $error')),
    );
  }
}
