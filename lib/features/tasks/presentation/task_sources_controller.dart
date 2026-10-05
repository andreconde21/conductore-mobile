import 'dart:async';
import 'dart:convert';

import 'package:conduit/features/tasks/domain/task_source.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

/// Where sources and their tokens are kept. Both stay on this device:
/// neither is part of device sync, so a token never leaves it.
abstract class TaskSourcesStore {
  Future<String?> readSources();
  Future<void> writeSources(String json);
  Future<String?> readToken(String sourceId);
  Future<void> writeToken(String sourceId, String token);
  Future<void> deleteToken(String sourceId);
}

/// [TaskSourcesStore] in the platform's secure storage, one key for the
/// list and one per token.
class SecureTaskSourcesStore implements TaskSourcesStore {
  const SecureTaskSourcesStore(this._storage);

  final FlutterSecureStorage _storage;

  static const sourcesKey = 'conductore.task_sources.v1';
  static String tokenKey(String sourceId) =>
      'conductore.task_source_token.$sourceId';

  @override
  Future<String?> readSources() => _storage.read(key: sourcesKey);

  @override
  Future<void> writeSources(String json) =>
      _storage.write(key: sourcesKey, value: json);

  @override
  Future<String?> readToken(String sourceId) =>
      _storage.read(key: tokenKey(sourceId));

  @override
  Future<void> writeToken(String sourceId, String token) =>
      _storage.write(key: tokenKey(sourceId), value: token);

  @override
  Future<void> deleteToken(String sourceId) =>
      _storage.delete(key: tokenKey(sourceId));
}

/// Builds the adapter for a source with its token.
typedef TaskSourceBuilder =
    TaskSource Function(TaskSourceConfig config, String? token);

/// One source's tasks as last loaded.
@immutable
class SourceTasks {
  const SourceTasks({
    this.tasks = const [],
    this.error,
    this.loading = false,
    this.loadedAt,
  });

  final List<TaskItem> tasks;
  final String? error;
  final bool loading;
  final DateTime? loadedAt;
}

/// How the combined task list is ordered. Ties always fall back to the
/// newest update, then the source's name, then the key, so the order is
/// the same whichever sources are shown.
enum TaskSort {
  updated('Last updated'),
  status('Status'),
  source('Source'),
  key('Key');

  const TaskSort(this.label);

  final String label;
}

/// The task list's filters; null means any.
@immutable
class TaskFilter {
  const TaskFilter({
    this.sourceIds,
    this.status,
    this.assignee,
    this.project,
    this.query,
  });

  /// The sources shown; null shows every source.
  final Set<String>? sourceIds;

  /// A status label (statuses differ per source, so by label).
  final String? status;
  final String? assignee;

  /// A [TaskItem.project].
  final String? project;
  final String? query;

  /// The value [TaskFilter.assignee] takes for "nobody".
  static const unassigned = '\u0000unassigned';

  bool matches(TaskItem task) {
    if (sourceIds != null && !sourceIds!.contains(task.sourceId)) {
      return false;
    }
    if (status != null && task.status?.label != status) return false;
    if (project != null && task.project != project) return false;
    if (assignee == unassigned) {
      if (task.assignees.isNotEmpty) return false;
    } else if (assignee != null && !task.assignees.contains(assignee)) {
      return false;
    }
    final q = query?.trim().toLowerCase();
    if (q != null && q.isNotEmpty) {
      return task.title.toLowerCase().contains(q) ||
          task.key.toLowerCase().contains(q);
    }
    return true;
  }

  TaskFilter copyWith({
    Set<String>? Function()? sourceIds,
    String? Function()? status,
    String? Function()? assignee,
    String? Function()? project,
    String? Function()? query,
  }) => TaskFilter(
    sourceIds: sourceIds == null ? this.sourceIds : sourceIds(),
    status: status == null ? this.status : status(),
    assignee: assignee == null ? this.assignee : assignee(),
    project: project == null ? this.project : project(),
    query: query == null ? this.query : query(),
  );
}

/// The configured task sources and their tasks (Settings › Tasks).
class TaskSourcesController extends ChangeNotifier {
  TaskSourcesController({required this.store, required this.build});

