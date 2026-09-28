import 'dart:async';

import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention_notifier.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:flutter/widgets.dart';

/// Opens the agent a tapped notification points at.
///
/// Mount it inside the unlocked app: a tap that started or resumed the app
/// while it was locked is consumed when this widget mounts, after the
/// unlock, so agent locations never open over the lock screen.
class AgentNotificationOpenListener extends StatefulWidget {
  const AgentNotificationOpenListener({
    required this.source,
    required this.findHost,
    required this.onOpen,
    required this.child,
    this.intercept,
    super.key,
  });

  final AgentOpenRequestSource source;

  /// Takes a tap that is not an agent's (a Talkbawt reply opens its
  /// preview); true when it handled it.
  final bool Function(AgentOpenTarget target)? intercept;

  /// The saved host for a notification's host id; null when it was removed.
  final Future<SavedHost?> Function(String hostId) findHost;

  /// Opens [agent] on [host] (the app wires the connect flow's deep link).
  final Future<void> Function(SavedHost host, AgentInfo agent) onOpen;
  final Widget child;

  @override
  State<AgentNotificationOpenListener> createState() =>
      _AgentNotificationOpenListenerState();
}

class _AgentNotificationOpenListenerState
    extends State<AgentNotificationOpenListener> {
  @override
  void initState() {
    super.initState();
    widget.source.setListener(_consume);
    _consume();
  }

  @override
  void didUpdateWidget(AgentNotificationOpenListener oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) {
      oldWidget.source.setListener(null);
      widget.source.setListener(_consume);
    }
  }

  @override
  void dispose() {
    widget.source.setListener(null);
    super.dispose();
  }

  void _consume() {
    unawaited(() async {
      final target = await widget.source.consume();
      if (!mounted || target == null) {
        return;
      }
      if (widget.intercept?.call(target) ?? false) {
        return;
      }
      final host = await widget.findHost(target.hostId);
      if (!mounted || host == null) {
        return;
      }
      String? orNull(String value) => value.isEmpty ? null : value;
      await widget.onOpen(
        host,
        AgentInfo(
          id: target.agentId,
          name: '',
          state: AgentAttentionState.unknown,
          workspace: orNull(target.workspaceId),
          tab: orNull(target.tabId),
          pane: orNull(target.paneId),
        ),
      );
    }());
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
