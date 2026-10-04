import 'dart:convert';

import 'package:conduit/features/tasks/data/azure_boards_task_source.dart';
import 'package:conduit/features/tasks/data/github_task_source.dart';
import 'package:conduit/features/tasks/data/gitlab_task_source.dart';
import 'package:conduit/features/tasks/data/jira_task_source.dart';
import 'package:conduit/features/tasks/data/linear_task_source.dart';
import 'package:conduit/features/tasks/domain/task_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Every tracker adapter against recorded answers (shapes from each API's
/// documentation): no request leaves the test, and the token is a fake.
const _token = 'fake-token-not-real';

/// A [MockClient] that answers from [routes] ("METHOD path" → body or
/// (status, body)) and records every request.
class _Recorder {
  _Recorder(this.routes);

  final Map<String, Object?> routes;
  final requests = <http.Request>[];

  late final client = MockClient((request) async {
    requests.add(request);
    final key = '${request.method} ${request.url.path}';
    if (!routes.containsKey(key)) {
      return http.Response('{"message":"no route $key"}', 404);
    }
    final answer = routes[key];
    if (answer is (int, Object?)) {
      return _json(answer.$2, answer.$1);
    }
    return answer == null ? http.Response('', 204) : _json(answer, 200);
  });

  http.Request last(String method) =>
      requests.lastWhere((r) => r.method == method);

  Object? lastJson(String method) => jsonDecode(last(method).body);
}

/// UTF-8 JSON without a charset, as some APIs answer.
http.Response _json(Object? body, int status) =>
    http.Response.bytes(utf8.encode(jsonEncode(body)), status);

TaskSourceConfig _config(TaskSourceKind kind, Map<String, String> settings) =>
    TaskSourceConfig(
      id: 's1',
      kind: kind,
      name: kind.label,
      settings: settings,
    );

