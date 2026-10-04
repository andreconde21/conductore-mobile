import 'package:conduit/features/tasks/data/trello_task_source.dart';
import 'package:conduit/features/tasks/domain/task_source.dart';
import 'package:flutter_test/flutter_test.dart';

import 'http_recorder.dart';

/// Trello against recorded answers: lists are statuses, the key and
/// token travel in the OAuth header only.
void main() {
  final lists = [
    {'id': 'L1', 'name': 'To Do'},
    {'id': 'L2', 'name': 'Doing'},
    {'id': 'L3', 'name': 'Done'},
  ];
  Map<String, Object?> card(String id, String list, String at) => {
    'id': id,
    'idShort': 4,
    'name': 'Card $id',
    'idList': list,
    'dateLastActivity': at,
    'shortUrl': 'https://trello.com/c/$id',
    'labels': [
      {'name': 'ux'},
      {'name': ''},
    ],
    'members': [
      {'fullName': 'Ana Silva', 'username': 'ana'},
    ],
  };

  TrelloTaskSource source(HttpRecorder r) => TrelloTaskSource(
    sourceConfig(TaskSourceKind.trello, {'board': 'AbC123', 'apiKey': 'key1'}),
    token: fakeToken,
    client: r.client,
  );

  test('cards with their list as status, newest first', () async {
    final r = HttpRecorder({
      'GET /1/boards/AbC123/lists': lists,
      'GET /1/boards/AbC123/cards': [
        card('c1', 'L1', '2026-10-01T00:00:00Z'),
        card('c2', 'L3', '2026-10-03T00:00:00Z'),
      ],
    });
    final tasks = await source(r).list();
    expect(tasks.map((t) => t.id), ['c2', 'c1']);
    expect(tasks.first.status?.label, 'Done');
    expect(tasks.first.status?.category, TaskStatusCategory.done);
    expect(tasks.last.status?.category, TaskStatusCategory.todo);
    expect(tasks.last.labels, ['ux']);
    expect(tasks.last.assignees, ['Ana Silva']);
    for (final q in r.requests) {
      expect(
        q.headers['authorization'],
        'OAuth oauth_consumer_key="key1", oauth_token="$fakeToken"',
      );
      expect(q.url.toString(), isNot(contains(fakeToken)));
      expect(q.url.queryParameters.containsKey('token'), isFalse);
    }
  });

  test('read with comments, move to a list, comment', () async {
    final r = HttpRecorder({
      'GET /1/boards/AbC123/lists': lists,
      'GET /1/cards/c1': {
        ...card('c1', 'L2', '2026-10-01T00:00:00Z'),
        'desc': 'Details',
      },
      'GET /1/cards/c1/actions': [
        {
          'data': {'text': 'second'},
          'date': '2026-10-02T00:00:00Z',
          'memberCreator': {'fullName': 'Bo'},
        },
        {
          'data': {'text': 'first'},
          'date': '2026-10-01T00:00:00Z',
          'memberCreator': {'fullName': 'Ana'},
        },
      ],
      'PUT /1/cards/c1': {'id': 'c1'},
      'POST /1/cards/c1/actions/comments': {'id': 'a1'},
    });
    final trello = source(r);
    final full = await trello.read(itemRef('c1'));
    expect(full.body, 'Details');
    expect(full.status?.label, 'Doing');
    expect(full.comments!.map((c) => c.body), ['first', 'second']);
    final options = await trello.statusOptions(full);
    expect(options.map((o) => o.label), ['To Do', 'Doing', 'Done']);
    await trello.updateStatus(full, options.last);
    expect(r.lastJson('PUT'), {'idList': 'L3'});
    await trello.comment(full, 'Moved by the agent');
    expect(r.lastJson('POST'), {'text': 'Moved by the agent'});
  });

  test('a board code with path characters is refused', () async {
    final r = HttpRecorder({});
    final bad = TrelloTaskSource(
      sourceConfig(TaskSourceKind.trello, {'board': '../x', 'apiKey': 'k'}),
      token: fakeToken,
      client: r.client,
    );
    await expectLater(bad.list(), throwsA(isA<TaskSourceFailure>()));
    expect(r.requests, isEmpty);
  });
}
