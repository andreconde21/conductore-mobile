import 'dart:async';

import 'package:conduit/core/platform_features.dart';
import 'package:conduit/core/presentation/adaptive_modal.dart';
import 'package:conduit/core/presentation/system_navigation_insets.dart';
import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/core/theme/app_theme.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/domain/agent_inbox.dart';
import 'package:conduit/features/agent_attention/domain/agent_kinds.dart';
import 'package:conduit/features/agent_attention/domain/approval_rules.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/agent_attention/presentation/approval_sheets.dart';
import 'package:conduit/features/agent_attention/presentation/widgets/agent_inbox_widgets.dart';
import 'package:conduit/features/agent_attention/presentation/widgets/agent_machines_section.dart';
import 'package:conduit/features/agent_attention/presentation/widgets/agent_usage_tab.dart';
import 'package:conduit/features/agent_attention/presentation/widgets/approval_widgets.dart';
import 'package:conduit/features/agent_attention/presentation/widgets/usage_update_hint.dart';
import 'package:conduit/features/agents_digest/domain/agents_digest.dart';
import 'package:conduit/features/agents_digest/presentation/digest_controller.dart';
import 'package:conduit/features/chat_view/data/conductore_chat_client.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_launcher.dart';
import 'package:conduit/features/companion_setup/presentation/companion_setup_page.dart';
import 'package:conduit/features/desktop_shell/domain/project_tree.dart';
import 'package:conduit/features/desktop_shell/presentation/project_layout_controller.dart';
import 'package:conduit/features/desktop_shell/presentation/widgets/project_view.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/live/domain/live_host_model.dart';
import 'package:conduit/features/review/presentation/review_launcher.dart';
import 'package:conduit/features/session_navigation/domain/session_view_preferences.dart';
import 'package:conduit/features/session_navigation/presentation/session_view_controller.dart';
import 'package:conduit/features/session_navigation/presentation/session_view_launcher.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/talkbawt/presentation/talkbawt_entry.dart';
import 'package:conduit/features/talkbawt/presentation/talkbawt_scope.dart';
import 'package:conduit/features/tasks/presentation/task_runs_controller.dart';
import 'package:conduit/features/tasks/presentation/task_runs_panel.dart';
import 'package:conduit/features/usage/presentation/usage_widgets.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Opens an agent (its chat, or its terminal).
typedef DigestOpenAgent = void Function(SavedHost host, AgentInfo agent);

/// Sends a prompt to an agent; the default goes through the companion's
/// `send` over the monitor's connection.
typedef DigestSendText =
    Future<void> Function(SavedHost host, String sessionId, String text);

/// Shows the Agents screen as its own page (from home, on the phone).
Future<void> showAgentsDashboard(
  BuildContext context, {
  required DigestController controller,
  required AgentAttentionController attention,
  required DigestOpenAgent onOpenChat,
  required DigestOpenAgent onOpenTerminal,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (context) => AgentsDashboardPage(
        controller: controller,
        attention: attention,
        onOpenChat: onOpenChat,
        onOpenTerminal: onOpenTerminal,
      ),
    ),
  );
}

/// Shows the same Agents screen as a sheet (from the terminal, and the
/// home-screen widget's status tap). [controller] defaults to the app's
/// [DigestScope]. The sheet closes before an agent opens.
Future<void> showAgentsSheet({
  required BuildContext context,
  required AgentAttentionController attention,
  required DigestOpenAgent onOpenChat,
  required DigestOpenAgent onOpenTerminal,
  DigestController? controller,
}) {
  return showAdaptiveModal<void>(
    kind: AdaptiveModalKind.sidePanel,
    desktopFill: true,
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) {
      // The sheet extends under the system navigation bar; keep the last
      // card above three-button navigation (Samsung One UI reports gesture
      // insets there too, see shouldApplyBottomSafeArea).
      final bottomInset = shouldApplyBottomSafeArea(context)
          ? MediaQuery.viewPaddingOf(context).bottom
          : 0.0;
      void close(DigestOpenAgent open, SavedHost host, AgentInfo agent) {
        Navigator.of(context).pop();
        open(host, agent);
      }

      return AnnotatedRegion<SystemUiOverlayStyle>(
        value: AppTheme.systemUiOverlayStyle(Theme.of(context).brightness),
        child: DraggableScrollableSheet(
          expand: false,
          initialChildSize: adaptiveSheetFraction(context, 0.6),
          minChildSize: adaptiveSheetFraction(context, 0.3),
          maxChildSize: adaptiveSheetFraction(context, 0.92),
          builder: (context, scrollController) => AgentsDashboardView(
            controller: controller,
            attention: attention,
            scrollController: scrollController,
            tabs: true,
            inlineMenu: true,
            padding: EdgeInsets.fromLTRB(16, 8, 16, 24 + bottomInset),
            onOpenChat: (host, agent) => close(onOpenChat, host, agent),
            onOpenTerminal: (host, agent) => close(onOpenTerminal, host, agent),
          ),
        ),
      );
    },
  );
}

/// The phone's Agents page: the Agents screen under an app bar.
class AgentsDashboardPage extends StatelessWidget {
  const AgentsDashboardPage({
    required this.controller,
    required this.attention,
    required this.onOpenChat,
    required this.onOpenTerminal,
    super.key,
  });

  final DigestController controller;
  final AgentAttentionController attention;
  final DigestOpenAgent onOpenChat;
  final DigestOpenAgent onOpenTerminal;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Agents'),
        actions: [DigestWindowMenu(controller: controller)],
      ),
      body: SafeArea(
        top: false,
        child: AgentsDashboardView(
          controller: controller,
          attention: attention,
          tabs: true,
          onOpenChat: (host, agent) {
            Navigator.of(context).pop();
            onOpenChat(host, agent);
          },
          onOpenTerminal: (host, agent) {
            Navigator.of(context).pop();
            onOpenTerminal(host, agent);
          },
        ),
      ),
    );
  }
}

/// "Since last check / Last 2 hours / Today", and "Mark all seen".
class DigestWindowMenu extends StatelessWidget {
  const DigestWindowMenu({required this.controller, super.key});

