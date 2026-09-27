import 'dart:async';

import 'package:conduit/core/app_failure.dart';
import 'package:conduit/core/presentation/adaptive_modal.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/domain/approval_rules.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/agent_attention/presentation/widgets/approval_widgets.dart';
import 'package:flutter/material.dart';

/// What the user picked in the trust sheet.
sealed class TrustChoice {
  const TrustChoice();
}

/// Save this rule in the companion and allow the request.
class TrustChoiceSave extends TrustChoice {
  const TrustChoiceSave(this.draft);

  final ApprovalRuleDraft draft;
}

/// The old "Always": let Claude Code write its own rule.
class TrustChoiceClaudeCode extends TrustChoice {
  const TrustChoiceClaudeCode();
}

/// Asks which rule to save for [request], where and for how long.
/// [initialDuration] 15 min for "Trust…", forever for "Always".
Future<TrustChoice?> showTrustSheet(
  BuildContext context, {
  required PendingPermissionRequest request,
  TrustDuration initialDuration = const TrustDuration.minutes(15),
  bool offerClaudeCodeAlways = false,
}) {
  return showAdaptiveModal<TrustChoice>(
    kind: AdaptiveModalKind.dialog,
    desktopMaxWidth: 520,
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) => TrustSheet(
      request: request,
      initialDuration: initialDuration,
      offerClaudeCodeAlways: offerClaudeCodeAlways,
    ),
  );
}

class TrustSheet extends StatefulWidget {
  const TrustSheet({
    required this.request,
    this.initialDuration = const TrustDuration.minutes(15),
    this.offerClaudeCodeAlways = false,
    super.key,
  });

  final PendingPermissionRequest request;
  final TrustDuration initialDuration;
  final bool offerClaudeCodeAlways;

  @override
  State<TrustSheet> createState() => _TrustSheetState();
}

class _TrustSheetState extends State<TrustSheet> {
  late final TextEditingController _rule = TextEditingController(
    text: widget.request.suggestedRules.firstOrNull ?? widget.request.toolName,
  );
  late ApprovalScopeKind _scope = widget.request.repo != null
      ? ApprovalScopeKind.repo
      : ApprovalScopeKind.session;
  late TrustDuration _duration = widget.initialDuration;

  @override
  void initState() {
    super.initState();
    _rule.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _rule.dispose();
    super.dispose();
  }

