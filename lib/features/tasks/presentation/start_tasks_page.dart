import 'dart:async';

import 'package:conduit/features/agent_attention/domain/agent_kinds.dart';
import 'package:conduit/features/tasks/domain/task_run.dart';
import 'package:conduit/features/tasks/domain/task_source.dart';
import 'package:conduit/features/tasks/domain/task_start_defaults.dart';
import 'package:conduit/features/tasks/presentation/task_runs_controller.dart';
import 'package:conduit/features/tasks/presentation/task_sources_controller.dart';
import 'package:conduit/features/tasks/presentation/task_sources_page.dart';
import 'package:flutter/material.dart';

/// The machines tasks can start on and the agents each has.
@immutable
class TaskStartEnvironment {
  const TaskStartEnvironment({required this.machines, required this.agentsOn});

  /// Machines whose companion starts tasks (capability `task-runs`).
  final List<TaskMachine> Function() machines;

  /// The agents installed on a machine (the New workspace picker's check).
  final Future<List<KnownAgentKind>> Function(String hostId) agentsOn;
}

/// The value of "Machine" that lets the app pick the least busy one.
const autoMachine = '';

/// Starts one task, or a batch (CON-037): machine (one for all, per task,
/// or automatic), repository, worktree on or off, place, agent, attempts,
/// the machine's concurrency cap, and whether a task that finishes moves to
/// done in its source. Pops with the number of runs queued.
class StartTasksPage extends StatefulWidget {
  const StartTasksPage({
    required this.tasks,
    required this.sources,
    required this.runs,
    required this.environment,
    super.key,
  });

  final List<TaskItem> tasks;
  final TaskSourcesController sources;
  final TaskRunsController runs;
  final TaskStartEnvironment environment;

  @override
  State<StartTasksPage> createState() => _StartTasksPageState();
}

class _StartTasksPageState extends State<StartTasksPage> {
  final _repo = TextEditingController();
  final _extra = TextEditingController();
  late final List<TaskMachine> _machines = widget.environment.machines();
  TaskStartDefaults _defaults = const TaskStartDefaults();
  bool _loaded = false;

  String _machine = autoMachine;

  /// Task ref → machine id, for tasks that do not follow [_machine].
  final Map<String, String> _perTask = {};
  bool _showPerTask = false;
  TaskPlace _place = TaskPlace.herdr;
  String? _agent;
  bool _worktree = true;
  int _attempts = 1;
  int _cap = 3;
  bool _markDone = false;

  /// Machine id → its agents (a future while checking).
  final Map<String, Future<List<KnownAgentKind>>> _agentChecks = {};
  List<KnownAgentKind>? _agents;
  bool _agentsFailed = false;
  bool _busy = false;
  String? _error;

  List<TaskItem> get _tasks => widget.tasks;
  String get _firstSource => _tasks.first.sourceId;

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  @override
  void dispose() {
    _repo.dispose();
    _extra.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final d = await widget.runs.defaults();
    if (!mounted) return;
    setState(() {
      _defaults = d;
      final remembered = d.machineBySource[_firstSource];
      _machine = remembered != null && _machines.any((m) => m.id == remembered)
          ? remembered
          : (_machines.length == 1 ? _machines.single.id : autoMachine);
      _repo.text = d.repoBySource[_firstSource] ?? '';
      _place = d.place;
      _agent = d.agent;
      _worktree = d.worktree;
      _attempts = d.attempts;
      _cap = d.cap;
      _markDone = d.markDone && _canMarkDone;
      _loaded = true;
    });
    _loadAgents();
  }

  /// Every task's source can change statuses.
  bool get _canMarkDone =>
      _tasks.every((t) => widget.sources.capabilitiesOf(t.sourceId).statuses);

  /// The machines the batch may use.
  Set<String> get _usedMachines => {
    for (final t in _tasks) _perTask[t.ref] ?? _machine,
  };