  /// The app's one instance (Settings and the task list read it).
  static TaskSourcesController? instance;

  final TaskSourcesStore store;
  final TaskSourceBuilder build;

  List<TaskSourceConfig> _sources = const [];
  final Map<String, SourceTasks> _tasks = {};
  final Map<String, TaskSource> _adapters = {};
  Future<void>? _loading;
  bool _loaded = false;

  List<TaskSourceConfig> get sources => _sources;
  bool get loaded => _loaded;

  TaskSourceConfig? sourceById(String id) {
    for (final s in _sources) {
      if (s.id == id) return s;
    }
    return null;
  }

  SourceTasks tasksOf(String sourceId) =>
      _tasks[sourceId] ?? const SourceTasks();

  bool get loadingTasks => _tasks.values.any((t) => t.loading);

  /// Every source's tasks, newest first.
  List<TaskItem> get allTasks =>
      sorted([for (final s in _sources) ...tasksOf(s.id).tasks]);

  /// [tasks] in [sort] order (see [TaskSort]).
  List<TaskItem> sorted(
    List<TaskItem> tasks, [
    TaskSort sort = TaskSort.updated,
  ]) {
    final names = {for (final s in _sources) s.id: s.name.toLowerCase()};
    int newest(TaskItem a, TaskItem b) =>
        (b.updatedAt ?? DateTime(0)).compareTo(a.updatedAt ?? DateTime(0));
    int bySource(TaskItem a, TaskItem b) =>
        (names[a.sourceId] ?? '').compareTo(names[b.sourceId] ?? '');
    int byKey(TaskItem a, TaskItem b) => _naturalCompare(a.key, b.key);
    int byStatus(TaskItem a, TaskItem b) {
      final ca = (a.status?.category ?? TaskStatusCategory.unknown).index;
      final cb = (b.status?.category ?? TaskStatusCategory.unknown).index;
      if (ca != cb) return ca.compareTo(cb);
      return (a.status?.label ?? '').toLowerCase().compareTo(
        (b.status?.label ?? '').toLowerCase(),
      );
    }

    final order = switch (sort) {
      TaskSort.updated => [newest, bySource, byKey],
      TaskSort.status => [byStatus, newest, bySource, byKey],
      TaskSort.source => [bySource, newest, byKey],
      TaskSort.key => [bySource, byKey, newest],
    };
    return [...tasks]..sort((a, b) {
      for (final compare in order) {
        final c = compare(a, b);
        if (c != 0) return c;
      }
      return a.ref.compareTo(b.ref);
    });
  }

  /// `CON-9` before `CON-10`: digit runs compare as numbers.
  static int _naturalCompare(String a, String b) {
    final re = RegExp(r'(\d+)|(\D+)');
    final pa = re.allMatches(a.toLowerCase()).map((m) => m[0]!).toList();
    final pb = re.allMatches(b.toLowerCase()).map((m) => m[0]!).toList();
    for (var i = 0; i < pa.length && i < pb.length; i++) {
      final na = int.tryParse(pa[i]);
      final nb = int.tryParse(pb[i]);
      final c = na != null && nb != null
          ? na.compareTo(nb)
          : pa[i].compareTo(pb[i]);
      if (c != 0) return c;
    }
    return pa.length.compareTo(pb.length);
  }

