import 'dart:async';

import 'package:conduit/core/presentation/multiplexer_icon.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_launcher.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/hosts/presentation/home_board_controller.dart';
import 'package:conduit/features/hosts/presentation/widgets/home_session_grid.dart';
import 'package:conduit/features/session_navigation/presentation/quick_switcher_model.dart';
import 'package:conduit/features/session_navigation/presentation/session_view_controller.dart';
import 'package:conduit/features/session_navigation/presentation/session_view_launcher.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/sessions/presentation/session_connect_flow.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:conduit/features/voice/presentation/dictation_controller.dart';
import 'package:flutter/widgets.dart';

/// Where the quick switcher reads from and opens things through.
class QuickSwitcherSource {
  const QuickSwitcherSource({
    required this.workspace,
    this.attention,
    this.connectFlow,
    this.homeBoards,
  });

  final TerminalWorkspaceController workspace;
  final AgentAttentionController? attention;

  /// Opens other workspaces, recents and agents at their pane; without it
  /// the switcher only lists open sessions and waiting agents.
  final SessionConnectFlow? connectFlow;

  /// The home page's live boards (tmux sessions, Herdr workspaces).
  final HomeBoards? homeBoards;

  /// Fires when anything the switcher lists changes.
  Listenable get changes =>
      Listenable.merge([workspace, ?attention, ?homeBoards]);

  /// The machines ("This computer" on a desktop, then the saved remote
  /// ones), in the home page's order.
  List<SavedHost> get machines => [
    for (final host
        in connectFlow?.hostsController.sortedMachines ?? const <SavedHost>[])
      if (!host.isLocal) host,
  ];

  /// Each machine's recent connect-picker targets.
  Future<Map<String, List<ConnectTarget>>> loadRecents() async {
    final flow = connectFlow;
    if (flow == null) return const {};
    final entries = await Future.wait([
      for (final machine in machines)
        flow.preferences
            .load(machine.id)
            .then((preferences) => MapEntry(machine.id, preferences.recents))
            .catchError((Object _) => MapEntry(machine.id, <ConnectTarget>[])),
    ]);
    return Map.fromEntries(entries);
  }

  List<SwitcherItem> items({
    Map<String, List<ConnectTarget>> recents = const {},
  }) => buildSwitcherItems(
    sessions: workspace.sessions,
    active: workspace.activeSession,
    attention: attention,
    machines: machines,
    boards: [
      if (homeBoards case final boards?)
        for (final id in boards.hostIds)
          if (boards[id] case final board? when board.host != null)
            (host: board.host!, state: board.state),
    ],
    recents: recents,
  );

  SavedHost? machineFor(String sessionHostId) {
    final id = baseHostId(sessionHostId);
    return machines.where((machine) => machine.id == id).firstOrNull;
  }
}

/// Opens what [item] names and shows it: a session, workspace or recent
/// target (in a new or reused session) in its effective view, an agent at
/// its pane (in Chat View when its session opens there). [showTerminal]
/// brings the terminal on screen (a no-op when it already is); Chat View
/// is pushed on top of it from [context].
Future<void> openSwitcherItem(
  BuildContext context,
  SwitcherItem item, {
  required QuickSwitcherSource source,
  required VoidCallback showTerminal,
  DictationController? dictation,
}) async {
  final flow = source.connectFlow;
  final attention = source.attention;

  void toAgentPane(SavedHost host, AgentInfo agent) {
    if (flow != null) {
      unawaited(flow.openAgent(source.machineFor(host.id) ?? host, agent));
    } else if (attention != null) {
      unawaited(attention.focusAgent(host.id, agent));
    }
    showTerminal();
  }

  /// The terminal, then Chat View over it when [session] opens there.
  void show(TerminalSessionController? session, {AgentInfo? agent}) {
    if (!context.mounted) return;
    showTerminal();
    if (session == null) return;
    unawaited(
      openPreferredChatView(
        context,
        attention: attention,
        workspace: source.workspace,
        session: session,
        agent: agent,
        herdr: flow?.herdr,
        dictation: dictation,
        onOpenTerminal: toAgentPane,
      ),
    );
  }

  switch (item) {
    case SwitcherSessionItem(:final session):
      source.workspace.activate(session);
      show(session);
    case SwitcherAgentItem(:final host, :final machine, :final agent):
      TerminalSessionController? session;
      if (flow != null) {
        session = await flow.openAgent(machine ?? host, agent);
      } else {
        session = source.workspace.sessions
            .where((candidate) => candidate.host.id == host.id)
            .firstOrNull;
        if (session != null) source.workspace.activate(session);
        if (attention != null) unawaited(attention.focusAgent(host.id, agent));
      }
      if (!context.mounted) return;
      if (session != null) {
        show(session, agent: agent);
      } else if (attention != null &&
          agentOpensInChat(
            views: SessionViewScope.maybeOf(context),
            attention: attention,
            monitoredHost: host,
            agent: agent,
          )) {
        // No session to show it in: Chat View straight over the terminal.
        showTerminal();
        unawaited(
          openChatView(
            context: context,
            attention: attention,
            host: host,
            agent: agent,
            dictation: dictation,
            onOpenTerminal: () => toAgentPane(host, agent),
          ),
        );
      } else {
        showTerminal();
      }
    case SwitcherWorkspaceItem(:final host, :final kind, :final id):
      TerminalSessionController? session;
      if (kind == MultiplexerKind.herdr) {
        if (flow == null) return;
        session = await flow.openAgentLocation(
          host,
          workspaceId: id,
          label: item.label,
        );
      } else {
        session = source.workspace.sessions
            .where(
              (session) =>
                  baseHostId(session.host.id) == host.id &&
                  HomeSessionInfo.tmuxSessionOf(session) == id,
            )
            .firstOrNull;
        if (session != null) {
          source.workspace.activate(session);
        } else {
          if (flow == null) return;
          unawaited(flow.hostsController.markConnected(host));
          session = flow.open(host, ConnectTarget.tmux(id));
        }
      }
      show(session);
    case SwitcherRecentItem(:final host, :final target):
      if (flow == null) return;
      unawaited(flow.hostsController.markConnected(host));
      show(flow.open(host, target));
  }
}
