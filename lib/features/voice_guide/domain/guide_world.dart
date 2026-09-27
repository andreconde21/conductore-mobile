import 'package:conduit/features/agent_attention/domain/agent_attention.dart';

/// Which kind of screen is showing.
enum GuideView { home, chat, terminal, other }

/// What is on screen, as far as the guide cares: the view and, in Chat
/// View or the terminal, the machine and agent it shows.
class GuideScreen {
  const GuideScreen(this.view, {this.hostId, this.agentId});

  static const home = GuideScreen(GuideView.home);

  final GuideView view;

  /// Saved host id (the machine) of the chat or terminal on screen.
  final String? hostId;

  /// The agent Chat View shows, or the one running in the terminal's pane.
  final String? agentId;
}

/// A saved machine the guide can name.
class GuideMachine {
  const GuideMachine({
    required this.hostId,
    required this.name,
    this.monitored = false,
  });

  /// Saved host id.
  final String hostId;
  final String name;

  /// Its agents are being watched (they are in [GuideWorld.agents]).
  final bool monitored;
}

/// One agent on one machine.
class GuideAgent {
  const GuideAgent({
    required this.hostId,
    required this.machineName,
    required this.info,
  });

  /// Saved host id of its machine.
  final String hostId;
  final String machineName;
  final AgentInfo info;

  String get id => info.id;

  /// What the guide calls it: its project, else its name.
  String get label {
    final project = info.projectLabel?.trim();
    if (project != null && project.isNotEmpty) return project;
    final name = info.name.trim();
    return name.isEmpty ? 'the agent' : name;
  }

  /// Its session ended (Claude exited); it only stays listed for a while.
  bool get ended => info.state == AgentAttentionState.finished;

  List<PendingPermissionRequest> get pending => info.pendingRequests;

  bool same(GuideAgent other) => other.hostId == hostId && other.id == id;
}

/// A pending permission request with the agent that asked.
class GuidePending {
  const GuidePending(this.agent, this.request);

  final GuideAgent agent;
  final PendingPermissionRequest request;

  String get hostId => agent.hostId;
}

/// The app as the guide sees it at one moment. Rebuilt for every step, so
/// agents that ended or appeared since are never acted on from a stale
/// copy.
class GuideWorld {
  const GuideWorld({
    this.machines = const [],
    this.agents = const [],
    this.screen = GuideScreen.home,
  });

  final List<GuideMachine> machines;

  /// Every agent on every watched machine, one record each.
  final List<GuideAgent> agents;
  final GuideScreen screen;

  GuideAgent? agent(String hostId, String agentId) => agents
      .where((agent) => agent.hostId == hostId && agent.id == agentId)
      .firstOrNull;

  GuideMachine? machine(String hostId) =>
      machines.where((machine) => machine.hostId == hostId).firstOrNull;

  /// The agent Chat View or the terminal shows, if the app knows it.
  GuideAgent? get onScreen {
    final hostId = screen.hostId;
    final agentId = screen.agentId;
    if (hostId == null || agentId == null) return null;
    return agent(hostId, agentId);
  }

  List<GuideAgent> get live => [
    for (final agent in agents)
      if (!agent.ended) agent,
  ];

  /// Every pending request, oldest agent state first.
  List<GuidePending> get pending => [
    for (final agent in agents)
      if (!agent.ended)
        for (final request in agent.pending) GuidePending(agent, request),
  ];

  /// [requestId] on [hostId], if it is still waiting.
  GuidePending? request(String hostId, String requestId) => pending
      .where(
        (pending) =>
            pending.hostId == hostId && pending.request.id == requestId,
      )
      .firstOrNull;
}
