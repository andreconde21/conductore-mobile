import 'package:conduit/features/tasks/data/task_http.dart';
import 'package:conduit/features/tasks/domain/task_source.dart';
import 'package:http/http.dart' as http;

/// A Notion database's pages as tasks (API 2022-06-28, paged by cursor,
/// newest edits first). The status is a status or select property, "Status"
/// unless configured; people and multi-select properties are assignees
/// and labels. The body is the page's top-level text blocks; comments need
/// the integration's comment capabilities.
class NotionTaskSource implements TaskSource {
  NotionTaskSource(this.config, {required String token, http.Client? client})
    : _http = TaskHttp(
        client ?? http.Client(),
        service: 'Notion',
        headers: {
          'authorization': 'Bearer $token',
          'notion-version': '2022-06-28',
          'accept': 'application/json',
        },
      );

  @override
  final TaskSourceConfig config;
  final TaskHttp _http;

  static const _base = 'https://api.notion.com/v1';
  static const _maxRichText = 2000;

  /// The status property's type ('status' or 'select') and options.
  ({String type, List<TaskStatusOption> options})? _schema;

  @override
  TaskSourceCapabilities get capabilities => config.kind.capabilities;

  String get _statusProperty => config['statusProperty'] ?? 'Status';

  /// The database id, from an id or a database URL.
  String get _database {
    final raw = config['database'] ?? '';
    final m = RegExp(
      r'([0-9a-fA-F]{8}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{12})',
    ).firstMatch(raw);
    if (m == null) {
      throw const TaskSourceFailure(
        'bad-config',
        'Notion: the database id is the 32 hex characters in its URL.',
      );
    }
    return m.group(1)!.replaceAll('-', '');
  }

  Uri _uri(List<String> path, [Map<String, String>? query]) =>
      joinUri(_base, path, query);

  static String _plain(Object? richText) => [
    if (richText case final List<Object?> parts)
      for (final p in parts)
        if (p case {'plain_text': final String text}) text,
  ].join();

  static TaskStatusCategory _groupCategory(String group) =>
      switch (group.toLowerCase()) {
        'to-do' || 'to do' || 'todo' => TaskStatusCategory.todo,
        'in progress' => TaskStatusCategory.inProgress,
        'complete' || 'done' => TaskStatusCategory.done,
        _ => TaskStatusCategory.guess(group),
      };

  Future<({String type, List<TaskStatusOption> options})> _loadSchema() async {
    final json = await _http.get(_uri(['databases', _database]));
    final property = switch (json) {
      {'properties': final Map<Object?, Object?> props} =>
        props[_statusProperty],
      _ => null,
    };
    if (property is! Map ||
        (property['type'] != 'status' && property['type'] != 'select')) {
      throw TaskSourceFailure(
        'bad-config',
        'Notion: the database has no status or select property '
            '"$_statusProperty".',
      );
    }
    final type = property['type']! as String;
    final spec = property[type] is Map
        ? property[type]! as Map
        : const <Object?, Object?>{};
    final groupOf = <String, String>{
      if (spec['groups'] case final List<Object?> groups)
        for (final g in groups)
          if (g case {
            'name': final String name,
            'option_ids': final List<Object?> ids,
          })
            for (final id in ids)
              if (id is String) id: name,
    };
    return _schema = (
      type: type,
      options: [
        if (spec['options'] case final List<Object?> options)
          for (final o in options)
            if (o case {'name': final String name})
              TaskStatusOption(
                id: name,
                label: name,
                category: switch (groupOf[o['id']]) {
                  final String group => _groupCategory(group),
                  _ => TaskStatusCategory.guess(name),
                },
              ),
      ],
    );
  }

  static String _shortId(String id) {
    final hex = id.replaceAll('-', '');
    return hex.length > 8 ? hex.substring(0, 8) : hex;
  }

