import 'dart:convert';

import 'package:conduit/features/tasks/data/task_http.dart';
import 'package:conduit/features/tasks/domain/task_source.dart';
import 'package:http/http.dart' as http;

/// Azure Boards work items of one Azure DevOps project (REST 7.1): a WIQL
/// query for the newest 100, statuses from each work item type's states,
/// comments through the work item comments API. Basic auth with a PAT.
class AzureBoardsTaskSource implements TaskSource {
  AzureBoardsTaskSource(
    this.config, {
    required String token,
    http.Client? client,
  }) : _http = TaskHttp(
         client ?? http.Client(),
         service: 'Azure Boards',
         headers: {
           'authorization': 'Basic ${base64Encode(utf8.encode(':$token'))}',
           'accept': 'application/json',
         },
       );

  @override
  final TaskSourceConfig config;
  final TaskHttp _http;

  static const _api = '7.1';
  static const _commentsApi = '7.1-preview.4';
  static const _fields = [
    'System.Id',
    'System.Title',
    'System.State',
    'System.AssignedTo',
    'System.Tags',
    'System.ChangedDate',
    'System.WorkItemType',
  ];

  @override
  TaskSourceCapabilities get capabilities => config.kind.capabilities;

  List<String> get _project {
    final org = config['organization'];
    final project = config['project'];
    if (org == null || project == null) {
      throw const TaskSourceFailure(
        'bad-config',
        'Azure Boards: the organization and project are needed.',
      );
    }
    return [org, project];
  }

  String get _base => baseUrl(config['baseUrl'], 'https://dev.azure.com');

  Uri _uri(List<String> path, Map<String, String> query) =>
      joinUri(_base, [..._project, '_apis', 'wit', ...path], query);

  TaskItem _task(Map<Object?, Object?> json) {
    final id = '${json['id']}';
    final fields = json['fields'] is Map
        ? json['fields']! as Map
        : const <Object?, Object?>{};
    final state = str(fields['System.State']);
    final type = str(fields['System.WorkItemType']);
    return TaskItem(
      sourceId: config.id,
      id: id,
      key: '${type ?? 'Item'} $id',
      title: str(fields['System.Title']) ?? '',
      status: state == null ? null : TaskStatusOption.named(state),
      assignees: [
        if (fields['System.AssignedTo'] case {'displayName': final String name})
          name,
      ],
      labels: [
        for (final tag in (str(fields['System.Tags']) ?? '').split(';'))
          if (tag.trim().isNotEmpty) tag.trim(),
      ],
      url: joinUri(_base, [..._project, '_workitems', 'edit', id]).toString(),
      updatedAt: parseTime(fields['System.ChangedDate']),
      body: fields.containsKey('System.Description')
          ? htmlToText(str(fields['System.Description']) ?? '')
          : null,
      extra: {'type': ?type},
    );
  }

  @override
  Future<List<TaskItem>> list() async {
    final wiql = await _http.send(
      'POST',
      _uri(['wiql'], {'api-version': _api, r'$top': '100'}),
      body: {
        'query':
            'SELECT [System.Id] FROM WorkItems '
            'WHERE [System.TeamProject] = @project '
            "AND [System.State] <> 'Removed' "
            'ORDER BY [System.ChangedDate] DESC',
      },
    );
    final ids = [
      if (wiql case {'workItems': final List<Object?> items})
        for (final item in items.take(100))
          if (item case {'id': final num id}) id.toInt(),
    ];
    if (ids.isEmpty) return const [];
    final json = await _http.get(
      _uri(
        ['workitems'],
        {
          'ids': ids.join(','),
          'fields': _fields.join(','),
          'api-version': _api,
        },
      ),
    );
    final byId = {
      if (json case {'value': final List<Object?> items})
        for (final item in items)
          if (item is Map) '${item['id']}': _task(item),
    };
    return [for (final id in ids) ?byId['$id']];
  }

  @override
  Future<TaskItem> read(TaskItem task) async {
    final json = await _http.get(
      _uri(
        ['workitems', task.id],
        {
          'fields': [..._fields, 'System.Description'].join(','),
          'api-version': _api,
        },
      ),
    );
    final comments = await _http.get(
      _uri(['workItems', task.id, 'comments'], {'api-version': _commentsApi}),
    );
    if (json is! Map) {
      throw const TaskSourceFailure(
        'failed',
        'Azure Boards: unexpected answer.',
      );
    }
    final item = _task(json);
    return item.copyWith(
      body: item.body ?? '',
      comments: [
        if (comments case {'comments': final List<Object?> list})
          for (final c in list.reversed)
            if (c is Map)
              TaskComment(
                author: switch (c['createdBy']) {
                  {'displayName': final String name} => name,
                  _ => '?',
                },
                body: htmlToText(str(c['text']) ?? ''),
                at: parseTime(c['createdDate']),
              ),
      ],
    );
  }

  @override
  Future<List<TaskStatusOption>> statusOptions(TaskItem task) async {
    final type = task.extra['type'];
    if (type == null) return const [];
    final json = await _http.get(
      _uri(['workitemtypes', type, 'states'], {'api-version': _api}),
    );
    return [
      if (json case {'value': final List<Object?> states})
        for (final s in states)
          if (s case {
            'name': final String name,
          } when s['category'] != 'Removed')
            TaskStatusOption(
              id: name,
              label: name,
              category: switch (s['category']) {
                'Proposed' => TaskStatusCategory.todo,
                'InProgress' => TaskStatusCategory.inProgress,
                'Resolved' || 'Completed' => TaskStatusCategory.done,
                _ => TaskStatusCategory.unknown,
              },
            ),
    ];
  }

  @override
  Future<TaskItem> updateStatus(TaskItem task, TaskStatusOption status) async {
    await _http.send(
      'PATCH',
      _uri(['workitems', task.id], {'api-version': _api}),
      contentType: 'application/json-patch+json',
      body: [
        {'op': 'add', 'path': '/fields/System.State', 'value': status.id},
      ],
    );
    return task.copyWith(status: status);
  }

  @override
  Future<void> comment(TaskItem task, String text) async {
    await _http.send(
      'POST',
      _uri(['workItems', task.id, 'comments'], {'api-version': _commentsApi}),
      body: {'text': const HtmlEscape().convert(text).replaceAll('\n', '<br>')},
    );
  }
}
