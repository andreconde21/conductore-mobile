import 'dart:async';

import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_sheet.dart';
import 'package:conduit/features/home_widget/domain/agent_status_widget_channel.dart';
import 'package:conduit/features/sessions/presentation/session_connect_flow.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:flutter/material.dart';

/// Opens the agent attention sheet when the app is launched (or brought
/// back) from the home-screen widget or the quick-settings tile.
///
/// Mount it around the unlocked home page: the pending target is consumed
/// when this widget mounts, so a launch while the app is locked waits for
/// the unlock instead of showing agent names over the lock screen.
class AgentStatusLaunchListener extends StatefulWidget {
  const AgentStatusLaunchListener({
    required this.channel,
    required this.agentAttention,
    required this.workspace,
    required this.child,
    this.connectFlow,
    this.onGuide,
    super.key,
  });

  /// Starts the voice guide; null ignores its launches.
  final VoidCallback? onGuide;

  /// Opens agents at their exact Herdr place; without it the sheet only
  /// activates the host's tab and asks the provider to focus the agent.
  final SessionConnectFlow? connectFlow;

  final AgentStatusWidgetChannel channel;
  final AgentAttentionController agentAttention;
  final TerminalWorkspaceController workspace;
  final Widget child;

  @override
  State<AgentStatusLaunchListener> createState() =>
      _AgentStatusLaunchListenerState();
}

class _AgentStatusLaunchListenerState extends State<AgentStatusLaunchListener> {
  bool _sheetOpen = false;

  @override
  void initState() {
    super.initState();
    widget.channel.setLaunchTargetListener(_consume);
    _consume();
  }

  @override
  void didUpdateWidget(AgentStatusLaunchListener oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.channel != widget.channel) {
      oldWidget.channel.setLaunchTargetListener(null);
      widget.channel.setLaunchTargetListener(_consume);
    }
  }

  @override
  void dispose() {
    widget.channel.setLaunchTargetListener(null);
    super.dispose();
  }

  void _consume() {
    unawaited(() async {
      final target = await widget.channel.consumeLaunchTarget();
      if (!mounted || target == null) {
        return;
      }
      switch (target) {
        case AgentStatusLaunchTarget.agents:
          await _openAgents();
        case AgentStatusLaunchTarget.guide:
          widget.onGuide?.call();
      }
    }());
  }

  Future<void> _openAgents() async {
    if (_sheetOpen) {
      return;
    }
    _sheetOpen = true;
    try {
      await showAgentAttentionSheet(
        context: context,
        controller: widget.agentAttention,
        onOpenAgent: (host, agent) {
          final flow = widget.connectFlow;
          if (flow != null) {
            unawaited(flow.openAgent(host, agent));
            Navigator.of(context).pop();
            return;
          }
          // The terminal page (if open) shows the activated tab; from the
          // hosts page the user opens the workspace with it preselected.
          final session = widget.workspace.sessions
              .where((session) => session.host.id == host.id)
              .firstOrNull;
          if (session != null) {
            widget.workspace.activate(session);
          }
          unawaited(widget.agentAttention.focusAgent(host.id, agent));
          Navigator.of(context).pop();
        },
      );
    } finally {
      _sheetOpen = false;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
