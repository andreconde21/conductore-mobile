import 'package:conduit/features/tasks/data/task_http.dart';
import 'package:conduit/features/tasks/domain/task_source.dart';
import 'package:http/http.dart' as http;

/// A ClickUp list's tasks (API v2), closed ones included, paged 100 at a
/// time. Statuses are the list's own; a personal token goes bare in the
/// Authorization header.
class ClickUpTaskSource implements TaskSource {
  ClickUpTaskSource(this.config, {required String token, http.Client? client})
    : _http = TaskHttp(
        client ?? http.Client(),
        service: 'ClickUp',
        headers: {'authorization': token, 'accept': 'application/json'},
      );

  @override
  final TaskSourceConfig config;
  final TaskHttp _http;

  static const _base = 'https://api.clickup.com/api/v2';

  @override
  TaskSourceCapabilities get capabilities => config.kind.capabilities;

  String get _list {
    final list = config['list'];
    if (list == null || !RegExp(r'^[0-9A-Za-z_-]+$').hasMatch(list)) {
      throw const TaskSourceFailure(
        'bad-config',
        'ClickUp: the list id is the number in the list URL (…/li/<id>).',
      );
    }
    return list;
  }

  Uri _uri(List<String> path, [Map<String, String>? query]) =>
      joinUri(_base, path, query);

  static TaskStatusOption? _status(Object? status) => switch (status) {
    {'status': final String name} => TaskStatusOption(
      id: name,
      label: name,
      category: switch (status['type']) {
        'open' => TaskStatusCategory.todo,
        'closed' || 'done' => TaskStatusCategory.done,
        _ => TaskStatusCategory.inProgress,
      },
    ),
    _ => null,
  };

  static DateTime? _ms(Object? v) {
    final n = v is String ? int.tryParse(v) : (v is num ? v.toInt() : null);
    return n == null ? null : DateTime.fromMillisecondsSinceEpoch(n);
  }

  TaskItem _task(Map<Object?, Object?> json) => TaskItem(
    sourceId: config.id,
    id: str(json['id']) ?? '',
    key: str(json['custom_id']) ?? '#${json['id']}',
    title: str(json['name']) ?? '',
    status: _status(json['status']),
    assignees: [
      if (json['assignees'] case final List<Object?> list)
        for (final a in list)
          if (a is Map) str(a['username']) ?? str(a['email']) ?? '?',
    ],
    labels: [
      if (json['tags'] case final List<Object?> tags)
        for (final t in tags)
          if (t case {'name': final String name}) name,
    ],
    url: str(json['url']),
    updatedAt: _ms(json['date_updated']),
    body: json.containsKey('description')
        ? str(json['text_content']) ?? str(json['description']) ?? ''
        : null,
  );

  @override
  Future<List<TaskItem>> list() => collectPages((cursor) async {
    final page = (cursor as int?) ?? 0;
    final json = await _http.get(
      _uri(
        ['list', _list, 'task'],
        {
          'page': '$page',
          'include_closed': 'true',
          'subtasks': 'true',
          'order_by': 'updated',
        },
      ),
    );
    final tasks = [
      if (json case {'tasks': final List<Object?> list})
        for (final t in list)
          if (t is Map) _task(t),
    ];
    final last = json is Map && json['last_page'] == true;
    return (tasks, last || tasks.isEmpty ? null : page + 1);
  });

  @override
  Future<TaskItem> read(TaskItem task) async {
    final json = await _http.get(_uri(['task', task.id]));
    final comments = await _http.get(_uri(['task', task.id, 'comment']));
    if (json is! Map) {
      throw const TaskSourceFailure('failed', 'ClickUp: unexpected answer.');
    }
    final full = _task(json);
    return full.copyWith(
      body: full.body ?? '',
      comments: [
        if (comments case {'comments': final List<Object?> list})
          for (final c in list.reversed)
            if (c is Map)
              TaskComment(
                author: switch (c['user']) {
                  {'username': final String name} => name,
                  _ => '?',
                },
                body: str(c['comment_text']) ?? '',
                at: _ms(c['date']),
              ),
      ],
    );
  }

  @override
  Future<List<TaskStatusOption>> statusOptions(TaskItem task) async {
    final json = await _http.get(_uri(['list', _list]));
    return [
      if (json case {'statuses': final List<Object?> list})
        for (final s in list) ?_status(s),
    ];
  }

  @override
  Future<TaskItem> updateStatus(TaskItem task, TaskStatusOption status) async {
    final json = await _http.send(
      'PUT',
      _uri(['task', task.id]),
      body: {'status': status.id},
    );
    if (json is Map) {
      return _task(json).copyWith(body: task.body, comments: task.comments);
    }
    return task.copyWith(status: status);
  }

  @override
  Future<void> comment(TaskItem task, String text) async {
    await _http.send(
      'POST',
      _uri(['task', task.id, 'comment']),
      body: {'comment_text': text, 'notify_all': false},
    );
  }
}
