import 'package:conduit/features/tasks/data/jira_task_source.dart';
import 'package:conduit/features/tasks/domain/task_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'http_recorder.dart';

/// Jira Server / Data Center: REST v2, Bearer PAT, startAt paging, plain
/// text bodies.
void main() {
  JiraTaskSource source(HttpRecorder r) => JiraTaskSource(
    sourceConfig(TaskSourceKind.jiraServer, {
      'site': 'https://jira.example.com/jira',
      'project': 'OPS',
    }),
    token: fakeToken,
    client: r.client,
  );

  Map<String, Object?> issue(int i) => {
    'id': '$i',
    'key': 'OPS-$i',
    'fields': {
      'summary': 'Issue $i',
      'status': {
        'id': '1',
        'name': 'Open',
        'statusCategory': {'key': 'new'},
      },
      'assignee': {'displayName': 'Ana'},
      'updated': '2026-10-01T10:00:00.000+0000',
    },
  };

  test('searches v2 by startAt with a Bearer token', () async {
    final r = HttpRecorder({
      'GET /jira/rest/api/2/search': (http.Request request) {
        final start = int.parse(request.url.queryParameters['startAt']!);
        return {
          'startAt': start,
          'total': 130,
          'issues': [
            for (var i = start; i < (start == 0 ? 100 : 130); i++) issue(i),
          ],
        };
      },
    });
    final tasks = await source(r).list();
    expect(tasks, hasLength(130));
    expect(tasks.first.key, 'OPS-0');
    expect(tasks.first.url, 'https://jira.example.com/jira/browse/OPS-0');
    expect(r.requests.map((q) => q.url.queryParameters['startAt']), [
      '0',
      '100',
    ]);
    expect(
      r.requests.first.url.queryParameters['jql'],
      'project = OPS ORDER BY updated DESC',
    );
    expect(r.requests.first.headers['authorization'], 'Bearer $fakeToken');
  });

  test('plain text description, comments and new comments', () async {
    final r = HttpRecorder({
      'GET /jira/rest/api/2/issue/OPS-1': {
        ...issue(1),
        'fields': {
          ...issue(1)['fields']! as Map<String, Object?>,
          'description': 'Plain *wiki* text',
          'comment': {
            'comments': [
              {
                'author': {'displayName': 'Bo'},
                'body': 'Looks good',
                'created': '2026-10-02T10:00:00.000+0000',
              },
            ],
          },
        },
      },
      'GET /jira/rest/api/2/issue/OPS-1/transitions': {
        'transitions': [
          {
            'id': '21',
            'name': 'Close',
            'to': {
              'name': 'Closed',
              'statusCategory': {'key': 'done'},
            },
          },
        ],
      },
      'POST /jira/rest/api/2/issue/OPS-1/transitions': null,
      'POST /jira/rest/api/2/issue/OPS-1/comment': {'id': '9'},
    });
    final jira = source(r);
    final full = await jira.read(itemRef('OPS-1'));
    expect(full.body, 'Plain *wiki* text');
    expect(full.comments!.single.body, 'Looks good');
    final [closed] = await jira.statusOptions(full);
    expect(closed.category, TaskStatusCategory.done);
    await jira.updateStatus(full, closed);
    expect(r.lastJson('POST'), {
      'transition': {'id': '21'},
    });
    await jira.comment(full, 'Done\nby the agent');
    expect(r.lastJson('POST'), {'body': 'Done\nby the agent'});
  });

  test('needs the server URL and a project or JQL', () {
    const config = TaskSourceConfig(
      id: 'x',
      kind: TaskSourceKind.jiraServer,
      name: 'J',
      settings: {'site': 'https://j'},
    );
    expect(config.missingField(), 'Project key or JQL');
    expect(
      TaskSourceKind.jiraServer.fields.any((f) => f.key == 'email'),
      false,
    );
  });
}