  final DigestController controller;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<Object>(
      key: const ValueKey('digest-window-menu'),
      tooltip: 'Time window',
      icon: const Icon(Icons.schedule_rounded),
      onSelected: (value) {
        if (value is DigestWindow) {
          unawaited(controller.setWindow(value));
        } else {
          unawaited(controller.markAllSeen());
        }
      },
      itemBuilder: (context) => [
        for (final window in DigestWindow.values)
          CheckedPopupMenuItem<Object>(
            key: ValueKey('digest-window-${window.name}'),
            value: window,
            checked: controller.preferences.window == window,
            child: Text(window.label),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem<Object>(
          key: ValueKey('digest-mark-seen'),
          value: 'seen',
          child: Text('Mark all seen'),
        ),
      ],
    );
  }
}

/// The Agents screen, the one place agents are listed: a header line with
/// the counts, then Needs you, Stuck, Working and Done since, one card per
/// agent, with the approvals (one by one, or the safe ones at once) and
/// the auto-approved rules. With [tabs], a Usage tab (tokens, limits and
/// each session's context) and the machines' monitor status follow.
///
/// Opened as a page from home ([showAgentsDashboard]), as a sheet from the
/// terminal ([showAgentsSheet]), in the desktop's right panel, and
/// (agents only) on the desktop dashboard. Shown while mounted: it
/// attaches to the [DigestController], which polls only then.
class AgentsDashboardView extends StatefulWidget {
  const AgentsDashboardView({
    required this.attention,
    required this.onOpenChat,
    required this.onOpenTerminal,
    this.controller,
    this.sendText,
    this.padding = const EdgeInsets.fromLTRB(16, 8, 16, 24),
    this.shrinkWrap = false,
    this.inlineMenu = false,
    this.tabs = false,
    this.scrollController,
    this.now,
    this.projects,
    super.key,
  });

  /// Grouping by project (CON-065); null uses the app's
  /// ([ProjectLayoutController.instance]), and without one the dashboard
  /// groups by state only.
  final ProjectLayoutController? projects;

  /// The digest; null uses the app's ([DigestScope]), and without one the
  /// view keeps its own.
  final DigestController? controller;
  final AgentAttentionController attention;
  final DigestOpenAgent onOpenChat;
  final DigestOpenAgent onOpenTerminal;
  final DigestSendText? sendText;
  final EdgeInsets padding;

  /// Inside another scroll view (the desktop dashboard).
  final bool shrinkWrap;

  /// The window menu next to the header, or the tabs (no app bar to hold
  /// it).
  final bool inlineMenu;

  /// The Agents and Usage tabs, and the machines at the end.
  final bool tabs;

  /// The sheet's scroll controller.
  final ScrollController? scrollController;

  /// For tests: the clock used for relative times.
  final DateTime Function()? now;

  @override
  State<AgentsDashboardView> createState() => _AgentsDashboardViewState();
}

