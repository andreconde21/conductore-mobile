import 'dart:convert';

import 'package:conduit/features/tasks/data/azure_boards_task_source.dart';
import 'package:conduit/features/tasks/data/github_task_source.dart';
import 'package:conduit/features/tasks/data/gitlab_task_source.dart';
import 'package:conduit/features/tasks/data/jira_task_source.dart';
import 'package:conduit/features/tasks/data/linear_task_source.dart';
import 'package:conduit/features/tasks/data/task_http.dart';
import 'package:conduit/features/tasks/domain/task_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Paging past 100 items, up to [maxTasksPerSource], with fake answers.
const _token = 'fake-token-not-real';

http.Response _json(Object? body) =>
    http.Response.bytes(utf8.encode(jsonEncode(body)), 200);

TaskSourceConfig _config(TaskSourceKind kind, Map<String, String> settings) =>
    TaskSourceConfig(
      id: 's1',
      kind: kind,
      name: kind.label,
      settings: settings,
    );

void main() {
  test('collectPages stops at the last page and at the cap', () async {
    final pages = <Object?>[];
    final all = await collectPages<int>((cursor) async {
      pages.add(cursor);
      final n = (cursor as int?) ?? 0;
      return ([for (var i = 0; i < 100; i++) n * 100 + i], n + 1);
    });
    expect(all, hasLength(maxTasksPerSource));
    expect(pages, [null, 1, 2, 3, 4]);
  });

  test('GitHub and GitLab: page numbers until a short page', () async {
    final asked = <String>[];
    final client = MockClient((request) async {
      final page = int.parse(request.url.queryParameters['page']!);
      asked.add('${request.url.host}:$page');
      final count = page == 1 ? 100 : 30;
      return _json([
        for (var i = 0; i < count; i++)
          {
            'number': page * 1000 + i,
            'iid': page * 1000 + i,
            'title': 't',
            'state': 'open',
          },
      ]);
    });
    final gh = await GitHubTaskSource(
      _config(TaskSourceKind.github, {'repo': 'a/b'}),
      token: _token,
      client: client,
    ).list();
    expect(gh, hasLength(130));
    final gl = await GitLabTaskSource(
      _config(TaskSourceKind.gitlab, {'project': 'g/p'}),
      token: _token,
      client: client,
    ).list();
    expect(gl, hasLength(130));
    expect(asked, [
      'api.github.com:1',
      'api.github.com:2',
      'gitlab.com:1',
      'gitlab.com:2',
    ]);
  });

  test('Jira: nextPageToken until it is gone', () async {
    final tokens = <Object?>[];
    final client = MockClient((request) async {
      final body = jsonDecode(request.body) as Map;
      tokens.add(body['nextPageToken']);
      final last = body['nextPageToken'] == 'p2';
      return _json({
        'issues': [
          for (var i = 0; i < (last ? 5 : 100); i++)
            {
              'key': 'P-${tokens.length}-$i',
              'fields': {'summary': 's'},
            },
        ],
        if (!last) 'nextPageToken': 'p${tokens.length + 1}',
      });
    });
    final tasks = await JiraTaskSource(
      _config(TaskSourceKind.jira, {
        'site': 'https://x.atlassian.net',
        'email': 'a@b.c',
        'project': 'P',
      }),
      token: _token,
      client: client,
    ).list();
    expect(tasks, hasLength(105));
    expect(tokens, [null, 'p2']);
  });

  test('Linear: endCursor while hasNextPage', () async {
    final afters = <Object?>[];
    final client = MockClient((request) async {
      final vars = (jsonDecode(request.body) as Map)['variables'] as Map;
      afters.add(vars['after']);
      final more = vars['after'] == null;
      return _json({
        'data': {
          'issues': {
            'nodes': [
              for (var i = 0; i < (more ? 100 : 1); i++)
                {'id': 'i$i', 'identifier': 'E-$i', 'title': 't'},
            ],
            'pageInfo': {'hasNextPage': more, 'endCursor': 'c1'},
          },
        },
      });
    });
    final tasks = await LinearTaskSource(
      _config(TaskSourceKind.linear, {}),
      token: _token,
      client: client,
    ).list();
    expect(tasks, hasLength(101));
    expect(afters, [null, 'c1']);
  });

  test('Azure Boards: ids read 200 at a time, in WIQL order', () async {
    final batches = <int>[];
    final client = MockClient((request) async {
      if (request.method == 'POST') {
        expect(request.url.queryParameters[r'$top'], '$maxTasksPerSource');
        return _json({
          'workItems': [
            for (var i = 450; i > 0; i--) {'id': i},
          ],
        });
      }
      final ids = request.url.queryParameters['ids']!.split(',');
      batches.add(ids.length);
      return _json({
        'value': [
          for (final id in ids.reversed)
            {
              'id': int.parse(id),
              'fields': {'System.Title': 't', 'System.State': 'New'},
            },
        ],
      });
    });
    final tasks = await AzureBoardsTaskSource(
      _config(TaskSourceKind.azureBoards, {
        'organization': 'o',
        'project': 'p',
      }),
      token: _token,
      client: client,
    ).list();
    expect(batches, [200, 200, 50]);
    expect(tasks.first.id, '450');
    expect(tasks.last.id, '1');
  });
}
