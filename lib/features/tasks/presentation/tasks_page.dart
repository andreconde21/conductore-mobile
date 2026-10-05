import 'dart:async';

import 'package:conduit/features/tasks/domain/task_source.dart';
import 'package:conduit/features/tasks/presentation/start_tasks_page.dart';
import 'package:conduit/features/tasks/presentation/task_detail_page.dart';
import 'package:conduit/features/tasks/presentation/task_runs_controller.dart';
import 'package:conduit/features/tasks/presentation/task_runs_panel.dart';
import 'package:conduit/features/tasks/presentation/task_sources_controller.dart';
import 'package:conduit/features/tasks/presentation/task_sources_page.dart';
import 'package:flutter/material.dart';

/// Every source's tasks in one list, filtered by source, status, assignee
/// and project; a task opens its detail page. With [runs], tasks start as
/// agents: "Start" on a task, or long-press to select several and
/// "Start N tasks" (CON-037).
class TasksPage extends StatefulWidget {
  const TasksPage({
    required this.controller,
    required this.machines,
    this.runs,
    this.startEnvironment,
    this.hostName,
    super.key,
  });

  final TaskSourcesController controller;
  final List<TaskMachine> Function() machines;
  final TaskRunsController? runs;
  final TaskStartEnvironment? startEnvironment;

  /// A machine's name, for the started tasks.
  final String Function(String hostId)? hostName;

  @override
  State<TasksPage> createState() => _TasksPageState();
}

class _TasksPageState extends State<TasksPage> {
  TaskFilter _filter = const TaskFilter();
  TaskSort _sort = TaskSort.updated;
  final _search = TextEditingController();

  bool _shown(TaskItem t) =>
      _filter.sourceIds == null || _filter.sourceIds!.contains(t.sourceId);

  /// Picks the sources shown: every one, or the ones ticked.
  Future<void> _pickSources() async {
    final chosen = await showDialog<Set<String>>(
      context: context,
      builder: (context) => _SourcesDialog(
        sources: [for (final s in _c.sources) (s.id, s.name, s.kind.label)],
        selected: _filter.sourceIds ?? {for (final s in _c.sources) s.id},
      ),
    );
    if (chosen == null) return;
    final all = chosen.length == _c.sources.length;
    setState(
      () => _filter = _filter.copyWith(
        sourceIds: () => all ? null : chosen,
        status: () => null,
        assignee: () => null,
        project: () => null,
      ),
    );
  }

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

  /// Refs of the tasks selected for "Start N tasks".
  final Set<String> _selected = {};

  bool get _canStart => widget.runs != null && widget.startEnvironment != null;