class _AgentsDashboardViewState extends State<AgentsDashboardView>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  VoidCallback? _detach;
  DigestController? _attachedTo;
  DigestController? _owned;
  bool _quietOpen = false;

  /// The pending ids the user chose to review one by one: the batch card
  /// stays hidden until that set changes.
  Set<String>? _reviewing;
  bool _batching = false;

  AgentAttentionController get _attention => widget.attention;

  DigestController get _digest =>
      widget.controller ??
      DigestScope.maybeOf(context) ??
      (_owned ??= DigestController(
        source: AttentionDigestHostSource(attention: widget.attention),
      ));

  // Swap the content as soon as a tab is picked, not after the indicator
  // animation.
  void _onTab() => setState(() {});

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this)..addListener(_onTab);
    // The auto-approved list: once per opening, then kept fresh by the
    // controller whenever a rule answers something.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      for (final host in _attention.monitoredHosts) {
        if (_attention.supportsSmartApprovals(host.id)) {
          unawaited(_attention.loadApprovals(host).catchError((_) => null));
        }
      }
    });
  }

  // Attached (and so polling) only while visible: a route on top or the
  // desktop showing a terminal instead disables tickers here.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAttached(TickerMode.valuesOf(context).enabled);
  }

  @override
  void didUpdateWidget(AgentsDashboardView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(_attachedTo, _digest)) {
      _syncAttached(false);
      _syncAttached(TickerMode.valuesOf(context).enabled);
    }
  }

  void _syncAttached(bool visible) {
    if (visible && _detach == null) {
      _attachedTo = _digest;
      _detach = _attachedTo!.attachView();
    } else if (!visible && _detach != null) {
      _detach!();
      _detach = null;
      _attachedTo = null;
    }
  }

  @override
  void dispose() {
    _detach?.call();
    _owned?.dispose();
    _tabs
      ..removeListener(_onTab)
      ..dispose();
    super.dispose();
  }

  String _hostName(String hostId) => _host(hostId)?.name ?? hostId;

  SavedHost? _host(String hostId) => _attention.monitoredHosts
      .where((host) => host.id == baseHostId(hostId))
      .firstOrNull;

  AgentInfo? _live(DigestAgent agent) => _attention
      .statusFor(agent.hostId)
      ?.agents
      .where((live) => live.id == agent.sessionId)
      .firstOrNull;

  /// The digest's agents, plus the monitor's for every machine the digest
  /// has no report from (Herdr monitoring, a companion that has not
  /// answered yet or failed): every monitored agent gets a card. Agents
  /// the user hid are left out until they change; the second value counts
  /// them.
  (DigestOverview, int) _overview(DigestController controller) {
    final digest = controller.overview;
    final reported = {
      for (final machine in controller.machines)
        if (machine.report != null) baseHostId(machine.hostId),
    };
    final agents = [
      ...digest.agents,
      for (final host in _attention.monitoredHosts)
        if (reported.add(baseHostId(host.id)))
          ...digestFromStatus(
            hostId: host.id,
            hostName: host.name,
            agents: _attention.statusFor(host.id)?.agents ?? const [],
            waitingNeedsYou: !chatViewAvailable(_attention, host),
          ).agents,
    ];
    final dismissals = _attention.inboxDismissals;
    final shown = <DigestAgent>[];
    var hidden = 0;
    for (final agent in agents) {
      final live = _live(agent);
      if (live != null &&
          _hideable(agent, digest.since) &&
          dismissals.isHidden(agent.hostId, live)) {
        hidden++;
      } else {
        shown.add(agent);
      }
    }
    return (DigestOverview(shown, since: digest.since), hidden);
  }

  /// Cards that can be swiped away (hidden until they change): the ones
  /// that need nothing.
  static bool _hideable(DigestAgent agent, DateTime since) =>
      switch (agent.sectionSince(since)) {
        DigestSection.done || DigestSection.quiet => true,
        _ => false,
      };

  /// A card's tap: the agent's effective view (Open sessions in, or the
  /// session's own choice); [other] (the long-press) the other one. An
  /// agent with no Chat View always gets its terminal (CON-107); on a
  /// machine Herdr monitors, the long-press still tries its chat (the
  /// companion may be there too). [chat] forces one.
  void _open(DigestAgent agent, {bool? chat, bool other = false}) {
    final host = _host(agent.hostId);
    final live = _live(agent);
    if (host == null || live == null) return;
    final attention = _attention;
    final canChat = supportsChatView(live, attention.agentKinds(host.id));
    final hasChat = canChat && chatViewAvailable(attention, host);
    final views = SessionViewScope.maybeOf(context);
    // Without the app's view settings (tests, embeds), Chat View.
    final inChat =
        views == null ||
        agentOpensInChat(
          views: views,
          attention: attention,
          monitoredHost: host,
          agent: live,
        );
    final preferChat = chat ?? (hasChat ? inChat != other : canChat && other);
    if (preferChat) {
      widget.onOpenChat(host, live);
    } else {
      widget.onOpenTerminal(host, live);
    }
  }

  /// Review of the agent's last turn, when its machine can show one and it
  /// is not in the middle of a turn (nor gone).
  VoidCallback? _reviewAction(DigestAgent agent) {
    final host = _host(agent.hostId);
    final live = _live(agent);
    if (host == null ||
        live == null ||
        !agentCanBeReviewed(live) ||
        live.state == AgentAttentionState.finished ||
        !reviewAvailable(_attention, host) ||
        (!agent.fromStatus &&
            agent.facts.filesEdited == 0 &&
            agent.facts.turns == 0)) {
      return null;
    }
    return () => unawaited(
      openReview(
        context: context,
        attention: _attention,
        host: host,
        agent: live,
      ),
    );
  }

  /// "Hand off" (Talkbawt), when the app has it and the agent is live on
  /// a companion machine.
  VoidCallback? _handOffAction(DigestAgent agent) {
    final host = _host(agent.hostId);
    final live = _live(agent);
    if (host == null || live == null) return null;
    return handOffAction(
      context,
      TalkbawtScope.maybeOf(context),
      _attention,
      host,
      live,
    );
  }

  Future<void> _tell(DigestAgent agent, {required bool answer}) async {
    final host = _host(agent.hostId);
    if (host == null) return;
    final text = await showDialog<String>(
      context: context,
      builder: (context) => _TellDialog(agent: agent, answer: answer),
    );
    if (text == null || text.trim().isEmpty || !mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final send = widget.sendText ?? _sendThroughCompanion;
      await send(host, agent.sessionId, text.trim());
      messenger?.showSnackBar(SnackBar(content: Text('Sent to ${agent.name}')));
    } on Object catch (error) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Could not send to ${agent.name}: $error')),
      );
    }
  }

  Future<void> _sendThroughCompanion(
    SavedHost host,
    String sessionId,
    String text,
  ) async {
    final (runner, :owned) = _attention.runnerFor(host);
    try {
      await ConductoreChatClient(runner).send(sessionId, text);
    } finally {
      if (owned) unawaited(runner.close());
    }
  }

  /// An approval's answer: Always goes through the trust sheet where the
  /// machine keeps rules; errors show as a snack bar.
  Future<void> _decide(
    DigestAgent agent,
    AgentInfo live,
    PendingPermissionRequest request,
    PermissionVerdict verdict,
  ) async {
    await answerPermissionRequest(
      context,
      controller: _attention,
      hostId: agent.hostId,
      request: request,
      verdict: verdict,
      nativeAlways: _attention.agentKinds(agent.hostId).of(live.kind).always,
    );
    unawaited(_digest.refresh());
  }

  Future<void> _approveSafe(List<PendingApproval> safe) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (!await showBatchApproveSheet(context, safe) || !mounted) {
      return;
    }
    setState(() => _batching = true);
    try {
      final result = await _attention.approveAllLowRisk(only: safe);
      final skipped = result.skipped.length;
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            'Approved ${result.approved.length}'
            '${skipped > 0 ? '; $skipped left to review' : ''}.',
          ),
        ),
      );
    } catch (error) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Could not approve: $error')),
      );
    } finally {
      if (mounted) setState(() => _batching = false);
    }
  }

  Future<void> _revoke(SavedHost host, ApprovalRule rule) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await _attention.removeRule(host, rule.id);
      messenger?.showSnackBar(
        SnackBar(content: Text('Revoked ${rule.rule}. It asks again.')),
      );
    } catch (error) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Could not revoke ${rule.rule}: $error')),
      );
    }
  }

  /// Mutes (or unmutes) the agent's notifications on this device.
  Future<void> _toggleMute(DigestAgent agent) async {
    final muted = _attention.isAgentMuted(agent.hostId, agent.sessionId);
    final messenger = ScaffoldMessenger.maybeOf(context);
    await _attention.setAgentMuted(
      agent.hostId,
      agent.sessionId,
      muted: !muted,
    );
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          muted
              ? 'Alerts for ${agent.name} are back.'
              : 'No alerts for ${agent.name} on this device. The ongoing '
                    'notification still lists it.',
        ),
      ),
    );
  }

  void _hide(DigestAgent agent) {
    if (_live(agent) case final live?) {
      _attention.inboxDismissals.dismiss(agent.hostId, live);
    }
  }

  /// The project grouping's controller, if the app has one.
  ProjectLayoutController? get _projects =>
      widget.projects ?? ProjectLayoutController.instance;

  /// The agents by project: layout projects in their order (pinned
  /// first), then the others by urgency, then Other; inside each, the
  /// state sections' order.
  List<(ProjectGroup, List<DigestAgent>)> _byProject(
    ProjectLayoutController projects,
    DigestOverview overview,
  ) {
    final byName = <String, List<DigestAgent>>{};
    final firstSection = <String, int>{};
    for (final section in DigestSection.values) {
      for (final agent in overview.section(section)) {
        final host = _host(agent.hostId);
        final name = host == null
            ? (agent.project ?? ProjectGroup.otherKey)
            : projects.projectOfAgent(
                host,
                live: _live(agent),
                project: agent.project,
              );
        (byName[name] ??= []).add(agent);
        firstSection.putIfAbsent(name, () => section.index);
      }
    }
    final layout = projects.layout;
    final order = [
      for (final index in layout.displayOrder) layout.groups[index].name,
    ];
    final names = byName.keys.toList()
      ..sort((a, b) {
        if (a == ProjectGroup.otherKey || b == ProjectGroup.otherKey) {
          return a == ProjectGroup.otherKey ? 1 : -1;
        }
        final ia = order.indexOf(a);
        final ib = order.indexOf(b);
        if (ia >= 0 || ib >= 0) {
          if (ia < 0 || ib < 0) return ia < 0 ? 1 : -1;
          return ia.compareTo(ib);
        }
        final bySection = firstSection[a]!.compareTo(firstSection[b]!);
        return bySection != 0
            ? bySection
            : a.toLowerCase().compareTo(b.toLowerCase());
      });
    int count(List<DigestAgent> agents, Set<DigestSection> sections) => agents
        .where((a) => sections.contains(a.sectionSince(overview.since)))
        .length;
    return [
      for (final name in names)
        (
          ProjectGroup(
            key: name == ProjectGroup.otherKey
                ? ProjectGroup.otherKey
                : name.toLowerCase(),
            name: name == ProjectGroup.otherKey ? 'Other' : name,
            members: const [],
            isOther: name == ProjectGroup.otherKey,
            pinned: layout.byName(name)?.pinned ?? false,
            inLayout: layout.byName(name) != null,
            needsYou: count(byName[name]!, {
              DigestSection.needsYou,
              DigestSection.stuck,
            }),
            working: count(byName[name]!, {DigestSection.working}),
            done: count(byName[name]!, {DigestSection.done}),
          ),
          byName[name]!,
        ),
    ];
  }

  /// One card, swipeable: to the right mutes or unmutes its alerts, to the
  /// left hides it (only when it needs nothing).
  Widget _card(
    DigestController controller,
    DigestAgent agent,
    DateTime now, {
    required bool hideable,
  }) {
    final host = _host(agent.hostId);
    final live = _live(agent);
    final muted = _attention.isAgentMuted(agent.hostId, agent.sessionId);
    final smart =
        host != null && _attention.supportsSmartApprovals(agent.hostId);
    final card = DigestAgentCard(
      key: ValueKey('digest-card-${agent.sessionId}'),
      agent: agent,
      live: live,
      canAct: host != null,
      muted: muted,
      canTell: host != null && chatViewAvailable(_attention, host),
      kinds: host == null ? null : _attention.agentKinds(host.id),
      summarizing: controller.isSummarizing && agent.summaryPending,
      isDeciding: _attention.isDeciding,
      now: now,
      onOpen: () => _open(agent),
      onOpenOther: () => _open(agent, other: true),
      onChat: () => _open(agent, chat: true),
      onTerminal: () => _open(agent, chat: false),
      onReview: _reviewAction(agent),
      onHandOff: _handOffAction(agent),
      onTell: (answer) => unawaited(_tell(agent, answer: answer)),
      onDecide: (request, verdict) {
        if (live != null) unawaited(_decide(agent, live, request, verdict));
      },
      onTrust: smart
          ? (request) => unawaited(
              trustPermissionRequest(
                context,
                controller: _attention,
                hostId: agent.hostId,
                request: request,
              ),
            )
          : null,
      onToggleMute: live == null ? null : () => unawaited(_toggleMute(agent)),
      onHide: hideable && live != null ? () => _hide(agent) : null,
    );
    if (live == null) {
      return Padding(padding: const EdgeInsets.only(bottom: 8), child: card);
    }
    final theme = Theme.of(context);
    Widget background(AlignmentGeometry alignment, String label) => Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 20),
      alignment: alignment,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppTheme.radius),
      ),
      child: Text(label, style: theme.textTheme.labelLarge),
    );
    return Dismissible(
      key: ValueKey('dismiss-${agent.key}'),
      direction: hideable
          ? DismissDirection.horizontal
          : DismissDirection.startToEnd,
      background: background(
        AlignmentDirectional.centerStart,
        muted ? 'Unmute' : 'Mute',
      ),
      secondaryBackground: background(AlignmentDirectional.centerEnd, 'Hide'),
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.startToEnd) {
          unawaited(_toggleMute(agent));
          return false;
        }
        return true;
      },
      onDismissed: (_) => _hide(agent),
      child: Padding(padding: const EdgeInsets.only(bottom: 8), child: card),
    );
  }

  List<Widget> _agentsChildren(
    BuildContext context,
    DigestController controller,
    DigestOverview overview,
    int hidden,
    DateTime now,
  ) {
    final projects = _projects;
    final attention = _attention;
    final hosts = attention.monitoredHosts;
    Widget card(DigestAgent agent) => _card(
      controller,
      agent,
      now,
      hideable: _hideable(agent, overview.since),
    );
    final byProject = projects != null && projects.groupByProject;
    // The machines' sidebar.toml, at most every few minutes.
    if (byProject) unawaited(projects.refresh());
    final waiting = attention.pendingApprovals;
    final safe = attention.lowRiskPending;
    final waitingIds = {for (final p in waiting) p.request.id};
    final reviewing = _reviewing;
    final showBatch =
        waiting.length >= 2 &&
        safe.isNotEmpty &&
        (reviewing == null ||
            !(reviewing.length == waitingIds.length &&
                reviewing.containsAll(waitingIds)));
    return [
      _Header(
        controller: controller,
        overview: overview,
        now: now,
        menu: widget.inlineMenu && !widget.tabs
            ? DigestWindowMenu(controller: controller)
            : null,
      ),
      if (hidden > 0)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            key: const ValueKey('agents-show-hidden'),
            onPressed: attention.inboxDismissals.restoreAll,
            child: Text('Show $hidden hidden'),
          ),
        ),
      for (final host in attention.unmonitoredHosts)
        Card(
          key: ValueKey('agents-monitoring-off-${host.id}'),
          margin: const EdgeInsets.only(bottom: 8),
          child: ListTile(
            leading: const Icon(Icons.monitor_heart_outlined),
            title: Text(
              host.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: const Text('Agent monitoring is off'),
            trailing: TextButton(
              onPressed: () => attention.enableMonitoring(host),
              child: const Text('Turn on'),
            ),
          ),
        ),
      for (final machine in controller.outdated)
        _UpdateHint(
          key: ValueKey('digest-update-hint-${machine.hostId}'),
          machine: machine,
          host: _host(machine.hostId),
        ),
      for (final machine in controller.machines)
        if (machine.error case final error?)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              '${machine.hostName}: $error',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ),
      // Started tasks (CON-037), by batch with their progress.
      if (TaskRunsController.instance case final runs?)
        TaskBatchesPanel(controller: runs, hostName: _hostName),
      if (overview.isEmpty)
        _Empty(
          loading: controller.isLoading,
          machines: hosts.isNotEmpty || controller.machines.isNotEmpty,
          hidden: hidden > 0,
        ),
      if (projects != null && !overview.isEmpty)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const ValueKey('digest-group-by-toggle'),
            onPressed: () => projects.setGroupByProject(!byProject),
            icon: Icon(
              byProject
                  ? Icons.label_important_outline_rounded
                  : Icons.folder_copy_outlined,
              size: 18,
            ),
            label: Text(byProject ? 'Group by state' : 'Group by project'),
          ),
        ),
      if (showBatch)
        BatchApprovalCard(
          waiting: waiting.length,
          safe: safe.length,
          busy: _batching,
          onReviewEach: () => setState(() => _reviewing = waitingIds),
          onApproveSafe: () => unawaited(_approveSafe(safe)),
        ),
      if (byProject)
        for (final (project, agents) in _byProject(projects, overview)) ...[
          ProjectHeaderTile(
            key: ValueKey('digest-project-${project.key}'),
            project: project,
            collapsed: projects.isCollapsed(project),
            count: agents.length,
            onToggle: () => projects.toggleCollapsed(project),
          ),
          if (!projects.isCollapsed(project))
            for (final agent in agents) card(agent),
        ]
      else
        for (final section in DigestSection.values)
          if (overview.section(section) case final agents
              when agents.isNotEmpty) ...[
            _SectionTitle(
              key: ValueKey('digest-section-${section.name}'),
              section: section,
              count: agents.length,
              open: section != DigestSection.quiet || _quietOpen,
              onToggle: section == DigestSection.quiet
                  ? () => setState(() => _quietOpen = !_quietOpen)
                  : null,
            ),
            if (section != DigestSection.quiet || _quietOpen)
              for (final agent in agents) card(agent),
          ],
      // What the machines' rules answered on their own, revocable.
      for (final host in hosts)
        if (attention.approvalsFor(host.id) case final approvals?)
          AutoApprovedSection(
            key: ValueKey('auto-approved-${host.id}'),
            hostName: host.name,
            showHost: hosts.length > 1,
            approvals: approvals,
            onRevoke: (rule) => _revoke(host, rule),
          ),
    ];
  }

  /// Tokens, cost and limits per machine (companion 0.6+), then each
  /// session's context.
  List<Widget> _usageChildren(BuildContext context) {
    final hosts = _attention.monitoredHosts;
    final usage = UsageScope.maybeOf(context);
    return [
      if (usage != null) ...[
        UsageBreakdown(
          controller: usage,
          onUpdateCompanion: (hostId) {
            final host = usage.hostFor(hostId);
            if (host != null) {
              unawaited(showCompanionSetup(context, host));
            }
          },
        ),
        const Divider(height: 24),
      ],
      ...buildAgentUsageChildren(
        context,
        _inputs(),
        showRateLimits: usage == null,
        hostNotice: (hostId) => UsageUpdateHint(
          host: hosts.firstWhere((host) => host.id == hostId),
        ),
      ),
    ];
  }

  List<AgentInboxHostInput> _inputs() => [
    for (final host in _attention.monitoredHosts)
      (
        hostId: host.id,
        hostName: host.name,
        agents: _attention.statusFor(host.id)?.agents ?? const [],
      ),
  ];

  @override
  Widget build(BuildContext context) {
    final projects = _projects;
    final controller = _digest;
    final attention = _attention;
    return ListenableBuilder(
      listenable: Listenable.merge([
        controller,
        attention,
        attention.inboxDismissals,
        ?projects,
      ]),
      builder: (context, _) {
        final (overview, hidden) = _overview(controller);
        final now = (widget.now ?? DateTime.now)();
        final hosts = attention.monitoredHosts;
        final tabBar = TabBar(
          key: const ValueKey('agents-tabs'),
          controller: _tabs,
          tabs: [
            Tab(
              height: 40,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Agents'),
                  if (attention.attentionCount case final count
                      when count > 0) ...[
                    const SizedBox(width: 6),
                    Badge.count(count: count),
                  ],
                ],
              ),
            ),
            const Tab(height: 40, text: 'Usage'),
          ],
        );
        final children = <Widget>[
          if (widget.tabs) ...[
            if (widget.inlineMenu)
              Row(
                children: [
                  Expanded(child: tabBar),
                  DigestWindowMenu(controller: controller),
                ],
              )
            else
              tabBar,
            const SizedBox(height: 8),
          ],
          if (widget.tabs && _tabs.index == 1)
            ..._usageChildren(context)
          else
            ..._agentsChildren(context, controller, overview, hidden, now),
          // Each machine's monitor: provider, problems, refresh.
          if (widget.tabs && hosts.isNotEmpty)
            AgentMachinesSection(
              hosts: hosts,
              controller: attention,
              hasAgents: !overview.isEmpty,
            ),
        ];
        final list = ListView(
          key: const ValueKey('agents-dashboard'),
          controller: widget.scrollController,
          shrinkWrap: widget.shrinkWrap,
          physics: widget.shrinkWrap
              ? const NeverScrollableScrollPhysics()
              : const AlwaysScrollableScrollPhysics(),
          padding: widget.padding,
          children: children,
        );
        if (widget.shrinkWrap) return list;
        return RefreshIndicator(onRefresh: controller.refresh, child: list);
      },
    );
  }
}

