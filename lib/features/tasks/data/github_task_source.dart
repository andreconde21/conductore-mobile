import 'package:conduit/features/tasks/data/task_http.dart';
import 'package:conduit/features/tasks/domain/task_source.dart';
import 'package:http/http.dart' as http;

/// GitHub Issues of one repository (REST v3). Statuses are open and
/// closed (closed as completed); pull requests are left out.
class GitHubTaskSource implements TaskSource {
  GitHubTaskSource(this.config, {required String token, http.Client? client})
    : _http = TaskHttp(
        client ?? http.Client(),
        service: 'GitHub',
        headers: {
          'authorization': 'Bearer $token',
          'accept': 'application/vnd.github+json',
          'x-github-api-version': '2022-11-28',
        },
      );

  @override
  final TaskSourceConfig config;
  final TaskHttp _http;

  static const open = TaskStatusOption(
    id: 'open',
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

  String get _base => baseUrl(config['apiBase'], 'https://api.github.com');

  List<String> get _repo {
    final parts = (config['repo'] ?? '').split('/');
    if (parts.length != 2 || parts.any((p) => p.isEmpty)) {
      throw const TaskSourceFailure(
        'bad-config',
        'GitHub: the repository is owner/name.',
      );
    }
    return parts;
  }

  Uri _uri(List<String> path, [Map<String, String>? query]) =>
      joinUri(_base, ['repos', ..._repo, ...path], query);

  TaskItem _task(Map<Object?, Object?> json) {
    final number = '${json['number']}';
    return TaskItem(
      sourceId: config.id,
      id: number,
      key: '#$number',
      title: str(json['title']) ?? '',
      status: json['state'] == 'closed' ? closed : open,
      assignees: [
        if (json['assignees'] case final List<Object?> list)
          for (final a in list)
            if (a is Map && a['login'] is String) a['login'] as String,
      ],
      labels: [
        if (json['labels'] case final List<Object?> list)
          for (final l in list)
            if (l is Map && l['name'] is String) l['name'] as String,
      ],
      url: str(json['html_url']),
      updatedAt: parseTime(json['updated_at']),
      body: str(json['body']),
    );
  }

  @override
  Future<List<TaskItem>> list() async {
    final json = await _http.get(
      _uri(['issues'], {'state': 'all', 'sort': 'updated', 'per_page': '100'}),
    );
    return [
      if (json is List)
        for (final issue in json)
          if (issue is Map && issue['pull_request'] == null) _task(issue),
    ];
  }

  @override
  Future<TaskItem> read(TaskItem task) async {
    final issue = await _http.get(_uri(['issues', task.id]));
    final comments = await _http.get(
      _uri(['issues', task.id, 'comments'], {'per_page': '100'}),
    );
    if (issue is! Map) {
      throw const TaskSourceFailure('failed', 'GitHub: unexpected answer.');
    }
    return _task(issue).copyWith(
      body: str(issue['body']) ?? '',
      comments: [
        if (comments is List)
          for (final c in comments)
            if (c is Map)
              TaskComment(
                author: switch (c['user']) {
                  {'login': final String login} => login,
                  _ => '?',
                },
                body: str(c['body']) ?? '',
                at: parseTime(c['created_at']),
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
      'PATCH',
      _uri(['issues', task.id]),
      body: {
        'state': status.id,
        if (status.id == 'closed') 'state_reason': 'completed',
      },
    );
    if (json is! Map) return task.copyWith(status: status);
    return _task(json).copyWith(comments: task.comments);
  }

  @override
  Future<void> comment(TaskItem task, String text) async {
    await _http.send(
      'POST',
      _uri(['issues', task.id, 'comments']),
      body: {'body': text},
    );
  }
}
