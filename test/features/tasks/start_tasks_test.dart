import 'package:conduit/features/agent_attention/domain/agent_kinds.dart';
import 'package:conduit/features/tasks/domain/task_source.dart';
import 'package:conduit/features/tasks/presentation/start_tasks_page.dart';
import 'package:conduit/features/tasks/presentation/task_runs_controller.dart';
import 'package:conduit/features/tasks/presentation/task_runs_panel.dart';
import 'package:conduit/features/tasks/presentation/task_sources_controller.dart';
import 'package:conduit/features/tasks/presentation/tasks_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'task_fakes.dart';

/// The start UI (CON-037): Start on a task and "Start N tasks", every
/// choice reaching the companion's task-start, automatic machines spread
/// by load, and the batches with their progress.
void main() {
  late TaskSourcesController sources;
  late TaskRunsController runs;
  late List<(String, String, Map<String, Object?>?)> calls;
  late Map<String, List<Map<String, Object?>>> companionRuns;
  String? storedDefaults;

  Map<String, Object?> run(
    String id, {
    String status = 'running',
    String batch = 'b1',
    String? outcome,
  }) => {
    'id': id,
    'batchId': batch,
    'status': status,
    'agent': 'codex',
    'place': 'tmux',
    'task': {'ref': 'a/$id', 'key': 'K-$id', 'title': 'Task $id'},
    'branch': 'task/k-$id',
    'outcome': ?outcome,
    'createdAt': 1000,
  };

  const env = TaskStartEnvironment(machines: _machines, agentsOn: _agentsOn);

  setUp(() async {
    calls = [];
    companionRuns = {};
    storedDefaults = null;
    sources = TaskSourcesController(
      store: MemoryTaskSourcesStore(),
      build: (config, token) => FakeTaskSource(
        config,
        tasks: [
          task('a', '1', updated: DateTime.utc(2026, 10, 3)),
          task('a', '2', updated: DateTime.utc(2026, 10, 2)),
          task('a', '3', updated: DateTime.utc(2026, 10)),
        ],
      ),
    );
    await sources.save(
      const TaskSourceConfig(id: 'a', kind: TaskSourceKind.linear, name: 'A'),
      token: 't',
    );
    await sources.refresh();
    runs = TaskRunsController(
      call: (hostId, args, {stdin}) async {
        calls.add((hostId, args, stdin));
        if (args == 'task-start -') {
          final tasks = stdin!['tasks']! as List;
          final made = [
            for (final t in tasks)
              run((t as Map)['ref'].toString().split('/').last),
          ];
          (companionRuns[hostId] ??= []).addAll(made);
          return {'ok': true, 'runs': made};
        }
        return {'ok': true, 'runs': companionRuns[hostId] ?? []};
      },
      sources: sources,
      loadSynced: () async => [],
      saveSynced: (_) async {},
      loadDefaults: () async => storedDefaults,
      saveDefaults: (json) async => storedDefaults = json,
    );
  });

  Future<void> pumpList(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: TasksPage(
          controller: sources,
          machines: () => const [],
          runs: runs,
          startEnvironment: env,
          hostName: (id) => 'Machine $id',
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> scrollTo(WidgetTester tester, String key) async {
    await tester.scrollUntilVisible(
      find.byKey(ValueKey(key)),
      200,
      scrollable: find
          .descendant(
            of: find.byType(ListView).last,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
  }

  testWidgets('Start on one task sends every choice', (tester) async {
    await pumpList(tester);
    await tester.tap(find.byKey(const ValueKey('task-a/1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('task-start')));
    await tester.pumpAndSettle();
    expect(find.text('Start task'), findsOneWidget);

    // Two machines: automatic by default.
    expect(find.text('Automatic (least busy)'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('start-machine')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Box two').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('start-repo')),
      '~/src/app',
    );
    // Box two has Claude and Codex.
    expect(find.byKey(const ValueKey('start-agent-codex')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('start-agent-codex')));
    await tester.tap(find.text('tmux window'));
    await tester.pumpAndSettle();
    await scrollTo(tester, 'start-attempts');
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('start-attempts')),
        matching: find.byIcon(Icons.add),
      ),
    );
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('start-cap')),
        matching: find.byIcon(Icons.remove),
      ),
    );
    await scrollTo(tester, 'start-mark-done');
    await tester.tap(find.byKey(const ValueKey('start-mark-done')));
    await tester.pumpAndSettle();
    await scrollTo(tester, 'start-submit');
    expect(find.text('Start 2 runs'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('start-submit')));
    await tester.pumpAndSettle();

    final (host, args, stdin) = calls.firstWhere((c) => c.$2 == 'task-start -');
    expect(host, 'h2');
    expect(args, 'task-start -');
    expect(stdin!['repo'], '~/src/app');
    expect(stdin['agent'], 'codex');
    expect(stdin['place'], 'tmux');
    expect(stdin['attempts'], 2);
    expect(stdin['cap'], 2);
    expect(stdin['markDone'], isTrue);
    expect(stdin.containsKey('worktree'), isFalse, reason: 'on by default');
    final item = (stdin['tasks']! as List).single as Map;
    expect(item['ref'], 'a/1');
    expect(item['prompt'], contains('Body of 1'));
    expect(find.textContaining('started or queued'), findsOneWidget);

    // The choices are remembered for the next Start.
    expect(storedDefaults, contains('"place":"tmux"'));
    expect(storedDefaults, contains('"repoBySource":{"a":"~/src/app"}'));
  });

  testWidgets('select several: Start N tasks spreads them automatically', (
    tester,
  ) async {
    // h1 is already busy with two runs.
    companionRuns['h1'] = [run('x'), run('y')];
    await runs.refresh('h1');
    await pumpList(tester);
    await tester.longPress(find.byKey(const ValueKey('task-a/1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('task-a/2')));
    await tester.tap(find.byKey(const ValueKey('task-a/3')));
    await tester.pumpAndSettle();
    expect(find.text('Start 3 tasks'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('tasks-start-selected')));
    await tester.pumpAndSettle();
    expect(find.text('Start 3 tasks'), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('start-repo')), '~/app');
    // Automatic: only agents on both machines (Claude).
    expect(find.byKey(const ValueKey('start-agent-claude')), findsOneWidget);
    expect(find.byKey(const ValueKey('start-agent-codex')), findsNothing);
    await scrollTo(tester, 'start-worktree');
    await tester.tap(find.byKey(const ValueKey('start-worktree')));
    await tester.pumpAndSettle();
    await scrollTo(tester, 'start-submit');
    await tester.tap(find.byKey(const ValueKey('start-submit')));
    await tester.pumpAndSettle();

    final starts = calls.where((c) => c.$2 == 'task-start -').toList();
    final byHost = {
      for (final (host, _, stdin) in starts)
        host: [for (final t in stdin!['tasks']! as List) (t as Map)['ref']],
    };
    // h2 is idle, so it takes tasks until it is as busy as h1.
    expect(byHost, {
      'h2': ['a/1', 'a/2'],
      'h1': ['a/3'],
    });
    expect(starts.first.$3!['worktree'], isFalse);
    expect(find.text('Tasks'), findsOneWidget, reason: 'selection cleared');
  });

  testWidgets('batches show their progress', (tester) async {
    companionRuns['h1'] = [
      run('1', status: 'finished', outcome: 'done'),
      run('2'),
      run('3', status: 'queued'),
      run('4', status: 'failed'),
      run('9', batch: 'b2'),
    ];
    await runs.refresh('h1');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: TaskBatchesPanel(
              watch: false,
              controller: runs,
              hostName: (id) => 'Machine $id',
            ),
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('task-batch-b1')), findsOneWidget);
    expect(find.byKey(const ValueKey('task-batch-b2')), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('task-batch-summary-b1')))
          .data,
      '1 finished · 1 running · 1 waiting · 1 failed or stopped',
    );
    final bar = tester.widget<LinearProgressIndicator>(
      find.byKey(const ValueKey('task-batch-progress-b1')),
    );
    expect(bar.value, 0.5);
    expect(
      find.textContaining('Codex · Machine h1 · tmux window'),
      findsWidgets,
    );
  });

  testWidgets('no machine can start tasks: Start says so', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: StartTasksPage(
          tasks: [sources.allTasks.first],
          sources: sources,
          runs: runs,
          environment: const TaskStartEnvironment(
            machines: _none,
            agentsOn: _agentsOn,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('needs updating'), findsOneWidget);
    await scrollTo(tester, 'start-submit');
    await tester.tap(find.byKey(const ValueKey('start-submit')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('start-error')), findsOneWidget);
    expect(calls.where((c) => c.$2 == 'task-start -'), isEmpty);
  });
}

List<({String id, String name})> _machines() => const [
  (id: 'h1', name: 'Box one'),
  (id: 'h2', name: 'Box two'),
];

List<({String id, String name})> _none() => const [];

Future<List<KnownAgentKind>> _agentsOn(String hostId) async => [
  knownAgentKinds.first,
  if (hostId == 'h2') knownAgentKinds[1],
];
