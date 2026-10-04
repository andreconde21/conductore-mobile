import 'dart:convert';

import 'package:conduit/features/tasks/data/github_projects_task_source.dart';
import 'package:conduit/features/tasks/domain/task_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'http_recorder.dart';

/// GitHub Projects v2 over GraphQL, against recorded answers.
void main() {
  Map<String, Object?> item(String id, String status, {bool draft = false}) => {
    'id': id,
    'updatedAt': '2026-10-0${id.substring(id.length - 1)}T10:00:00Z',
    'fieldValueByName': {'name': status, 'optionId': 'opt-$status'},
    'content': draft
        ? {
            '__typename': 'DraftIssue',
            'id': 'DI_$id',
            'title': 'Draft $id',
            'assignees': {'nodes': <Object?>[]},
          }
        : {
            '__typename': 'Issue',
            'id': 'I_$id',
            'number': 7,
            'title': 'Issue $id',
            'url': 'https://github.com/acme/app/issues/7',
            'repository': {'name': 'app'},
            'assignees': {
              'nodes': [
                {'login': 'ana'},
              ],
            },
            'labels': {
              'nodes': [
                {'name': 'bug'},
              ],
            },
          },
  };

  Map<String, Object?> page(List<Object?> nodes, {String? next}) => {
    'data': {
      'repositoryOwner': {
        'projectV2': {
          'id': 'PVT_1',
          'field': {
            'id': 'F_status',
            'options': [
              {'id': 'opt-Todo', 'name': 'Todo'},
              {'id': 'opt-In Progress', 'name': 'In Progress'},
              {'id': 'opt-Done', 'name': 'Done'},
            ],
          },
          'items': {
            'nodes': nodes,
            'pageInfo': {'hasNextPage': next != null, 'endCursor': next},
          },
        },
      },
    },
  };

  test('lists items across pages with the status field', () async {
    final bodies = <Map<Object?, Object?>>[];
    final answers = [
      page([item('i1', 'Todo')], next: 'c1'),
      page([item('i2', 'Done', draft: true)]),
      {
        'data': {
          'updateProjectV2ItemFieldValue': {
            'projectV2Item': {'id': 'i1'},
          },
        },
      },
      {
        'data': {
          'addComment': {'clientMutationId': null},
        },
      },
    ];
    final client = MockClient((request) async {
      bodies.add(jsonDecode(request.body) as Map);
      expect(request.url.toString(), 'https://api.github.com/graphql');
      expect(request.headers['authorization'], 'Bearer $fakeToken');
      return jsonResponse(answers.removeAt(0), 200);
    });
    final source = GitHubProjectsTaskSource(
      sourceConfig(TaskSourceKind.githubProjects, {
        'owner': 'acme',
        'number': '3',
      }),
      token: fakeToken,
      client: client,
    );
    final tasks = await source.list();
    expect(tasks.map((t) => t.id), ['i2', 'i1'], reason: 'newest first');
    final issue = tasks.last;
    expect(issue.key, 'app#7');
    expect(issue.status?.label, 'Todo');
    expect(issue.status?.category, TaskStatusCategory.todo);
    expect(issue.assignees, ['ana']);
    expect(issue.labels, ['bug']);
    expect(tasks.first.key, 'Draft');
    expect(tasks.first.status?.category, TaskStatusCategory.done);
    expect(bodies[0]['variables'], {
      'owner': 'acme',
      'number': 3,
      'field': 'Status',
    });
    expect((bodies[1]['variables'] as Map)['after'], 'c1');

    final options = await source.statusOptions(issue);
    expect(options.map((o) => o.label), ['Todo', 'In Progress', 'Done']);
    final moved = await source.updateStatus(issue, options.last);
    expect(moved.status?.label, 'Done');
    expect(bodies[2]['variables'], {
      'project': 'PVT_1',
      'item': 'i1',
      'field': 'F_status',
      'option': 'opt-Done',
    });
    await source.comment(issue, 'Shipped');
    expect(bodies[3]['variables'], {'subject': 'I_i1', 'body': 'Shipped'});
    await expectLater(
      source.comment(tasks.first, 'x'),
      throwsA(isA<TaskSourceFailure>()),
    );
  });

  test('reads the body and comments of the item content', () async {
    final client = MockClient(
      (request) async => jsonResponse({
        'data': {
          'node': {
            ...item('i1', 'Todo'),
            'content': {
              ...item('i1', 'Todo')['content']! as Map<String, Object?>,
              'body': 'Steps',
              'comments': {
                'nodes': [
                  {
                    'author': {'login': 'bo'},
                    'body': 'Same here',
                    'createdAt': '2026-10-02T00:00:00Z',
                  },
                ],
              },
            },
          },
        },
      }, 200),
    );
    final full = await GitHubProjectsTaskSource(
      sourceConfig(TaskSourceKind.githubProjects, {
        'owner': 'acme',
        'number': '3',
        'statusField': 'Stage',
      }),
      token: fakeToken,
      client: client,
    ).read(itemRef('i1'));
    expect(full.body, 'Steps');
    expect(full.comments!.single.author, 'bo');
  });

  test('GHES endpoint, missing project and bad number', () async {
    final asked = <Uri>[];
    final client = MockClient((request) async {
      asked.add(request.url);
      return jsonResponse({
        'data': {'repositoryOwner': null},
      }, 200);
    });
    final ghes = GitHubProjectsTaskSource(
      sourceConfig(TaskSourceKind.githubProjects, {
        'owner': 'acme',
        'number': '3',
        'apiBase': 'https://ghe.example.com/api/v3',
      }),
      token: fakeToken,
      client: client,
    );
    await expectLater(
      ghes.list(),
      throwsA(
        isA<TaskSourceFailure>().having((e) => e.code, 'code', 'not-found'),
      ),
    );
    expect(asked.single.toString(), 'https://ghe.example.com/api/graphql');
    final bad = GitHubProjectsTaskSource(
      sourceConfig(TaskSourceKind.githubProjects, {
        'owner': 'acme',
        'number': 'x',
      }),
      token: fakeToken,
      client: http.Client(),
    );
    await expectLater(
      bad.list(),
      throwsA(
        isA<TaskSourceFailure>().having((e) => e.code, 'code', 'bad-config'),
      ),
    );
  });
}