  Future<void> ensureLoaded() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final raw = await store.readSources();
      final decoded = raw == null ? null : jsonDecode(raw);
      if (decoded is List) {
        _sources = [for (final s in decoded) ?TaskSourceConfig.fromJson(s)];
      }
    } catch (_) {
      // Unreadable: no sources.
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> _persist() =>
      store.writeSources(jsonEncode([for (final s in _sources) s.toJson()]));

  /// A new source's id.
  static String newId() => const Uuid().v4();

  /// Whether [sourceId] has a token saved.
  Future<bool> hasToken(String sourceId) async =>
      ((await store.readToken(sourceId)) ?? '').isNotEmpty;

  /// Adds or replaces [config]; [token] null keeps the saved one.
  Future<void> save(TaskSourceConfig config, {String? token}) async {
    await ensureLoaded();
    final i = _sources.indexWhere((s) => s.id == config.id);
    _sources = [..._sources];
    if (i == -1) {
      _sources.add(config);
    } else {
      _sources[i] = config;
    }
    if (token != null && token.isNotEmpty) {
      await store.writeToken(config.id, token);
    }
    _adapters.remove(config.id);
    await _persist();
    notifyListeners();
  }

  Future<void> remove(String sourceId) async {
    await ensureLoaded();
    _sources = [
      for (final s in _sources)
        if (s.id != sourceId) s,
    ];
    _tasks.remove(sourceId);
    _adapters.remove(sourceId);
    await store.deleteToken(sourceId);
    await _persist();
    notifyListeners();
  }

  /// Lists [config]'s tasks without saving anything: [token] null uses
  /// the saved one. The number of tasks, or throws [TaskSourceFailure].
  Future<int> test(TaskSourceConfig config, {String? token}) async {
    final missing = config.missingField();
    if (missing != null) {
      throw TaskSourceFailure('bad-config', '$missing is missing.');
    }
    final t = token == null || token.isEmpty
        ? await store.readToken(config.id)
        : token;
    return (await build(config, t).list()).length;
  }

  Future<TaskSource> _adapter(String sourceId) async {
    final cached = _adapters[sourceId];
    if (cached != null) return cached;
    final config = sourceById(sourceId);
    if (config == null) {
      throw const TaskSourceFailure('not-found', 'That source was removed.');
    }
    final adapter = build(config, await store.readToken(sourceId));
    return _adapters[sourceId] = adapter;
  }

  /// The adapter's capabilities for [sourceId].
  TaskSourceCapabilities capabilitiesOf(String sourceId) =>
      _adapters[sourceId]?.capabilities ??
      sourceById(sourceId)?.kind.capabilities ??
      const TaskSourceCapabilities();

  /// Loads every source's tasks (or [sourceId]'s), side by side.
  Future<void> refresh({String? sourceId}) async {
    await ensureLoaded();
    final targets = [
      for (final s in _sources)
        if (sourceId == null || s.id == sourceId) s,
    ];
    for (final s in targets) {
      _tasks[s.id] = SourceTasks(
        tasks: tasksOf(s.id).tasks,
        loading: true,
        loadedAt: tasksOf(s.id).loadedAt,
      );
    }
    notifyListeners();
    await Future.wait([for (final s in targets) _refreshOne(s)]);
  }

  Future<void> _refreshOne(TaskSourceConfig config) async {
    SourceTasks next;
    try {
      final tasks = await (await _adapter(config.id)).list();
      next = SourceTasks(tasks: tasks, loadedAt: DateTime.now());
    } on TaskSourceFailure catch (e) {
      next = SourceTasks(tasks: tasksOf(config.id).tasks, error: e.message);
    } catch (e) {
      next = SourceTasks(tasks: tasksOf(config.id).tasks, error: '$e');
    }
    if (sourceById(config.id) == null) return;
    _tasks[config.id] = next;
    notifyListeners();
  }

  /// [task] with its body and comments.
  Future<TaskItem> read(TaskItem task) async {
    final full = await (await _adapter(task.sourceId)).read(task);
    _replace(full);
    return full;
  }

  Future<List<TaskStatusOption>> statusOptions(TaskItem task) async =>
      (await _adapter(task.sourceId)).statusOptions(task);

  Future<TaskItem> updateStatus(TaskItem task, TaskStatusOption status) async {
    final next = await (await _adapter(
      task.sourceId,
    )).updateStatus(task, status);
    _replace(next);
    return next;
  }

  Future<void> comment(TaskItem task, String text) async =>
      (await _adapter(task.sourceId)).comment(task, text);

  /// Finds a loaded task by its [TaskItem.ref].
  TaskItem? taskByRef(String ref) {
    for (final t in allTasks) {
      if (t.ref == ref) return t;
    }
    return null;
  }

  void _replace(TaskItem task) {
    final current = _tasks[task.sourceId];
    if (current == null) return;
    _tasks[task.sourceId] = SourceTasks(
      tasks: [for (final t in current.tasks) t.id == task.id ? task : t],
      error: current.error,
      loading: current.loading,
      loadedAt: current.loadedAt,
    );
    notifyListeners();
  }
}
