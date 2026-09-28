import 'dart:async';

import 'package:conduit/core/app_failure.dart';
import 'package:conduit/core/presentation/adaptive_modal.dart';
import 'package:conduit/core/presentation/adaptive_page.dart';
import 'package:conduit/features/agent_attention/domain/approval_rules.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/agent_attention/presentation/approval_sheets.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:flutter/material.dart';

/// Opens one machine's approval rules (Settings › Agents › Approval rules):
/// a full page on phones, a dialog over the window on desktop.
Future<void> showApprovalRules(
  BuildContext context, {
  required AgentAttentionController controller,
  required SavedHost host,
}) {
  return pushAdaptivePage<void>(
    context,
    desktopMaxWidth: 760,
    builder: (_) => ApprovalRulesPage(controller: controller, host: host),
  );
}

/// The rules and time-boxed trusts the companion on [host] answers by
/// itself: list, add, edit, revoke.
class ApprovalRulesPage extends StatefulWidget {
  const ApprovalRulesPage({
    required this.controller,
    required this.host,
    super.key,
  });

  final AgentAttentionController controller;
  final SavedHost host;

  @override
  State<ApprovalRulesPage> createState() => _ApprovalRulesPageState();
}

class _ApprovalRulesPageState extends State<ApprovalRulesPage> {
  String? _error;
  bool _unsupported = false;
  final Set<String> _busy = {};