/// "14:05", "yesterday 18:10", "Tue 09:30", "3 Sep 09:30".
String digestSinceLabel(DateTime since, DateTime now) {
  final local = since.toLocal();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  String two(int n) => n.toString().padLeft(2, '0');
  final time = '${two(local.hour)}:${two(local.minute)}';
  final days = today.difference(day).inDays;
  if (days <= 0) return time;
  if (days == 1) return 'yesterday $time';
  if (days < 7) {
    const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return '${names[local.weekday - 1]} $time';
  }
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return '${local.day} ${months[local.month - 1]} $time';
}

/// "3m", "1h 20m", "2d".
String digestDuration(Duration d) {
  if (d.inMinutes < 1) return '<1m';
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  if (d.inHours < 24) {
    final m = d.inMinutes % 60;
    return m == 0 ? '${d.inHours}h' : '${d.inHours}h ${m}m';
  }
  return '${d.inDays}d';
}

class _Header extends StatelessWidget {
  const _Header({
    required this.controller,
    required this.overview,
    required this.now,
    this.menu,
  });

  final DigestController controller;
  final DigestOverview overview;
  final DateTime now;
  final Widget? menu;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    final parts = [
      'Since ${digestSinceLabel(overview.since, now)}',
      '${overview.count(DigestSection.needsYou)} need you',
      '${overview.count(DigestSection.working)} working',
      '${overview.count(DigestSection.done)} done',
      '${overview.count(DigestSection.stuck)} stuck',
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  parts.join(' · '),
                  key: const ValueKey('digest-header'),
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              ?menu,
            ],
          ),
          if (controller.isSummarizing)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                key: const ValueKey('digest-summarizing'),
                children: [
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Summarizing what changed…',
                    style: TextStyle(
                      color: palette.mutedForeground,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          if (!controller.preferences.summariesEnabled)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Summaries are off: facts only (Settings › Agents).',
                key: const ValueKey('digest-summaries-off'),
                style: TextStyle(color: palette.mutedForeground, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({
    required this.section,
    required this.count,
    required this.open,
    this.onToggle,
    super.key,
  });

  final DigestSection section;
  final int count;
  final bool open;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final color = switch (section) {
      DigestSection.needsYou => palette.attention,
      DigestSection.stuck => palette.danger,
      DigestSection.working => palette.accent,
      _ => palette.mutedForeground,
    };
    final title = Padding(
      padding: const EdgeInsets.fromLTRB(2, 12, 2, 8),
      child: Row(
        children: [
          Text(
            section.label.toUpperCase(),
            style: TextStyle(
              color: color,
              fontSize: 11.5,
              letterSpacing: 1.2,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '$count',
            style: TextStyle(color: palette.mutedForeground, fontSize: 12),
          ),
          if (onToggle != null) ...[
            const Spacer(),
            Icon(
              open ? Icons.expand_less_rounded : Icons.expand_more_rounded,
              size: 18,
              color: palette.mutedForeground,
            ),
          ],
        ],
      ),
    );
    return onToggle == null ? title : InkWell(onTap: onToggle, child: title);
  }
}

class _Empty extends StatelessWidget {
  const _Empty({
    required this.loading,
    required this.machines,
    this.hidden = false,
  });

  final bool loading;

  /// Some machine is monitored.
  final bool machines;

  /// Every agent left is one the user hid.
  final bool hidden;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final text = !machines
        ? 'No machine reports agents yet. Turn on agent monitoring in a '
              "machine's settings, then connect to it."
        : loading
        ? 'Asking your machines…'
        : hidden
        ? 'Nothing new. Hidden agents come back when they change.'
        : 'No agents in this window.';
    return Padding(
      key: const ValueKey('digest-empty'),
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(color: palette.mutedForeground),
      ),
    );
  }
}

