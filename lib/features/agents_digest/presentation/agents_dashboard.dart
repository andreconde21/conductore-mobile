import 'dart:async';

import 'package:conduit/core/platform_features.dart';
import 'package:conduit/core/presentation/adaptive_modal.dart';
import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/core/theme/app_theme.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/agent_attention/presentation/widgets/agent_inbox_widgets.dart';
import 'package:conduit/features/agents_digest/domain/agents_digest.dart';
import 'package:conduit/features/agents_digest/presentation/digest_controller.dart';
import 'package:conduit/features/chat_view/data/conductore_chat_client.dart';
import 'package:conduit/features/companion_setup/presentation/companion_setup_page.dart';
import 'package:conduit/features/desktop_shell/domain/project_tree.dart';
import 'package:conduit/features/desktop_shell/presentation/project_layout_controller.dart';
import 'package:conduit/features/desktop_shell/presentation/widgets/project_view.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/review/presentation/review_launcher.dart';
import 'package:conduit/features/session_navigation/domain/session_view_preferences.dart';
import 'package:conduit/features/session_navigation/presentation/session_view_controller.dart';
import 'package:conduit/features/talkbawt/presentation/talkbawt_entry.dart';
import 'package:conduit/features/talkbawt/presentation/talkbawt_scope.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Opens an agent (its chat, or its terminal).
typedef DigestOpenAgent = void Function(SavedHost host, AgentInfo agent);

/// Sends a prompt to an agent; the default goes through the companion's
/// `send` over the monitor's connection.
typedef DigestSendText =
    Future<void> Function(SavedHost host, String sessionId, String text);

/// Shows the agents dashboard as its own screen (the phone).
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

/// The phone's Agents screen: the dashboard under an app bar.
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

/// The dashboard: a header line with the counts, then Needs you, Stuck,
/// Working and Done since, one card per agent. Shown while mounted: it
/// attaches to the [DigestController], which polls only then.
class AgentsDashboardView extends StatefulWidget {
  const AgentsDashboardView({
    required this.controller,
    required this.attention,
    required this.onOpenChat,
    required this.onOpenTerminal,
    this.sendText,
    this.padding = const EdgeInsets.fromLTRB(16, 8, 16, 24),
    this.shrinkWrap = false,
    this.inlineMenu = false,
    this.now,
    this.projects,
    super.key,
  });

  /// Grouping by project (CON-065); null uses the app's
  /// ([ProjectLayoutController.instance]), and without one the dashboard
  /// groups by state only.
  final ProjectLayoutController? projects;

  final DigestController controller;
  final AgentAttentionController attention;
  final DigestOpenAgent onOpenChat;
  final DigestOpenAgent onOpenTerminal;
  final DigestSendText? sendText;
  final EdgeInsets padding;

  /// Inside another scroll view (the desktop dashboard).
  final bool shrinkWrap;

  /// The window menu next to the header (no app bar to hold it).
  final bool inlineMenu;

  /// For tests: the clock used for relative times.
  final DateTime Function()? now;

  @override
  State<AgentsDashboardView> createState() => _AgentsDashboardViewState();
}