  Future<void> _open(TaskItem task) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => TaskDetailPage(
        controller: _c,
        task: task,
        actions: [
          if (_canStart)
            Builder(
              builder: (context) => FilledButton.icon(
                key: const ValueKey('task-start'),
                onPressed: () => unawaited(_start(context, [task])),
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('Start'),
              ),
            ),
        ],
      ),
    ),
  );

  Future<void> _start(BuildContext context, List<TaskItem> tasks) async {
    final runs = widget.runs;
    final environment = widget.startEnvironment;
    if (runs == null || environment == null || tasks.isEmpty) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final queued = await Navigator.of(context).push<int>(
      MaterialPageRoute(
        builder: (_) => StartTasksPage(
          tasks: tasks,
          sources: _c,
          runs: runs,
          environment: environment,
        ),
      ),
    );
    if (queued == null || !mounted) return;
    setState(_selected.clear);
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          '$queued run${queued == 1 ? '' : 's'} started or queued.',
        ),
        action: SnackBarAction(label: 'Show', onPressed: _openRuns),
      ),
    );
  }

  void _openRuns() {
    final runs = widget.runs;
    final environment = widget.startEnvironment;
    if (runs == null) return;
    final hostIds = [
      for (final m in environment?.machines() ?? const <TaskMachine>[]) m.id,
    ];
    unawaited(runs.watch());
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => TaskRunsPage(
            controller: runs,
            hostName: widget.hostName ?? (id) => id,
            hostIds: () => hostIds,
          ),
        ),
      ),
    );
  }

  void _toggle(TaskItem task) => setState(
    () => _selected.contains(task.ref)
        ? _selected.remove(task.ref)
        : _selected.add(task.ref),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(_selected.isEmpty ? 'Tasks' : '${_selected.length} selected'),
      leading: _selected.isEmpty
          ? null
          : IconButton(
              key: const ValueKey('tasks-clear-selection'),
              tooltip: 'Clear selection',
              icon: const Icon(Icons.close),
              onPressed: () => setState(_selected.clear),
            ),
      actions: [
        if (_selected.isNotEmpty)
          TextButton.icon(
            key: const ValueKey('tasks-start-selected'),
            onPressed: () => unawaited(
              _start(context, [
                for (final t in _c.allTasks)
                  if (_selected.contains(t.ref)) t,
              ]),
            ),
            icon: const Icon(Icons.play_arrow_rounded),
            label: Text(
              _selected.length == 1
                  ? 'Start'
                  : 'Start ${_selected.length} tasks',
            ),
          ),
        if (widget.runs != null && _selected.isEmpty)
          IconButton(
            key: const ValueKey('tasks-runs'),
            tooltip: 'Started tasks',
            icon: const Icon(Icons.rocket_launch_outlined),
            onPressed: _openRuns,
          ),
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
        final tasks = _c.sorted(all.where(_filter.matches).toList(), _sort);
        final errors = [
          for (final s in _c.sources)
            if (_c.tasksOf(s.id).error case final error?) (s.name, error),
        ];
        final partial = [
          for (final s in _c.sources)
            if (_c.tasksOf(s.id) case final t when t.partial)
              (s, t.tasks.length, t.total!),
        ];
        return RefreshIndicator(
          onRefresh: _c.refresh,
          child: ListView.builder(
            key: const ValueKey('tasks-list'),
            physics: const AlwaysScrollableScrollPhysics(),
            itemCount: tasks.length + 1,
            itemBuilder: (context, i) {
              if (i == 0) {
                return _header(context, all, errors, partial, tasks.length);
              }
              final task = tasks[i - 1];
              return _TaskTile(
                task: task,
                sourceName: _c.sourceById(task.sourceId)?.name ?? '',
                showSource: _c.sources.length > 1,
                selected: _selected.isEmpty
                    ? null
                    : _selected.contains(task.ref),
                onTap: () =>
                    _selected.isEmpty ? unawaited(_open(task)) : _toggle(task),
                onLongPress: _canStart ? () => _toggle(task) : null,
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
    List<(TaskSourceConfig, int, int)> partial,
    int shown,
  ) {
    final theme = Theme.of(context);
    final statuses = {
      for (final t in all)
        if (_shown(t) && t.status != null) t.status!.label,
    }.toList()..sort();
    final assignees = {
      for (final t in all)
        if (_shown(t)) ...t.assignees,
    }.toList()..sort();
    final projects = {
      for (final t in all)
        if (_shown(t) && t.project != null) t.project!,
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
                ActionChip(
                  key: const ValueKey('tasks-filter-source'),
                  avatar: Icon(
                    _filter.sourceIds == null
                        ? Icons.layers_outlined
                        : Icons.check,
                    size: 16,
                  ),
                  label: Text(switch (_filter.sourceIds) {
                    null => 'All sources',
                    final ids when ids.length == 1 =>
                      _c.sourceById(ids.first)?.name ?? '1 source',
                    final ids => '${ids.length} sources',
                  }),
                  onPressed: () => unawaited(_pickSources()),
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
              if (projects.isNotEmpty || _filter.project != null)
                _FilterChip<String>(
                  key: const ValueKey('tasks-filter-project'),
                  label: 'Project',
                  value: _filter.project,
                  options: [for (final p in projects) (p, p)],
                  onChanged: (v) => setState(
                    () => _filter = _filter.copyWith(project: () => v),
                  ),
                ),
              if (_c.hasDoneToggle)
                FilterChip(
                  key: const ValueKey('tasks-show-done'),
                  label: const Text('Show done'),
                  selected: _c.showDone,
                  onSelected: (v) => unawaited(_c.setShowDone(v)),
                ),
              PopupMenuButton<TaskSort>(
                key: const ValueKey('tasks-sort'),
                tooltip: 'Sort',
                initialValue: _sort,
                onSelected: (v) => setState(() => _sort = v),
                itemBuilder: (context) => [
                  for (final s in TaskSort.values)
                    PopupMenuItem(value: s, child: Text(s.label)),
                ],
                child: Chip(
                  avatar: const Icon(Icons.sort, size: 16),
                  label: Text(_sort.label),
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
          for (final (source, count, total) in partial)
            Padding(
              key: ValueKey('tasks-partial-${source.id}'),
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '${source.name}: showing the newest $count of $total '
                '${_c.showDone ? '' : 'open '}tasks.',
                style: theme.textTheme.bodySmall,
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
    this.selected,
    this.onLongPress,
  });

  final TaskItem task;
  final String sourceName;
  final bool showSource;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  /// Null outside selection mode.
  final bool? selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final meta = [
      ?task.status?.label,
      if (task.assignees.isNotEmpty) task.assignees.join(', '),
    ].join(' · ');
    return ListTile(
      key: ValueKey('task-${task.ref}'),
      onTap: onTap,
      onLongPress: onLongPress,
      selected: selected ?? false,
      leading: selected != null
          ? Checkbox(value: selected, onChanged: (_) => onTap())
          : Icon(
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
      subtitle: !showSource && task.project == null && meta.isEmpty
          ? null
          : Text.rich(
              TextSpan(
                children: [
                  if (showSource)
                    WidgetSpan(
                      alignment: PlaceholderAlignment.middle,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: TaskSourceBadge(name: sourceName),
                      ),
                    ),
                  if (task.project case final project?)
                    WidgetSpan(
                      alignment: PlaceholderAlignment.middle,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: _ProjectLabel(name: project),
                      ),
                    ),
                  TextSpan(text: meta),
                ],
              ),
            ),
    );
  }
}

/// A task's source, as a small label with a colour of its own (stable per
/// name), so tasks from several sources tell apart at a glance.
class TaskSourceBadge extends StatelessWidget {
  const TaskSourceBadge({required this.name, super.key});

  final String name;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hue =
        (name.codeUnits.fold<int>(7, (h, c) => (h * 31 + c) & 0xffff) % 360)
            .toDouble();
    final color = HSLColor.fromAHSL(
      1,
      hue,
      0.45,
      scheme.brightness == Brightness.dark ? 0.7 : 0.4,
    ).toColor();
    return DecoratedBox(
      key: ValueKey('task-source-badge-$name'),
      decoration: BoxDecoration(
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        child: Text(
          name,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
        ),
      ),
    );
  }
}

/// A task's project, as a small filled label (quieter than the source
/// badge beside it).
class _ProjectLabel extends StatelessWidget {
  const _ProjectLabel({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      key: ValueKey('task-project-$name'),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        child: Text(
          name,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSecondaryContainer,
          ),
        ),
      ),
    );
  }
}

/// Ticks the sources the list shows.
class _SourcesDialog extends StatefulWidget {
  const _SourcesDialog({required this.sources, required this.selected});

  final List<(String id, String name, String kind)> sources;
  final Set<String> selected;

  @override
  State<_SourcesDialog> createState() => _SourcesDialogState();
}

class _SourcesDialogState extends State<_SourcesDialog> {
  late final Set<String> _selected = {...widget.selected};

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Show tasks from'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (id, name, kind) in widget.sources)
            CheckboxListTile(
              key: ValueKey('tasks-source-check-$id'),
              value: _selected.contains(id),
              title: Text(name),
              subtitle: Text(kind),
              onChanged: (on) => setState(
                () => on == true ? _selected.add(id) : _selected.remove(id),
              ),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () =>
            setState(() => _selected.addAll(widget.sources.map((s) => s.$1))),
        child: const Text('All'),
      ),
      FilledButton(
        key: const ValueKey('tasks-sources-apply'),
        onPressed: _selected.isEmpty
            ? null
            : () => Navigator.of(context).pop(_selected),
        child: const Text('Show'),
      ),
    ],
  );
}
