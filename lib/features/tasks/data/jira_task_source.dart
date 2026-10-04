import 'dart:convert';

import 'package:conduit/features/tasks/data/task_http.dart';
import 'package:conduit/features/tasks/domain/task_source.dart';
import 'package:http/http.dart' as http;

/// Jira Cloud issues (REST v3): a project's issues or any JQL, statuses
/// through each issue's transitions, comments in Atlassian Document
/// Format. Basic auth with the account email and an API token.
class JiraTaskSource implements TaskSource {
  JiraTaskSource(this.config, {required String token, http.Client? client})
    : _http = TaskHttp(
        client ?? http.Client(),
        service: 'Jira',
        headers: {
          'authorization':
              'Basic ${base64Encode(utf8.encode('${config['email'] ?? ''}:$token'))}',
          'accept': 'application/json',
        },
      );

  @override
  final TaskSourceConfig config;
  final TaskHttp _http;

  static const _fields = 'summary,status,assignee,labels,updated';

  @override
  TaskSourceCapabilities get capabilities => config.kind.capabilities;

  String get _site {
    final site = config['site'];
    if (site == null) {
      throw const TaskSourceFailure('bad-config', 'Jira: the site is missing.');
    }
    return baseUrl(site, '');
  }

  Uri _uri(List<String> path, [Map<String, String>? query]) =>
      joinUri(_site, ['rest', 'api', '3', ...path], query);

  /// The configured JQL, else the project's issues, newest first.
  String get jql {
    final jql = config['jql'];
    if (jql != null) return jql;
    final project = config['project'] ?? '';
    if (!RegExp(r'^[A-Za-z][A-Za-z0-9_]*$').hasMatch(project)) {
      throw const TaskSourceFailure(
        'bad-config',
        'Jira: the project key is letters and digits (PROJ).',
      );
    }
    return 'project = $project ORDER BY updated DESC';
  }

  static TaskStatusCategory _category(Object? statusCategory) =>
      switch (statusCategory) {
        {'key': 'new'} => TaskStatusCategory.todo,
        {'key': 'indeterminate'} => TaskStatusCategory.inProgress,
        {'key': 'done'} => TaskStatusCategory.done,
        _ => TaskStatusCategory.unknown,
      };

  TaskItem _task(Map<Object?, Object?> json) {
    final key = str(json['key']) ?? '';
    final fields = json['fields'] is Map
        ? json['fields']! as Map
        : const <Object?, Object?>{};
    final status = fields['status'];
    return TaskItem(
      sourceId: config.id,
      id: key,
      key: key,
      title: str(fields['summary']) ?? '',
      status: status is Map && status['name'] is String
          ? TaskStatusOption(
              id: str(status['id']) ?? status['name'] as String,
              label: status['name'] as String,
              category: _category(status['statusCategory']),
            )
          : null,
      assignees: [
        if (fields['assignee'] case {'displayName': final String name}) name,
      ],
      labels: [
        if (fields['labels'] case final List<Object?> list)
          for (final l in list)
            if (l is String) l,
      ],
      url: key.isEmpty ? null : '$_site/browse/$key',
      updatedAt: parseTime(fields['updated']),
      body: fields.containsKey('description')
          ? adfToText(fields['description'])
          : null,
      extra: {if (json['id'] is String) 'issueId': json['id']! as String},
    );
  }

  @override
  Future<List<TaskItem>> list() async {
    final json = await _http.send(
      'POST',
      _uri(['search', 'jql']),
      body: {'jql': jql, 'maxResults': 100, 'fields': _fields.split(',')},
    );
    return [
      if (json case {'issues': final List<Object?> issues})
        for (final issue in issues)
          if (issue is Map) _task(issue),
    ];
  }

  @override
  Future<TaskItem> read(TaskItem task) async {
    final json = await _http.get(
      _uri(['issue', task.id], {'fields': '$_fields,description,comment'}),
    );
    if (json is! Map) {
      throw const TaskSourceFailure('failed', 'Jira: unexpected answer.');
    }
    final fields = json['fields'];
    return _task(json).copyWith(
      body: fields is Map ? adfToText(fields['description']) : '',
      comments: [
        if (fields case {'comment': {'comments': final List<Object?> comments}})
          for (final c in comments)
            if (c is Map)
              TaskComment(
                author: switch (c['author']) {
                  {'displayName': final String name} => name,
                  _ => '?',
                },
                body: adfToText(c['body']),
                at: parseTime(c['created']),
              ),
      ],
    );
  }

  /// The issue's transitions; each option's id is the transition's.
  @override
  Future<List<TaskStatusOption>> statusOptions(TaskItem task) async {
    final json = await _http.get(_uri(['issue', task.id, 'transitions']));
    return [
      if (json case {'transitions': final List<Object?> list})
        for (final t in list)
          if (t is Map && t['id'] is String)
            TaskStatusOption(
              id: t['id']! as String,
              label: switch (t['to']) {
                {'name': final String name} => name,
                _ => str(t['name']) ?? '?',
              },
              category: _category(
                t['to'] is Map ? (t['to']! as Map)['statusCategory'] : null,
              ),
            ),
    ];
  }

  @override
  Future<TaskItem> updateStatus(TaskItem task, TaskStatusOption status) async {
    await _http.send(
      'POST',
      _uri(['issue', task.id, 'transitions']),
      body: {
        'transition': {'id': status.id},
      },
    );
    return task.copyWith(status: status);
  }

  @override
  Future<void> comment(TaskItem task, String text) async {
    await _http.send(
      'POST',
      _uri(['issue', task.id, 'comment']),
      body: {'body': textToAdf(text)},
    );
  }
}

/// Plain text from an Atlassian Document Format node (or a plain string,
/// as Jira Server sends).
String adfToText(Object? node) {
  final out = StringBuffer();
  void walk(Object? n, String indent) {
    if (n is String) {
      out.write(n);
      return;
    }
    if (n is! Map) return;
    final children = n['content'] is List
        ? n['content']! as List
        : const <Object?>[];
    switch (n['type']) {
      case 'text':
        out.write(str(n['text']) ?? '');
      case 'hardBreak':
        out.write('\n');
      case 'mention' || 'emoji' || 'status':
        out.write(switch (n['attrs']) {
          {'text': final String text} => text,
          _ => '',
        });
      case 'listItem':
        out.write('$indent- ');
        for (final c in children) {
          walk(c, '$indent  ');
        }
      case 'paragraph' || 'heading' || 'codeBlock' || 'blockquote':
        for (final c in children) {
          walk(c, indent);
        }
        out.write('\n');
      default:
        for (final c in children) {
          walk(c, indent);
        }
    }
  }

  walk(node, '');
  return out.toString().replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
}

/// [text] as an ADF document: one paragraph per line.
Map<String, Object?> textToAdf(String text) => {
  'type': 'doc',
  'version': 1,
  'content': [
    for (final line in text.split('\n'))
      {
        'type': 'paragraph',
        'content': [
          if (line.isNotEmpty) {'type': 'text', 'text': line},
        ],
      },
  ],
};
