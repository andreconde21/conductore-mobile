import 'dart:async';

import 'package:conduit/core/presentation/adaptive_modal.dart';
import 'package:conduit/core/presentation/system_navigation_insets.dart';
import 'package:conduit/core/theme/app_theme.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/domain/agent_inbox.dart';
import 'package:conduit/features/agent_attention/domain/approval_rules.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/agent_attention/presentation/approval_sheets.dart';
import 'package:conduit/features/agent_attention/presentation/widgets/agent_inbox_widgets.dart';
import 'package:conduit/features/agent_attention/presentation/widgets/agent_usage_tab.dart';
import 'package:conduit/features/agent_attention/presentation/widgets/approval_widgets.dart';
import 'package:conduit/features/agent_attention/presentation/widgets/inbox_row_desktop_actions.dart';
import 'package:conduit/features/agent_attention/presentation/widgets/usage_update_hint.dart';
import 'package:conduit/features/companion_setup/presentation/companion_setup_page.dart';
import 'package:conduit/features/companion_setup/presentation/companion_status_chip.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/review/presentation/review_launcher.dart';
import 'package:conduit/features/usage/presentation/usage_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Called when the user taps an agent: navigate to the host's terminal tab
/// (and optionally send the provider's focus command first).
typedef AgentAttentionNavigate = void Function(SavedHost host, AgentInfo agent);

/// Shows the Agent panel: the Inbox (one live row per agent session, by
/// section, approvals pinned on top) and the Usage tab. [onOpenChat], when
/// given, adds a "Chat" button to every row.
Future<void> showAgentAttentionSheet({
  required BuildContext context,
  required AgentAttentionController controller,
  required AgentAttentionNavigate onOpenAgent,
  AgentAttentionNavigate? onOpenChat,
}) {
  return showAdaptiveModal<void>(
    kind: AdaptiveModalKind.sidePanel,
    desktopFill: true,
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => AnnotatedRegion<SystemUiOverlayStyle>(
      value: AppTheme.systemUiOverlayStyle(Theme.of(context).brightness),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: adaptiveSheetFraction(context, 0.6),
        minChildSize: adaptiveSheetFraction(context, 0.3),
        maxChildSize: adaptiveSheetFraction(context, 0.92),
        builder: (context, scrollController) => AgentAttentionSheet(
          controller: controller,
          scrollController: scrollController,
          onOpenAgent: onOpenAgent,
          onOpenChat: onOpenChat,
        ),
      ),
    ),
  );
}

class AgentAttentionSheet extends StatefulWidget {
  const AgentAttentionSheet({
    required this.controller,
    required this.onOpenAgent,
    this.onOpenChat,
    this.scrollController,
    super.key,
  });

  final AgentAttentionController controller;
  final AgentAttentionNavigate onOpenAgent;

  /// Opens the agent's chat view; the row shows a "Chat" button when set.
  final AgentAttentionNavigate? onOpenChat;
  final ScrollController? scrollController;

  @override
  State<AgentAttentionSheet> createState() => _AgentAttentionSheetState();
}

