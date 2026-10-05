import 'dart:convert';

import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/tasks/data/markdown_folder_task_source.dart';
import 'package:conduit/features/tasks/data/task_source_factory.dart';
import 'package:conduit/features/tasks/domain/task_source.dart';
import 'package:conduit/features/tasks/presentation/task_sources_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'task_fakes.dart';

void main() {
  group('TaskSourcesController', () {
    test('sources and tokens are stored apart; remove drops both', () async {
      final store = MemoryTaskSourcesStore();
      final c = TaskSourcesController(
        store: store,
        build: (config, token) => FakeTaskSource(config),
      );
      const gh = TaskSourceConfig(
        id: 'gh',
        kind: TaskSourceKind.github,
        name: 'App',
        settings: {'repo': 'acme/app'},
      );
      await c.save(gh, token: 'secret-1');
      expect(store.tokens, {'gh': 'secret-1'});
      expect(store.sources, isNot(contains('secret-1')));
      expect(
        (jsonDecode(store.sources!) as List).single,
        containsPair('kind', 'github'),
      );
      // An empty token on edit keeps the saved one.
      await c.save(gh.copyWith(name: 'Renamed'), token: '');
      expect(store.tokens['gh'], 'secret-1');
      expect(await c.hasToken('gh'), isTrue);

      final again = TaskSourcesController(
        store: store,
        build: (config, token) => FakeTaskSource(config),
      );
      await again.ensureLoaded();
      expect(again.sources.single.name, 'Renamed');

      await again.remove('gh');
      expect(store.tokens, isEmpty);
      expect(jsonDecode(store.sources!), isEmpty);
    });

    test(
      'refresh merges sources newest first and keeps errors per source',
      () async {
        final store = MemoryTaskSourcesStore();
        final c = TaskSourcesController(
          store: store,
          build: (config, token) => config.id == 'bad'
              ? FakeTaskSource(
                  config,
                  failure: 'GitHub refused the token (401).',
                )
              : FakeTaskSource(
                  config,
                  tasks: [
                    task(config.id, '1', updated: DateTime.utc(2026, 10)),
                    task(config.id, '2', updated: DateTime.utc(2026, 10, 3)),
                  ],
                ),
        );
        await c.save(
          const TaskSourceConfig(
            id: 'a',
            kind: TaskSourceKind.linear,
            name: 'A',
          ),
        );
        await c.save(
          const TaskSourceConfig(
            id: 'bad',
            kind: TaskSourceKind.github,
            name: 'Bad',
          ),
        );
        await c.refresh();
        expect(c.allTasks.map((t) => t.ref), ['a/2', 'a/1']);
        expect(c.tasksOf('bad').error, contains('401'));
        expect(c.loadingTasks, isFalse);
      },
    );

    test('updateStatus replaces the task in the list', () async {
      final c = TaskSourcesController(
        store: MemoryTaskSourcesStore(),
        build: (config, token) =>
            FakeTaskSource(config, tasks: [task(config.id, '1')]),
      );
      await c.save(
        const TaskSourceConfig(id: 'a', kind: TaskSourceKind.linear, name: 'A'),
      );
      await c.refresh();
      final done = TaskStatusOption.named('done');
      await c.updateStatus(c.allTasks.single, done);
      expect(c.allTasks.single.status, done);
    });

    test('test() checks required fields before any call', () async {
      var built = 0;
      final c = TaskSourcesController(
        store: MemoryTaskSourcesStore(),
        build: (config, token) {
          built++;
          return FakeTaskSource(config);
        },
      );
      await expectLater(
        c.test(
          const TaskSourceConfig(
            id: 'j',
            kind: TaskSourceKind.jira,
            name: 'J',
            settings: {'site': 'https://x.atlassian.net', 'email': 'a@b.c'},
          ),
        ),
        throwsA(
          isA<TaskSourceFailure>().having(
            (e) => e.message,
            'message',
            contains('Project key or JQL'),
          ),
        ),
      );
      expect(built, 0);
    });

    test('a tracker without a token is refused before any request', () {
      expect(
        () => createTaskSource(
          const TaskSourceConfig(
            id: 'g',
            kind: TaskSourceKind.github,
            name: 'G',
            settings: {'repo': 'a/b'},
          ),
          token: null,
          companion: (_, _, _) async => {},
        ),
        throwsA(isA<TaskSourceFailure>()),
      );
    });
  });

  test('sorting is the same whichever sources are combined', () async {
    final c = TaskSourcesController(
      store: MemoryTaskSourcesStore(),
      build: (config, token) => FakeTaskSource(config),
    );
    await c.save(
      const TaskSourceConfig(
        id: 'b',
        kind: TaskSourceKind.linear,
        name: 'Beta',
      ),
    );
    await c.save(
      const TaskSourceConfig(id: 'a', kind: TaskSourceKind.jira, name: 'Alpha'),
    );
    final same = DateTime.utc(2026, 10);
    final tasks = [
      task('b', '10', updated: same),
      task('a', '9', updated: same),
      task('a', '10', updated: same),
      task('b', '2', status: 'done', updated: DateTime.utc(2026, 10, 5)),
    ];
    List<String> refs(TaskSort s) => [
      for (final t in c.sorted(tasks, s)) t.ref,
    ];
    expect(refs(TaskSort.updated), ['b/2', 'a/9', 'a/10', 'b/10']);
    expect(refs(TaskSort.status), ['a/9', 'a/10', 'b/10', 'b/2']);
    expect(refs(TaskSort.source), ['a/9', 'a/10', 'b/2', 'b/10']);
    expect(refs(TaskSort.key), ['a/9', 'a/10', 'b/2', 'b/10']);
    // A subset keeps the relative order of the whole.
    final subset = c.sorted(tasks.where((t) => t.sourceId == 'a').toList());
    expect(subset.map((t) => t.ref), ['a/9', 'a/10']);
  });

  group('TaskFilter', () {
    final tasks = [
      task('a', '1', assignees: ['ana']),
      task('a', '2', status: 'done'),
      task('b', '3', assignees: ['bo'], title: 'Fix login'),
    ];

    List<String> ids(TaskFilter f) => [
      for (final t in tasks)
        if (f.matches(t)) t.id,
    ];

    test('by source, status, assignee, nobody and text', () {
      expect(ids(const TaskFilter(sourceIds: {'a'})), ['1', '2']);
      expect(ids(const TaskFilter(sourceIds: {'a', 'b'})), ['1', '2', '3']);
      expect(ids(const TaskFilter(sourceIds: {})), isEmpty);
      expect(ids(const TaskFilter(status: 'todo')), ['1', '3']);
      expect(ids(const TaskFilter(assignee: 'bo')), ['3']);
      expect(ids(const TaskFilter(assignee: TaskFilter.unassigned)), ['2']);
      expect(ids(const TaskFilter(query: 'LOGIN')), ['3']);
      expect(ids(const TaskFilter(sourceIds: {'a'}, status: 'todo')), ['1']);
    });
  });

  group('markdown folder', () {
    test('sends the folder and id to the companion', () async {
      final calls = <(String, String, Map<String, Object?>)>[];
      final source = MarkdownFolderTaskSource(
        const TaskSourceConfig(
          id: 'md',
          kind: TaskSourceKind.markdownFolder,
          name: 'Cards',
          settings: {'host': 'h1', 'folder': '~/tasks'},
        ),
        call: (host, op, input) async {
          calls.add((host, op, input));
          return switch (op) {
            'list' => {
              'ok': true,
              'statuses': ['backlog', 'todo', 'done', 'verify'],
              'tasks': [
                {
                  'id': 'CON-1',
                  'key': 'CON-1',
                  'title': 'One',
                  'status': 'todo',
                  'assignees': ['andre'],
                  'labels': <String>[],
                  'updatedAt': '2026-10-01T00:00:00Z',
                },
                {
                  'id': 'CON-2',
                  'title': 'Two',
                  'status': 'verify',
                  'mtimeMs': DateTime.utc(2026, 10, 2).millisecondsSinceEpoch,
                },
              ],
            },
            'status' || 'read' => {
              'ok': true,
              'task': {
                'id': 'CON-1',
                'title': 'One',
                'status': input['status'] ?? 'todo',
                'body': 'Body',
                'comments': [
                  {
                    'author': 'ana',
                    'createdAt': '2026-10-01T10:00:00Z',
                    'body': 'hi',
                  },
                ],
              },
            },
            _ => {'ok': true},
          };
        },
      );
      final tasks = await source.list();
      expect(tasks.map((t) => t.id), ['CON-2', 'CON-1']);
      expect(tasks.first.status?.category, TaskStatusCategory.inProgress);
      expect(calls.single.$1, 'h1');
      expect(calls.single.$2, 'list');
      expect(calls.single.$3, {'folder': '~/tasks'});
      final options = await source.statusOptions(tasks.last);
      expect(options.map((o) => o.id), ['backlog', 'todo', 'done', 'verify']);
      final moved = await source.updateStatus(tasks.last, options[2]);
      expect(moved.status?.id, 'done');
      expect(moved.comments!.single.author, 'ana');
      expect(calls.last.$3, {
        'folder': '~/tasks',
        'id': 'CON-1',
        'status': 'done',
      });
      await source.comment(tasks.last, 'Started');
      expect(calls.last.$2, 'comment');
      expect(calls.last.$3['text'], 'Started');
    });

    test(
      'a folder of project folders: project/id ids and the project',
      () async {
        final calls = <(String, Map<String, Object?>)>[];
        final source = MarkdownFolderTaskSource(
          const TaskSourceConfig(
            id: 'pt',
            kind: TaskSourceKind.markdownFolder,
            name: 'ProjectsTasks',
            settings: {'host': 'h1', 'folder': '/data/projectstasks'},
          ),
          call: (host, op, input) async {
            calls.add((op, input));
            final card = {
              'id': 'conductore-mobile/CON-084',
              'key': 'CON-084',
              'title': 'Tree',
              'status': input['status'] ?? 'todo',
              'project': 'conductore-mobile',
            };
            return op == 'list'
                ? {
                    'ok': true,
                    'projects': ['amedia', 'conductore-mobile'],
                    'tasks': [
                      card,
                      {'id': 'amedia/AM-1', 'title': 'A', 'project': 'amedia'},
                      {'id': 'FLAT-1', 'title': 'Flat', 'project': ''},
                    ],
                  }
                : {'ok': true, 'task': card};
          },
        );
        final tasks = await source.list();
        final card = tasks.firstWhere((t) => t.key == 'CON-084');
        expect(card.project, 'conductore-mobile');
        expect(card.ref, 'pt/conductore-mobile/CON-084');
        expect(
          tasks.firstWhere((t) => t.id == 'amedia/AM-1').project,
          'amedia',
        );
        expect(tasks.firstWhere((t) => t.id == 'FLAT-1').project, isNull);
        final moved = await source.updateStatus(
          card,
          TaskStatusOption.named('done'),
        );
        expect(calls.last.$2['id'], 'conductore-mobile/CON-084');
        expect(moved.project, 'conductore-mobile');
        expect(moved.copyWith(body: 'b').project, 'conductore-mobile');
      },
    );

    test('the project filter keeps one project', () {
      const filter = TaskFilter(project: 'amedia');
      expect(filter.matches(task('pt', 'amedia/1', project: 'amedia')), isTrue);
      expect(filter.matches(task('pt', 'cm/1', project: 'cm')), isFalse);
      expect(filter.matches(task('pt', 'flat')), isFalse);
      expect(const TaskFilter().matches(task('pt', 'flat')), isTrue);
    });

    test('runCompanionTasks passes JSON on stdin and maps errors', () async {
      final runner = FakeStdinRunner(
        (command, stdin) => const AgentCommandResult(
          stdout: '{"error":"no task X","code":"not-found"}\n',
          stderr: '',
          exitCode: 1,
        ),
      );
      await expectLater(
        runCompanionTasks(runner, 'read', {'folder': '/t', 'id': 'X'}),
        throwsA(
          isA<TaskSourceFailure>().having((e) => e.code, 'code', 'not-found'),
        ),
      );
      expect(runner.commands.single, contains('tasks read -'));
      expect(runner.commands.single, isNot(contains('/t')));
      expect(jsonDecode(runner.stdins.single), {'folder': '/t', 'id': 'X'});

      final old = FakeStdinRunner(
        (_, _) => const AgentCommandResult(
          stdout: '{"error":"unknown command: tasks"}',
          stderr: '',
          exitCode: 1,
        ),
      );
      await expectLater(
        runCompanionTasks(old, 'list', {'folder': '/t'}),
        throwsA(
          isA<TaskSourceFailure>().having((e) => e.code, 'code', 'outdated'),
        ),
      );
    });
  });
}
