import 'package:conduit/features/tasks/data/task_http.dart';
import 'package:conduit/features/tasks/domain/task_source.dart';
import 'package:http/http.dart' as http;

/// An Asana project's tasks (REST 1.0, paged by offset). A task's status is
/// its section in the project, or "Completed" once it is complete; moving
/// it adds it to that section or completes it. Comments are its comment
/// stories.
class AsanaTaskSource implements TaskSource {
  AsanaTaskSource(this.config, {required String token, http.Client? client})
    : _http = TaskHttp(
        client ?? http.Client(),
        service: 'Asana',
        headers: {
          'authorization': 'Bearer $token',
          'accept': 'application/json',
        },
      );

  @override
  final TaskSourceConfig config;
  final TaskHttp _http;

  static const _base = 'https://app.asana.com/api/1.0';
  static const _fields =
      'name,completed,assignee.name,tags.name,modified_at,permalink_url,'
      'memberships.section.gid,memberships.section.name,memberships.project.gid';

  /// The status of a completed task.
  static const completed = TaskStatusOption(
    id: 'completed',
    label: 'Completed',
    category: TaskStatusCategory.done,
  );

  @override
  TaskSourceCapabilities get capabilities => config.kind.capabilities;

  String get _project {
    final p = config['project'];
    if (p == null || !RegExp(r'^[0-9]+$').hasMatch(p)) {
      throw const TaskSourceFailure(
        'bad-config',
        'Asana: the project id is the number in its URL '
            '(app.asana.com/0/<project>/…).',
      );
    }
    return p;
  }

  Uri _uri(List<String> path, [Map<String, String>? query]) =>
      joinUri(_base, path, query);

  TaskItem _task(Map<Object?, Object?> json) {
    TaskStatusOption? status;
    if (json['completed'] == true) {
      status = completed;
    } else if (json['memberships'] case final List<Object?> memberships) {
      for (final m in memberships) {
        if (m case {
          'project': {'gid': final String project},
          'section': {'gid': final String gid, 'name': final String name},
        } when project == _project) {
          status = TaskStatusOption(
            id: gid,
            label: name,
            category: TaskStatusCategory.guess(name),
          );
        }
      }
    }
    return TaskItem(
      sourceId: config.id,
      id: str(json['gid']) ?? '',
      key: str(json['gid']) ?? '',
      title: str(json['name']) ?? '',
      status: status,
      assignees: [if (json['assignee'] case {'name': final String name}) name],
      labels: [
        if (json['tags'] case final List<Object?> tags)
          for (final t in tags)
            if (t case {'name': final String name}) name,
      ],
      url: str(json['permalink_url']),
      updatedAt: parseTime(json['modified_at']),
      body: json.containsKey('notes') ? str(json['notes']) ?? '' : null,
    );
  }

  @override
  Future<List<TaskItem>> list() async {
    final tasks = await collectPages((cursor) async {
      final json = await _http.get(
        _uri(
          ['projects', _project, 'tasks'],
          {
            'opt_fields': _fields,
            'limit': '100',
            'offset': ?(cursor as String?),
          },
        ),
      );
      return (
        [
          if (json case {'data': final List<Object?> list})
            for (final t in list)
              if (t is Map) _task(t),
        ],
        switch (json) {
          {'next_page': {'offset': final String offset}} => offset,
          _ => null,
        },
      );
    });
    return tasks..sort(
      (a, b) =>
          (b.updatedAt ?? DateTime(0)).compareTo(a.updatedAt ?? DateTime(0)),
    );
  }

  @override
  Future<TaskItem> read(TaskItem task) async {
    final json = await _http.get(
      _uri(['tasks', task.id], {'opt_fields': '$_fields,notes'}),
    );
    final stories = await _http.get(
      _uri(
        ['tasks', task.id, 'stories'],
        {'opt_fields': 'type,text,created_by.name,created_at'},
      ),
    );
    if (json case {'data': final Map<Object?, Object?> data}) {
      return _task(data).copyWith(
        comments: [
          if (stories case {'data': final List<Object?> list})
            for (final s in list)
              if (s is Map && s['type'] == 'comment')
                TaskComment(
                  author: switch (s['created_by']) {
                    {'name': final String name} => name,
                    _ => '?',
                  },
                  body: str(s['text']) ?? '',
                  at: parseTime(s['created_at']),
                ),
        ],
      );
    }
    throw const TaskSourceFailure('failed', 'Asana: unexpected answer.');
  }

  /// The project's sections, then Completed.
  @override
  Future<List<TaskStatusOption>> statusOptions(TaskItem task) async {
    final json = await _http.get(
      _uri(['projects', _project, 'sections'], {'opt_fields': 'name'}),
    );
    return [
      if (json case {'data': final List<Object?> list})
        for (final s in list)
          if (s case {'gid': final String gid, 'name': final String name})
            TaskStatusOption(
              id: gid,
              label: name,
              category: TaskStatusCategory.guess(name),
            ),
      completed,
    ];
  }

  @override
  Future<TaskItem> updateStatus(TaskItem task, TaskStatusOption status) async {
    if (status.id == completed.id) {
      await _http.send(
        'PUT',
        _uri(['tasks', task.id]),
        body: {
          'data': {'completed': true},
        },
      );
      return task.copyWith(status: completed);
    }
    await _http.send(
      'POST',
      _uri(['sections', status.id, 'addTask']),
      body: {
        'data': {'task': task.id},
      },
    );
    if (task.status?.id == completed.id) {
      await _http.send(
        'PUT',
        _uri(['tasks', task.id]),
        body: {
          'data': {'completed': false},
        },
      );
    }
    return task.copyWith(status: status);
  }

  @override
  Future<void> comment(TaskItem task, String text) async {
    await _http.send(
      'POST',
      _uri(['tasks', task.id, 'stories']),
      body: {
        'data': {'text': text},
      },
    );
  }
}
