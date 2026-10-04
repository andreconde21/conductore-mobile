import 'package:conduit/features/tasks/data/asana_task_source.dart';
import 'package:conduit/features/tasks/domain/task_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'http_recorder.dart';

/// Asana against recorded answers.
void main() {
  Map<String, Object?> task(String gid, {bool done = false}) => {
    'gid': gid,
    'name': 'Task $gid',
    'completed': done,
    'assignee': {'name': 'Ana'},
    'tags': [
      {'name': 'web'},
    ],
    'modified_at': '2026-10-0${gid.length % 9 + 1}T00:00:00.000Z',
    'permalink_url': 'https://app.asana.com/0/42/$gid',
    'memberships': [
      {
        'project': {'gid': '99'},
        'section': {'gid': 'other', 'name': 'Elsewhere'},
      },
      {
        'project': {'gid': '42'},
        'section': {'gid': 'S2', 'name': 'Doing'},
      },
    ],
  };

  AsanaTaskSource source(HttpRecorder r) => AsanaTaskSource(
    sourceConfig(TaskSourceKind.asana, {'project': '42'}),
    token: fakeToken,
    client: r.client,
  );

  test('pages by offset; the section in this project is the status', () async {
    final r = HttpRecorder({
      'GET /api/1.0/projects/42/tasks': (http.Request request) {
        final offset = request.url.queryParameters['offset'];
        return {
          'data': offset == null
              ? [for (var i = 0; i < 100; i++) task('a$i')]
              : [task('b1', done: true)],
          if (offset == null) 'next_page': {'offset': 'tok1'},
        };
      },
    });
    final tasks = await source(r).list();
    expect(tasks, hasLength(101));
    expect(r.requests.map((q) => q.url.queryParameters['offset']), [
      null,
      'tok1',
    ]);
    expect(r.requests.first.headers['authorization'], 'Bearer $fakeToken');
    final open = tasks.firstWhere((t) => t.id == 'a1');
    expect(open.status?.label, 'Doing');
    expect(open.status?.category, TaskStatusCategory.inProgress);
    expect(open.assignees, ['Ana']);
    expect(open.labels, ['web']);
    expect(
      tasks.firstWhere((t) => t.id == 'b1').status,
      AsanaTaskSource.completed,
    );
  });

  test('read keeps comment stories only; move, complete, comment', () async {
    final r = HttpRecorder({
      'GET /api/1.0/tasks/t1': {
        'data': {...task('t1'), 'notes': 'Notes'},
      },
      'GET /api/1.0/tasks/t1/stories': {
        'data': [
          {'type': 'system', 'text': 'added to Doing'},
          {
            'type': 'comment',
            'text': 'On it',
            'created_by': {'name': 'Bo'},
            'created_at': '2026-10-02T00:00:00.000Z',
          },
        ],
      },
      'GET /api/1.0/projects/42/sections': {
        'data': [
          {'gid': 'S1', 'name': 'To do'},
          {'gid': 'S2', 'name': 'Doing'},
        ],
      },
      'POST /api/1.0/sections/S1/addTask': {'data': <String, Object?>{}},
      'PUT /api/1.0/tasks/t1': {'data': <String, Object?>{}},
      'POST /api/1.0/tasks/t1/stories': {'data': <String, Object?>{}},
    });
    final asana = source(r);
    final full = await asana.read(itemRef('t1'));
    expect(full.body, 'Notes');
    expect(full.comments!.single.body, 'On it');
    final options = await asana.statusOptions(full);
    expect(options.map((o) => o.label), ['To do', 'Doing', 'Completed']);

    final moved = await asana.updateStatus(full, options.first);
    expect(moved.status?.id, 'S1');
    expect(r.lastJson('POST'), {
      'data': {'task': 't1'},
    });
    expect(r.requests.where((q) => q.method == 'PUT'), isEmpty);

    final done = await asana.updateStatus(moved, options.last);
    expect(done.status, AsanaTaskSource.completed);
    expect(r.lastJson('PUT'), {
      'data': {'completed': true},
    });

    // Back to a section reopens it.
    await asana.updateStatus(done, options.first);
    expect(r.lastJson('PUT'), {
      'data': {'completed': false},
    });

    await asana.comment(full, 'Hi');
    expect(r.lastJson('POST'), {
      'data': {'text': 'Hi'},
    });
  });
}
