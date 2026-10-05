import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/tasks/domain/task_source.dart';
import 'package:conduit/features/tasks/presentation/task_sources_controller.dart';

class MemoryTaskSourcesStore implements TaskSourcesStore {
  String? sources;
  final tokens = <String, String>{};

  @override
  Future<String?> readSources() async => sources;

  @override
  Future<void> writeSources(String json) async => sources = json;

  @override
  Future<String?> readToken(String sourceId) async => tokens[sourceId];

  @override
  Future<void> writeToken(String sourceId, String token) async =>
      tokens[sourceId] = token;

  @override
  Future<void> deleteToken(String sourceId) async => tokens.remove(sourceId);
}

TaskItem task(
  String sourceId,
  String id, {
  String status = 'todo',
  List<String> assignees = const [],
  String? title,
  DateTime? updated,
  String? project,
}) => TaskItem(
  sourceId: sourceId,
  id: id,
  key: 'K-$id',
  title: title ?? 'Task $id',
  status: TaskStatusOption.named(status),
  assignees: assignees,
  updatedAt: updated,
  project: project,
);

/// An in-memory source: [tasks], status changes and comments recorded.
class FakeTaskSource implements TaskSource {
  FakeTaskSource(this.config, {List<TaskItem>? tasks, this.failure})
    : tasks = tasks ?? [];

  @override
  final TaskSourceConfig config;
  final List<TaskItem> tasks;
  final String? failure;
  final comments = <(String, String)>[];
  final moves = <(String, String)>[];

  @override
  TaskSourceCapabilities get capabilities => config.kind.capabilities;

  void _fail() {
    if (failure != null) throw TaskSourceFailure('auth', failure!);
  }

  @override
  Future<List<TaskItem>> list() async {
    _fail();
    return [...tasks];
  }

  @override
  Future<TaskItem> read(TaskItem task) async {
    _fail();
    return task.copyWith(
      body: 'Body of ${task.id}',
      comments: [
        for (final (id, text) in comments)
          if (id == task.id) TaskComment(author: 'me', body: text),
      ],
    );
  }

  @override
  Future<List<TaskStatusOption>> statusOptions(TaskItem task) async => [
    TaskStatusOption.named('todo'),
    TaskStatusOption.named('in-progress'),
    TaskStatusOption.named('done'),
  ];

  @override
  Future<TaskItem> updateStatus(TaskItem task, TaskStatusOption status) async {
    _fail();
    moves.add((task.id, status.id));
    final next = task.copyWith(status: status);
    final i = tasks.indexWhere((t) => t.id == task.id);
    if (i != -1) tasks[i] = next;
    return next;
  }

  @override
  Future<void> comment(TaskItem task, String text) async {
    _fail();
    comments.add((task.id, text));
  }
}

class FakeStdinRunner implements StdinAgentCommandRunner {
  FakeStdinRunner(this.answer);

  final AgentCommandResult Function(String command, String stdin) answer;
  final commands = <String>[];
  final stdins = <String>[];

  @override
  Future<AgentCommandResult> run(
    String command, {
    required Duration timeout,
  }) async {
    commands.add(command);
    stdins.add('');
    return answer(command, '');
  }

  @override
  Future<AgentCommandResult> runWithStdin(
    String command, {
    required String stdin,
    required Duration timeout,
    Future<void>? cancel,
  }) async {
    commands.add(command);
    stdins.add(stdin);
    return answer(command, stdin);
  }

  @override
  Future<void> close() async {}
}