class _UpdateHint extends StatelessWidget {
  const _UpdateHint({required this.machine, required this.host, super.key});

  final MachineDigest machine;
  final SavedHost? host;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final host = this.host;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${machine.hostName}: states only. Update the agent hooks for '
              'counts, stuck alerts and summaries.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          if (host != null)
            TextButton(
              onPressed: () => showCompanionSetup(context, host),
              child: const Text('Update agent hooks'),
            ),
        ],
      ),
    );
  }
}

/// One agent: name · machine, its state, the summary (or a line built
/// from the facts), the facts, its approvals and what can be done.
class DigestAgentCard extends StatelessWidget {
  const DigestAgentCard({
    required this.agent,
    required this.onOpen,
    required this.onOpenOther,
    required this.onChat,
    required this.onTerminal,
    required this.onTell,
    required this.onDecide,
    this.live,
    this.canAct = true,
    this.summarizing = false,
    this.isDeciding,
    this.now,
    this.onReview,
    this.onHandOff,
    this.onTrust,
    this.onToggleMute,
    this.onHide,
    this.muted = false,
    this.canTell = true,
    this.kinds,
    super.key,
  });

  final DigestAgent agent;

  /// "Trust…" on an approval (a machine that keeps rules); null hides it.
  final void Function(PendingPermissionRequest request)? onTrust;

