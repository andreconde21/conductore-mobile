import 'dart:async';
import 'dart:convert';

import 'package:conduit/features/tasks/domain/task_run.dart';
import 'package:conduit/features/tasks/domain/task_source.dart';
import 'package:conduit/features/tasks/domain/task_start_defaults.dart';
import 'package:conduit/features/tasks/presentation/task_sources_controller.dart';
import 'package:flutter/widgets.dart';

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
    this.every = const Duration(seconds: 20),
    this.allEvery = 15,
    bool observeLifecycle = false,
  }) {
    if (observeLifecycle) {
      _lifecycle = AppLifecycleListener(
        onStateChange: (state) => setAppActive(
          state == AppLifecycleState.resumed ||
              state == AppLifecycleState.inactive,
        ),
      );
    }
  }

  /// How often machines with waiting or going runs are asked.
  final Duration every;

  /// While a view is on screen, every machine of [hosts] is asked every
  /// [allEvery] ticks (the first tick too).
  final int allEvery;

  AppLifecycleListener? _lifecycle;

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

  /// Asks every machine of [hosts] once and follows them while the
  /// returned function is not called: Tasks or the dashboard is on screen.
  ///
  /// CON-089: polling used to start at the first visit and never stop.
  /// Now it runs while a view is attached, or while a run waits or goes
  /// (to move its task to done), never in the background, and stops once
  /// neither holds.
  VoidCallback attachView() {
    _views += 1;
    _syncPolling();
    unawaited(refreshAll(hosts?.call() ?? const []));
    var attached = true;
    return () {
      if (!attached) return;
      attached = false;
      _views -= 1;
      _syncPolling();
    };
  }

  int _views = 0;
  bool _appActive = true;
  int _tick = 0;

  /// Pauses all polling while the app is in the background.
  void setAppActive(bool active) {
    if (_appActive == active) return;
    _appActive = active;
    _syncPolling();
  }

  /// Whether the timer runs (tests).
  @visibleForTesting
  bool get polling => _poll != null;

  void _syncPolling() {
    final wanted = !_disposed && _appActive && (_views > 0 || anyActive);
    if (!wanted) {
      _poll?.cancel();
      _poll = null;
    } else if (_poll == null) {
      _tick = 0;
      _poll = Timer.periodic(every, (_) => _onTick());
    }
  }

  void _onTick() {
    final all = _views > 0 && _tick++ % allEvery == 0;
    final ids = {
      if (all) ...?hosts?.call(),
      for (final MapEntry(key: hostId, value: runs) in _runs.entries)
        if (runs.any((r) => r.active || r.status == TaskRunStatus.queued))
          hostId,
    };
    for (final id in ids) {
      unawaited(refresh(id));
    }
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
  /// Notifies only when the runs or the error changed.
  Future<void> refresh(String hostId) async {
    final before = (_raw[hostId], _errors[hostId]);
    try {
      final json = await call(hostId, 'task-runs list');
      _raw[hostId] = jsonEncode(json['runs']);
      _runs[hostId] = _parse(json);
      _errors.remove(hostId);
    } on Object catch (e) {
      _errors[hostId] = '$e';
    }
    if (_disposed) return;
    if ((_raw[hostId], _errors[hostId]) != before) notifyListeners();
    // A run that finished may end the polling; a new one may start it.
    _syncPolling();
    await _syncDone(hostId);
  }

  /// Each machine's last `runs` reply as received, to tell a change.
  final Map<String, String> _raw = {};
  bool _disposed = false;

  Future<void> cancel(String hostId, String runId) async {
    await call(hostId, 'task-runs cancel $runId');
    await refresh(hostId);
  }

  Future<void> forget(String hostId, String runId) async {
    await call(hostId, 'task-runs forget $runId');
    await refresh(hostId);
  }

  /// How many runs a machine starts at once.
  Future<void> setCap(String hostId, int cap) async {
    await call(hostId, 'task-runs cap $cap');
    await refresh(hostId);
  }

  @override
  void dispose() {
    _disposed = true;
    _lifecycle?.dispose();
    _poll?.cancel();
    _poll = null;
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
