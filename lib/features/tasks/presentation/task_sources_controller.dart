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

/// The task list's filters; null means any.
@immutable
class TaskFilter {
  const TaskFilter({this.sourceId, this.status, this.assignee, this.query});

  final String? sourceId;

  /// A status label (statuses differ per source, so by label).
  final String? status;
  final String? assignee;
  final String? query;

  /// The value [TaskFilter.assignee] takes for "nobody".
  static const unassigned = '\u0000unassigned';

  bool matches(TaskItem task) {
    if (sourceId != null && task.sourceId != sourceId) return false;
    if (status != null && task.status?.label != status) return false;
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
    String? Function()? sourceId,
    String? Function()? status,
    String? Function()? assignee,
    String? Function()? query,
  }) => TaskFilter(
    sourceId: sourceId == null ? this.sourceId : sourceId(),
    status: status == null ? this.status : status(),
    assignee: assignee == null ? this.assignee : assignee(),
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
  List<TaskItem> get allTasks {
    final all = [for (final s in _sources) ...tasksOf(s.id).tasks];
    all.sort(
      (a, b) =>
          (b.updatedAt ?? DateTime(0)).compareTo(a.updatedAt ?? DateTime(0)),
    );
    return all;
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