  /// Mutes or unmutes its alerts (desktop right-click menu; phones swipe
  /// the card to the right).
  final VoidCallback? onToggleMute;

  /// Hides it until it changes (desktop right-click menu; phones swipe the
  /// card to the left); null when it needs something.
  final VoidCallback? onHide;

  /// Its notifications are muted on this device.
  final bool muted;

  /// Prompts can be sent to it (the companion's `send`): Answer and
  /// "Tell it…".
  final bool canTell;

  /// The machine's agent kinds, for the agent's name on approvals.
  final AgentKindCatalog? kinds;

  /// Opens Review of its last turn; null hides the button.
  final VoidCallback? onReview;

  /// Hands the agent's work off through Talkbawt (desktop right-click
  /// menu); null leaves it out.
  final VoidCallback? onHandOff;

  /// The monitor's record of it (its requests, with their full input);
  /// null when the monitor does not know it (ended, another machine).
  final AgentInfo? live;
  final bool canAct;
  final bool summarizing;
  final bool Function(String requestId)? isDeciding;
  final DateTime? now;

  /// The card's tap: the agent's effective view (the terminal with no
  /// transcript).
  final VoidCallback onOpen;

  /// The card's long-press: the other view.
  final VoidCallback onOpenOther;

  /// Chat and Terminal in the desktop right-click menu.
  final VoidCallback onChat;
  final VoidCallback onTerminal;

