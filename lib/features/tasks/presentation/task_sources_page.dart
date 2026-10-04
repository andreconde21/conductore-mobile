import 'dart:async';

import 'package:conduit/features/tasks/domain/task_source.dart';
import 'package:conduit/features/tasks/presentation/task_sources_controller.dart';
import 'package:flutter/material.dart';

/// A machine a markdown folder can live on.
typedef TaskMachine = ({String id, String name});

/// Settings › Tasks › Sources: the configured trackers, add, edit, remove.
class TaskSourcesPage extends StatefulWidget {
  const TaskSourcesPage({
    required this.controller,
    required this.machines,
    super.key,
  });

  final TaskSourcesController controller;
  final List<TaskMachine> Function() machines;

  @override
  State<TaskSourcesPage> createState() => _TaskSourcesPageState();
}

class _TaskSourcesPageState extends State<TaskSourcesPage> {
  @override
  void initState() {
    super.initState();
    unawaited(widget.controller.ensureLoaded());
  }

  Future<void> _add() async {
    final kind = await showModalBottomSheet<TaskSourceKind>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final kind in TaskSourceKind.values)
              ListTile(
                key: ValueKey('task-source-kind-${kind.wire}'),
                title: Text(kind.label),
                subtitle: Text(kind.description),
                onTap: () => Navigator.of(context).pop(kind),
              ),
          ],
        ),
      ),
    );
    if (kind == null || !mounted) return;
    await _edit(
      TaskSourceConfig(
        id: TaskSourcesController.newId(),
        kind: kind,
        name: kind.label,
      ),
      isNew: true,
    );
  }

  Future<void> _edit(TaskSourceConfig config, {bool isNew = false}) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => TaskSourceFormPage(
            controller: widget.controller,
            config: config,
            isNew: isNew,
            machines: widget.machines(),
          ),
        ),
      );

  Future<void> _remove(TaskSourceConfig config) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${config.name}?'),
        content: const Text(
          'Its settings and its token are deleted from this device. '
          'Nothing changes in the tracker.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('task-source-remove-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok == true) await widget.controller.remove(config.id);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Task sources')),
    floatingActionButton: FloatingActionButton.extended(
      key: const ValueKey('task-source-add'),
      onPressed: () => unawaited(_add()),
      icon: const Icon(Icons.add),
      label: const Text('Add source'),
    ),
    body: ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final sources = widget.controller.sources;
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
          children: [
            Text(
              'Trackers whose tasks you can list, open, move and comment on. '
              'Tokens stay in this device\'s secure storage and are never '
              'synced. A markdown folder (one .md file per task, YAML '
              'frontmatter) is read through the machine\'s companion.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            if (widget.controller.loaded && sources.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: Text('No sources yet.')),
              ),
            for (final s in sources)
              Card(
                child: ListTile(
                  key: ValueKey('task-source-${s.id}'),
                  title: Text(s.name),
                  subtitle: Text(_describe(s)),
                  onTap: () => unawaited(_edit(s)),
                  trailing: IconButton(
                    tooltip: 'Remove',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => unawaited(_remove(s)),
                  ),
                ),
              ),
          ],
        );
      },
    ),
  );

  String _describe(TaskSourceConfig s) {
    final where = switch (s.kind) {
      TaskSourceKind.markdownFolder => s['folder'],
      TaskSourceKind.github => s['repo'],
      TaskSourceKind.gitlab => s['project'],
      TaskSourceKind.jira ||
      TaskSourceKind.jiraServer => s['project'] ?? s['jql'],
      TaskSourceKind.linear => s['team'] ?? 'every team',
      TaskSourceKind.azureBoards => [
        s['organization'],
        s['project'],
      ].nonNulls.join('/'),
    };
    return [s.kind.label, ?where].join(' · ');
  }
}

/// Adds or edits one source: its name, its kind's fields, the token, a
/// connection test.
class TaskSourceFormPage extends StatefulWidget {
  const TaskSourceFormPage({
    required this.controller,
    required this.config,
    required this.machines,
    this.isNew = false,
    super.key,
  });

  final TaskSourcesController controller;
  final TaskSourceConfig config;
  final List<TaskMachine> machines;
  final bool isNew;

  @override
  State<TaskSourceFormPage> createState() => _TaskSourceFormPageState();
}

