import 'package:conduit/features/tasks/data/clickup_task_source.dart';
import 'package:conduit/features/tasks/domain/task_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'http_recorder.dart';

/// ClickUp against recorded answers.
void main() {
  Map<String, Object?> task(String id, {String status = 'to do'}) => {
    'id': id,
    'custom_id': null,
    'name': 'Task $id',
    'status': {
      'status': status,
      'type': status == 'complete' ? 'closed' : 'open',
    },
    'assignees': [
      {'username': 'ana', 'email': 'a@x'},
    ],
    'tags': [
      {'name': 'api'},
    ],
    'url': 'https://app.clickup.com/t/$id',
    'date_updated': '1790000000000',
  };

  ClickUpTaskSource source(HttpRecorder r) => ClickUpTaskSource(
    sourceConfig(TaskSourceKind.clickup, {'list': '901'}),
    token: fakeToken,
    client: r.client,
  );

  test('pages until last_page, closed tasks included', () async {
    final r = HttpRecorder({
      'GET /api/v2/list/901/task': (http.Request request) {
        final page = int.parse(request.url.queryParameters['page']!);
        return {
          'tasks': [
            for (var i = 0; i < (page == 0 ? 100 : 3); i++) task('p$page-$i'),
          ],
          'last_page': page == 1,
        };
      },
    });
    final tasks = await source(r).list();
    expect(tasks, hasLength(103));
    expect(r.requests.map((q) => q.url.queryParameters['page']), ['0', '1']);
    expect(r.requests.first.url.queryParameters['include_closed'], 'true');
    expect(r.requests.first.headers['authorization'], fakeToken);
    final t = tasks.first;
    expect(t.key, '#p0-0');
    expect(t.status?.category, TaskStatusCategory.todo);
    expect(t.assignees, ['ana']);
    expect(t.labels, ['api']);
    expect(t.updatedAt, DateTime.fromMillisecondsSinceEpoch(1790000000000));
  });

  test('read, the list statuses, move and comment', () async {
    final r = HttpRecorder({
      'GET /api/v2/task/abc': {
        ...task('abc'),
        'description': 'Desc',
        'text_content': 'Desc',
      },
      'GET /api/v2/task/abc/comment': {
        'comments': [
          {
            'comment_text': 'newer',
            'user': {'username': 'bo'},
            'date': '1790000002000',
          },
          {
            'comment_text': 'older',
            'user': {'username': 'ana'},
            'date': '1790000001000',
          },
        ],
      },
      'GET /api/v2/list/901': {
        'statuses': [
          {'status': 'to do', 'type': 'open'},
          {'status': 'in progress', 'type': 'custom'},
          {'status': 'complete', 'type': 'closed'},
        ],
      },
      'PUT /api/v2/task/abc': task('abc', status: 'complete'),
      'POST /api/v2/task/abc/comment': {'id': 1},
    });
    final clickup = source(r);
    final full = await clickup.read(itemRef('abc'));
    expect(full.body, 'Desc');
    expect(full.comments!.map((c) => c.body), ['older', 'newer']);
    final options = await clickup.statusOptions(full);
    expect(options.map((o) => o.category), [
      TaskStatusCategory.todo,
      TaskStatusCategory.inProgress,
      TaskStatusCategory.done,
    ]);
    final moved = await clickup.updateStatus(full, options.last);
    expect(moved.status?.label, 'complete');
    expect(r.lastJson('PUT'), {'status': 'complete'});
    await clickup.comment(full, 'Done');
    expect(r.lastJson('POST'), {'comment_text': 'Done', 'notify_all': false});
  });
}