class _AgentAttentionSheetState extends State<AgentAttentionSheet>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this)
    ..addListener(_onTab);

  AgentAttentionController get controller => widget.controller;

  // Swap the content as soon as a tab is picked, not after the indicator
  // animation.
  void _onTab() => setState(() {});

  /// The pending ids the user chose to review one by one: the batch card
  /// stays hidden until that set changes.
  Set<String>? _reviewing;
  bool _batching = false;

  @override
  void initState() {
    super.initState();
    // The auto-approved list: once per opening, then kept fresh by the
    // controller whenever a rule answers something.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final host in controller.monitoredHosts) {
        if (controller.supportsSmartApprovals(host.id)) {
          unawaited(controller.loadApprovals(host).catchError((_) => null));
        }
      }
    });
  }

  @override
  void dispose() {
    _tabs
      ..removeListener(_onTab)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // The sheet itself extends under the system navigation bar; keep the
    // last row above three-button navigation (Samsung One UI reports
    // gesture insets there too, see shouldApplyBottomSafeArea).
    final bottomInset = shouldApplyBottomSafeArea(context)
        ? MediaQuery.viewPaddingOf(context).bottom
        : 0.0;
    return ListenableBuilder(
      listenable: Listenable.merge([controller, controller.inboxDismissals]),
      builder: (context, _) {
        final hosts = controller.monitoredHosts;
        final inputs = <AgentInboxHostInput>[
          for (final host in hosts)
            (
              hostId: host.id,
              hostName: host.name,
              agents: controller.statusFor(host.id)?.agents ?? const [],
            ),
        ];
        final inbox = AgentInbox.build(
          inputs,
          dismissals: controller.inboxDismissals,
        );
        final attention =
            inbox.countIn(AgentInboxSection.needsApproval) +
            inbox.countIn(AgentInboxSection.needsInput);
        return ListView(
          controller: widget.scrollController,
          padding: EdgeInsets.fromLTRB(16, 8, 16, 24 + bottomInset),
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Agents', style: theme.textTheme.titleMedium),
                ),
                if (inbox.hiddenCount > 0)
                  TextButton(
                    onPressed: controller.inboxDismissals.restoreAll,
                    child: Text('Show ${inbox.hiddenCount} hidden'),
                  ),
              ],
            ),
            TabBar(
              controller: _tabs,
              tabs: [
                Tab(
                  height: 40,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Inbox'),
                      if (attention > 0) ...[
                        const SizedBox(width: 6),
                        Badge.count(count: attention),
                      ],
                    ],
                  ),
                ),
                const Tab(height: 40, text: 'Usage'),
              ],
            ),
            const SizedBox(height: 8),
            for (final host in controller.unmonitoredHosts)
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
                    onPressed: () => controller.enableMonitoring(host),
                    child: const Text('Turn on'),
                  ),
                ),
              ),
            if (hosts.isEmpty) ...[
              if (controller.unmonitoredHosts.isEmpty)
                const _EmptyState(
                  icon: Icons.monitor_heart_outlined,
                  message:
                      'No machines are being monitored. Enable agent '
                      "monitoring in a machine's settings, then connect "
                      'to it.',
                ),
            ] else ...[
              if (_tabs.index == 0)
                ..._inboxChildren(context, inbox, grouped: hosts.length > 1)
              else ...[
                // Tokens, cost and limits per machine (companion 0.6+),
                // then each session's context.
                if (UsageScope.maybeOf(context) case final usage?) ...[
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
                  inputs,
                  showRateLimits: UsageScope.maybeOf(context) == null,
                  hostNotice: (hostId) => UsageUpdateHint(
                    host: hosts.firstWhere((host) => host.id == hostId),
                  ),
                ),
              ],
              _MachinesSection(
                hosts: hosts,
                controller: controller,
                hasAgents: inputs.any((input) => input.agents.isNotEmpty),
              ),
            ],
          ],
        );
      },
    );
  }

  List<Widget> _inboxChildren(
    BuildContext context,
    AgentInbox inbox, {
    required bool grouped,
  }) {
    final theme = Theme.of(context);
    final hostsById = {
      for (final host in controller.monitoredHosts) host.id: host,
    };
    final anyLoaded = controller.monitoredHosts.any((host) {
      final status = controller.statusFor(host.id);
      return status != null && !status.loading;
    });
    if (inbox.isEmpty) {
      if (!anyLoaded) {
        return const [];
      }
      return [
        _EmptyState(
          icon: Icons.check_circle_outline_rounded,
          message: inbox.hiddenCount > 0
              ? 'Nothing new. Dismissed agents come back when they change.'
              : 'No agents are running on the monitored machines.',
        ),
      ];
    }
    final waiting = controller.pendingApprovals;
    final safe = controller.lowRiskPending;
    final waitingIds = {for (final p in waiting) p.request.id};
    final reviewing = _reviewing;
    final showBatch =
        waiting.length >= 2 &&
        safe.isNotEmpty &&
        (reviewing == null ||
            !(reviewing.length == waitingIds.length &&
                reviewing.containsAll(waitingIds)));
    return [
      for (final MapEntry(key: section, value: groups)
          in inbox.sections.entries) ...[
        _SectionHeader(section: section, count: inbox.countIn(section)),
        if (section == AgentInboxSection.needsApproval && showBatch)
          BatchApprovalCard(
            waiting: waiting.length,
            safe: safe.length,
            busy: _batching,
            onReviewEach: () => setState(() => _reviewing = waitingIds),
            onApproveSafe: () => _approveSafe(context, safe),
          ),
        for (final group in groups) ...[
          if (grouped)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 2, 4, 6),
              child: Text(
                '${group.hostName} / ${group.project}',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          for (final entry in group.entries)
            if (hostsById[entry.hostId] case final host?)
              _row(context, host, entry, section, showHost: !grouped),
        ],
      ],
      for (final host in controller.monitoredHosts)
        if (controller.approvalsFor(host.id) case final approvals?)
          AutoApprovedSection(
            key: ValueKey('auto-approved-${host.id}'),
            hostName: host.name,
            showHost: grouped,
            approvals: approvals,
            onRevoke: (rule) => _revoke(context, host, rule),
          ),
    ];
  }

  Future<void> _approveSafe(
    BuildContext context,
    List<PendingApproval> safe,
  ) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (!await showBatchApproveSheet(context, safe) || !mounted) {
      return;
    }
    setState(() => _batching = true);
    try {
      final result = await controller.approveAllLowRisk(only: safe);
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

  Future<void> _revoke(
    BuildContext context,
    SavedHost host,
    ApprovalRule rule,
  ) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await controller.removeRule(host, rule.id);
      messenger?.showSnackBar(
        SnackBar(content: Text('Revoked ${rule.rule}. It asks again.')),
      );
    } catch (error) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Could not revoke ${rule.rule}: $error')),
      );
    }
  }

  Widget _row(
    BuildContext context,
    SavedHost host,
    AgentInboxEntry entry,
    AgentInboxSection section, {
    required bool showHost,
  }) {
    final agent = entry.agent;
    final openChat = widget.onOpenChat;
    final row = AgentInboxRow(
      key: ValueKey('agent-row-${entry.key}'),
      entry: entry,
      showHost: showHost,
      onOpen: () => widget.onOpenAgent(host, agent),
      onOpenChat: openChat == null ? null : () => openChat(host, agent),
      onReview:
          reviewAvailable(controller, host) &&
              agentCanBeReviewed(agent) &&
              agent.state != AgentAttentionState.finished
          ? () => unawaited(
              openReview(
                context: context,
                attention: controller,
                host: host,
                agent: agent,
              ),
            )
          : null,
      pending: agent.pendingRequests.isEmpty
          ? null
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final request in agent.pendingRequests)
                  PendingRequestCard(
                    key: ValueKey('request-${request.id}'),
                    request: request,
                    busy: controller.isDeciding(request.id),
                    onDecide: (verdict) => answerPermissionRequest(
                      context,
                      controller: controller,
                      hostId: host.id,
                      request: request,
                      verdict: verdict,
                      nativeAlways: controller
                          .agentKinds(host.id)
                          .of(agent.kind)
                          .always,
                    ),
                    onAnswer: (answers) => answerPermissionRequest(
                      context,
                      controller: controller,
                      hostId: host.id,
                      request: request.withAnswers(answers),
                      verdict: PermissionVerdict.allow,
                    ),
                    onTrust: controller.supportsSmartApprovals(host.id)
                        ? () => trustPermissionRequest(
                            context,
                            controller: controller,
                            hostId: host.id,
                            request: request,
                          )
                        : null,
                  ),
              ],
            ),
    );
    if (!section.dismissible) {
      return row;
    }
    final theme = Theme.of(context);
    Widget background(AlignmentGeometry alignment) => Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 20),
      alignment: alignment,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppTheme.radius),
      ),
      child: Text('Hide', style: theme.textTheme.labelLarge),
    );
    return Dismissible(
      key: ValueKey('dismiss-${entry.key}'),
      background: background(AlignmentDirectional.centerStart),
      secondaryBackground: background(AlignmentDirectional.centerEnd),
      onDismissed: (_) =>
          controller.inboxDismissals.dismiss(entry.hostId, agent),
      child: InboxRowDesktopActions(
        entryKey: entry.key,
        onHide: () => controller.inboxDismissals.dismiss(entry.hostId, agent),
        onOpen: row.onOpen,
        onOpenChat: row.onOpenChat,
        onReview: row.onReview,
        child: row,
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.section, required this.count});

  final AgentInboxSection section;
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loud =
        section == AgentInboxSection.needsApproval ||
        section == AgentInboxSection.needsInput;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 10, 4, 6),
      child: Text(
        '${section.label.toUpperCase()}  $count',
        style: theme.textTheme.labelMedium?.copyWith(
          letterSpacing: 0.8,
          fontWeight: FontWeight.w700,
          color: loud
              ? theme.colorScheme.error
              : theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// Per machine: which provider it uses, whether it is loading, failing or
/// unavailable, and a refresh button.
class _MachinesSection extends StatelessWidget {
  const _MachinesSection({
    required this.hosts,
    required this.controller,
    required this.hasAgents,
  });

  final List<SavedHost> hosts;
  final AgentAttentionController controller;
  final bool hasAgents;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 14, 4, 2),
          child: Text(
            'MACHINES',
            style: theme.textTheme.labelMedium?.copyWith(
              letterSpacing: 0.8,
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        for (final host in hosts)
          _MachineRow(
            host: host,
            providerLabel: controller.providerFor(host.id).label,
            status:
                controller.statusFor(host.id) ??
                const AgentHostStatus(loading: true),
            onRefresh: () => controller.refresh(host.id),
          ),
      ],
    );
  }
}

