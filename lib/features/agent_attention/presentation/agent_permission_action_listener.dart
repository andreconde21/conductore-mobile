import 'dart:async';

import 'package:conduit/features/agent_attention/domain/agent_permission_actions.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:flutter/material.dart';

/// Completes Allow / Deny / Always taps made on permission notifications.
///
/// Mount it around the unlocked home page: queued taps are consumed when
/// this widget mounts (a tap that cold-started the app is answered once
/// the app is unlocked, never over the lock screen) and again whenever the
/// platform reports a new one while the app runs. Each tap is answered on
/// its host through [AgentAttentionController.completePermissionAction],
/// which also dismisses or rewrites the notification.
class AgentPermissionActionListener extends StatefulWidget {
  const AgentPermissionActionListener({
    required this.source,
    required this.agentAttention,
    required this.findHost,
    required this.child,
    this.launcherActions,
    this.mayAct = _always,
    super.key,
  });

  static bool _always() => true;

  /// Whether the app lock lets an action from outside the app run now
  /// (`AppLockController.admitsActions`): mounted is not enough, the app
  /// may have been in the background past its re-lock delay. When it
  /// refuses, a notification tap stays queued (the notification asks to
  /// open the app) and a launcher answer is refused with [unlockFirst].
  final bool Function() mayAct;

  /// The launcher's message while the app lock refuses actions.
  static const unlockFirst = 'Unlock Conductore first';

  final AgentPermissionActionSource source;

  /// Answers from the launcher's details sheet (CON-082): taken only while
  /// this widget is mounted (the app unlocked), through
  /// [AgentAttentionController.completeLauncherAction].
  final LauncherActionSource? launcherActions;
  final AgentAttentionController agentAttention;

  /// Looks up a saved host by id (null when it was deleted meanwhile).
  /// Asynchronous because a tap that cold-started the app is drained
  /// before the saved hosts have finished loading.
  final Future<SavedHost?> Function(String hostId) findHost;
  final Widget child;

  @override
  State<AgentPermissionActionListener> createState() =>
      _AgentPermissionActionListenerState();
}

class _AgentPermissionActionListenerState
    extends State<AgentPermissionActionListener> {
  bool _draining = false;
  bool _drainAgain = false;

  @override
  void initState() {
    super.initState();
    widget.source.setListener(_onAction);
    widget.launcherActions?.setListener(_onLauncherAction);
    _drain();
  }

  /// One launcher answer; resolves with why it failed, null once done.
  Future<String?> _onLauncherAction(AgentPermissionAction action) async {
    final host = await widget.findHost(action.hostId);
    if (!mounted) {
      return 'Open Conductore first';
    }
    if (!widget.mayAct()) {
      return AgentPermissionActionListener.unlockFirst;
    }
    return widget.agentAttention.completeLauncherAction(action, host);
  }

  /// The platform's ping; returns whether the tap will be handled now.
  bool _onAction() {
    if (!mounted || !widget.mayAct()) {
      return false;
    }
    _drain();
    return true;
  }

  @override
  void didUpdateWidget(AgentPermissionActionListener oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) {
      oldWidget.source.setListener(null);
      widget.source.setListener(_onAction);
    }
    if (oldWidget.launcherActions != widget.launcherActions) {
      oldWidget.launcherActions?.setListener(null);
      widget.launcherActions?.setListener(_onLauncherAction);
    }
  }

  @override
  void dispose() {
    widget.source.setListener(null);
    widget.launcherActions?.setListener(null);
    super.dispose();
  }

  /// Answers every queued tap in order; taps that arrive meanwhile are
  /// picked up by one more pass.
  void _drain() {
    if (_draining) {
      _drainAgain = true;
      return;
    }
    _draining = true;
    unawaited(() async {
      try {
        do {
          _drainAgain = false;
          // Left queued while the app lock refuses: drained after unlock.
          if (!mounted || !widget.mayAct()) {
            return;
          }
          final actions = await widget.source.consumeActions();
          for (final action in actions) {
            if (!mounted) {
              return;
            }
            final host = await widget.findHost(action.hostId);
            // Re-checked at the moment of acting: never answered once the
            // app lock refuses (the request stays pending, answered in the
            // app).
            if (!mounted || !widget.mayAct()) {
              return;
            }
            await widget.agentAttention.completePermissionAction(action, host);
            _report(action, host);
          }
        } while (_drainAgain && mounted);
      } finally {
        _draining = false;
      }
    }());
  }

  void _report(AgentPermissionAction action, SavedHost? host) {
    if (!mounted || host == null) {
      return;
    }
    final verdict = switch (action.verdict) {
      'allow' => 'Allowed',
      'deny' => 'Denied',
      'always' => 'Always allowed',
      _ => 'Answered',
    };
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text('$verdict the permission request on ${host.name}.'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
