import 'package:conduit/features/tasks/data/task_http.dart';
import 'package:conduit/features/tasks/domain/task_source.dart';
import 'package:http/http.dart' as http;

/// GitLab Issues of one project (REST v4, gitlab.com or self-managed).
/// Statuses are opened and closed; comments are the issue's notes, system
/// notes left out.
class GitLabTaskSource implements TaskSource {
  GitLabTaskSource(this.config, {required String token, http.Client? client})
    : _http = TaskHttp(
        client ?? http.Client(),
        service: 'GitLab',
        headers: {'private-token': token, 'accept': 'application/json'},
      );

  @override
  final TaskSourceConfig config;
  final TaskHttp _http;

  static const open = TaskStatusOption(
    id: 'opened',
    label: 'Open',
    category: TaskStatusCategory.todo,
  );
  static const closed = TaskStatusOption(
    id: 'closed',
    label: 'Closed',
    category: TaskStatusCategory.done,
  );

  @override
  TaskSourceCapabilities get capabilities => config.kind.capabilities;

  Uri _uri(List<String> path, [Map<String, String>? query]) {
    final project = config['project'];
    if (project == null) {
      throw const TaskSourceFailure(
        'bad-config',
        'GitLab: the project is group/project.',
      );
    }
    // One path segment: joinUri encodes its slashes as %2F, as the API
    // wants a project path.
    return joinUri(baseUrl(config['baseUrl'], 'https://gitlab.com'), [
      'api',
      'v4',
      'projects',
      project,
      ...path,
    ], query);
  }

  TaskItem _task(Map<Object?, Object?> json) {
    final iid = '${json['iid']}';
    return TaskItem(
      sourceId: config.id,
      id: iid,
      key: '#$iid',
      title: str(json['title']) ?? '',
      status: json['state'] == 'closed' ? closed : open,
      assignees: [
        if (json['assignees'] case final List<Object?> list)
          for (final a in list)
            if (a is Map && a['username'] is String) a['username'] as String,
      ],
      labels: [
        if (json['labels'] case final List<Object?> list)
          for (final l in list)
            if (l is String) l,
      ],
      url: str(json['web_url']),
      updatedAt: parseTime(json['updated_at']),
      body: str(json['description']),
    );
  }

  @override
  Future<List<TaskItem>> list() async {
    final json = await _http.get(
      _uri(['issues'], {'order_by': 'updated_at', 'per_page': '100'}),
    );
    return [
      if (json is List)
        for (final issue in json)
          if (issue is Map) _task(issue),
    ];
  }

  @override
  Future<TaskItem> read(TaskItem task) async {
    final issue = await _http.get(_uri(['issues', task.id]));
    final notes = await _http.get(
      _uri(['issues', task.id, 'notes'], {'sort': 'asc', 'per_page': '100'}),
    );
    if (issue is! Map) {
      throw const TaskSourceFailure('failed', 'GitLab: unexpected answer.');
    }
    return _task(issue).copyWith(
      body: str(issue['description']) ?? '',
      comments: [
        if (notes is List)
          for (final n in notes)
            if (n is Map && n['system'] != true)
              TaskComment(
                author: switch (n['author']) {
                  {'username': final String name} => name,
                  _ => '?',
                },
                body: str(n['body']) ?? '',
                at: parseTime(n['created_at']),
              ),
      ],
    );
  }

  @override
  Future<List<TaskStatusOption>> statusOptions(TaskItem task) async => const [
    open,
    closed,
  ];

  @override
  Future<TaskItem> updateStatus(TaskItem task, TaskStatusOption status) async {
    final json = await _http.send(
      'PUT',
      _uri(['issues', task.id]),
      body: {'state_event': status.id == 'closed' ? 'close' : 'reopen'},
    );
    if (json is! Map) return task.copyWith(status: status);
    return _task(json).copyWith(comments: task.comments);
  }

  @override
  Future<void> comment(TaskItem task, String text) async {
    await _http.send(
      'POST',
      _uri(['issues', task.id, 'notes']),
      body: {'body': text},
    );
  }
}