class _MachineRow extends StatelessWidget {
  const _MachineRow({
    required this.host,
    required this.providerLabel,
    required this.status,
    required this.onRefresh,
  });

  final SavedHost host;
  final String providerLabel;
  final AgentHostStatus status;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final count = status.agents.length;
    final problem =
        status.unavailableReason ??
        (status.error == null
            ? null
            : 'Could not read agent state. ${status.error!} '
                  'Monitoring keeps retrying while connected.');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: host.name, style: theme.textTheme.bodyLarge),
                    TextSpan(
                      text:
                          '  $providerLabel'
                          '${problem == null && !status.loading ? ' · $count agent${count == 1 ? '' : 's'}' : ''}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (status.loading && status.agents.isEmpty && problem == null)
              const Padding(
                padding: EdgeInsets.all(12),
                child: SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else
              IconButton(
                tooltip: 'Refresh ${host.name}',
                iconSize: 18,
                icon: const Icon(Icons.refresh_rounded),
                onPressed: onRefresh,
              ),
          ],
        ),
        // Offers the Agent hooks screen while the companion is missing
        // (renders nothing once it is installed, or without a scope).
        if (status.unavailableReason != null ||
            (!status.loading && status.error == null && status.agents.isEmpty))
          CompanionInstallBanner(host: host),
        if (problem != null)
          _EmptyState(
            icon: status.unavailableReason != null
                ? Icons.extension_off_outlined
                : Icons.error_outline_rounded,
            message: problem,
          ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(child: Text(message, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}
