import 'dart:async';

import 'package:conduit/core/presentation/adaptive_modal.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/quick_actions/data/project_files.dart';
import 'package:conduit/features/quick_actions/domain/quick_action.dart';
import 'package:conduit/features/quick_actions/presentation/quick_action_form.dart';
import 'package:conduit/features/quick_actions/presentation/quick_action_runner.dart';
import 'package:flutter/material.dart';

/// The project a session works on, as its agents report it.
typedef SessionProject = ({String name, String? path, AgentInfo? agent});

/// [sessionHostId]'s project: its agent's repo (name and folder), or,
/// when personal actions apply to every project, the session itself.
/// Null when there is nothing to offer (the menu entry stays hidden).
SessionProject? sessionProjectOf({
  required AgentAttentionController? attention,
  required String sessionHostId,
  required String sessionTitle,
  required List<QuickAction> personal,
}) {
  for (final agent
      in attention?.statusFor(sessionHostId)?.agents ?? const <AgentInfo>[]) {
    final name = agent.repoLabel;
    if (name == null || name.isEmpty) continue;
    final raw = agent.workspace?.trim() ?? '';
    final path = raw.startsWith('/') || raw.startsWith('~') ? raw : null;
    return (name: name, path: path, agent: agent);
  }
  if (personal.any((action) => action.appliesTo(sessionTitle))) {
    return (name: sessionTitle, path: null, agent: null);
  }
  return null;
}

/// The session menu's "Quick actions": the project's repo actions (read
/// from its `.code-workspace` over the command channel) and the personal
/// ones; picking one runs it. A popover on desktop, a sheet on phones.
Future<void> showSessionQuickActions(
  BuildContext context, {
  required SessionProject project,
  required SavedHost machine,
  required SavedHost sessionHost,
  required List<QuickAction> personal,
  required QuickActionRunner runner,
  AgentAttentionController? attention,
}) async {
  final picked = await showAdaptiveModal<(QuickAction, String?)>(
    context: context,
    kind: AdaptiveModalKind.menu,
    desktopMaxWidth: 360,
    useSafeArea: true,
    builder: (context) => _SessionQuickActions(
      project: project,
      machine: machine,
      personal: personal,
      attention: attention,
    ),
  );
  if (picked == null || !context.mounted) return;
  final (action, root) = picked;
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    final message = await runner.run(
      action,
      QuickActionContext(
        machine: machine,
        root: root ?? project.path,
        agent: project.agent,
        agentHost: project.agent == null ? null : sessionHost,
      ),
    );
    messenger?.showSnackBar(SnackBar(content: Text(message)));
  } on Object catch (error) {
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          '${action.label}: ${error is StateError ? error.message : error}',
        ),
      ),
    );
  }
}

class _SessionQuickActions extends StatefulWidget {
  const _SessionQuickActions({
    required this.project,
    required this.machine,
    required this.personal,
    this.attention,
  });

  final SessionProject project;
  final SavedHost machine;
  final List<QuickAction> personal;
  final AgentAttentionController? attention;

  @override
  State<_SessionQuickActions> createState() => _SessionQuickActionsState();
}

class _SessionQuickActionsState extends State<_SessionQuickActions> {
  ProjectFiles? _files;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    final path = widget.project.path;
    final attention = widget.attention;
    if (path != null && attention != null) {
      _loading = true;
      unawaited(_load(attention, path));
    }
  }

  Future<void> _load(AgentAttentionController attention, String path) async {
    ProjectFiles? files;
    try {
      final (runner, :owned) = attention.runnerFor(widget.machine);
      try {
        files = await ProjectFilesCommands.load(runner, path);
      } finally {
        if (owned) unawaited(runner.close());
      }
    } catch (_) {
      files = null;
    }
    if (!mounted) return;
    setState(() {
      _files = files;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final actions = [
      ...?_files?.actions,
      for (final action in widget.personal)
        if (action.appliesTo(widget.project.name)) action,
    ];
    return ListView(
      key: const ValueKey('session-quick-actions'),
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Text(
            'Quick actions · ${widget.project.name}',
            style: theme.textTheme.titleSmall,
          ),
        ),
        for (final action in actions)
          ListTile(
            key: ValueKey('session-quick-action-${action.id}'),
            dense: true,
            leading: Icon(quickActionIcon(action)),
            title: Text(action.label),
            subtitle: Text(
              action.command,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => Navigator.of(context).pop((action, _files?.root)),
          ),
        if (_loading)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Center(
              child: SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          )
        else if (actions.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Text(
              'No quick actions yet. Add them to the repo\'s .code-workspace '
              '"commands", or in the desktop app\'s Projects tab.',
              style: theme.textTheme.bodySmall,
            ),
          ),
      ],
    );
  }
}
