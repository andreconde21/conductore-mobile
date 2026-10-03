import 'dart:async';

import 'package:conduit/core/presentation/terminal_route.dart';
import 'package:conduit/features/agent_attention/data/conductore_host_attention_provider.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/domain/approval_rules.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/chat_view/data/conductore_chat_client.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_launcher.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/hosts/presentation/hosts_controller.dart';
import 'package:conduit/features/review/data/review_client.dart';
import 'package:conduit/features/review/presentation/review_launcher.dart';
import 'package:conduit/features/session_navigation/domain/session_view_preferences.dart';
import 'package:conduit/features/session_navigation/presentation/session_view_controller.dart';
import 'package:conduit/features/session_navigation/presentation/session_view_launcher.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/sessions/presentation/session_connect_flow.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:conduit/features/usage/domain/usage_summary.dart';
import 'package:conduit/features/usage/presentation/usage_controller.dart';
import 'package:conduit/features/voice_guide/domain/approval_actions.dart';
import 'package:conduit/features/voice_guide/domain/guide_ports.dart';
import 'package:conduit/features/voice_guide/domain/guide_world.dart';
import 'package:conduit/features/voice_guide/presentation/guide_controller.dart';
import 'package:flutter/widgets.dart';

/// The app's machines and agents as the guide sees them: every saved
/// machine, and every agent of every monitored one (a machine with
/// several open sessions is monitored once per session; its agents are
/// listed once, under the saved host id).
GuideWorld buildGuideWorld({
  required AgentAttentionController attention,
  required HostsController hosts,
  required GuideScreen screen,
}) {
  final monitored = attention.monitoredHosts;
  final machines = [
    for (final host in hosts.machines)
      if (!host.isLocal)
        GuideMachine(
          hostId: host.id,
          name: host.name,
          monitored: monitored.any((m) => baseHostId(m.id) == host.id),
        ),
  ];
  final seen = <String>{};
  final agents = <GuideAgent>[];
  for (final host in monitored) {
    final base = baseHostId(host.id);
    if (!seen.add(base)) continue;
    final name = hosts.findById(base)?.name ?? host.name;
    for (final agent
        in attention.statusFor(host.id)?.agents ?? const <AgentInfo>[]) {
      agents.add(GuideAgent(hostId: base, machineName: name, info: agent));
    }
  }
  return GuideWorld(machines: machines, agents: agents, screen: screen);
}

/// The monitored session host of saved machine [savedHostId] (the key the
/// attention controller, Chat View and the connect flow use).
SavedHost? monitoredHostFor(
  AgentAttentionController attention,
  String savedHostId,
) => attention.monitoredHosts
    .where((host) => baseHostId(host.id) == savedHostId)
    .firstOrNull;

/// The guide's approvals over the agent monitor: one request at a time
/// through `decide` everywhere, plus the companion's smart approvals
/// (risk labels, approve all low-risk, time-boxed trust) on machines that
/// report the `smart-approvals` capability. Host ids here are saved host
/// ids; the monitor keys its machines by session host id.
ApprovalActions attentionApprovalActions(AgentAttentionController attention) {
  String session(String hostId) {
    final host = monitoredHostFor(attention, hostId);
    if (host == null) throw StateError('That machine is not connected.');
    return host.id;
  }

  bool supportedOn(String hostId) {
    final host = monitoredHostFor(attention, hostId);
    return host != null && attention.supportsSmartApprovals(host.id);
  }

  return SmartApprovalActions(
    riskOf: (_, request) => switch (request.risk?.level) {
      PermissionRiskLevel.low => ApprovalRisk.low,
      PermissionRiskLevel.medium => ApprovalRisk.medium,
      PermissionRiskLevel.high => ApprovalRisk.high,
      null => ApprovalRisk.unknown,
    },
    decide: (hostId, request, verdict) => verdict == PermissionVerdict.allow
        ? attention.approveRequest(session(hostId), request)
        : attention.decide(session(hostId), request, verdict),
    supportedOn: supportedOn,
    supported: () => attention.monitoredHosts.any(
      (host) => attention.supportsSmartApprovals(host.id),
    ),
    approveLow: (targets) async {
      final wanted = {for (final t in targets) '${t.hostId}/${t.request.id}'};
      final only = [
        for (final pending in attention.lowRiskPending)
          if (wanted.contains(
            '${baseHostId(pending.hostId)}/${pending.request.id}',
          ))
            pending,
      ];
      if (only.isEmpty) return 0;
      final result = await attention.approveAllLowRisk(only: only);
      return result.approved.length;
    },
    // No rule: the companion saves the exact call as the rule.
    trust: (hostId, request, duration) => attention.trustRequest(
      session(hostId),
      request,
      duration: TrustDuration.minutes(duration.inMinutes),
      source: 'voice',
    ),
  );
}

