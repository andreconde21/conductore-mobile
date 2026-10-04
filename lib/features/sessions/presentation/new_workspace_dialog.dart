import 'dart:async';

import 'package:conduit/core/presentation/multiplexer_icon.dart';
import 'package:conduit/features/agent_attention/domain/agent_kinds.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/sessions/domain/new_workspace.dart';
import 'package:flutter/material.dart';

/// Asks for a new Herdr workspace's or tmux session's name, starting
/// folder and which agent to start in it (none, or one of [agents]: those
/// installed on the machine), then runs [create]. Resolves with the target
/// that opens it, or null when cancelled; a failure stays in the dialog.
Future<ConnectTarget?> showNewWorkspaceDialog(
  BuildContext context, {
  required MultiplexerKind kind,
  required Future<ConnectTarget> Function(NewWorkspaceRequest request) create,
  List<String> folders = const [],
  Future<List<KnownAgentKind>>? agents,
  String? initialAgent,
}) => showDialog<ConnectTarget>(
  context: context,
  builder: (context) => NewWorkspaceDialog(
    kind: kind,
    create: create,
    folders: folders,
    agents: agents,
    initialAgent: initialAgent,
  ),
);

class NewWorkspaceDialog extends StatefulWidget {
  const NewWorkspaceDialog({
    required this.kind,
    required this.create,
    this.folders = const [],
    this.agents,
    this.initialAgent,
    super.key,
  });

  final MultiplexerKind kind;
  final Future<ConnectTarget> Function(NewWorkspaceRequest request) create;

  /// Suggested starting folders, most recent first: where the machine's
  /// agents and shells worked.
  final List<String> folders;

  /// The agents installed on the machine, offered besides "None"; null
  /// offers none.
  final Future<List<KnownAgentKind>>? agents;

  /// The kind chosen last time on this machine (`''`: none), preselected
  /// when it is installed.
  final String? initialAgent;

  @override
  State<NewWorkspaceDialog> createState() => _NewWorkspaceDialogState();
}

class _NewWorkspaceDialogState extends State<NewWorkspaceDialog> {
  static const _maxSuggestions = 6;

  late final _name = TextEditingController(
    text: widget.kind == MultiplexerKind.tmux ? defaultTmuxSessionName : '',
  );
  final _folder = TextEditingController();

  /// The chosen agent's kind; empty for none.
  late String _agent = widget.initialAgent ?? '';
  List<KnownAgentKind>? _agents;
  bool _agentsFailed = false;
  bool _busy = false;
  String? _error;

  /// The name was filled in from a folder, so picking another folder
  /// replaces it.
  bool _nameFromFolder = false;

  bool get _herdr => widget.kind == MultiplexerKind.herdr;

  @override
  void initState() {
    super.initState();
    final agents = widget.agents;
    if (agents == null) {
      _agents = const [];
      return;
    }
    agents.then(
      (found) {
        if (mounted) setState(() => _agents = found);
      },
      onError: (Object _) {
        if (mounted) {
          setState(() {
            _agents = const [];
            _agentsFailed = true;
          });
        }
      },
    );
  }

  /// The chosen agent, when it is one the machine has.
  KnownAgentKind? get _chosenAgent =>
      _agents?.where((agent) => agent.kind == _agent).firstOrNull;

  @override
  void dispose() {
    _name.dispose();
    _folder.dispose();
    super.dispose();
  }

  void _useFolder(String folder) {
    setState(() {
      _folder.text = folder;
      final name = _name.text.trim();
      if (name.isEmpty ||
          _nameFromFolder ||
          (!_herdr && name == defaultTmuxSessionName)) {
        _name.text = NewWorkspaceCommands.folderName(folder);
        _nameFromFolder = true;
      }
      _error = null;
    });
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final target = await widget.create(
        NewWorkspaceRequest(
          kind: widget.kind,
          name: _name.text,
          folder: _folder.text,
          agent: _chosenAgent,
        ),
      );
      if (mounted) Navigator.of(context).pop(target);
    } on NewWorkspaceFailure catch (failure) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = failure.message;
        });
      }
    }
  }

  /// "Start an agent": None plus every agent installed on the machine.
  Widget _agentChoice(ThemeData theme) {
    final agents = _agents;
    if (agents == null) {
      return Row(
        key: const ValueKey('new-workspace-agents-loading'),
        children: [
          const SizedBox.square(
            dimension: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Text('Looking for agents…', style: theme.textTheme.bodySmall),
        ],
      );
    }
    final chosen = _chosenAgent?.kind ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Start an agent in it', style: theme.textTheme.labelLarge),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final (kind, label) in [
              ('', 'None'),
              for (final agent in agents) (agent.kind, agent.label),
            ])
              ChoiceChip(
                key: ValueKey(
                  'new-workspace-agent-${kind.isEmpty ? 'none' : kind}',
                ),
                label: Text(label),
                selected: chosen == kind,
                onSelected: _busy ? null : (_) => setState(() => _agent = kind),
              ),
          ],
        ),
        if (agents.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              _agentsFailed
                  ? 'Could not check which agents this machine has.'
                  : 'No coding agents found on this machine.',
              style: theme.textTheme.bodySmall,
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final suggestions = widget.folders.take(_maxSuggestions).toList();
    return AlertDialog(
      key: const ValueKey('new-workspace-dialog'),
      title: Text(_herdr ? 'New Herdr workspace' : 'New tmux session'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const ValueKey('new-workspace-name'),
              controller: _name,
              autofocus: true,
              enabled: !_busy,
              textInputAction: TextInputAction.next,
              onChanged: (_) => _nameFromFolder = false,
              decoration: InputDecoration(
                labelText: _herdr ? 'Workspace name' : 'Session name',
                hintText: _herdr ? 'Named after the folder' : null,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('new-workspace-folder'),
              controller: _folder,
              enabled: !_busy,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => unawaited(_submit()),
              decoration: const InputDecoration(
                labelText: 'Starting folder',
                hintText: '~/Projects/app',
              ),
            ),
            if (suggestions.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final folder in suggestions)
                    Tooltip(
                      message: folder,
                      child: ActionChip(
                        key: ValueKey('new-workspace-folder-$folder'),
                        avatar: const Icon(Icons.folder_outlined, size: 16),
                        label: Text(
                          NewWorkspaceCommands.folderName(folder).isEmpty
                              ? folder
                              : NewWorkspaceCommands.folderName(folder),
                        ),
                        onPressed: _busy ? null : () => _useFolder(folder),
                      ),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            _agentChoice(theme),
            if (_error case final error?)
              Text(
                error,
                key: const ValueKey('new-workspace-error'),
                style: TextStyle(color: theme.colorScheme.error),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('new-workspace-create'),
          onPressed: _busy ? null : () => unawaited(_submit()),
          child: _busy
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Create'),
        ),
      ],
    );
  }
}
