import 'package:conduit/features/tasks/data/task_http.dart';
import 'package:conduit/features/tasks/domain/task_source.dart';
import 'package:http/http.dart' as http;

/// Linear issues (GraphQL) of one team, or of every team the key sees.
/// Statuses are the issue's team workflow states.
class LinearTaskSource implements TaskSource {
  LinearTaskSource(this.config, {required String token, http.Client? client})
    : _http = TaskHttp(
        client ?? http.Client(),
        service: 'Linear',
        // Personal API keys go bare; OAuth tokens carry "Bearer".
        headers: {'authorization': token, 'accept': 'application/json'},
      );

  @override
  final TaskSourceConfig config;
  final TaskHttp _http;

  static final endpoint = Uri.parse('https://api.linear.app/graphql');

  static const _issueFields =
      'id identifier title url updatedAt '
      'state { id name type } assignee { displayName } '
      'labels { nodes { name } }';

  @override
  TaskSourceCapabilities get capabilities => config.kind.capabilities;

  Future<Map<Object?, Object?>> _query(
    String query, [
    Map<String, Object?> variables = const {},
  ]) async {
    final json = await _http.send(
      'POST',
      endpoint,
      body: {'query': query, 'variables': variables},
    );
    if (json case {
      'errors': final List<Object?> errors,
    } when errors.isNotEmpty) {
      final first = errors.first;
      throw TaskSourceFailure(
        'failed',
        'Linear: ${first is Map ? first['message'] : first}',
      );
    }
    if (json case {'data': final Map<Object?, Object?> data}) return data;
    throw const TaskSourceFailure('failed', 'Linear: unexpected answer.');
  }

  static TaskStatusOption? _state(Object? state) => switch (state) {
    {'id': final String id, 'name': final String name} => TaskStatusOption(
      id: id,
      label: name,
      category: switch (state['type']) {
        'triage' || 'backlog' || 'unstarted' => TaskStatusCategory.todo,
        'started' => TaskStatusCategory.inProgress,
        'completed' || 'canceled' => TaskStatusCategory.done,
        _ => TaskStatusCategory.unknown,
      },
    ),
    _ => null,
  };

  TaskItem _task(Map<Object?, Object?> json) => TaskItem(
    sourceId: config.id,
    id: str(json['id']) ?? '',
    key: str(json['identifier']) ?? '',
    title: str(json['title']) ?? '',
    status: _state(json['state']),
    assignees: [
      if (json['assignee'] case {'displayName': final String name}) name,
    ],
    labels: [
      if (json['labels'] case {'nodes': final List<Object?> nodes})
        for (final l in nodes)
          if (l case {'name': final String name}) name,
    ],
    url: str(json['url']),
    updatedAt: parseTime(json['updatedAt']),
    body: json.containsKey('description')
        ? str(json['description']) ?? ''
        : null,
  );

  @override
  Future<List<TaskItem>> list() => collectPages((cursor) async {
    final team = config['team'];
    final data = await _query(
      'query Issues(\$filter: IssueFilter, \$after: String) { issues('
      'first: 100, after: \$after, filter: \$filter, orderBy: updatedAt) '
      '{ nodes { $_issueFields } pageInfo { hasNextPage endCursor } } }',
      {
        if (team != null)
          'filter': {
            'team': {
              'key': {'eq': team},
            },
          },
        'after': ?cursor,
      },
    );
    return (
      [
        if (data case {'issues': {'nodes': final List<Object?> nodes}})
          for (final issue in nodes)
            if (issue is Map) _task(issue),
      ],
      switch (data) {
        {
          'issues': {
            'pageInfo': {'hasNextPage': true, 'endCursor': final String end},
          },
        } =>
          end,
        _ => null,
      },
    );
  });

  @override
  Future<TaskItem> read(TaskItem task) async {
    final data = await _query(
      'query Issue(\$id: String!) { issue(id: \$id) { $_issueFields '
      'description comments { nodes { body createdAt '
      'user { displayName } } } } }',
      {'id': task.id},
    );
    final issue = data['issue'];
    if (issue is! Map) {
      throw const TaskSourceFailure('not-found', 'Linear: no such issue.');
    }
    final comments = [
      if (issue['comments'] case {'nodes': final List<Object?> nodes})
        for (final c in nodes)
          if (c is Map)
            TaskComment(
              author: switch (c['user']) {
                {'displayName': final String name} => name,
                _ => '?',
              },
              body: str(c['body']) ?? '',
              at: parseTime(c['createdAt']),
            ),
    ]..sort((a, b) => (a.at ?? DateTime(0)).compareTo(b.at ?? DateTime(0)));
    return _task(issue).copyWith(comments: comments);
  }

  @override
  Future<List<TaskStatusOption>> statusOptions(TaskItem task) async {
    final data = await _query(
      'query States(\$id: String!) { issue(id: \$id) { team { states { '
      'nodes { id name type position } } } } }',
      {'id': task.id},
    );
    final nodes = switch (data) {
      {'issue': {'team': {'states': {'nodes': final List<Object?> nodes}}}} =>
        nodes.whereType<Map<Object?, Object?>>().toList(),
      _ => <Map<Object?, Object?>>[],
    };
    nodes.sort(
      (a, b) => ((a['position'] as num?) ?? 0).compareTo(
        (b['position'] as num?) ?? 0,
      ),
    );
    return [for (final n in nodes) ?_state(n)];
  }

  @override
  Future<TaskItem> updateStatus(TaskItem task, TaskStatusOption status) async {
    final data = await _query(
      'mutation Move(\$id: String!, \$stateId: String!) { '
      'issueUpdate(id: \$id, input: { stateId: \$stateId }) { success } }',
      {'id': task.id, 'stateId': status.id},
    );
    if (data case {'issueUpdate': {'success': true}}) {
      return task.copyWith(status: status);
    }
    throw const TaskSourceFailure('failed', 'Linear did not move the issue.');
  }

  @override
  Future<void> comment(TaskItem task, String text) async {
    final data = await _query(
      'mutation Comment(\$id: String!, \$body: String!) { '
      'commentCreate(input: { issueId: \$id, body: \$body }) { success } }',
      {'id': task.id, 'body': text},
    );
    if (data case {'commentCreate': {'success': true}}) return;
    throw const TaskSourceFailure('failed', 'Linear did not add the comment.');
  }
}