/// Sends prompts through the companion's `send` on the agent's machine.
class AttentionGuideMessenger implements GuideMessenger {
  AttentionGuideMessenger(this.attention);

  final AgentAttentionController attention;

  @override
  Future<void> send(GuideAgent agent, String text) async {
    final host = monitoredHostFor(attention, agent.hostId);
    if (host == null) throw StateError('That machine is not connected.');
    final (runner, :owned) = attention.runnerFor(host);
    try {
      await ConductoreChatClient(runner).send(agent.id, text);
    } finally {
      if (owned) unawaited(runner.close());
    }
  }
}

/// The machines that may be the brain, best first: the one picked in
/// Settings (connected or not: the brain runs over its own command
/// channel), else every connected machine whose agents come from the
/// companion.
List<SavedHost> guideBrainCandidates({
  required AgentAttentionController attention,
  required HostsController hosts,
  required String preferredHostId,
}) {
  if (preferredHostId.isNotEmpty) {
    final host =
        monitoredHostFor(attention, preferredHostId) ??
        hosts.findById(preferredHostId);
    return [?host];
  }
  const companion = ConductoreHostAttentionProvider();
  final seen = <String>{};
  return [
    for (final host in attention.monitoredHosts)
      if (!host.isLocal &&
          attention.providerFor(host.id).id == companion.id &&
          seen.add(baseHostId(host.id)))
        host,
  ];
}

/// Spoken Claude limits: "5-hour limit 42 percent, weekly 18 percent."
String? guideUsageText(UsageSummary summary, String languageCode) {
  final now = DateTime.now();
  final fiveHour = summary.fiveHour;
  final weekly = summary.weekly;
  if (fiveHour == null && weekly == null) return null;
  String pct(double value) => value.round().toString();
  String? resets(DateTime? at, bool pt) {
    if (at == null || !at.isAfter(now)) return null;
    final left = at.difference(now);
    final hours = left.inHours;
    final minutes = left.inMinutes % 60;
    if (pt) {
      return hours > 0
          ? 'renova em $hours h e $minutes minutos'
          : 'renova em $minutes minutos';
    }
    return hours > 0
        ? 'resets in $hours h $minutes minutes'
        : 'resets in $minutes minutes';
  }

  final pt = languageCode == 'pt';
  final parts = <String>[];
  if (fiveHour != null) {
    final reset = resets(fiveHour.resetsAt, pt);
    parts.add(
      pt
          ? 'Limite de 5 horas a ${pct(fiveHour.effectivePct(now))} por cento'
                '${reset == null ? '' : ', $reset'}'
          : '5-hour limit ${pct(fiveHour.effectivePct(now))} percent'
                '${reset == null ? '' : ', $reset'}',
    );
  }
  if (weekly != null) {
    parts.add(
      pt
          ? 'semanal a ${pct(weekly.effectivePct(now))} por cento'
          : 'weekly ${pct(weekly.effectivePct(now))} percent',
    );
  }
  return '${parts.join('. ')}.';
}