  TaskItem _task(Map<Object?, Object?> page) {
    final props = page['properties'] is Map
        ? page['properties']! as Map
        : const <Object?, Object?>{};
    var title = '';
    String? key;
    final people = <String>[];
    final labels = <String>[];
    for (final p in props.values) {
      if (p is! Map) continue;
      switch (p['type']) {
        case 'title':
          title = _plain(p['title']);
        case 'unique_id':
          if (p['unique_id'] case {'number': final num n}) {
            final prefix = str((p['unique_id']! as Map)['prefix']);
            key = prefix == null ? '$n' : '$prefix-$n';
          }
        case 'people':
          for (final u in p['people'] is List ? p['people']! as List : []) {
            if (u case {'name': final String name}) people.add(name);
          }
        case 'multi_select':
          for (final o
              in p['multi_select'] is List ? p['multi_select']! as List : []) {
            if (o case {'name': final String name}) labels.add(name);
          }
      }
    }
    final status = props[_statusProperty];
    final statusName = switch (status) {
      {'status': {'name': final String name}} => name,
      {'select': {'name': final String name}} => name,
      _ => null,
    };
    final id = str(page['id']) ?? '';
    return TaskItem(
      sourceId: config.id,
      id: id,
      key: key ?? _shortId(id),
      title: title,
      status: statusName == null
          ? null
          : _schema?.options.firstWhere(
                  (o) => o.id == statusName,
                  orElse: () => TaskStatusOption.named(statusName),
                ) ??
                TaskStatusOption.named(statusName),
      assignees: people,
      labels: labels,
      url: str(page['url']),
      updatedAt: parseTime(page['last_edited_time']),
    );
  }

  @override
  Future<List<TaskItem>> list() async {
    if (_schema == null) await _loadSchema();
    return collectPages((cursor) async {
      final json = await _http.send(
        'POST',
        _uri(['databases', _database, 'query']),
        body: {
          'page_size': 100,
          'sorts': [
            {'timestamp': 'last_edited_time', 'direction': 'descending'},
          ],
          'start_cursor': ?cursor,
        },
      );
      return (
        [
          if (json case {'results': final List<Object?> results})
            for (final p in results)
              if (p is Map) _task(p),
        ],
        switch (json) {
          {'has_more': true, 'next_cursor': final String next} => next,
          _ => null,
        },
      );
    });
  }

  /// One line per top-level text block.
  static String _blockText(Map<Object?, Object?> block) {
    final type = block['type'];
    final data = block[type];
    final text = data is Map ? _plain(data['rich_text']) : '';
    return switch (type) {
      'heading_1' => '# $text',
      'heading_2' => '## $text',
      'heading_3' => '### $text',
      'bulleted_list_item' => '- $text',
      'numbered_list_item' => '1. $text',
      'to_do' =>
        '[${data is Map && data['checked'] == true ? 'x' : ' '}] $text',
      'quote' => '> $text',
      'code' => '```\n$text\n```',
      _ => text,
    };
  }

  @override
  Future<TaskItem> read(TaskItem task) async {
    if (_schema == null) await _loadSchema();
    final page = await _http.get(_uri(['pages', task.id]));
    final blocks = await _http.get(
      _uri(['blocks', task.id, 'children'], {'page_size': '100'}),
    );
    final comments = await _http.get(
      _uri(['comments'], {'block_id': task.id, 'page_size': '100'}),
    );
    if (page is! Map) {
      throw const TaskSourceFailure('failed', 'Notion: unexpected answer.');
    }
    return _task(page).copyWith(
      body: [
        if (blocks case {'results': final List<Object?> list})
          for (final b in list)
            if (b is Map) _blockText(b),
      ].join('\n').trim(),
      comments: [
        if (comments case {'results': final List<Object?> list})
          for (final c in list)
            if (c is Map)
              TaskComment(
                author: switch (c['created_by']) {
                  {'name': final String name} => name,
                  _ => 'Notion user',
                },
                body: _plain(c['rich_text']),
                at: parseTime(c['created_time']),
              ),
      ],
    );
  }

  @override
  Future<List<TaskStatusOption>> statusOptions(TaskItem task) async =>
      (_schema ?? await _loadSchema()).options;

  @override
  Future<TaskItem> updateStatus(TaskItem task, TaskStatusOption status) async {
    final schema = _schema ?? await _loadSchema();
    await _http.send(
      'PATCH',
      _uri(['pages', task.id]),
      body: {
        'properties': {
          _statusProperty: {
            schema.type: {'name': status.id},
          },
        },
      },
    );
    return task.copyWith(status: status);
  }

  @override
  Future<void> comment(TaskItem task, String text) async {
    await _http.send(
      'POST',
      _uri(['comments']),
      body: {
        'parent': {'page_id': task.id},
        'rich_text': [
          for (var i = 0; i < text.length; i += _maxRichText)
            {
              'type': 'text',
              'text': {
                'content': text.substring(
                  i,
                  i + _maxRichText > text.length
                      ? text.length
                      : i + _maxRichText,
                ),
              },
            },
        ],
      },
    );
  }
}