  /// Agents offered: those on every machine the batch may start on
  /// (every machine when one is automatic).
  void _loadAgents() {
    final used = _usedMachines;
    final ids = used.contains(autoMachine)
        ? [for (final m in _machines) m.id]
        : used.toList();
    setState(() {
      _agents = null;
      _agentsFailed = false;
    });
    if (ids.isEmpty) {
      setState(() => _agents = const []);
      return;
    }
    final checks = [
      for (final id in ids)
        _agentChecks[id] ??= widget.environment.agentsOn(id),
    ];
    Future.wait(checks).then(
      (lists) {
        if (!mounted) return;
        final common = lists.first
            .where((a) => lists.every((l) => l.any((b) => b.kind == a.kind)))
            .toList();
        setState(() {
          _agents = common;
          if (!common.any((a) => a.kind == _agent)) {
            _agent = common.isEmpty ? null : common.first.kind;
          }
        });
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

  /// [_machine], or per task, with "automatic" resolved to the least busy
  /// machine (counting the runs this batch adds).
  Map<String, List<TaskItem>> _assign() {
    final load = {for (final m in _machines) m.id: widget.runs.busyOn(m.id)};
    final out = <String, List<TaskItem>>{};
    for (final t in _tasks) {
      var id = _perTask[t.ref] ?? _machine;
      if (id == autoMachine) {
        id = load.entries.reduce((a, b) => b.value < a.value ? b : a).key;
      }
      load[id] = (load[id] ?? 0) + _attempts;
      (out[id] ??= []).add(t);
    }
    return out;
  }

  Future<TaskStartItem> _item(TaskItem task) async {
    var full = task;
    if (task.body == null) {
      try {
        full = await widget.sources.read(task);
      } on Object catch (_) {
        // Start with the title alone.
      }
    }
    return TaskStartItem(
      key: full.key.isEmpty ? full.id : full.key,
      title: full.title,
      url: full.url,
      ref: full.ref,
      prompt: taskPrompt(
        key: full.key,
        title: full.title,
        body: full.body,
        url: full.url,
        extra: _extra.text,
      ),
    );
  }

  Future<void> _start() async {
    final repo = _repo.text.trim();
    final agent = _agent;
    String? problem;
    if (_machines.isEmpty) {
      problem = 'No machine can start tasks: update its companion.';
    } else if (repo.isEmpty) {
      problem = 'Enter the repository on the machine.';
    } else if (agent == null) {
      problem = 'Pick an agent.';
    }
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    var queued = 0;
    try {
      for (final MapEntry(key: hostId, value: tasks) in _assign().entries) {
        final runs = await widget.runs.start(
          hostId,
          TaskStartRequest(
            repo: repo,
            agent: agent!,
            place: _place,
            worktree: _worktree,
            attempts: _attempts,
            cap: _cap,
            markDone: _markDone,
            tasks: [for (final t in tasks) await _item(t)],
          ),
        );
        queued += runs.length;
      }
      await widget.runs.rememberDefaults(
        _defaults.copyWith(
          place: _place,
          agent: agent,
          worktree: _worktree,
          attempts: _attempts,
          cap: _cap,
          markDone: _markDone,
          machineBySource: {
            ..._defaults.machineBySource,
            _firstSource: _machine,
          },
          repoBySource: {..._defaults.repoBySource, _firstSource: repo},
        ),
      );
      if (mounted) Navigator.of(context).pop(queued);
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = queued == 0 ? '$e' : '$queued started, then: $e';
        });
      }
    }
  }

  Widget _machineMenu({
    required Key key,
    required String value,
    required ValueChanged<String> onChanged,
    String? label,
  }) => DropdownButtonFormField<String>(
    key: key,
    initialValue: value,
    isExpanded: true,
    decoration: InputDecoration(labelText: label, isDense: true),
    items: [
      const DropdownMenuItem(
        value: autoMachine,
        child: Text('Automatic (least busy)'),
      ),
      for (final m in _machines)
        DropdownMenuItem(value: m.id, child: Text(m.name)),
    ],
    onChanged: _busy
        ? null
        : (v) {
            if (v == null) return;
            onChanged(v);
            _loadAgents();
          },
  );