/// Claude account switching for the guide over the usage feature: the
/// accounts cswap reports, switchable where a machine's companion has
/// cswap.
class UsageGuideAccounts implements GuideAccounts {
  UsageGuideAccounts(this.usage);

  final UsageController usage;

  @override
  bool get available =>
      usage.summary.machines.any((machine) => machine.canSwitchAccounts);

  @override
  List<GuideAccount> get accounts => [
    for (final account in usage.summary.accounts)
      GuideAccount(
        label: account.label,
        active: account.active,
        targets: [
          for (final p in account.switchTargets)
            (hostId: p.hostId, hostName: p.hostName, slot: p.account.slot!),
        ],
      ),
  ];

  @override
  Future<List<GuideAccountSwitch>> switchTo(GuideAccount account) async => [
    for (final target in account.targets)
      await usage
          .switchAccount(target.hostId, slot: target.slot)
          .then(
            (result) =>
                (hostName: target.hostName, ok: result.ok, error: result.error),
          ),
  ];
}

/// Moves the app for the guide: pops back home, then opens Chat View or
/// the terminal through the same paths as a tap (openChatView, the
/// connect flow's deep links).
class AppGuideNavigator implements GuideNavigator {
  AppGuideNavigator({
    required this.navigatorKey,
    required this.workspace,
    required this.attention,
    required this.hosts,
    this.connectFlow,
    this.sessionViews,
  });

  final GlobalKey<NavigatorState> navigatorKey;
  final TerminalWorkspaceController workspace;
  final AgentAttentionController attention;
  final HostsController hosts;
  final SessionConnectFlow? connectFlow;
  final SessionViewController? sessionViews;

  NavigatorState? get _navigator => navigatorKey.currentState;

  @override
  GuideScreen get screen {
    final navigator = _navigator;
    if (navigator == null) return GuideScreen.home;
    final top = topRouteOf(navigator);
    if (top == null) return GuideScreen.home;
    if (reviewRouteTarget(top) case final target?) {
      return GuideScreen(
        GuideView.other,
        hostId: baseHostId(target.hostId),
        agentId: target.agentId,
      );
    }
    if (chatRouteTarget(top) case final target?) {
      return GuideScreen(
        GuideView.chat,
        hostId: baseHostId(target.hostId),
        agentId: target.agentId,
      );
    }
    if (isTerminalRoute(top)) {
      final session = workspace.activeSession;
      if (session == null) return const GuideScreen(GuideView.terminal);
      final agent = chatAgentForSession(attention, session.host);
      return GuideScreen(
        GuideView.terminal,
        hostId: baseHostId(session.host.id),
        agentId: agent?.id,
      );
    }
    return top.isFirst ? GuideScreen.home : const GuideScreen(GuideView.other);
  }

  @override
  Future<void> home() async {
    _navigator?.popUntil((route) => route.isFirst);
  }

  @override
  Future<GuideView?> openAgent(GuideAgent agent, {GuideView? view}) async {
    final host = monitoredHostFor(attention, agent.hostId);
    if (host == null) return null;
    final info = agent.info;
    final canChat =
        supportsChatView(info, attention.agentKinds(host.id)) &&
        !agent.ended &&
        chatViewAvailable(attention, host);
    final wantChat =
        view == GuideView.chat ||
        (view == null &&
            agentOpensInChat(
              views: sessionViews,
              attention: attention,
              monitoredHost: host,
              agent: info,
            ));
    await home();
    final flow = connectFlow;
    if (wantChat && canChat) {
      final context = _navigator?.overlay?.context;
      if (context == null || !context.mounted) return null;
      unawaited(
        openChatView(
          context: context,
          attention: attention,
          host: host,
          agent: info,
          onOpenTerminal: () {
            if (flow != null) {
              unawaited(flow.openAgent(host, info));
            } else {
              unawaited(attention.focusAgent(host.id, info));
            }
          },
        ),
      );
      return GuideView.chat;
    }
    if (flow == null) return null;
    final session = await flow.openAgent(host, info);
    return session == null ? null : GuideView.terminal;
  }

