import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/companion_setup/presentation/companion_status_chip.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:flutter/material.dart';

/// Per machine: which provider it uses, whether it is loading, failing or
/// unavailable, and a refresh button.
class AgentMachinesSection extends StatelessWidget {
  const AgentMachinesSection({
    required this.hosts,
    required this.controller,
    required this.hasAgents,
    super.key,
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