void main() {
  group('GitHub Issues', () {
    final issue = {
      'number': 12,
      'title': 'Login redirect loops',
      'state': 'open',
      'body': 'Steps…',
      'html_url': 'https://github.com/acme/app/issues/12',
      'updated_at': '2026-10-01T10:00:00Z',
      'assignees': [
        {'login': 'ana'},
      ],
      'labels': [
        {'name': 'bug'},
      ],
    };

    test('lists issues without pull requests', () async {
      final r = _Recorder({
        'GET /repos/acme/app/issues': [
          issue,
          {...issue, 'number': 13, 'pull_request': <String, Object?>{}},
        ],
      });
      final source = GitHubTaskSource(
        _config(TaskSourceKind.github, {'repo': 'acme/app'}),
        token: _token,
        client: r.client,
      );
      final tasks = await source.list();
      expect(tasks, hasLength(1));
      final t = tasks.single;
      expect(t.key, '#12');
      expect(t.status, GitHubTaskSource.open);
      expect(t.assignees, ['ana']);
      expect(t.labels, ['bug']);
      final req = r.requests.single;
      expect(req.url.host, 'api.github.com');
      expect(req.url.queryParameters['state'], 'all');
      expect(req.headers['authorization'], 'Bearer $_token');
    });

    test('reads, closes and comments', () async {
      final r = _Recorder({
        'GET /repos/acme/app/issues/12': issue,
        'GET /repos/acme/app/issues/12/comments': [
          {
            'user': {'login': 'bo'},
            'body': 'Seen it too',
            'created_at': '2026-10-01T11:00:00Z',
          },
        ],
        'PATCH /repos/acme/app/issues/12': {...issue, 'state': 'closed'},
        'POST /repos/acme/app/issues/12/comments': {'id': 1},
      });
      final source = GitHubTaskSource(
        _config(TaskSourceKind.github, {'repo': 'acme/app'}),
        token: _token,
        client: r.client,
      );
      final listed = TaskItem(sourceId: 's1', id: '12', key: '#12', title: '');
      final full = await source.read(listed);
      expect(full.body, 'Steps…');
      expect(full.comments!.single.author, 'bo');
      final closed = await source.updateStatus(full, GitHubTaskSource.closed);
      expect(closed.status?.category, TaskStatusCategory.done);
      expect(r.lastJson('PATCH'), {
        'state': 'closed',
        'state_reason': 'completed',
      });
      await source.comment(full, 'Fixed in #14');
      expect(r.lastJson('POST'), {'body': 'Fixed in #14'});
    });

    test('a bad repository or token is a clear failure', () async {
      final r = _Recorder({
        'GET /repos/acme/app/issues': (401, {'message': 'Bad credentials'}),
      });
      final source = GitHubTaskSource(
        _config(TaskSourceKind.github, {'repo': 'acme/app'}),
        token: _token,
        client: r.client,
      );
      await expectLater(
        source.list(),
        throwsA(
          isA<TaskSourceFailure>()
              .having((e) => e.code, 'code', 'auth')
              .having((e) => e.message, 'message', isNot(contains(_token))),
        ),
      );
      final bad = GitHubTaskSource(
        _config(TaskSourceKind.github, {'repo': 'acme'}),
        token: _token,
        client: r.client,
      );
      await expectLater(
        bad.list(),
        throwsA(
          isA<TaskSourceFailure>().having((e) => e.code, 'code', 'bad-config'),
        ),
      );
    });

    test('refuses plain http', () async {
      final r = _Recorder({});
      final source = GitHubTaskSource(
        _config(TaskSourceKind.github, {
          'repo': 'acme/app',
          'apiBase': 'http://ghe.example.com/api/v3',
        }),
        token: _token,
        client: r.client,
      );
      await expectLater(source.list(), throwsA(isA<TaskSourceFailure>()));
      expect(r.requests, isEmpty, reason: 'the token never goes in clear');
    });
  });

  group('GitLab Issues', () {
    final issue = {
      'iid': 7,
      'title': 'Crash on start',
      'state': 'opened',
      'description': 'Trace…',
      'web_url': 'https://gitlab.com/g/p/-/issues/7',
      'updated_at': '2026-10-02T09:00:00Z',
      'assignees': [
        {'username': 'cy'},
      ],
      'labels': ['p1'],
    };

    test('lists, reads notes without system notes, closes, comments', () async {
      final r = _Recorder({
        'GET /api/v4/projects/g%2Fp/issues': [issue],
        'GET /api/v4/projects/g%2Fp/issues/7': issue,
        'GET /api/v4/projects/g%2Fp/issues/7/notes': [
          {
            'author': {'username': 'cy'},
            'body': 'On it',
            'system': false,
            'created_at': '2026-10-02T10:00:00Z',
          },
          {
            'author': {'username': 'cy'},
            'body': 'changed the description',
            'system': true,
          },
        ],
        'PUT /api/v4/projects/g%2Fp/issues/7': {...issue, 'state': 'closed'},
        'POST /api/v4/projects/g%2Fp/issues/7/notes': {'id': 3},
      });
      final source = GitLabTaskSource(
        _config(TaskSourceKind.gitlab, {'project': 'g/p'}),
        token: _token,
        client: r.client,
      );
      final [task] = await source.list();
      expect(task.key, '#7');
      expect(task.labels, ['p1']);
      expect(
        r.requests.single.url.toString(),
        startsWith('https://gitlab.com/api/v4/projects/g%2Fp/issues'),
      );
      expect(r.requests.single.headers['private-token'], _token);
      final full = await source.read(task);
      expect(full.comments!.map((c) => c.body), ['On it']);
      final closed = await source.updateStatus(full, GitLabTaskSource.closed);
      expect(closed.status, GitLabTaskSource.closed);
      expect(r.lastJson('PUT'), {'state_event': 'close'});
      await source.comment(full, 'Done');
      expect(r.lastJson('POST'), {'body': 'Done'});
    });
  });

  group('Jira Cloud', () {
    final issueJson = {
      'id': '10001',
      'key': 'PROJ-7',
      'fields': {
        'summary': 'Export fails',
        'status': {
          'id': '3',
          'name': 'In Progress',
          'statusCategory': {'key': 'indeterminate'},
        },
        'assignee': {'displayName': 'Ana Silva'},
        'labels': ['backend'],
        'updated': '2026-10-03T08:00:00.000+0000',
      },
    };

    JiraTaskSource source(_Recorder r, [Map<String, String>? extra]) =>
        JiraTaskSource(
          _config(TaskSourceKind.jira, {
            'site': 'https://acme.atlassian.net/',
            'email': 'me@example.com',
            'project': 'PROJ',
            ...?extra,
          }),
          token: _token,
          client: r.client,
        );

    test('searches the project with JQL and basic auth', () async {
      final r = _Recorder({
        'POST /rest/api/3/search/jql': {
          'issues': [issueJson],
        },
      });
      final [task] = await source(r).list();
      expect(task.key, 'PROJ-7');
      expect(task.status?.category, TaskStatusCategory.inProgress);
      expect(task.assignees, ['Ana Silva']);
      expect(task.url, 'https://acme.atlassian.net/browse/PROJ-7');
      final body = r.lastJson('POST')! as Map;
      expect(body['jql'], 'project = PROJ ORDER BY updated DESC');
      expect(
        r.last('POST').headers['authorization'],
        'Basic ${base64Encode(utf8.encode('me@example.com:$_token'))}',
      );
    });

    test('a project key cannot inject JQL; a JQL setting wins', () async {
      final r = _Recorder({
        'POST /rest/api/3/search/jql': {'issues': <Object?>[]},
      });
      await expectLater(
        source(r, {'project': 'X OR 1=1'}).list(),
        throwsA(isA<TaskSourceFailure>()),
      );
      await source(r, {'jql': 'assignee = currentUser()'}).list();
      expect((r.lastJson('POST')! as Map)['jql'], 'assignee = currentUser()');
    });

    test('reads ADF, moves through a transition, comments in ADF', () async {
      final r = _Recorder({
        'GET /rest/api/3/issue/PROJ-7': {
          ...issueJson,
          'fields': {
            ...issueJson['fields']! as Map<String, Object?>,
            'description': {
              'type': 'doc',
              'version': 1,
              'content': [
                {
                  'type': 'paragraph',
                  'content': [
                    {'type': 'text', 'text': 'Export to CSV '},
                    {
                      'type': 'mention',
                      'attrs': {'text': '@Bo'},
                    },
                  ],
                },
                {
                  'type': 'bulletList',
                  'content': [
                    {
                      'type': 'listItem',
                      'content': [
                        {
                          'type': 'paragraph',
                          'content': [
                            {'type': 'text', 'text': 'fails'},
                          ],
                        },
                      ],
                    },
                  ],
                },
              ],
            },
            'comment': {
              'comments': [
                {
                  'author': {'displayName': 'Bo'},
                  'body': {
                    'type': 'doc',
                    'content': [
                      {
                        'type': 'paragraph',
                        'content': [
                          {'type': 'text', 'text': 'Repro'},
                        ],
                      },
                    ],
                  },
                  'created': '2026-10-03T09:00:00.000+0000',
                },
              ],
            },
          },
        },
        'GET /rest/api/3/issue/PROJ-7/transitions': {
          'transitions': [
            {
              'id': '31',
              'name': 'Finish',
              'to': {
                'name': 'Done',
                'statusCategory': {'key': 'done'},
              },
            },
          ],
        },
        'POST /rest/api/3/issue/PROJ-7/transitions': null,
        'POST /rest/api/3/issue/PROJ-7/comment': {'id': '5'},
      });
      final jira = source(r);
      final full = await jira.read(
        const TaskItem(sourceId: 's1', id: 'PROJ-7', key: 'PROJ-7', title: ''),
      );
      expect(full.body, 'Export to CSV @Bo\n- fails');
      expect(full.comments!.single.body, 'Repro');
      final [done] = await jira.statusOptions(full);
      expect(done.id, '31');
      expect(done.label, 'Done');
      expect(done.category, TaskStatusCategory.done);
      final moved = await jira.updateStatus(full, done);
      expect(moved.status?.label, 'Done');
      expect(r.requests[r.requests.length - 1].body, contains('"31"'));
      await jira.comment(full, 'line one\nline two');
      expect(r.lastJson('POST'), {
        'body': {
          'type': 'doc',
          'version': 1,
          'content': [
            {
              'type': 'paragraph',
              'content': [
                {'type': 'text', 'text': 'line one'},
              ],
            },
            {
              'type': 'paragraph',
              'content': [
                {'type': 'text', 'text': 'line two'},
              ],
            },
          ],
        },
      });
    });
  });

  group('Linear', () {
    final issue = {
      'id': 'uuid-1',
      'identifier': 'ENG-42',
      'title': 'Flaky sync',
      'url': 'https://linear.app/acme/issue/ENG-42',
      'updatedAt': '2026-10-03T12:00:00.000Z',
      'state': {'id': 'st-2', 'name': 'In Progress', 'type': 'started'},
      'assignee': {'displayName': 'cy'},
      'labels': {
        'nodes': [
          {'name': 'sync'},
        ],
      },
    };

    test('queries a team, moves to a state, comments', () async {
      final answers = <Object?>[
        {
          'data': {
            'issues': {
              'nodes': [issue],
            },
          },
        },
        {
          'data': {
            'issue': {
              'team': {
                'states': {
                  'nodes': [
                    {
                      'id': 'st-3',
                      'name': 'Done',
                      'type': 'completed',
                      'position': 3,
                    },
                    {
                      'id': 'st-1',
                      'name': 'Todo',
                      'type': 'unstarted',
                      'position': 1,
                    },
                  ],
                },
              },
            },
          },
        },
        {
          'data': {
            'issueUpdate': {'success': true},
          },
        },
        {
          'data': {
            'commentCreate': {'success': true},
          },
        },
      ];
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        return http.Response(jsonEncode(answers.removeAt(0)), 200);
      });
      final source = LinearTaskSource(
        _config(TaskSourceKind.linear, {'team': 'ENG'}),
        token: _token,
        client: client,
      );
      final [task] = await source.list();
      expect(task.key, 'ENG-42');
      expect(task.id, 'uuid-1');
      expect(task.status?.category, TaskStatusCategory.inProgress);
      expect(task.labels, ['sync']);
      expect(requests.first.url, LinearTaskSource.endpoint);
      expect(requests.first.headers['authorization'], _token);
      final vars = (jsonDecode(requests.first.body) as Map)['variables'];
      expect(vars, {
        'filter': {
          'team': {
            'key': {'eq': 'ENG'},
          },
        },
      });
      final options = await source.statusOptions(task);
      expect(options.map((o) => o.label), ['Todo', 'Done']);
      expect(options.last.category, TaskStatusCategory.done);
      final moved = await source.updateStatus(task, options.last);
      expect(moved.status?.label, 'Done');
      expect((jsonDecode(requests[2].body) as Map)['variables'], {
        'id': 'uuid-1',
        'stateId': 'st-3',
      });
      await source.comment(task, 'Shipped');
      expect((jsonDecode(requests[3].body) as Map)['variables'], {
        'id': 'uuid-1',
        'body': 'Shipped',
      });
    });

    test('GraphQL errors become failures', () async {
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode({
            'errors': [
              {'message': 'Authentication required'},
            ],
          }),
          200,
        ),
      );
      final source = LinearTaskSource(
        _config(TaskSourceKind.linear, {}),
        token: _token,
        client: client,
      );
      await expectLater(
        source.list(),
        throwsA(
          isA<TaskSourceFailure>().having(
            (e) => e.message,
            'message',
            contains('Authentication required'),
          ),
        ),
      );
    });
  });

  group('Azure Boards', () {
    Map<String, Object?> item(int id, String state) => {
      'id': id,
      'fields': {
        'System.Id': id,
        'System.Title': 'Item $id',
        'System.State': state,
        'System.WorkItemType': 'Bug',
        'System.AssignedTo': {'displayName': 'Ana'},
        'System.Tags': 'mobile; ux',
        'System.ChangedDate': '2026-10-0${id}T10:00:00Z',
      },
    };

    test('WIQL then a batch read, in WIQL order', () async {
      final r = _Recorder({
        'POST /acme/My%20Project/_apis/wit/wiql': {
          'workItems': [
            {'id': 2},
            {'id': 1},
          ],
        },
        'GET /acme/My%20Project/_apis/wit/workitems': {
          'value': [item(1, 'New'), item(2, 'Active')],
        },
      });
      final source = AzureBoardsTaskSource(
        _config(TaskSourceKind.azureBoards, {
          'organization': 'acme',
          'project': 'My Project',
        }),
        token: _token,
        client: r.client,
      );
      final tasks = await source.list();
      expect(tasks.map((t) => t.id), ['2', '1']);
      expect(tasks.first.key, 'Bug 2');
      expect(tasks.first.labels, ['mobile', 'ux']);
      expect(tasks.first.status?.category, TaskStatusCategory.inProgress);
      expect(tasks.last.status?.category, TaskStatusCategory.todo);
      expect(
        tasks.first.url,
        'https://dev.azure.com/acme/My%20Project/_workitems/edit/2',
      );
      expect(r.last('GET').url.queryParameters['ids'], '2,1');
      expect(
        r.last('POST').headers['authorization'],
        'Basic ${base64Encode(utf8.encode(':$_token'))}',
      );
    });

    test('states of the type, a JSON patch, an HTML comment', () async {
      final r = _Recorder({
        'GET /acme/P/_apis/wit/workitems/1': {
          ...item(1, 'New'),
          'fields': {
            ...item(1, 'New')['fields']! as Map<String, Object?>,
            'System.Description': '<div>Hello&nbsp;<b>world</b></div>',
          },
        },
        'GET /acme/P/_apis/wit/workItems/1/comments': {
          'comments': [
            {
              'text': '<p>second</p>',
              'createdBy': {'displayName': 'Bo'},
              'createdDate': '2026-10-02T00:00:00Z',
            },
            {
              'text': '<p>first</p>',
              'createdBy': {'displayName': 'Ana'},
              'createdDate': '2026-10-01T00:00:00Z',
            },
          ],
        },
        'GET /acme/P/_apis/wit/workitemtypes/Bug/states': {
          'value': [
            {'name': 'New', 'category': 'Proposed'},
            {'name': 'Active', 'category': 'InProgress'},
            {'name': 'Closed', 'category': 'Completed'},
            {'name': 'Removed', 'category': 'Removed'},
          ],
        },
        'PATCH /acme/P/_apis/wit/workitems/1': item(1, 'Closed'),
        'POST /acme/P/_apis/wit/workItems/1/comments': {'id': 9},
      });
      final source = AzureBoardsTaskSource(
        _config(TaskSourceKind.azureBoards, {
          'organization': 'acme',
          'project': 'P',
        }),
        token: _token,
        client: r.client,
      );
      final full = await source.read(
        const TaskItem(sourceId: 's1', id: '1', key: '', title: ''),
      );
      expect(full.body, 'Hello world');
      expect(full.comments!.map((c) => c.body), ['first', 'second']);
      final options = await source.statusOptions(full);
      expect(options.map((o) => o.label), ['New', 'Active', 'Closed']);
      await source.updateStatus(full, options.last);
      final patch = r.last('PATCH');
      expect(
        patch.headers['content-type'],
        startsWith('application/json-patch+json'),
      );
      expect(jsonDecode(patch.body), [
        {'op': 'add', 'path': '/fields/System.State', 'value': 'Closed'},
      ]);
      await source.comment(full, 'a <b>\nb');
      expect(r.lastJson('POST'), {'text': 'a &lt;b&gt;<br>b'});
    });
  });

  test('every kind declares its capabilities and fields', () {
    for (final kind in TaskSourceKind.values) {
      expect(kind.fields, isNotEmpty, reason: kind.label);
      expect(TaskSourceKind.parse(kind.wire), kind);
    }
    expect(TaskSourceKind.markdownFolder.needsToken, isFalse);
    expect(TaskSourceKind.github.needsToken, isTrue);
  });
}
