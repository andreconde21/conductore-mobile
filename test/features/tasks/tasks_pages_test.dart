import 'package:conduit/features/tasks/domain/task_source.dart';
import 'package:conduit/features/tasks/presentation/task_sources_controller.dart';
import 'package:conduit/features/tasks/presentation/tasks_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'task_fakes.dart';

void main() {
  late MemoryTaskSourcesStore store;
  late Map<String, FakeTaskSource> sources;
  late TaskSourcesController controller;

  setUp(() {
    store = MemoryTaskSourcesStore();
    sources = {};
    controller = TaskSourcesController(
      store: store,
      build: (config, token) => sources[config.id] ??= FakeTaskSource(
        config,
        tasks: config.id == 'a'
            ? [
                task('a', '1', assignees: ['ana']),
                task('a', '2', status: 'done', title: 'Shipped thing'),
              ]
            : [
                task('b', '3', status: 'in-progress', assignees: ['bo']),
              ],
      ),
    );
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: TasksPage(
          controller: controller,
          machines: () => [(id: 'h1', name: 'Box')],
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> addTwoSources() async {
    await controller.save(
      const TaskSourceConfig(id: 'a', kind: TaskSourceKind.linear, name: 'A'),
      token: 't',
    );
    await controller.save(
      const TaskSourceConfig(id: 'b', kind: TaskSourceKind.github, name: 'B'),
      token: 't',
    );
  }

  testWidgets('no sources: offers to add one', (tester) async {
    await pump(tester);
    expect(find.byKey(const ValueKey('tasks-add-source')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('tasks-add-source')));
    await tester.pumpAndSettle();
    expect(find.text('Task sources'), findsOneWidget);
  });

  testWidgets('lists every source and filters by source, status, assignee', (
    tester,
  ) async {
    await addTwoSources();
    await pump(tester);
    expect(find.byKey(const ValueKey('task-a/1')), findsOneWidget);
    expect(find.byKey(const ValueKey('task-a/2')), findsOneWidget);
    expect(find.byKey(const ValueKey('task-b/3')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('tasks-filter-status')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('done').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('task-a/2')), findsOneWidget);
    expect(find.byKey(const ValueKey('task-a/1')), findsNothing);
    expect(find.byKey(const ValueKey('task-b/3')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('tasks-filter-status')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Any status'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('tasks-filter-assignee')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('bo').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('task-b/3')), findsOneWidget);
    expect(find.byKey(const ValueKey('task-a/1')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('tasks-filter-assignee')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Any assignee'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('tasks-filter-source')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('A').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('task-b/3')), findsNothing);
    expect(find.byKey(const ValueKey('task-a/1')), findsOneWidget);
  });

  testWidgets('a task opens: change its status, add a comment', (tester) async {
    await addTwoSources();
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('task-a/1')));
    await tester.pumpAndSettle();
    expect(find.text('Body of 1'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('task-status')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('task-status-option-done')));
    await tester.pumpAndSettle();
    expect(sources['a']!.moves, [('1', 'done')]);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('task-status')),
        matching: find.text('done'),
      ),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const ValueKey('task-comment-field')),
      'Started from the phone',
    );
    await tester.tap(find.byKey(const ValueKey('task-comment-send')));
    await tester.pumpAndSettle();
    expect(sources['a']!.comments, [('1', 'Started from the phone')]);
    expect(find.text('Started from the phone'), findsOneWidget);

    // Back on the list, the task shows its new status.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(controller.taskByRef('a/1')!.status?.id, 'done');
  });

  testWidgets('adding a source: fields, token, test and save', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('tasks-add-source')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('task-source-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('task-source-kind-github')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('task-source-save')));
    await tester.pumpAndSettle();
    expect(find.text('Repository is missing.'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('task-source-field-repo')),
      'acme/app',
    );
    await tester.tap(find.byKey(const ValueKey('task-source-save')));
    await tester.pumpAndSettle();
    expect(find.text('Add the token.'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('task-source-token')),
      'ghp_fake',
    );
    await tester.tap(find.byKey(const ValueKey('task-source-test')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Connected: 1 task'), findsOneWidget);
    expect(store.tokens, isEmpty, reason: 'Test saves nothing');

    await tester.tap(find.byKey(const ValueKey('task-source-save')));
    await tester.pumpAndSettle();
    final saved = controller.sources.single;
    expect(saved.kind, TaskSourceKind.github);
    expect(saved['repo'], 'acme/app');
    expect(store.tokens[saved.id], 'ghp_fake');
    expect(store.sources, isNot(contains('ghp_fake')));
  });
}