  Widget _stepper(
    String label,
    int value,
    int min,
    int max,
    Key key,
    ValueChanged<int> onChanged,
  ) => Row(
    key: key,
    children: [
      Expanded(child: Text(label)),
      IconButton(
        tooltip: 'Fewer',
        icon: const Icon(Icons.remove),
        onPressed: _busy || value <= min ? null : () => onChanged(value - 1),
      ),
      Text('$value'),
      IconButton(
        tooltip: 'More',
        icon: const Icon(Icons.add),
        onPressed: _busy || value >= max ? null : () => onChanged(value + 1),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final n = _tasks.length;
    final agents = _agents;
    return Scaffold(
      appBar: AppBar(title: Text(n == 1 ? 'Start task' : 'Start $n tasks')),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                for (final t in _tasks.take(5))
                  Text(
                    '${t.key}  ${t.title}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                if (n > 5) Text('and ${n - 5} more'),
                const SizedBox(height: 16),
                if (_machines.isEmpty)
                  Text(
                    'No monitored machine can start tasks yet: its companion '
                    'needs updating (Settings › Agents).',
                    style: TextStyle(color: theme.colorScheme.error),
                  )
                else ...[
                  _machineMenu(
                    key: const ValueKey('start-machine'),
                    label: 'Machine',
                    value: _machine,
                    onChanged: (v) => setState(() => _machine = v),
                  ),
                  if (n > 1 && _machines.length > 1)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        key: const ValueKey('start-per-task'),
                        onPressed: () =>
                            setState(() => _showPerTask = !_showPerTask),
                        child: Text(
                          _showPerTask
                              ? 'Same machine for every task'
                              : 'Choose the machine per task',
                        ),
                      ),
                    ),
                  if (_showPerTask)
                    for (final t in _tasks)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: _machineMenu(
                          key: ValueKey('start-machine-${t.ref}'),
                          label: t.key,
                          value: _perTask[t.ref] ?? _machine,
                          onChanged: (v) => setState(() => _perTask[t.ref] = v),
                        ),
                      ),
                ],
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('start-repo'),
                  controller: _repo,
                  enabled: !_busy,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: 'Repository on the machine',
                    hintText: '~/Projects/app',
                  ),
                ),
                const SizedBox(height: 16),
                Text('Agent', style: theme.textTheme.labelLarge),
                const SizedBox(height: 6),
                if (agents == null)
                  const LinearProgressIndicator()
                else if (agents.isEmpty)
                  Text(
                    _agentsFailed
                        ? 'Could not check which agents the machine has.'
                        : 'No coding agent found on '
                              '${_usedMachines.length > 1 || _usedMachines.contains(autoMachine) ? 'every one of these machines' : 'this machine'}.',
                    style: theme.textTheme.bodySmall,
                  )
                else
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final a in agents)
                        ChoiceChip(
                          key: ValueKey('start-agent-${a.kind}'),
                          label: Text(a.label),
                          selected: _agent == a.kind,
                          onSelected: _busy
                              ? null
                              : (_) => setState(() => _agent = a.kind),
                        ),
                    ],
                  ),
                const SizedBox(height: 16),
                Text('Where it runs', style: theme.textTheme.labelLarge),
                const SizedBox(height: 6),
                SegmentedButton<TaskPlace>(
                  key: const ValueKey('start-place'),
                  segments: [
                    for (final p in TaskPlace.values)
                      ButtonSegment(value: p, label: Text(p.label)),
                  ],
                  selected: {_place},
                  onSelectionChanged: _busy
                      ? null
                      : (s) => setState(() => _place = s.first),
                ),
                if (_place == TaskPlace.none)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      'The companion prepares the run; open it from the '
                      'task runs list in a terminal of its own.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                const SizedBox(height: 8),
                SwitchListTile(
                  key: const ValueKey('start-worktree'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Fresh worktree and branch'),
                  subtitle: Text(
                    _worktree
                        ? 'One per task and attempt, where Settings › Herdr '
                              'and worktrees says.'
                        : 'Works in the repository as it is.',
                  ),
                  value: _worktree,
                  onChanged: _busy
                      ? null
                      : (v) => setState(() {
                          _worktree = v;
                          if (!v) _attempts = 1;
                        }),
                ),
                _stepper(
                  'Attempts per task',
                  _attempts,
                  1,
                  _worktree ? 5 : 1,
                  const ValueKey('start-attempts'),
                  (v) => setState(() => _attempts = v),
                ),
                _stepper(
                  'At once on a machine',
                  _cap,
                  1,
                  20,
                  const ValueKey('start-cap'),
                  (v) => setState(() => _cap = v),
                ),
                SwitchListTile(
                  key: const ValueKey('start-mark-done'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Mark done in the source when finished'),
                  subtitle: Text(
                    _canMarkDone
                        ? 'Moves the task to a done status and comments, once '
                              'its agent ends its first turn.'
                        : 'A source of these tasks has no statuses.',
                  ),
                  value: _markDone,
                  onChanged: _busy || !_canMarkDone
                      ? null
                      : (v) => setState(() => _markDone = v),
                ),
                TextField(
                  key: const ValueKey('start-extra'),
                  controller: _extra,
                  enabled: !_busy,
                  minLines: 1,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'Extra instructions (optional)',
                  ),
                ),
                const SizedBox(height: 16),
                if (_error case final error?)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      error,
                      key: const ValueKey('start-error'),
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
                FilledButton.icon(
                  key: const ValueKey('start-submit'),
                  onPressed: _busy ? null : () => unawaited(_start()),
                  icon: _busy
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.play_arrow_rounded),
                  label: Text(
                    n == 1 && _attempts == 1
                        ? 'Start'
                        : 'Start ${n * _attempts} runs',
                  ),
                ),
              ],
            ),
    );
  }
}