  AgentAttentionController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final loaded = await _controller.loadApprovals(widget.host);
      if (mounted) setState(() => _unsupported = loaded == null);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is AppFailure ? error.userMessage : '$error',
        );
      }
    }
  }

  Future<void> _run(String key, Future<void> Function() body) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() => _busy.add(key));
    try {
      await body();
    } catch (error) {
      messenger?.showSnackBar(
        SnackBar(
          content: Text(error is AppFailure ? error.userMessage : '$error'),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy.remove(key));
    }
  }

  List<String> get _knownRepos {
    final agents = _controller.statusFor(widget.host.id)?.agents ?? const [];
    return {
      for (final agent in agents)
        for (final request in agent.pendingRequests) ?request.repo,
      for (final rule
          in _controller.approvalsFor(widget.host.id)?.rules ??
              const <ApprovalRule>[])
        ?rule.scope.path,
    }.toList();
  }

  Future<void> _edit([ApprovalRule? rule]) async {
    final draft = await showRuleEditorSheet(
      context,
      existing: rule,
      repos: _knownRepos,
    );
    if (draft == null || !mounted) {
      return;
    }
    await _run(rule?.id ?? 'add', () async {
      if (rule == null) {
        await _controller.addRule(widget.host, draft);
      } else {
        await _controller.editRule(widget.host, rule.id, draft);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Desktop: "Add rule" sits in the app bar instead of a floating button.
    final desktop = useDesktopPages(context);
    return Scaffold(
      appBar: AppBar(
        title: Text('Approval rules · ${widget.host.name}'),
        actions: [
          if (desktop && !_unsupported)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: TextButton.icon(
                key: const ValueKey('rules-add'),
                onPressed: _busy.contains('add') ? null : _edit,
                icon: const Icon(Icons.add_rounded),
                label: const Text('Add rule'),
              ),
            ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _load,
          ),
        ],
      ),
      floatingActionButton: _unsupported || desktop
          ? null
          : FloatingActionButton.extended(
              key: const ValueKey('rules-add'),
              onPressed: _busy.contains('add') ? null : _edit,
              icon: const Icon(Icons.add_rounded),
              label: const Text('Add rule'),
            ),
      body: ListenableBuilder(
        listenable: _controller,
        builder: (context, _) {
          final approvals = _controller.approvalsFor(widget.host.id);
          final loading = _controller.isLoadingApprovals(widget.host.id);
          final rules = approvals?.rules ?? const <ApprovalRule>[];
          return ListView(
            padding: EdgeInsets.fromLTRB(16, 8, 16, desktop ? 16 : 96),
            children: [
              Text(
                'The companion on ${widget.host.name} allows matching '
                'requests by itself, even with this phone offline. '
                'High-risk requests (recursive deletes, force pushes, sudo, '
                'secrets, writes outside the repo) always ask. Rules use '
                "Claude Code's syntax and are never written to its "
                'settings.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              if (loading && approvals == null)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: CircularProgressIndicator(),
                  ),
                ),
              if (_unsupported)
                const _Note(
                  icon: Icons.extension_off_outlined,
                  text:
                      "This machine's companion does not keep approval "
                      'rules. Update it from Settings › Agents › Agent '
                      'hooks.',
                ),
              if (_error case final error?)
                _Note(icon: Icons.error_outline_rounded, text: error),
              if (approvals != null && rules.isEmpty)
                const _Note(
                  icon: Icons.rule_rounded,
                  text:
                      'No rules yet. Tap Trust… or Always on an approval, '
                      'or add one here.',
                ),
              for (final rule in rules)
                Card(
                  key: ValueKey('rule-${rule.id}'),
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    onTap: () => _edit(rule),
                    leading: Icon(
                      rule.isTimeBoxed
                          ? Icons.timer_outlined
                          : Icons.rule_rounded,
                    ),
                    title: Text(
                      rule.rule,
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                    subtitle: Text(
                      [
                        rule.scope.kind == ApprovalScopeKind.repo
                            ? 'in ${rule.scope.path}'
                            : rule.scope.describe(),
                        rule.describeDuration(),
                        if (rule.hits > 0) 'used ${rule.hits}×',
                        'from ${rule.source}',
                      ].join(' · '),
                    ),
                    trailing: IconButton(
                      key: ValueKey('rule-revoke-${rule.id}'),
                      tooltip: 'Revoke',
                      icon: const Icon(Icons.delete_outline_rounded),
                      onPressed: _busy.contains(rule.id)
                          ? null
                          : () => _run(
                              rule.id,
                              () =>
                                  _controller.removeRule(widget.host, rule.id),
                            ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20),
          const SizedBox(width: 10),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

/// Adds or edits a rule: pattern, scope (all repos or one repo path),
/// duration. A session-scoped rule keeps its session.
Future<ApprovalRuleDraft?> showRuleEditorSheet(
  BuildContext context, {
  ApprovalRule? existing,
  List<String> repos = const [],
}) {
  return showAdaptiveModal<ApprovalRuleDraft>(
    kind: AdaptiveModalKind.dialog,
    desktopMaxWidth: 560,
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) => _RuleEditor(existing: existing, repos: repos),
  );
}

class _RuleEditor extends StatefulWidget {
  const _RuleEditor({required this.existing, required this.repos});

  final ApprovalRule? existing;
  final List<String> repos;

  @override
  State<_RuleEditor> createState() => _RuleEditorState();
}

class _RuleEditorState extends State<_RuleEditor> {
  static const _durations = [
    TrustDuration.minutes(15),
    TrustDuration.minutes(60),
    TrustDuration.forever(),
  ];

  late final _rule = TextEditingController(
    text: widget.existing?.rule ?? 'Bash(npm test *)',
  );
  late final _path = TextEditingController(
    text: widget.existing?.scope.path ?? widget.repos.firstOrNull ?? '',
  );
  late ApprovalScopeKind _kind =
      widget.existing?.scope.kind ??
      (widget.repos.isEmpty ? ApprovalScopeKind.any : ApprovalScopeKind.repo);

  /// Null: keep the existing rule's duration.
  TrustDuration? _duration;

  @override
  void initState() {
    super.initState();
    _rule.addListener(() => setState(() {}));
    _path.addListener(() => setState(() {}));
    if (widget.existing == null) {
      _duration = const TrustDuration.forever();
    }
  }

  @override
  void dispose() {
    _rule.dispose();
    _path.dispose();
    super.dispose();
  }

  ApprovalScope? get _scope => switch (_kind) {
    ApprovalScopeKind.any => const ApprovalScope.any(),
    ApprovalScopeKind.repo =>
      _path.text.trim().startsWith('/') && _path.text.trim() != '/'
          ? ApprovalScope.repo(_path.text.trim())
          : null,
    ApprovalScopeKind.session => widget.existing?.scope,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final existing = widget.existing;
    final validRule = isValidApprovalRule(_rule.text);
    final scope = _scope;
    final session = existing?.scope.kind == ApprovalScopeKind.session;
    final save = validRule && scope != null
        ? () => Navigator.of(context).pop(
            ApprovalRuleDraft(
              rule: _rule.text.trim(),
              scope: scope,
              duration:
                  _duration ?? _keep(existing) ?? const TrustDuration.forever(),
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
              existing == null ? 'Add rule' : 'Edit rule',
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('rule-editor-rule'),
              controller: _rule,
              style: const TextStyle(fontFamily: 'monospace'),
              // Enter saves in the desktop dialog; phones keep the keyboard's
              // plain Done.
              onSubmitted: useDesktopModals(context)
                  ? (_) => save?.call()
                  : null,
              decoration: InputDecoration(
                labelText: 'Rule',
                border: const OutlineInputBorder(),
                helperText:
                    'Bash(npm test *), Edit(src/**), Read, '
                    'WebFetch(domain:docs.rs)',
                errorText: validRule ? null : 'Tool or Tool(pattern)',
              ),
            ),
            const SizedBox(height: 16),
            Text('Where', style: theme.textTheme.labelLarge),
            const SizedBox(height: 6),
            if (session)
              Text('In session ${existing!.scope.describe()}')
            else ...[
              SegmentedButton<ApprovalScopeKind>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(
                    value: ApprovalScopeKind.repo,
                    label: Text('One repo'),
                  ),
                  ButtonSegment(
                    value: ApprovalScopeKind.any,
                    label: Text('All repos'),
                  ),
                ],
                selected: {_kind},
                onSelectionChanged: (value) =>
                    setState(() => _kind = value.first),
              ),
              if (_kind == ApprovalScopeKind.repo) ...[
                const SizedBox(height: 8),
                TextField(
                  key: const ValueKey('rule-editor-path'),
                  controller: _path,
                  // Enter saves in the desktop dialog; phones keep the keyboard's
                  // plain Done.
                  onSubmitted: useDesktopModals(context)
                      ? (_) => save?.call()
                      : null,
                  decoration: InputDecoration(
                    labelText: 'Repo path on the machine',
                    border: const OutlineInputBorder(),
                    errorText: scope == null ? 'An absolute path' : null,
                  ),
                ),
                if (widget.repos.isNotEmpty)
                  Wrap(
                    spacing: 6,
                    children: [
                      for (final repo in widget.repos.take(4))
                        ActionChip(
                          label: Text(repo.split('/').last),
                          onPressed: () => _path.text = repo,
                        ),
                    ],
                  ),
              ],
            ],
            const SizedBox(height: 16),
            Text('For how long', style: theme.textTheme.labelLarge),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              children: [
                if (existing != null)
                  ChoiceChip(
                    label: Text('Keep (${existing.describeDuration()})'),
                    selected: _duration == null,
                    onSelected: (_) => setState(() => _duration = null),
                  ),
                for (final choice in _durations)
                  ChoiceChip(
                    label: Text(
                      choice.isForever ? 'Until revoked' : choice.label,
                    ),
                    selected: _duration == choice,
                    onSelected: (_) => setState(() => _duration = choice),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            ApprovalSheetActions(
              cancel: useDesktopModals(context)
                  ? OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Cancel'),
                    )
                  : null,
              confirm: FilledButton(
                key: const ValueKey('rule-editor-save'),
                onPressed: save,
                child: const Text('Save'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The existing duration as a draft duration: minutes left, else forever
  /// (a session rule keeps ending with its session on the host).
  static TrustDuration? _keep(ApprovalRule? rule) {
    final expires = rule?.expiresAt;
    if (expires == null) {
      return rule?.endsWithSession != null
          ? const TrustDuration.untilSessionEnd()
          : null;
    }
    final left = expires.difference(DateTime.now().toUtc()).inMinutes;
    return TrustDuration.minutes(left < 1 ? 1 : left);
  }
}
