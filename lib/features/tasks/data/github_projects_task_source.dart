import 'package:conduit/features/tasks/data/task_http.dart';
import 'package:conduit/features/tasks/domain/task_source.dart';
import 'package:http/http.dart' as http;

/// A GitHub Projects (v2) board over GraphQL: its items (issues, pull
/// requests, drafts) with their single-select status field ("Status" by
/// default). Moving an item sets that field; comments go to the item's
/// issue or pull request (drafts take none).
class GitHubProjectsTaskSource implements TaskSource {
  GitHubProjectsTaskSource(
    this.config, {
    required String token,
    http.Client? client,
  }) : _http = TaskHttp(
         client ?? http.Client(),
         service: 'GitHub Projects',
         headers: {
           'authorization': 'Bearer $token',
           'accept': 'application/vnd.github+json',
         },
       );

  @override
  final TaskSourceConfig config;
  final TaskHttp _http;

  /// The project's node id, status field id and options, once loaded.
  ({String id, String? fieldId, List<TaskStatusOption> options})? _project;

  @override
  TaskSourceCapabilities get capabilities => config.kind.capabilities;

  String get _field => config['statusField'] ?? 'Status';

  /// api.github.com/graphql, or GHES's /api/graphql.
  Uri get _endpoint {
    final base = config['apiBase'];
    if (base == null) return Uri.parse('https://api.github.com/graphql');
    final b = baseUrl(base, '');
    return Uri.parse(
      b.endsWith('/api/v3')
          ? '${b.substring(0, b.length - 2)}graphql'
          : '$b/graphql',
    );
  }

  int get _number {
    final n = int.tryParse(config['number'] ?? '');
    if (n == null || n <= 0) {
      throw const TaskSourceFailure(
        'bad-config',
        'GitHub Projects: the project number is a whole number.',
      );
    }
    return n;
  }

  Future<Map<Object?, Object?>> _query(
    String query,
    Map<String, Object?> variables,
  ) async {
    final json = await _http.send(
      'POST',
      _endpoint,
      body: {'query': query, 'variables': variables},
    );
    if (json case {
      'errors': final List<Object?> errors,
    } when errors.isNotEmpty) {
      final first = errors.first;
      throw TaskSourceFailure(
        'failed',
        'GitHub Projects: ${first is Map ? first['message'] : first}',
      );
    }
    if (json case {'data': final Map<Object?, Object?> data}) return data;
    throw const TaskSourceFailure(
      'failed',
      'GitHub Projects: unexpected answer.',
    );
  }

  static const _content =
      '__typename '
      '... on Issue { id number title url repository { name } '
      'assignees(first: 10) { nodes { login } } '
      'labels(first: 20) { nodes { name } } } '
      '... on PullRequest { id number title url repository { name } '
      'assignees(first: 10) { nodes { login } } '
      'labels(first: 20) { nodes { name } } } '
      '... on DraftIssue { id title assignees(first: 10) { nodes { login } } }';

  static const _itemFields =
      'id updatedAt '
      'fieldValueByName(name: \$field) { '
      '... on ProjectV2ItemFieldSingleSelectValue { name optionId } }';

  static List<String> _names(Object? connection, String key) => [
    if (connection case {'nodes': final List<Object?> nodes})
      for (final n in nodes)
        if (n is Map && n[key] is String) n[key]! as String,
  ];

  TaskItem _task(Map<Object?, Object?> item) {
    final content = item['content'] is Map
        ? item['content']! as Map
        : const <Object?, Object?>{};
    final value = item['fieldValueByName'];
    final number = content['number'];
    final repo = switch (content['repository']) {
      {'name': final String name} => name,
      _ => null,
    };
    return TaskItem(
      sourceId: config.id,
      id: str(item['id']) ?? '',
      key: number == null ? 'Draft' : '${repo ?? ''}#$number',
      title: str(content['title']) ?? '',
      status: switch (value) {
        {'name': final String name} => TaskStatusOption(
          id: str(value['optionId']) ?? name,
          label: name,
          category: TaskStatusCategory.guess(name),
        ),
        _ => null,
      },
      assignees: _names(content['assignees'], 'login'),
      labels: _names(content['labels'], 'name'),
      url: str(content['url']),
      updatedAt: parseTime(item['updatedAt']),
      extra: {
        'contentId': ?str(content['id']),
        'type': ?str(content['__typename']),
      },
    );
  }

  void _remember(Map<Object?, Object?> project) {
    final field = project['field'];
    _project = (
      id: str(project['id']) ?? '',
      fieldId: field is Map ? str(field['id']) : null,
      options: [
        if (field case {'options': final List<Object?> options})
          for (final o in options)
            if (o case {'id': final String id, 'name': final String name})
              TaskStatusOption(
                id: id,
                label: name,
                category: TaskStatusCategory.guess(name),
              ),
      ],
    );
  }