  /// true: answer a question; false: any prompt.
  final ValueChanged<bool> onTell;
  final void Function(PendingPermissionRequest, PermissionVerdict) onDecide;

  ({String label, Color color}) _chip(AppPalette palette) {
    if (agent.attention == DigestAttention.permission) {
      return (label: 'Needs approval', color: palette.attention);
    }
    if (agent.attention == DigestAttention.question) {
      return (label: 'Asks you', color: palette.attention);
    }
    if (agent.stuck.isNotEmpty) return (label: 'Stuck', color: palette.danger);
    return switch (agent.state) {
      'working' => (label: 'Working', color: palette.accent),
      'ended' => (label: 'Ended', color: palette.mutedForeground),
      _ => (label: 'Done', color: palette.success),
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);
    final chip = _chip(palette);
    final live = this.live;
    final interactive = canAct && live != null && agent.live && !agent.ended;
    final requests = live?.pendingRequests ?? const [];
    final facts = _factsRow(palette, live);
    final at = agent.lastActivityAt;
    return Material(
      color: palette.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radius),
        side: BorderSide(
          color: agent.attention != null
              ? palette.attention.withValues(alpha: 0.55)
              : agent.stuck.isNotEmpty
              ? palette.danger.withValues(alpha: 0.5)
              : palette.hairline,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: interactive ? onOpen : null,
        onLongPress: interactive ? onOpenOther : null,
        // Desktop: right-click offers the card's buttons as a menu.
        onSecondaryTapUp: interactive && PlatformFeatures.isDesktop
            ? (details) => unawaited(_menu(context, details.globalPosition))
            : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 10, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  // Agents other than Claude Code carry their badge (Codex).
                  if (normalizeAgentKind(agent.kind) != defaultAgentKind)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: AgentKindBadge(
                        key: ValueKey('digest-kind-${agent.sessionId}'),
                        kind: agent.kind,
                        size: 18,
                      ),
                    ),
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: agent.name,
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                          TextSpan(
                            text:
                                ' · ${agent.hostName}'
                                // Status from Herdr's detection: no
                                // approvals, chat or usage.
                                '${live != null && isHerdrOnlyAgent(live) ? ' · ${agentKindLabel(live.kind, kinds)} via Herdr' : ''}',
                            style: TextStyle(color: palette.mutedForeground),
                          ),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (muted)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Tooltip(
                        message: 'Muted',
                        child: Icon(
                          Icons.notifications_off_outlined,
                          key: ValueKey('digest-muted-${agent.sessionId}'),
                          size: 14,
                          color: palette.mutedForeground,
                        ),
                      ),
                    ),
                  if (at != null)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Text(
                        relativeAgentTime(at, now: now),
                        style: TextStyle(
                          color: palette.mutedForeground,
                          fontSize: 11.5,
                        ),
                      ),
                    ),
                  Container(
                    key: ValueKey('digest-state-${agent.sessionId}'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: chip.color.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(AppTheme.radius),
                    ),
                    child: Text(
                      chip.label,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: chip.color,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                agent.line,
                key: ValueKey('digest-line-${agent.sessionId}'),
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium,
              ),
              if (summarizing)
                Text(
                  'Updating the summary…',
                  style: TextStyle(
                    color: palette.mutedForeground,
                    fontSize: 11.5,
                  ),
                ),
              for (final flag in agent.stuck)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                    children: [
                      Icon(
                        Icons.warning_amber_rounded,
                        size: 14,
                        color: palette.danger,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          flag.reason,
                          style: TextStyle(color: palette.danger, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
              if (facts.isNotEmpty) ...[
                const SizedBox(height: 6),
                Wrap(
                  key: ValueKey('digest-facts-${agent.sessionId}'),
                  spacing: 12,
                  runSpacing: 4,
                  children: facts,
                ),
              ],
              if (interactive)
                for (final request in requests) ...[
                  const SizedBox(height: 8),
                  PendingRequestCard(
                    key: ValueKey('request-${request.id}'),
                    request: request,
                    agentName: agentKindLabel(agent.kind, kinds),
                    busy: isDeciding?.call(request.id) ?? false,
                    onDecide: (verdict) => onDecide(request, verdict),
                    onAnswer: (answers) => onDecide(
                      request.withAnswers(answers),
                      PermissionVerdict.allow,
                    ),
                    onTrust: switch (onTrust) {
                      final trust? => () => trust(request),
                      null => null,
                    },
                  ),
                ],
              // One secondary action at most; the card's tap opens its
              // view and the long-press the other one (CON-107).
              if (interactive)
                if (_secondary() case final action?)
                  Align(alignment: Alignment.centerRight, child: action),
            ],
          ),
        ),
      ),
    );
  }

  /// Answer when it asks something, else Review when there is a turn to
  /// review. "Tell it…" and Hand off live in Chat View (and in the
  /// desktop right-click menu).
  Widget? _secondary() {
    if (canTell &&
        agent.attention == DigestAttention.question &&
        agent.state != 'needs_permission') {
      return TextButton.icon(
        key: ValueKey('digest-tell-${agent.sessionId}'),
        style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
        onPressed: () => onTell(true),
        icon: const Icon(Icons.reply_rounded, size: 18),
        label: const Text('Answer'),
      );
    }
    if (onReview case final review?) {
      return TextButton.icon(
        key: ValueKey('digest-review-${agent.sessionId}'),
        style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
        onPressed: review,
        icon: const Icon(Icons.rate_review_outlined, size: 18),
        label: const Text('Review'),
      );
    }
    return null;
  }

  Future<void> _menu(BuildContext context, Offset position) async {
    final question = agent.attention == DigestAttention.question;
    final actions = <(String, IconData, VoidCallback)>[
      ('Chat', Icons.forum_outlined, onChat),
      ('Terminal', Icons.terminal_rounded, onTerminal),
      if (onReview case final review?)
        ('Review', Icons.rate_review_outlined, review),
      if (onHandOff case final handOff?)
        ('Hand off…', Icons.outbox_outlined, handOff),
      if (canTell && agent.state != 'needs_permission')
        (
          question ? 'Answer…' : 'Tell it…',
          Icons.reply_rounded,
          () => onTell(question),
        ),
      if (onToggleMute case final toggle?)
        (
          muted ? 'Unmute notifications' : 'Mute notifications',
          muted
              ? Icons.notifications_active_outlined
              : Icons.notifications_off_outlined,
          toggle,
        ),
      if (onHide case final hide?)
        ('Hide', Icons.visibility_off_outlined, hide),
    ];
    final picked = await showAdaptiveModal<VoidCallback>(
      context: context,
      kind: AdaptiveModalKind.menu,
      anchorPosition: position,
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (label, icon, action) in actions)
            ListTile(
              key: ValueKey('digest-menu-$label'),
              dense: true,
              leading: Icon(icon, size: 20),
              title: Text(label),
              onTap: () => Navigator.of(context).pop(action),
            ),
        ],
      ),
    );
    picked?.call();
  }

  List<Widget> _factsRow(AppPalette palette, AgentInfo? live) {
    final f = agent.facts;
    final muted = TextStyle(color: palette.mutedForeground, fontSize: 12);
    Widget fact(String key, IconData icon, String text, {Color? color}) => Row(
      key: ValueKey('digest-fact-$key-${agent.sessionId}'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color ?? palette.mutedForeground),
        const SizedBox(width: 4),
        Text(text, style: color == null ? muted : muted.copyWith(color: color)),
      ],
    );
    return [
      if (f.filesEdited > 0)
        fact(
          'files',
          Icons.edit_note_rounded,
          '${f.filesEdited} ${f.filesEdited == 1 ? 'file' : 'files'} '
              '+${f.linesAdded} −${f.linesRemoved}',
        ),
      if (f.testRuns > 0)
        fact(
          'tests',
          f.lastTestPassed == false
              ? Icons.cancel_outlined
              : Icons.check_circle_outline_rounded,
          'tests ✓${f.testsPassed} ✗${f.testsFailed}',
          color: f.lastTestPassed == false ? palette.danger : palette.success,
        ),
      if (f.turns > 0)
        fact(
          'turns',
          Icons.chat_bubble_outline_rounded,
          '${f.turns} ${f.turns == 1 ? 'turn' : 'turns'}',
        ),
      if (f.tokens case final tokens? when tokens > 0)
        fact(
          'tokens',
          Icons.toll_outlined,
          '${compactTokens(tokens)} tok${_cost(f.costUsd)}',
        ),
      if (live?.usage?.contextUsedPct case final pct?)
        fact('context', Icons.data_usage_rounded, 'context ${pct.round()}%'),
      if (f.waitingPermission + f.waitingInput case final waited
          when agent.attention != null && waited.inMinutes >= 1)
        fact(
          'waiting',
          Icons.hourglass_bottom_rounded,
          'waited ${digestDuration(waited)}',
        ),
    ];
  }
}

