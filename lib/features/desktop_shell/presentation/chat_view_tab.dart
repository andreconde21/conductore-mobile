import 'package:conduit/features/chat_view/presentation/chat_view_page.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_presenter.dart';
import 'package:conduit/features/terminal/presentation/terminal_file_tabs_controller.dart';
import 'package:flutter/material.dart';

/// Chat View as a tab of the desktop shell, so it can sit in a split next
/// to its terminal. One per agent: opening it again shows the same tab.
class ChatViewTab extends TerminalFileTab {
  ChatViewTab(this.request) : super(host: request.host, path: request.agent.id);

  final ChatViewRequest request;

  @override
  String get viewKind => 'chat';

  @override
  String get title {
    final name = request.controller.name;
    return name.isEmpty ? 'Chat' : name;
  }

  @override
  String get tooltip => 'Chat View · $title · ${host.name}';

  @override
  IconData get icon => Icons.forum_outlined;

  @override
  Listenable? get listenable => request.controller;

  @override
  bool matches(TerminalFileTab other) =>
      other is ChatViewTab &&
      other.host.id == host.id &&
      other.request.agent.id == request.agent.id;

  @override
  WidgetBuilder get viewBuilder =>
      (context) => ChatViewPage(
        key: ValueKey(this),
        controller: request.controller,
        ownsController: false,
        hostName: host.name,
        dictation: request.dictation,
        initialDraft: request.initialDraft,
        imageAttacher: request.imageAttacher,
        pasteImages: request.pasteImages,
        onSetUpCompanion: request.onSetUpCompanion,
        onEnableMonitoring: request.onEnableMonitoring,
        attention: request.attention,
        hostId: host.id,
        onOpenTerminal: request.onOpenTerminal,
      );

  @override
  void dispose() => request.dispose();
}
