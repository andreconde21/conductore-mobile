import 'package:conduit/features/tasks/data/notion_task_source.dart';
import 'package:conduit/features/tasks/domain/task_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'http_recorder.dart';

/// Notion against recorded answers.
void main() {
  const db = '0123456789abcdef0123456789abcdef';
  final schema = {
    'properties': {
      'Stage': {
        'type': 'status',
        'status': {
          'options': [
            {'id': 'o1', 'name': 'Not started'},
            {'id': 'o2', 'name': 'Building'},
            {'id': 'o3', 'name': 'Shipped'},
          ],
          'groups': [
            {
              'name': 'To-do',
              'option_ids': ['o1'],
            },
            {
              'name': 'In progress',
              'option_ids': ['o2'],
            },
            {
              'name': 'Complete',
              'option_ids': ['o3'],
            },
          ],
        },
      },
    },
  };
  Map<String, Object?> page(String id, String stage) => {
    'id': id,
    'url': 'https://www.notion.so/$id',
    'last_edited_time': '2026-10-03T10:00:00.000Z',
    'properties': {
      'Name': {
        'type': 'title',
        'title': [
          {'plain_text': 'Fix '},
          {'plain_text': 'sync'},
        ],
      },
      'ID': {
        'type': 'unique_id',
        'unique_id': {'prefix': 'TSK', 'number': 12},
      },
      'Owner': {
        'type': 'people',
        'people': [
          {'name': 'Ana'},
        ],
      },
      'Tags': {
        'type': 'multi_select',
        'multi_select': [
          {'name': 'sync'},
        ],
      },
      'Stage': {
        'type': 'status',
        'status': {'name': stage},
      },
    },
  };

  NotionTaskSource source(HttpRecorder r) => NotionTaskSource(
    sourceConfig(TaskSourceKind.notion, {
      'database': 'https://www.notion.so/acme/$db?v=1',
      'statusProperty': 'Stage',
    }),
    token: fakeToken,
    client: r.client,
  );

  test('queries by cursor with the status groups as categories', () async {
    final r = HttpRecorder({
      'GET /v1/databases/$db': schema,
      'POST /v1/databases/$db/query': (http.Request request) {
        final first = !request.body.contains('start_cursor');
        return {
          'results': [
            for (var i = 0; i < (first ? 100 : 2); i++)
              page('${first ? 'a' : 'b'}$i-0000-0000', 'Building'),
          ],
          'has_more': first,
          'next_cursor': first ? 'cur1' : null,
        };
      },
    });
    final tasks = await source(r).list();
    expect(tasks, hasLength(102));
    final t = tasks.first;
    expect(t.title, 'Fix sync');
    expect(t.key, 'TSK-12');
    expect(t.status?.label, 'Building');
    expect(t.status?.category, TaskStatusCategory.inProgress);
    expect(t.assignees, ['Ana']);
    expect(t.labels, ['sync']);
    expect(r.lastJson('POST'), containsPair('start_cursor', 'cur1'));
    expect(r.requests.first.headers['notion-version'], '2022-06-28');
    expect(r.requests.first.headers['authorization'], 'Bearer $fakeToken');
  });

  test('read blocks and comments, move, comment', () async {
    const id = 'p1';
    final r = HttpRecorder({
      'GET /v1/databases/$db': schema,
      'GET /v1/pages/$id': page(id, 'Not started'),
      'GET /v1/blocks/$id/children': {
        'results': [
          {
            'type': 'heading_2',
            'heading_2': {
              'rich_text': [
                {'plain_text': 'Goal'},
              ],
            },
          },
          {
            'type': 'to_do',
            'to_do': {
              'checked': true,
              'rich_text': [
                {'plain_text': 'repro'},
              ],
            },
          },
          {'type': 'image', 'image': <String, Object?>{}},
        ],
      },
      'GET /v1/comments': {
        'results': [
          {
            'rich_text': [
              {'plain_text': 'Seen'},
            ],
            'created_time': '2026-10-02T00:00:00.000Z',
            'created_by': {'object': 'user', 'id': 'u1'},
          },
        ],
      },
      'PATCH /v1/pages/$id': page(id, 'Shipped'),
      'POST /v1/comments': {'id': 'c1'},
    });
    final notion = source(r);
    final full = await notion.read(itemRef(id));
    expect(full.body, '## Goal\n[x] repro');
    expect(full.comments!.single.body, 'Seen');
    expect(full.status?.category, TaskStatusCategory.todo);
    final options = await notion.statusOptions(full);
    expect(options.map((o) => o.category), [
      TaskStatusCategory.todo,
      TaskStatusCategory.inProgress,
      TaskStatusCategory.done,
    ]);
    await notion.updateStatus(full, options.last);
    expect(r.lastJson('PATCH'), {
      'properties': {
        'Stage': {
          'status': {'name': 'Shipped'},
        },
      },
    });
    await notion.comment(full, 'x' * 2500);
    final body = r.lastJson('POST')! as Map;
    expect(body['parent'], {'page_id': id});
    expect((body['rich_text'] as List).length, 2, reason: '2000 per part');
  });

  test('a missing status property or a bad id is a config error', () async {
    final r = HttpRecorder({
      'GET /v1/databases/$db': {'properties': <String, Object?>{}},
    });
    await expectLater(
      source(r).list(),
      throwsA(
        isA<TaskSourceFailure>().having(
          (e) => e.message,
          'message',
          contains('"Stage"'),
        ),
      ),
    );
    final bad = NotionTaskSource(
      sourceConfig(TaskSourceKind.notion, {'database': 'nope'}),
      token: fakeToken,
      client: r.client,
    );
    await expectLater(bad.list(), throwsA(isA<TaskSourceFailure>()));
  });
}