  String? get _repoName {
    final repo = widget.request.repo;
    if (repo == null) {
      return null;
    }
    final parts = repo.split('/').where((part) => part.isNotEmpty);
    return parts.isEmpty ? repo : parts.last;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final request = widget.request;
    final valid = isValidApprovalRule(_rule.text);
    final forever = widget.initialDuration.isForever;
    final save = valid
        ? () => Navigator.of(context).pop(
            TrustChoiceSave(
              ApprovalRuleDraft(
                rule: _rule.text.trim(),
                scope: _scope == ApprovalScopeKind.repo && request.repo != null
                    ? ApprovalScope.repo(request.repo!)
                    : ApprovalScope.ofKind(_scope),
                duration: _duration,
              ),
            ),
          )
        : null;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        approvalSheetTopPadding(context),
        20,
        16 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              forever ? 'Save a rule' : 'Trust ${request.toolName}',
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
            Text(
              'The companion on the machine answers matching requests by '
              'itself, even when this phone is offline. High-risk requests '
              'always ask.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Text(
              request.summary,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontFamily: 'monospace',
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            if (request.risk case final risk?) ...[
              const SizedBox(height: 6),
              RiskLine(risk: risk),
            ],
            const SizedBox(height: 16),
            Text('Rule', style: theme.textTheme.labelLarge),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final suggestion in request.suggestedRules.take(4))
                  ChoiceChip(
                    label: Text(
                      suggestion,
                      style: const TextStyle(fontFamily: 'monospace'),
                      overflow: TextOverflow.ellipsis,
                    ),
                    selected: _rule.text.trim() == suggestion,
                    onSelected: (_) => _rule.text = suggestion,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('trust-rule-field'),
              controller: _rule,
              style: const TextStyle(fontFamily: 'monospace'),
              // Enter saves in the desktop dialog; phones keep the keyboard's
              // plain Done.
              onSubmitted: useDesktopModals(context)
                  ? (_) => save?.call()
                  : null,
              decoration: InputDecoration(
                isDense: true,
                border: const OutlineInputBorder(),
                helperText:
                    'Claude Code syntax: Bash(npm test *), Edit(src/**)',
                errorText: valid ? null : 'Tool or Tool(pattern)',
              ),
            ),
            const SizedBox(height: 16),
            Text('Where', style: theme.textTheme.labelLarge),
            const SizedBox(height: 6),
            SegmentedButton<ApprovalScopeKind>(
              showSelectedIcon: false,
              segments: [
                const ButtonSegment(
                  value: ApprovalScopeKind.session,
                  label: Text('This session'),
                ),
                ButtonSegment(
                  value: ApprovalScopeKind.repo,
                  enabled: request.repo != null,
                  label: Text(
                    _repoName ?? 'This repo',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const ButtonSegment(
                  value: ApprovalScopeKind.any,
                  label: Text('All repos'),
                ),
              ],
              selected: {_scope},
              onSelectionChanged: (value) =>
                  setState(() => _scope = value.first),
            ),
            const SizedBox(height: 16),
            Text('For how long', style: theme.textTheme.labelLarge),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final choice in TrustDuration.choices)
                  ChoiceChip(
                    key: ValueKey('trust-duration-${choice.label}'),
                    label: Text(choice.label),
                    selected: _duration == choice,
                    onSelected: (_) => setState(() => _duration = choice),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            ApprovalSheetActions(
              cancel: OutlinedButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
              confirm: FilledButton(
                key: const ValueKey('trust-save'),
                onPressed: save,
                child: const Text('Allow and trust'),
              ),
            ),
            if (widget.offerClaudeCodeAlways)
              TextButton(
                onPressed: () =>
                    Navigator.of(context).pop(const TrustChoiceClaudeCode()),
                child: const Text(
                  "Use Claude Code's own Always instead (settings.local.json)",
                  textAlign: TextAlign.center,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Answers [request] with [verdict]. On a companion with smart approvals,
/// "Always" opens the rule sheet instead of writing Claude Code's rule, and
/// "Always" on a high-risk request is a one-time allow. Errors show as a
/// snack bar.
Future<void> answerPermissionRequest(
  BuildContext context, {
  required AgentAttentionController controller,
  required String hostId,
  required PendingPermissionRequest request,
  required PermissionVerdict verdict,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final smart =
      controller.supportsSmartApprovals(hostId) && request.risk != null;
  try {
    if (verdict == PermissionVerdict.always && smart) {
      if (!request.trustable) {
        await controller.decide(hostId, request, PermissionVerdict.allow);
        messenger?.showSnackBar(
          const SnackBar(
            content: Text(
              'Allowed once. High-risk requests always ask, so no rule '
              'was saved.',
            ),
          ),
        );
        return;
      }
      final choice = await showTrustSheet(
        context,
        request: request,
        initialDuration: const TrustDuration.forever(),
        offerClaudeCodeAlways: true,
      );
      switch (choice) {
        case null:
          return;
        case TrustChoiceClaudeCode():
          await controller.decide(hostId, request, PermissionVerdict.always);
        case TrustChoiceSave(:final draft):
          await _trust(controller, hostId, request, draft, messenger);
      }
      return;
    }
    await controller.decide(hostId, request, verdict);
  } catch (error) {
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          'Could not ${verdict.label.toLowerCase()} ${request.toolName}: '
          '${error is AppFailure ? error.userMessage : error}',
        ),
      ),
    );
  }
}

/// "Trust…" on a request: the sheet, then the trust. Errors show as a
/// snack bar.
Future<void> trustPermissionRequest(
  BuildContext context, {
  required AgentAttentionController controller,
  required String hostId,
  required PendingPermissionRequest request,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final choice = await showTrustSheet(context, request: request);
  if (choice is! TrustChoiceSave) {
    return;
  }
  try {
    await _trust(controller, hostId, request, choice.draft, messenger);
  } catch (error) {
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          'Could not trust ${request.toolName}: '
          '${error is AppFailure ? error.userMessage : error}',
        ),
      ),
    );
  }
}

Future<void> _trust(
  AgentAttentionController controller,
  String hostId,
  PendingPermissionRequest request,
  ApprovalRuleDraft draft,
  ScaffoldMessengerState? messenger,
) async {
  final result = await controller.trustRequest(
    hostId,
    request,
    duration: draft.duration,
    scope: draft.scope.kind,
    rule: draft.rule,
    source: draft.duration.isForever ? 'always' : 'trust',
  );
  final others = result.approved.length - 1;
  messenger?.showSnackBar(
    SnackBar(
      content: Text(
        'Trusted ${result.rule.rule} ${result.rule.scope.describe()}, '
        '${result.rule.describeDuration()}'
        '${others > 0 ? '. Also allowed $others waiting.' : '.'}',
      ),
    ),
  );
}

/// Confirms "Approve all N safe" with the list; returns whether to go on.
Future<bool> showBatchApproveSheet(
  BuildContext context,
  List<PendingApproval> safe,
) async {
  final confirmed = await showAdaptiveModal<bool>(
    kind: AdaptiveModalKind.dialog,
    desktopMaxWidth: 520,
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) {
      final theme = Theme.of(context);
      return Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          approvalSheetTopPadding(context),
          20,
          16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Approve ${safe.length} low-risk '
              'request${safe.length == 1 ? '' : 's'}?',
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
            Text(
              'Read-only tools and commands, and test runs. The companion '
              'checks each again and skips anything that is not low risk.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final pending in safe)
                    BatchApprovalRow(pending: pending),
                ],
              ),
            ),
            const SizedBox(height: 12),
            ApprovalSheetActions(
              cancel: OutlinedButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              confirm: FilledButton(
                key: const ValueKey('batch-confirm'),
                onPressed: () => Navigator.of(context).pop(true),
                child: Text('Approve ${safe.length}'),
              ),
            ),
          ],
        ),
      );
    },
  );
  return confirmed ?? false;
}

/// Space above a sheet's title: phones have the drag handle there, the
/// desktop dialog has none.
double approvalSheetTopPadding(BuildContext context) =>
    useDesktopModals(context) ? 20 : 0;

/// A sheet's Cancel / confirm pair: two equal full-width buttons on phones,
/// right-aligned buttons at their own size in a desktop dialog. [cancel]
/// may be null (a lone Save).
class ApprovalSheetActions extends StatelessWidget {
  const ApprovalSheetActions({required this.confirm, this.cancel, super.key});

  final Widget? cancel;
  final Widget confirm;

  @override
  Widget build(BuildContext context) {
    final cancel = this.cancel;
    if (useDesktopModals(context)) {
      return OverflowBar(
        alignment: MainAxisAlignment.end,
        spacing: 8,
        overflowAlignment: OverflowBarAlignment.end,
        children: [?cancel, confirm],
      );
    }
    if (cancel == null) return confirm;
    return Row(
      children: [
        Expanded(child: cancel),
        const SizedBox(width: 8),
        Expanded(child: confirm),
      ],
    );
  }
}