class _AgentsDashboardViewState extends State<AgentsDashboardView> {
  VoidCallback? _detach;
  bool _quietOpen = false;

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
    if (!identical(oldWidget.controller, widget.controller)) {
      _syncAttached(false);
      _syncAttached(TickerMode.valuesOf(context).enabled);
    }
  }

  void _syncAttached(bool visible) {
    if (visible && _detach == null) {
      _detach = widget.controller.attachView();
    } else if (!visible && _detach != null) {
      _detach!();
      _detach = null;
    }
  }

  @override
  void dispose() {
    _detach?.call();
    super.dispose();
  }

  SavedHost? _host(String hostId) => widget.attention.monitoredHosts
      .where((host) => host.id == hostId)
      .firstOrNull;

  AgentInfo? _live(DigestAgent agent) => widget.attention
      .statusFor(agent.hostId)
      ?.agents
      .where((live) => live.id == agent.sessionId)
      .firstOrNull;

  void _open(DigestAgent agent, {bool? chat}) {
    final host = _host(agent.hostId);
    final live = _live(agent);
    if (host == null || live == null) return;
    final preferChat =
        chat ??
        (SessionViewScope.maybeOf(context)?.defaultView ?? SessionView.chat) ==
            SessionView.chat;
    if (preferChat) {
      widget.onOpenChat(host, live);
    } else {
      widget.onOpenTerminal(host, live);
    }
  }

  /// Review of the agent's last turn, when its machine can show one and it
  /// is not in the middle of a turn.
  VoidCallback? _reviewAction(DigestAgent agent) {
    final host = _host(agent.hostId);
    final live = _live(agent);
    if (host == null ||
        live == null ||
        !agentCanBeReviewed(live) ||
        !reviewAvailable(widget.attention, host) ||
        (agent.facts.filesEdited == 0 && agent.facts.turns == 0)) {
      return null;
    }
    return () => unawaited(
      openReview(
        context: context,
        attention: widget.attention,
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
      widget.attention,
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
    final (runner, :owned) = widget.attention.runnerFor(host);
    try {
      await ConductoreChatClient(runner).send(sessionId, text);
    } finally {
      if (owned) unawaited(runner.close());
    }
  }

  Future<void> _decide(
    DigestAgent agent,
    PendingPermissionRequest request,
    PermissionVerdict verdict,
  ) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await widget.attention.decide(agent.hostId, request, verdict);
      unawaited(widget.controller.refresh());
    } on Object catch (error) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Could not answer: $error')),
      );
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

  @override
  Widget build(BuildContext context) {
    final projects = _projects;
    return ListenableBuilder(
      listenable: Listenable.merge([
        widget.controller,
        widget.attention,
        ?projects,
      ]),
      builder: (context, _) {
        final controller = widget.controller;
        final overview = controller.overview;
        final now = (widget.now ?? DateTime.now)();
        Widget card(DigestAgent agent) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: DigestAgentCard(
            key: ValueKey('digest-card-${agent.sessionId}'),
            agent: agent,
            live: _live(agent),
            canAct: _host(agent.hostId) != null,
            summarizing: controller.isSummarizing && agent.summaryPending,
            isDeciding: widget.attention.isDeciding,
            now: now,
            onOpen: () => _open(agent),
            onChat: () => _open(agent, chat: true),
            onTerminal: () => _open(agent, chat: false),
            onReview: _reviewAction(agent),
            onHandOff: _handOffAction(agent),
            onTell: (answer) => unawaited(_tell(agent, answer: answer)),
            onDecide: (request, verdict) =>
                unawaited(_decide(agent, request, verdict)),
          ),
        );
        final byProject = projects != null && projects.groupByProject;
        // The machines' sidebar.toml, at most every few minutes.
        if (byProject) unawaited(projects.refresh());
        final children = <Widget>[
          _Header(
            controller: controller,
            overview: overview,
            now: now,
            menu: widget.inlineMenu
                ? DigestWindowMenu(controller: controller)
                : null,
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
          if (overview.isEmpty)
            _Empty(
              loading: controller.isLoading,
              machines: controller.machines,
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
        ];
        final list = ListView(
          key: const ValueKey('agents-dashboard'),
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
  const _Empty({required this.loading, required this.machines});

  final bool loading;
  final List<MachineDigest> machines;

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final text = machines.isEmpty
        ? 'No machine reports agents yet. Turn on agent monitoring for a '
              'machine with the Conductore companion.'
        : loading
        ? 'Asking your machines…'
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
    super.key,
  });

  final DigestAgent agent;

  /// Opens Review of its last turn; null hides the button.
  final VoidCallback? onReview;

  /// Hands the agent's work off through Talkbawt; null hides the button.
  final VoidCallback? onHandOff;

  /// The monitor's record of it (its requests, with their full input);
  /// null when the monitor does not know it (ended, another machine).
  final AgentInfo? live;
  final bool canAct;
  final bool summarizing;
  final bool Function(String requestId)? isDeciding;
  final DateTime? now;
  final VoidCallback onOpen;
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
    final facts = _factsRow(palette);
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
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: agent.name,
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                          TextSpan(
                            text: ' · ${agent.hostName}',
                            style: TextStyle(color: palette.mutedForeground),
                          ),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
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
                    request: request,
                    busy: isDeciding?.call(request.id) ?? false,
                    onDecide: (verdict) => onDecide(request, verdict),
                  ),
                ],
              if (interactive)
                Wrap(
                  alignment: WrapAlignment.end,
                  children: [
                    if (agent.state != 'needs_permission')
                      TextButton.icon(
                        key: ValueKey('digest-tell-${agent.sessionId}'),
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                        onPressed: () =>
                            onTell(agent.attention == DigestAttention.question),
                        icon: const Icon(Icons.reply_rounded, size: 18),
                        label: Text(
                          agent.attention == DigestAttention.question
                              ? 'Answer'
                              : 'Tell it…',
                        ),
                      ),
                    if (onReview case final review?)
                      TextButton.icon(
                        key: ValueKey('digest-review-${agent.sessionId}'),
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                        onPressed: review,
                        icon: const Icon(Icons.rate_review_outlined, size: 18),
                        label: const Text('Review'),
                      ),
                    if (onHandOff case final handOff?)
                      TextButton.icon(
                        key: ValueKey('digest-handoff-${agent.sessionId}'),
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                        onPressed: handOff,
                        icon: const Icon(Icons.outbox_outlined, size: 18),
                        label: const Text('Hand off'),
                      ),
                    TextButton.icon(
                      key: ValueKey('digest-chat-${agent.sessionId}'),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: onChat,
                      icon: const Icon(Icons.forum_outlined, size: 18),
                      label: const Text('Chat'),
                    ),
                    TextButton.icon(
                      key: ValueKey('digest-terminal-${agent.sessionId}'),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: onTerminal,
                      icon: const Icon(Icons.terminal_rounded, size: 18),
                      label: const Text('Terminal'),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
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
      if (agent.state != 'needs_permission')
        (
          question ? 'Answer…' : 'Tell it…',
          Icons.reply_rounded,
          () => onTell(question),
        ),
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

  List<Widget> _factsRow(AppPalette palette) {
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