  @override
  Future<bool> openMachine(GuideMachine machine) async {
    final flow = connectFlow;
    final saved = hosts.findById(machine.hostId);
    if (flow == null || saved == null) return false;
    await home();
    final open = workspace.sessions
        .where((session) => baseHostId(session.host.id) == saved.id)
        .firstOrNull;
    if (open != null) {
      workspace.activate(open);
      flow.terminalRequests.value += 1;
      return true;
    }
    final remembered = await flow.preferences.load(saved.id);
    final context = _navigator?.overlay?.context;
    if (context == null || !context.mounted) return false;
    final connecting = flow.connect(context, saved);
    if (!remembered.rememberChoice || remembered.lastTarget == null) {
      // The connect picker is on screen; the user picks there.
      unawaited(
        connecting.then((session) {
          if (session != null) flow.terminalRequests.value += 1;
        }),
      );
      return false;
    }
    final session = await connecting;
    if (session == null) return false;
    flow.terminalRequests.value += 1;
    return true;
  }
}

/// Review and "undo that" for the guide, through the companion's turn
/// snapshots on the agent's machine (the same calls as the Review page).
class AppGuideReviewer implements GuideReviewer {
  AppGuideReviewer({required this.navigatorKey, required this.attention});

  final GlobalKey<NavigatorState> navigatorKey;
  final AgentAttentionController attention;

  SavedHost? _host(GuideAgent agent) =>
      monitoredHostFor(attention, agent.hostId);

  @override
  bool canReview(GuideAgent agent) {
    final host = _host(agent);
    return host != null && !agent.ended && reviewAvailable(attention, host);
  }

  @override
  bool canUndo(GuideAgent agent) {
    final host = _host(agent);
    return host != null && attention.supportsSnapshots(host.id);
  }

  @override
  Future<bool> review(GuideAgent agent) async {
    final host = _host(agent);
    final navigator = navigatorKey.currentState;
    if (host == null || navigator == null) return false;
    final top = topRouteOf(navigator);
    final showing = top == null ? null : reviewRouteTarget(top);
    if (showing != null &&
        showing.hostId == host.id &&
        showing.agentId == agent.id) {
      return true;
    }
    final context = navigator.overlay?.context;
    if (context == null || !context.mounted) return false;
    unawaited(
      openReview(
        context: context,
        attention: attention,
        host: host,
        agent: agent.info,
      ),
    );
    return true;
  }

  Future<T> _withClient<T>(
    GuideAgent agent,
    Future<T> Function(ConductoreReviewClient client) body,
  ) async {
    final host = _host(agent);
    if (host == null) throw StateError('That machine is not connected.');
    final (runner, :owned) = attention.runnerFor(host);
    try {
      return await body(ConductoreReviewClient(runner));
    } finally {
      if (owned) unawaited(runner.close());
    }
  }

  @override
  Future<GuideTurnPreview?> lastTurn(GuideAgent agent) =>
      _withClient(agent, (client) async {
        final turn = (await client.turns(agent.id)).latest;
        if (turn == null) return null;
        final dry = await client.undo(agent.id, turn.turn, dryRun: true);
        return GuideTurnPreview(
          turn: turn.turn,
          files: dry.restored.length,
          prompt: turn.prompt,
        );
      });

  @override
  Future<int> undo(GuideAgent agent, int turn) => _withClient(
    agent,
    (client) async => (await client.undo(agent.id, turn)).restored.length,
  );
}

/// Makes the guide reachable from the pages that start it (the home bar,
/// Chat View's Talk button).
class GuideScope extends InheritedWidget {
  const GuideScope({required this.controller, required super.child, super.key});

  final GuideController controller;

  static GuideController? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<GuideScope>()?.controller;

  @override
  bool updateShouldNotify(GuideScope oldWidget) =>
      controller != oldWidget.controller;
}
