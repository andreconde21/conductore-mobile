import 'dart:async';

import 'package:conduit/features/tasks/domain/task_run.dart';
import 'package:conduit/features/tasks/domain/task_source.dart';
import 'package:conduit/features/tasks/domain/task_start_defaults.dart';
import 'package:conduit/features/tasks/presentation/task_sources_controller.dart';
import 'package:flutter/foundation.dart';

/// Runs `conductore-hostd <args>` on [hostId], [stdin] as JSON on its
/// input; the decoded reply (throws [TaskSourceFailure]).
typedef CompanionJsonCall =
    Future<Map<String, Object?>> Function(
      String hostId,
      String args, {
      Map<String, Object?>? stdin,
    });

/// One batch on one machine, for the dashboard's grouping.
typedef TaskRunBatch = ({String hostId, String batchId, List<TaskRun> runs});

/// Started tasks per machine (CON-037): starts batches through the
/// companion, follows them, and when a run the user opted in for
/// ([TaskRun.markDone]) finishes well, moves its task to a done status
/// through its source and says so in a comment. Each run is synced once.
class TaskRunsController extends ChangeNotifier {
  TaskRunsController({
    required this.call,
    required this.sources,
    required this.loadSynced,
    required this.saveSynced,
    this.loadDefaults,
    this.saveDefaults,
    this.hosts,
  });

  /// The machines whose companion starts tasks: asked now and then, so
  /// runs started elsewhere (another device, the CLI) show too.
  final List<String> Function()? hosts;

  /// The app's one instance (the task list, Start and the dashboard).
  static TaskRunsController? instance;

  /// "Start"'s remembered choices, as stored on this device.
  final Future<String?> Function()? loadDefaults;
  final Future<void> Function(String json)? saveDefaults;

  TaskStartDefaults? _defaults;

  Future<TaskStartDefaults> defaults() async =>
      _defaults ??= TaskStartDefaults.parse(await loadDefaults?.call());

  Future<void> rememberDefaults(TaskStartDefaults defaults) async {
    _defaults = defaults;
    await saveDefaults?.call(defaults.toJson());
  }

  /// Runs waiting or going on [hostId] (Start's automatic machine choice
  /// takes the least busy).
  int busyOn(String hostId) => runsOn(
    hostId,
  ).where((r) => r.active || r.status == TaskRunStatus.queued).length;

  /// Asks every machine of [hosts] once, then keeps following: called
  /// when Tasks or the dashboard shows started tasks.
  Future<void> watch() async {
    if (_poll == null) startPolling();
    await refreshAll(hosts?.call() ?? const []);
  }

  /// Refreshes [hostIds] side by side.
  Future<void> refreshAll(Iterable<String> hostIds) =>
      Future.wait([for (final id in hostIds) refresh(id)]);

  final CompanionJsonCall call;
  final TaskSourcesController sources;

  /// The `<host>/<run id>`s already synced, as stored on this device.
  final Future<List<String>> Function() loadSynced;
  final Future<void> Function(List<String> ids) saveSynced;

  final Map<String, List<TaskRun>> _runs = {};
  final Map<String, String> _errors = {};
  final Map<String, String> _syncErrors = {};
  Set<String>? _synced;
  final Set<String> _syncing = {};
  Timer? _poll;

  List<TaskRun> runsOn(String hostId) => _runs[hostId] ?? const [];
  String? errorOn(String hostId) => _errors[hostId];

  /// Why moving [run]'s task to done failed, if it did.
  String? syncErrorOf(String hostId, String runId) =>
      _syncErrors['$hostId/$runId'];

  /// Every machine's runs, by batch, newest batch first.
  List<TaskRunBatch> get batches {
    final out = <TaskRunBatch>[];
    for (final MapEntry(key: hostId, value: runs) in _runs.entries) {
      final byBatch = <String, List<TaskRun>>{};
      for (final r in runs) {
        (byBatch[r.batchId] ??= []).add(r);
      }
      for (final MapEntry(key: batchId, value: list) in byBatch.entries) {
        out.add((hostId: hostId, batchId: batchId, runs: list));
      }
    }
    DateTime first(TaskRunBatch b) => b.runs
        .map((r) => r.createdAt ?? DateTime(0))
        .reduce((a, c) => a.isBefore(c) ? a : c);
    out.sort((a, b) => first(b).compareTo(first(a)));
    return out;
  }

  /// Whether any machine has runs waiting or going.
  bool get anyActive => _runs.values.any(
    (runs) => runs.any((r) => r.active || r.status == TaskRunStatus.queued),
  );

  List<TaskRun> _parse(Map<String, Object?> json) => [
    if (json['runs'] case final List<Object?> list)
      for (final r in list) ?TaskRun.fromJson(r),
  ];

  /// Starts [request]'s batch on [hostId]; the new runs.
  Future<List<TaskRun>> start(String hostId, TaskStartRequest request) async {
    final json = await call(hostId, 'task-start -', stdin: request.toJson());
    final started = _parse(json);
    await refresh(hostId);
    return started;
  }

