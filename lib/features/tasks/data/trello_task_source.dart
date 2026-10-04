import 'package:conduit/features/tasks/data/task_http.dart';
import 'package:conduit/features/tasks/domain/task_source.dart';
import 'package:http/http.dart' as http;

/// A Trello board's cards (REST v1). A card's status is its list; moving
/// it changes its list. The API key and token go in Trello's OAuth header,
/// never in the URL.
class TrelloTaskSource implements TaskSource {
  TrelloTaskSource(this.config, {required String token, http.Client? client})
    : _http = TaskHttp(
        client ?? http.Client(),
        service: 'Trello',
        headers: {
          'authorization':
              'OAuth oauth_consumer_key="${config['apiKey'] ?? ''}", '
              'oauth_token="$token"',
          'accept': 'application/json',
        },
      );

  @override
  final TaskSourceConfig config;
  final TaskHttp _http;

  static const _base = 'https://api.trello.com/1';
  static const _cardFields =
      'id,idShort,name,idList,dateLastActivity,shortUrl,labels';

  /// The board's open lists, by id, once loaded.
  Map<String, TaskStatusOption>? _lists;

  @override
  TaskSourceCapabilities get capabilities => config.kind.capabilities;

  String get _board {
    final board = config['board'];
    if (board == null || !RegExp(r'^[A-Za-z0-9]+$').hasMatch(board)) {
      throw const TaskSourceFailure(
        'bad-config',
        'Trello: the board is its id or the short code in its URL '
            '(trello.com/b/<code>/...).',
      );
    }
    return board;
  }

  Uri _uri(List<String> path, [Map<String, String>? query]) =>
      joinUri(_base, path, query);

  Future<Map<String, TaskStatusOption>> _loadLists() async {
    final json = await _http.get(
      _uri(
        ['boards', _board, 'lists'],
        {'fields': 'id,name', 'filter': 'open'},
      ),
    );
    return _lists = {
      if (json is List)
        for (final l in json)
          if (l case {'id': final String id, 'name': final String name})
            id: TaskStatusOption(
              id: id,
              label: name,
              category: TaskStatusCategory.guess(name),
            ),
    };
  }

  TaskItem _task(Map<Object?, Object?> card) => TaskItem(
    sourceId: config.id,
    id: str(card['id']) ?? '',
    key: '#${card['idShort'] ?? '?'}',
    title: str(card['name']) ?? '',
    status: _lists?[card['idList']],
    assignees: [
      if (card['members'] case final List<Object?> members)
        for (final m in members)
          if (m is Map) str(m['fullName']) ?? str(m['username']) ?? '?',
    ],
    labels: [
      if (card['labels'] case final List<Object?> labels)
        for (final l in labels)
          if (l is Map && (str(l['name']) ?? '').isNotEmpty)
            l['name']! as String,
    ],
    url: str(card['shortUrl']),
    updatedAt: parseTime(card['dateLastActivity']),
    body: card.containsKey('desc') ? str(card['desc']) ?? '' : null,
  );

  /// One call returns up to 1000 open cards; the newest
  /// [maxTasksPerSource] are kept.
  @override
  Future<List<TaskItem>> list() async {
    await _loadLists();
    final json = await _http.get(
      _uri(
        ['boards', _board, 'cards'],
        {
          'fields': _cardFields,
          'members': 'true',
          'member_fields': 'fullName,username',
          'limit': '1000',
        },
      ),
    );
    final tasks = [
      if (json is List)
        for (final c in json)
          if (c is Map) _task(c),
    ];
    tasks.sort(
      (a, b) =>
          (b.updatedAt ?? DateTime(0)).compareTo(a.updatedAt ?? DateTime(0)),
    );
    return tasks.length > maxTasksPerSource
        ? tasks.sublist(0, maxTasksPerSource)
        : tasks;
  }

  @override
  Future<TaskItem> read(TaskItem task) async {
    if (_lists == null) await _loadLists();
    final card = await _http.get(
      _uri(
        ['cards', task.id],
        {
          'fields': '$_cardFields,desc',
          'members': 'true',
          'member_fields': 'fullName,username',
        },
      ),
    );
    final actions = await _http.get(
      _uri(
        ['cards', task.id, 'actions'],
        {'filter': 'commentCard', 'memberCreator_fields': 'fullName,username'},
      ),
    );
    if (card is! Map) {
      throw const TaskSourceFailure('failed', 'Trello: unexpected answer.');
    }
    return _task(card).copyWith(
      comments: [
        if (actions is List)
          for (final a in actions.reversed)
            if (a is Map)
              TaskComment(
                author: switch (a['memberCreator']) {
                  {'fullName': final String name} => name,
                  _ => '?',
                },
                body: switch (a['data']) {
                  {'text': final String text} => text,
                  _ => '',
                },
                at: parseTime(a['date']),
              ),
      ],
    );
  }

  @override
  Future<List<TaskStatusOption>> statusOptions(TaskItem task) async =>
      (_lists ?? await _loadLists()).values.toList();

  @override
  Future<TaskItem> updateStatus(TaskItem task, TaskStatusOption status) async {
    await _http.send(
      'PUT',
      _uri(['cards', task.id]),
      body: {'idList': status.id},
    );
    return task.copyWith(status: status);
  }

  @override
  Future<void> comment(TaskItem task, String text) async {
    await _http.send(
      'POST',
      _uri(['cards', task.id, 'actions', 'comments']),
      body: {'text': text},
    );
  }
}
