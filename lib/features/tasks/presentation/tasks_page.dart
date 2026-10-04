import 'dart:async';

import 'package:conduit/features/tasks/domain/task_source.dart';
import 'package:conduit/features/tasks/presentation/task_detail_page.dart';
import 'package:conduit/features/tasks/presentation/task_sources_controller.dart';
import 'package:conduit/features/tasks/presentation/task_sources_page.dart';
import 'package:flutter/material.dart';

/// Every source's tasks in one list, filtered by source, status and
/// assignee; a task opens its detail page.
class TasksPage extends StatefulWidget {
  const TasksPage({
    required this.controller,
    required this.machines,
    super.key,
  });

  final TaskSourcesController controller;
  final List<TaskMachine> Function() machines;

  @override
  State<TasksPage> createState() => _TasksPageState();
}

class _TasksPageState extends State<TasksPage> {
  TaskFilter _filter = const TaskFilter();
  final _search = TextEditingController();

  TaskSourcesController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    unawaited(_initial());
  }

  Future<void> _initial() async {
    await _c.ensureLoaded();
    if (_c.allTasks.isEmpty && !_c.loadingTasks) await _c.refresh();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _openSources() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            TaskSourcesPage(controller: _c, machines: widget.machines),
      ),
    );
  }

  Future<void> _open(TaskItem task) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => TaskDetailPage(controller: _c, task: task),
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Tasks'),
      actions: [
        IconButton(
          key: const ValueKey('tasks-refresh'),
          tooltip: 'Refresh',
          icon: const Icon(Icons.refresh),
          onPressed: () => unawaited(_c.refresh()),
        ),
        IconButton(
          key: const ValueKey('tasks-sources'),
          tooltip: 'Sources',
          icon: const Icon(Icons.tune),
          onPressed: () => unawaited(_openSources()),
        ),
      ],
    ),
    body: ListenableBuilder(
      listenable: _c,
      builder: (context, _) {
        if (!_c.loaded) {
          return const Center(child: CircularProgressIndicator());
        }
        if (_c.sources.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Add a task source: a markdown folder on a machine, '
                    'GitHub or GitLab Issues, Jira, Linear or Azure Boards.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    key: const ValueKey('tasks-add-source'),
                    onPressed: () => unawaited(_openSources()),
                    child: const Text('Add a source'),
                  ),
                ],
              ),
            ),
          );
        }
        final all = _c.allTasks;
        final tasks = all.where(_filter.matches).toList();
        final errors = [
          for (final s in _c.sources)
            if (_c.tasksOf(s.id).error case final error?) (s.name, error),
        ];
        return RefreshIndicator(
          onRefresh: _c.refresh,
          child: ListView.builder(
            key: const ValueKey('tasks-list'),
            physics: const AlwaysScrollableScrollPhysics(),
            itemCount: tasks.length + 1,
            itemBuilder: (context, i) {
              if (i == 0) return _header(context, all, errors, tasks.length);
              final task = tasks[i - 1];
              return _TaskTile(
                task: task,
                sourceName: _c.sourceById(task.sourceId)?.name ?? '',
                showSource: _c.sources.length > 1,
                onTap: () => unawaited(_open(task)),
              );
            },
          ),
        );
      },
    ),
  );

  Widget _header(
    BuildContext context,
    List<TaskItem> all,
    List<(String, String)> errors,
    int shown,
  ) {
    final theme = Theme.of(context);
    final statuses = {
      for (final t in all)
        if ((_filter.sourceId == null || t.sourceId == _filter.sourceId) &&
            t.status != null)
          t.status!.label,
    }.toList()..sort();
    final assignees = {
      for (final t in all)
        if (_filter.sourceId == null || t.sourceId == _filter.sourceId)
          ...t.assignees,
    }.toList()..sort();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const ValueKey('tasks-search'),
            controller: _search,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search title or key',
              isDense: true,
            ),
            onChanged: (v) =>
                setState(() => _filter = _filter.copyWith(query: () => v)),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              if (_c.sources.length > 1)
                _FilterChip<String>(
                  key: const ValueKey('tasks-filter-source'),
                  label: 'Source',
                  value: _filter.sourceId,
                  options: [for (final s in _c.sources) (s.id, s.name)],
                  onChanged: (v) => setState(
                    () => _filter = _filter.copyWith(
                      sourceId: () => v,
                      status: () => null,
                      assignee: () => null,
                    ),
                  ),
                ),
              _FilterChip<String>(
                key: const ValueKey('tasks-filter-status'),
                label: 'Status',
                value: _filter.status,
                options: [for (final s in statuses) (s, s)],
                onChanged: (v) =>
                    setState(() => _filter = _filter.copyWith(status: () => v)),
              ),
              _FilterChip<String>(
                key: const ValueKey('tasks-filter-assignee'),
                label: 'Assignee',
                value: _filter.assignee,
                options: [
                  (TaskFilter.unassigned, 'Nobody'),
                  for (final a in assignees) (a, a),
                ],
                onChanged: (v) => setState(
                  () => _filter = _filter.copyWith(assignee: () => v),
                ),
              ),
            ],
          ),
          if (_c.loadingTasks)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: LinearProgressIndicator(),
            ),
          for (final (name, error) in errors)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '$name: $error',
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '$shown of ${all.length} tasks',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

/// A chip that opens a menu of [options]; "Any" clears it.
class _FilterChip<T> extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    super.key,
  });

  final String label;
  final T? value;
  final List<(T, String)> options;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) {
    String? selected;
    for (final (v, name) in options) {
      if (v == value) selected = name;
    }
    return PopupMenuButton<(T?,)>(
      tooltip: label,
      onSelected: (choice) => onChanged(choice.$1),
      itemBuilder: (context) => [
        PopupMenuItem(
          value: (null,),
          child: Text('Any ${label.toLowerCase()}'),
        ),
        for (final (v, name) in options)
          PopupMenuItem(value: (v,), child: Text(name)),
      ],
      child: Chip(
        avatar: Icon(value == null ? Icons.filter_list : Icons.check, size: 16),
        label: Text(selected == null ? label : '$label: $selected'),
      ),
    );
  }
}

class _TaskTile extends StatelessWidget {
  const _TaskTile({
    required this.task,
    required this.sourceName,
    required this.showSource,
    required this.onTap,
  });

  final TaskItem task;
  final String sourceName;
  final bool showSource;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final meta = [
      if (showSource) sourceName,
      ?task.status?.label,
      if (task.assignees.isNotEmpty) task.assignees.join(', '),
    ].join(' · ');
    return ListTile(
      key: ValueKey('task-${task.ref}'),
      onTap: onTap,
      leading: Icon(
        switch (task.status?.category) {
          TaskStatusCategory.done => Icons.check_circle_outline,
          TaskStatusCategory.inProgress => Icons.timelapse,
          _ => Icons.radio_button_unchecked,
        },
        color: task.status?.category == TaskStatusCategory.done
            ? theme.colorScheme.outline
            : theme.colorScheme.primary,
      ),
      title: Text(
        '${task.key}  ${task.title}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: meta.isEmpty ? null : Text(meta),
    );
  }
}
