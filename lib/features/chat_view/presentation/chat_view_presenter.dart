import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_controller.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/terminal/domain/prompt_image.dart';
import 'package:conduit/features/voice/presentation/dictation_controller.dart';
import 'package:flutter/widgets.dart';

/// A Chat View ready to show: its controller is created and polling.
/// Whoever shows it owns [controller] and calls [dispose] when done.
class ChatViewRequest {
  ChatViewRequest({
    required this.host,
    required this.agent,
    required this.controller,
    required this.onOpenTerminal,
    required this.onDispose,
    this.dictation,
    this.initialDraft = '',
    this.imageAttacher,
    this.pasteImages = true,
    this.onSetUpCompanion,
    this.onEnableMonitoring,
    this.attention,
  });

  final SavedHost host;
  final AgentInfo agent;
  final ChatViewController controller;

  /// The chat's Terminal button: show the agent's TUI.
  final VoidCallback onOpenTerminal;
  final VoidCallback onDispose;
  final DictationController? dictation;
  final String initialDraft;
  final PromptImageAttacher? imageAttacher;
  final bool pasteImages;
  final VoidCallback? onSetUpCompanion;
  final Future<void> Function()? onEnableMonitoring;

  /// For the approval cards' "Trust…" and rule-saving "Always".
  final AgentAttentionController? attention;

  bool _disposed = false;

  /// Stops the chat's polling and releases its connection.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    controller.dispose();
    onDispose();
  }
}

/// Shows Chat View somewhere else than a full-screen route: the desktop
/// shell opens it as a tab that can sit in a split next to the terminal.
/// `openChatView` asks the nearest presenter first.
class ChatViewPresenter extends InheritedWidget {
  const ChatViewPresenter({
    required this.present,
    required super.child,
    super.key,
  });

  /// Takes over [ChatViewRequest]; returns false to fall back to a route.
  final bool Function(ChatViewRequest request) present;

  static ChatViewPresenter? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<ChatViewPresenter>();

  @override
  bool updateShouldNotify(ChatViewPresenter oldWidget) => false;
}
