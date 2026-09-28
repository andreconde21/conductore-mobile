import 'dart:math' as math;

import 'package:conduit/core/theme/app_theme.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/domain/approval_rules.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/agent_attention/presentation/widgets/agent_inbox_widgets.dart';
import 'package:flutter/material.dart';

/// Colour and icon for a risk level: green, amber, red.
({Color color, IconData icon}) riskStyle(
  PermissionRiskLevel level,
  ColorScheme scheme,
) => switch (level) {
  PermissionRiskLevel.low => (
    color: const Color(0xFF3F9E62),
    icon: Icons.verified_user_outlined,
  ),
  PermissionRiskLevel.medium => (
    color: const Color(0xFFD08A1E),
    icon: Icons.shield_outlined,
  ),
  PermissionRiskLevel.high => (
    color: scheme.error,
    icon: Icons.gpp_maybe_outlined,
  ),
};

/// "Low risk" / "Medium risk" / "High risk" chip.
class RiskBadge extends StatelessWidget {
  const RiskBadge({required this.risk, super.key});

  final PermissionRisk risk;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = riskStyle(risk.level, theme.colorScheme);
    return Container(
      key: ValueKey('risk-${risk.level.name}'),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: style.color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppTheme.radius),
        border: Border.all(color: style.color.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(style.icon, size: 13, color: style.color),
          const SizedBox(width: 4),
          Text(
            risk.level.label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: style.color,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// The badge and the one-line reason, for approval cards.
class RiskLine extends StatelessWidget {
  const RiskLine({required this.risk, super.key});

  final PermissionRisk risk;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      label: '${risk.level.label}. ${risk.reason}',
      excludeSemantics: true,
      child: Row(
        children: [
          RiskBadge(risk: risk),
          if (risk.reason.isNotEmpty) ...[
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                risk.reason,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// "Approve all N safe" on top of the approvals: shown while several
/// requests wait and some are rated low.
class BatchApprovalCard extends StatelessWidget {
  const BatchApprovalCard({
    required this.waiting,
    required this.safe,
    required this.busy,
    required this.onApproveSafe,
    required this.onReviewEach,
    super.key,
  });

  /// All waiting requests.
  final int waiting;

  /// Low-risk ones among them.
  final int safe;
  final bool busy;
  final VoidCallback onApproveSafe;
  final VoidCallback onReviewEach;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final green = riskStyle(PermissionRiskLevel.low, theme.colorScheme).color;
    final rest = waiting - safe;
    return Card(
      key: const ValueKey('batch-approval-card'),
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.done_all_rounded, color: green),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '$waiting requests waiting',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '$safe low risk (read-only or tests)'
              '${rest > 0 ? '; $rest need a look each' : ''}.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: busy ? null : onReviewEach,
                    child: const Text('Review each'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    key: const ValueKey('batch-approve-safe'),
                    onPressed: busy ? null : onApproveSafe,
                    child: Text('Approve all $safe safe'),
                  ),
                ),
              ],
            ),
            if (busy)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: LinearProgressIndicator(),
              ),
          ],
        ),
      ),
    );
  }
}

/// One host's auto-approved log for the inbox: the active time-boxed
/// trusts (with Revoke) and what the rules answered in the last 24 h
/// (with "Undo trust" while the rule exists).
class AutoApprovedSection extends StatefulWidget {
  const AutoApprovedSection({
    required this.hostName,
    required this.approvals,
    required this.onRevoke,
    this.showHost = false,
    this.now,
    super.key,
  });

  final String hostName;
  final ApprovalsSnapshot approvals;

  /// Removes a rule (the trust behind an entry).
  final Future<void> Function(ApprovalRule rule) onRevoke;
  final bool showHost;
  final DateTime? now;

  @override
  State<AutoApprovedSection> createState() => _AutoApprovedSectionState();
}

class _AutoApprovedSectionState extends State<AutoApprovedSection> {
  static const _collapsed = 3;
  bool _all = false;
  final Set<String> _revoking = {};