  /// Reads [hostId]'s runs, then syncs the finished ones.
  Future<void> refresh(String hostId) async {
    try {
      final json = await call(hostId, 'task-runs list');
      _runs[hostId] = _parse(json);
      _errors.remove(hostId);
    } on Object catch (e) {
      _errors[hostId] = '$e';
    }
    notifyListeners();
    await _syncDone(hostId);
  }

  Future<void> cancel(String hostId, String runId) async {
    await call(hostId, 'task-runs cancel $runId');
    await refresh(hostId);
  }

  /// Forgets a done run; the companion closes its agent, removes a clean
  /// worktree and a merged branch (any branch with [deleteBranch]) and its
  /// prompt. Returns the companion's report (`worktree`, `branch`, ...).
  Future<Map<String, Object?>> forget(
    String hostId,
    String runId, {
    bool deleteBranch = false,
  }) async {
    final report = await call(
      hostId,
      'task-runs forget $runId${deleteBranch ? ' --delete-branch' : ''}',
    );
    await refresh(hostId);
    return report;
  }

  /// Keeps (or stops keeping) a done run's agent open past the companion's
  /// keep time.
  Future<void> keep(String hostId, String runId, {bool on = true}) async {
    await call(hostId, 'task-runs keep $runId${on ? '' : ' off'}');
    await refresh(hostId);
  }

  /// What [forget]'s report means for the user, or null when everything
  /// went.
  static String? forgetNote(Map<String, Object?> report) {
    final notes = [
      if (report['worktree'] == 'kept')
        'Worktree kept: ${report['worktreeReason'] ?? 'not clean'}'
            '${report['worktreePath'] is String ? ' (${report['worktreePath']})' : ''}',
      if (report['branch'] == 'kept')
        'Branch kept: ${report['branchReason'] ?? 'not merged'}',
    ];
    return notes.isEmpty ? null : notes.join('\n');
  }

  /// How many runs a machine starts at once.
  Future<void> setCap(String hostId, int cap) async {
    await call(hostId, 'task-runs cap $cap');
    await refresh(hostId);
  }

  /// Refreshes the machines with waiting or going runs every [every], and
  /// every machine of [hosts] every [allEvery] ticks (the first tick too).
  void startPolling({
    Duration every = const Duration(seconds: 20),
    int allEvery = 15,
  }) {
    _poll?.cancel();
    var tick = 0;
    _poll = Timer.periodic(every, (_) {
      final all = tick++ % allEvery == 0;
      final ids = {
        if (all) ...?hosts?.call(),
        for (final MapEntry(key: hostId, value: runs) in _runs.entries)
          if (runs.any((r) => r.active || r.status == TaskRunStatus.queued))
            hostId,
      };
      for (final id in ids) {
        unawaited(refresh(id));
      }
    });
  }

  void stopPolling() {
    _poll?.cancel();
    _poll = null;
  }

  @override
  void dispose() {
    stopPolling();
    super.dispose();
  }

  /// The status a finished task moves to: the source's first done status
  /// that is not a cancellation.
  static TaskStatusOption? doneStatus(List<TaskStatusOption> options) {
    final done = options.where((o) => o.category == TaskStatusCategory.done);
    for (final o in done) {
      final l = o.label.toLowerCase();
      if (!l.contains('cancel') && !l.contains('won') && !l.contains('remov')) {
        return o;
      }
    }
    return done.isEmpty ? null : done.first;
  }

  Future<void> _syncDone(String hostId) async {
    final synced = _synced ??= {...await loadSynced()};
    for (final run in runsOn(hostId)) {
      final key = '$hostId/${run.id}';
      final ref = run.taskRef;
      if (!run.markDone || !run.succeeded || ref == null) continue;
      if (synced.contains(key) || !_syncing.add(key)) continue;
      try {
        await _markDone(run, ref);
        synced.add(key);
        _syncErrors.remove(key);
        await saveSynced(synced.toList());
      } on Object catch (e) {
        _syncErrors[key] = '$e';
      } finally {
        _syncing.remove(key);
      }
      notifyListeners();
    }
  }

  Future<void> _markDone(TaskRun run, String ref) async {
    final slash = ref.indexOf('/');
    if (slash <= 0) {
      throw const TaskSourceFailure('bad-config', 'The run names no task.');
    }
    final sourceId = ref.substring(0, slash);
    final task =
        sources.taskByRef(ref) ??
        TaskItem(
          sourceId: sourceId,
          id: ref.substring(slash + 1),
          key: run.taskKey ?? '',
          title: run.taskTitle ?? '',
        );
    final caps = sources.capabilitiesOf(sourceId);
    if (caps.statuses) {
      final done = doneStatus(await sources.statusOptions(task));
      if (done == null) {
        throw const TaskSourceFailure(
          'unsupported',
          'The source offers no done status for this task.',
        );
      }
      if (task.status?.category != TaskStatusCategory.done) {
        await sources.updateStatus(task, done);
      }
    }
    if (caps.comments) {
      await sources.comment(
        task,
        'Finished by ${run.agent} (Conductore) on branch '
        '${run.branch ?? '?'}${run.attempts > 1 ? ', attempt ${run.attempt}' : ''}.',
      );
    }
  }
}