/// " · $0.41" for an estimate of at least a cent, else nothing.
String _cost(double? usd) =>
    usd != null && usd >= 0.01 ? ' · \$${usd.toStringAsFixed(2)}' : '';

class _TellDialog extends StatefulWidget {
  const _TellDialog({required this.agent, required this.answer});

  final DigestAgent agent;
  final bool answer;

  @override
  State<_TellDialog> createState() => _TellDialogState();
}

class _TellDialogState extends State<_TellDialog> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final question = widget.answer ? widget.agent.headline : null;
    final desktop = PlatformFeatures.isDesktop;
    final send = FilledButton(
      key: const ValueKey('digest-tell-send'),
      onPressed: _send,
      child: const Text('Send'),
    );
    final dialog = AlertDialog(
      title: Text(
        widget.answer
            ? 'Answer ${widget.agent.name}'
            : 'Tell ${widget.agent.name}',
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (question != null) ...[
            Text(question, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
          ],
          TextField(
            key: const ValueKey('digest-tell-field'),
            controller: _text,
            autofocus: true,
            minLines: 1,
            maxLines: 5,
            decoration: const InputDecoration(hintText: 'Message'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        if (desktop)
          Tooltip(message: '${_mac ? 'Cmd' : 'Ctrl'}+Enter', child: send)
        else
          send,
      ],
    );
    if (!desktop) return dialog;
    // Desktop: Ctrl+Enter (Cmd+Enter on macOS) sends; Enter is a new line.
    return CallbackShortcuts(
      bindings: {
        SingleActivator(LogicalKeyboardKey.enter, control: !_mac, meta: _mac):
            _send,
      },
      child: dialog,
    );
  }

  void _send() => Navigator.of(context).pop(_text.text);

  static bool get _mac => defaultTargetPlatform == TargetPlatform.macOS;
}