  Map<Object?, Object?> _projectOf(Map<Object?, Object?> data) {
    if (data case {
      'repositoryOwner': {'projectV2': final Map<Object?, Object?> project},
    }) {
      return project;
    }
    throw const TaskSourceFailure(
      'not-found',
      'GitHub Projects: no such project for that owner.',
    );
  }

  @override
  Future<List<TaskItem>> list() async {
    final owner = config['owner'];
    if (owner == null) {
      throw const TaskSourceFailure(
        'bad-config',
        'GitHub Projects: the owner is missing.',
      );
    }
    final tasks = await collectPages((cursor) async {
      final data = await _query(
        'query Items(\$owner: String!, \$number: Int!, \$field: String!, '
        '\$after: String) { repositoryOwner(login: \$owner) { '
        '... on ProjectV2Owner { projectV2(number: \$number) { id '
        'field(name: \$field) { ... on ProjectV2SingleSelectField { id '
        'options { id name } } } '
        'items(first: 100, after: \$after) { pageInfo { hasNextPage '
        'endCursor } nodes { $_itemFields content { $_content } } } } } } }',
        {'owner': owner, 'number': _number, 'field': _field, 'after': ?cursor},
      );
      final project = _projectOf(data);
      _remember(project);
      final items = project['items'];
      return (
        [
          if (items case {'nodes': final List<Object?> nodes})
            for (final n in nodes)
              if (n is Map) _task(n),
        ],
        switch (items) {
          {'pageInfo': {'hasNextPage': true, 'endCursor': final String end}} =>
            end,
          _ => null,
        },
      );
    });
    // Newest first, like the other sources.
    return tasks..sort(
      (a, b) =>
          (b.updatedAt ?? DateTime(0)).compareTo(a.updatedAt ?? DateTime(0)),
    );
  }

  @override
  Future<TaskItem> read(TaskItem task) async {
    final data = await _query(
      'query Item(\$id: ID!, \$field: String!) { node(id: \$id) { '
      '... on ProjectV2Item { $_itemFields content { $_content '
      '... on Issue { body comments(last: 50) { nodes { author { login } '
      'body createdAt } } } '
      '... on PullRequest { body comments(last: 50) { nodes { '
      'author { login } body createdAt } } } '
      '... on DraftIssue { body } } } } }',
      {'id': task.id, 'field': _field},
    );
    final node = data['node'];
    if (node is! Map) {
      throw const TaskSourceFailure(
        'not-found',
        'GitHub Projects: no such item.',
      );
    }
    final content = node['content'];
    return _task(node).copyWith(
      body: content is Map ? str(content['body']) ?? '' : '',
      comments: [
        if (content case {'comments': {'nodes': final List<Object?> nodes}})
          for (final c in nodes)
            if (c is Map)
              TaskComment(
                author: switch (c['author']) {
                  {'login': final String login} => login,
                  _ => '?',
                },
                body: str(c['body']) ?? '',
                at: parseTime(c['createdAt']),
              ),
      ],
    );
  }

  @override
  Future<List<TaskStatusOption>> statusOptions(TaskItem task) async {
    if (_project == null) await list();
    return _project?.options ?? const [];
  }

  @override
  Future<TaskItem> updateStatus(TaskItem task, TaskStatusOption status) async {
    if (_project == null) await list();
    final project = _project;
    if (project == null || project.fieldId == null) {
      throw TaskSourceFailure(
        'unsupported',
        'GitHub Projects: the project has no single-select "$_field" field.',
      );
    }
    await _query(
      'mutation Move(\$project: ID!, \$item: ID!, \$field: ID!, '
      '\$option: String!) { updateProjectV2ItemFieldValue(input: { '
      'projectId: \$project, itemId: \$item, fieldId: \$field, '
      'value: { singleSelectOptionId: \$option } }) { projectV2Item { id } } }',
      {
        'project': project.id,
        'item': task.id,
        'field': project.fieldId,
        'option': status.id,
      },
    );
    return task.copyWith(status: status);
  }

  @override
  Future<void> comment(TaskItem task, String text) async {
    final subject = task.extra['contentId'];
    if (subject == null || task.extra['type'] == 'DraftIssue') {
      throw const TaskSourceFailure(
        'unsupported',
        'Draft items take no comments; convert it to an issue first.',
      );
    }
    await _query(
      'mutation Comment(\$subject: ID!, \$body: String!) { '
      'addComment(input: { subjectId: \$subject, body: \$body }) { '
      'clientMutationId } }',
      {'subject': subject, 'body': text},
    );
  }
}