class _TaskSourceFormPageState extends State<TaskSourceFormPage> {
  late final _name = TextEditingController(text: widget.config.name);
  late final Map<String, TextEditingController> _fields = {
    for (final f in widget.config.kind.fields)
      if (f.kind != TaskSourceFieldKind.machine)
        f.key: TextEditingController(
          text: widget.config.settings[f.key] ?? f.initial ?? '',
        ),
  };
  final _token = TextEditingController();
  String? _machine;
  bool _hasToken = false;
  bool _busy = false;
  String? _message;
  bool _messageIsError = false;

  TaskSourceKind get _kind => widget.config.kind;

  @override
  void initState() {
    super.initState();
    _machine = widget.config.settings['host'];
    if (!widget.isNew && _kind.needsToken) {
      unawaited(
        widget.controller.hasToken(widget.config.id).then((has) {
          if (mounted) setState(() => _hasToken = has);
        }),
      );
    }
  }

  @override
  void dispose() {
    _name.dispose();
    for (final c in _fields.values) {
      c.dispose();
    }
    _token.dispose();
    super.dispose();
  }

  TaskSourceConfig get _config => widget.config.copyWith(
    name: _name.text.trim().isEmpty ? _kind.label : _name.text.trim(),
    settings: {
      for (final e in _fields.entries)
        if (e.value.text.trim().isNotEmpty) e.key: e.value.text.trim(),
      'host': ?_machine,
    },
  );

  String? _check() {
    final missing = _config.missingField();
    if (missing != null) return '$missing is missing.';
    if (_kind.needsToken && !_hasToken && _token.text.trim().isEmpty) {
      return 'Add the token.';
    }
    return null;
  }

  Future<void> _test() async {
    final problem = _check();
    if (problem != null) {
      setState(() {
        _message = problem;
        _messageIsError = true;
      });
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final count = await widget.controller.test(
        _config,
        token: _token.text.trim(),
      );
      _message = 'Connected: $count task${count == 1 ? '' : 's'}.';
      _messageIsError = false;
    } on Object catch (e) {
      _message = '$e';
      _messageIsError = true;
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _save() async {
    final problem = _check();
    if (problem != null) {
      setState(() {
        _message = problem;
        _messageIsError = true;
      });
      return;
    }
    await widget.controller.save(_config, token: _token.text.trim());
    unawaited(widget.controller.refresh(sourceId: widget.config.id));
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isNew ? 'Add ${_kind.label}' : _kind.label),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(_kind.description, style: theme.textTheme.bodySmall),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('task-source-name'),
            controller: _name,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
          for (final f in _kind.fields) ...[
            const SizedBox(height: 12),
            if (f.kind == TaskSourceFieldKind.machine)
              DropdownButtonFormField<String>(
                key: const ValueKey('task-source-field-host'),
                initialValue: widget.machines.any((m) => m.id == _machine)
                    ? _machine
                    : null,
                decoration: InputDecoration(
                  labelText: f.label,
                  helperText: f.help,
                ),
                items: [
                  for (final m in widget.machines)
                    DropdownMenuItem(value: m.id, child: Text(m.name)),
                ],
                onChanged: (v) => setState(() => _machine = v),
              )
            else
              TextField(
                key: ValueKey('task-source-field-${f.key}'),
                controller: _fields[f.key],
                autocorrect: false,
                keyboardType: switch (f.kind) {
                  TaskSourceFieldKind.url => TextInputType.url,
                  TaskSourceFieldKind.email => TextInputType.emailAddress,
                  _ => TextInputType.text,
                },
                decoration: InputDecoration(
                  labelText: f.required ? f.label : '${f.label} (optional)',
                  hintText: f.hint.isEmpty ? null : f.hint,
                  helperText: f.help,
                  helperMaxLines: 3,
                ),
              ),
          ],
          if (_kind.tokenLabel case final label?) ...[
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('task-source-token'),
              controller: _token,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: label,
                helperText: _hasToken
                    ? 'Saved on this device. Leave empty to keep it.'
                    : 'Kept in this device\'s secure storage, never synced.',
                helperMaxLines: 2,
              ),
            ),
          ],
          const SizedBox(height: 16),
          if (_message case final message?)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                message,
                key: const ValueKey('task-source-message'),
                style: TextStyle(
                  color: _messageIsError
                      ? theme.colorScheme.error
                      : theme.colorScheme.primary,
                ),
              ),
            ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                key: const ValueKey('task-source-test'),
                onPressed: _busy ? null : () => unawaited(_test()),
                child: _busy
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Test'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                key: const ValueKey('task-source-save'),
                onPressed: _busy ? null : () => unawaited(_save()),
                child: const Text('Save'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