  Future<void> _revoke(ApprovalRule rule) async {
    setState(() => _revoking.add(rule.id));
    try {
      await widget.onRevoke(rule);
    } finally {
      if (mounted) setState(() => _revoking.remove(rule.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final approvals = widget.approvals;
    final trusts = [
      for (final rule in approvals.rules)
        if (rule.isTimeBoxed) rule,
    ];
    final entries = approvals.autoApproved;
    if (trusts.isEmpty && entries.isEmpty) {
      return const SizedBox.shrink();
    }
    final shown = _all ? entries : entries.take(_collapsed).toList();
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 10, 4, 6),
          child: Text(
            'AUTO-APPROVED (24 H)  ${entries.length}'
            '${widget.showHost ? ' · ${widget.hostName}' : ''}',
            style: theme.textTheme.labelMedium?.copyWith(
              letterSpacing: 0.8,
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        for (final rule in trusts)
          Card(
            key: ValueKey('trust-${rule.id}'),
            margin: const EdgeInsets.only(bottom: 6),
            child: ListTile(
              dense: true,
              leading: const Icon(Icons.timer_outlined),
              title: Text(
                rule.rule,
                style: const TextStyle(fontFamily: 'monospace'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                'Trusted ${rule.scope.describe()} · '
                '${rule.describeDuration(now: widget.now)}'
                '${rule.hits > 0 ? ' · used ${rule.hits}×' : ''}',
              ),
              trailing: TextButton(
                onPressed: _revoking.contains(rule.id)
                    ? null
                    : () => _revoke(rule),
                child: const Text('Revoke'),
              ),
            ),
          ),
        for (final entry in shown)
          _EntryRow(
            key: ValueKey('auto-${entry.requestId ?? entry.at}'),
            entry: entry,
            rule: approvals.ruleById(entry.ruleId),
            busy: _revoking.contains(entry.ruleId),
            now: widget.now,
            onUndo: _revoke,
            muted: muted,
          ),
        if (entries.length > _collapsed)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              onPressed: () => setState(() => _all = !_all),
              child: Text(_all ? 'Show fewer' : 'Show all ${entries.length}'),
            ),
          ),
      ],
    );
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({
    required this.entry,
    required this.rule,
    required this.busy,
    required this.onUndo,
    required this.muted,
    this.now,
    super.key,
  });

  final AutoApprovedEntry entry;

  /// The rule that answered it, while it still exists.
  final ApprovalRule? rule;
  final bool busy;
  final Future<void> Function(ApprovalRule rule) onUndo;
  final TextStyle? muted;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rule = this.rule;
    final risk = entry.risk;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(AppTheme.radius),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          entry.toolName,
                          style: theme.textTheme.titleSmall,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (risk != null) ...[
                        const SizedBox(width: 8),
                        RiskBadge(risk: risk),
                      ],
                    ],
                  ),
                  Text(
                    entry.summary,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    [
                      ?entry.agent,
                      relativeAgentTime(entry.at, now: now),
                      'by ${entry.rule}',
                    ].join(' · '),
                    style: muted,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (rule != null)
              TextButton(
                onPressed: busy ? null : () => onUndo(rule),
                child: const Text('Undo trust'),
              )
            else
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text('Rule gone', style: muted),
              ),
          ],
        ),
      ),
    );
  }
}

/// A row for the batch sheet: what will be approved and why it is safe.
class BatchApprovalRow extends StatelessWidget {
  const BatchApprovalRow({required this.pending, super.key});

  final PendingApproval pending;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final request = pending.request;
    final agent = pending.agent;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: AgentKindBadge(kind: agent.kind, size: 30),
      title: Text(
        request.summary,
        style: theme.textTheme.bodyMedium?.copyWith(fontFamily: 'monospace'),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${request.toolName} · ${agent.projectLabel ?? agent.name} · '
        '${pending.hostName}'
        '${request.risk?.reason.isNotEmpty ?? false ? '\n${request.risk!.reason}' : ''}',
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

/// One answer on an approval card.
class ApprovalAction {
  const ApprovalAction(this.label, this.onPressed, {this.key});

  final String label;
  final VoidCallback? onPressed;
  final Key? key;
}

/// The answers of an approval card: Deny (outlined) and Allow (filled),
/// with [secondary] answers (Trust…, Always; tonal) between them. All in
/// one row of equal buttons when every label fits on one line; otherwise
/// the secondary answers get a row of their own above Deny and Allow, and
/// a row whose labels still don't fit stacks its buttons full width, so
/// a label never breaks mid-word (narrow phones, large text).
class ApprovalButtons extends StatelessWidget {
  const ApprovalButtons({
    required this.deny,
    required this.allow,
    this.secondary = const [],
    super.key,
  });

  final ApprovalAction deny;
  final ApprovalAction allow;
  final List<ApprovalAction> secondary;

  static const double _gap = 8;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    final styles = [
      theme.filledButtonTheme.style,
      theme.outlinedButtonTheme.style,
    ];
    final textStyle =
        styles.first?.textStyle?.resolve(const {}) ??
        theme.textTheme.labelLarge;
    // The widest horizontal padding of the button styles, plus the
    // outline and a little rounding slack.
    final padding =
        styles
            .map((s) => s?.padding?.resolve(const {})?.horizontal ?? 48.0)
            .reduce(math.max) +
        6;
    double needed(ApprovalAction action) {
      final painter = TextPainter(
        text: TextSpan(text: action.label, style: textStyle),
        textDirection: direction,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final width = painter.width;
      painter.dispose();
      return width + padding;
    }

    Widget button(ApprovalAction action, _AnswerKind kind) {
      final child = Text(
        action.label,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
      );
      return switch (kind) {
        _AnswerKind.deny => OutlinedButton(
          key: action.key,
          onPressed: action.onPressed,
          child: child,
        ),
        _AnswerKind.secondary => FilledButton.tonal(
          key: action.key,
          onPressed: action.onPressed,
          child: child,
        ),
        _AnswerKind.allow => FilledButton(
          key: action.key,
          onPressed: action.onPressed,
          child: child,
        ),
      };
    }

    final all = [
      (deny, _AnswerKind.deny),
      for (final action in secondary) (action, _AnswerKind.secondary),
      (allow, _AnswerKind.allow),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        bool fits(List<(ApprovalAction, _AnswerKind)> row) =>
            row.map((e) => needed(e.$1)).reduce(math.max) * row.length +
                _gap * (row.length - 1) <=
            constraints.maxWidth;
        Widget line(List<(ApprovalAction, _AnswerKind)> row) => fits(row)
            ? Row(
                children: [
                  for (final (i, (action, kind)) in row.indexed) ...[
                    if (i > 0) const SizedBox(width: _gap),
                    Expanded(child: button(action, kind)),
                  ],
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (i, (action, kind)) in row.indexed) ...[
                    if (i > 0) const SizedBox(height: _gap),
                    button(action, kind),
                  ],
                ],
              );
        if (secondary.isEmpty || fits(all)) return line(all);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            line(all.sublist(1, all.length - 1)),
            const SizedBox(height: _gap),
            line([all.first, all.last]),
          ],
        );
      },
    );
  }
}

enum _AnswerKind { deny, secondary, allow }
