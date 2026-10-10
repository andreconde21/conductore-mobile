import 'dart:async';

import 'package:conduit/features/agent_attention/domain/agent_permission_actions.dart';
import 'package:conduit/features/agent_attention/domain/launcher_prompt.dart';
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
///
/// Launcher answers held while the app was locked or not running
/// (contract 3, CON-119) are sent once the app lock lets actions run: on
/// mount, whenever [lockChanges] notifies and when the platform says one
/// was held. Each says in a snack bar whether it was sent.
class AgentPermissionActionListener extends StatefulWidget {
  const AgentPermissionActionListener({
    required this.source,
    required this.agentAttention,
    required this.findHost,
    required this.child,
    this.launcherActions,
    this.mayAct = _always,
    this.lockChanges,
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

  /// Notifies when [mayAct] may have changed (the app lock's action
  /// state): held launcher answers go out after the unlock.
  final Listenable? lockChanges;

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
  bool _sendingHeld = false;
  bool _sendHeldAgain = false;

  @override
  void initState() {
    super.initState();
    widget.source.setListener(_onAction);
    widget.launcherActions?.setListener(_onLauncherAction);
    widget.launcherActions?.setQueuedListener(_sendHeld);
    widget.lockChanges?.addListener(_sendHeld);
    _drain();
    _sendHeld();
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
      oldWidget.launcherActions?.setQueuedListener(null);
      widget.launcherActions?.setListener(_onLauncherAction);
      widget.launcherActions?.setQueuedListener(_sendHeld);
    }
    if (oldWidget.lockChanges != widget.lockChanges) {
      oldWidget.lockChanges?.removeListener(_sendHeld);
      widget.lockChanges?.addListener(_sendHeld);
    }
  }

  @override
  void dispose() {
    widget.source.setListener(null);
    widget.launcherActions?.setListener(null);
    widget.launcherActions?.setQueuedListener(null);
    widget.lockChanges?.removeListener(_sendHeld);
    super.dispose();
  }

  /// Sends the launcher answers held for the unlock, in order, and says
  /// how each went; held ones that arrive meanwhile get one more pass.
  void _sendHeld() {
    final source = widget.launcherActions;
    if (source == null) {
      return;
    }
    if (_sendingHeld) {
      _sendHeldAgain = true;
      return;
    }
    _sendingHeld = true;
    unawaited(() async {
      try {
        do {
          _sendHeldAgain = false;
          // Left held while the app lock refuses: sent after unlock.
          if (!mounted || !widget.mayAct()) {
            return;
          }
          final answers = await source.takeQueued();
          for (final (index, answer) in answers.indexed) {
            final host = await widget.findHost(answer.action.hostId);
            // Re-checked at the moment of sending: gone or locked again,
            // this one and the rest stay held for the next unlock.
            if (!mounted || !widget.mayAct()) {
              await source.releaseQueued([
                for (final left in answers.skip(index)) left.key,
              ]);
              return;
            }
            final error = await widget.agentAttention
                .deliverQueuedLauncherAnswer(answer, host);
            if (heldAnswerSettled(error)) {
              await source.resolveQueued(answer.key);
            } else {
              await source.releaseQueued([answer.key]);
            }
            _reportHeld(answer, error);
          }
        } while (_sendHeldAgain && mounted);
      } finally {
        _sendingHeld = false;
      }
    }());
  }

  void _reportHeld(QueuedLauncherAnswer answer, String? error) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(heldAnswerMessage(answer, error))));
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

/// Whether a held launcher answer is done with after [error]: sent
/// (null), or dropped on purpose (expired, stale or answered elsewhere,
/// no longer answerable from the launcher, its machine deleted). Anything
/// else (the machine not monitored yet, a failed send) leaves it held, to
/// be tried after the next unlock until it expires.
bool heldAnswerSettled(String? error) => switch (error) {
  null ||
  QueuedLauncherAnswer.expiredError ||
  LauncherPrompt.staleError ||
  LauncherPrompt.highRiskNote ||
  LauncherPrompt.terminalNote ||
  LauncherPrompt.openNote ||
  LauncherPrompt.severalQuestionsNote ||
  LauncherPrompt.multiSelectNote ||
  AgentAttentionController.machineGoneError => true,
  _ => false,
};

/// What the app says about a held launcher answer: sent ([error] null),
/// dropped and why, or still held and why.
String heldAnswerMessage(QueuedLauncherAnswer answer, String? error) {
  if (error == null) {
    return 'Sent your answer to ${answer.label}.';
  }
  if (!heldAnswerSettled(error)) {
    return 'Your answer to ${answer.label} is still waiting: '
        '${error.endsWith('.') ? error.substring(0, error.length - 1) : error}. '
        'Conductore tries again after the next unlock.';
  }
  final reason = switch (error) {
    LauncherPrompt.staleError => 'it was answered elsewhere',
    _ => error.endsWith('.') ? error.substring(0, error.length - 1) : error,
  };
  return "Your answer to ${answer.label} wasn't sent: $reason.";
}
