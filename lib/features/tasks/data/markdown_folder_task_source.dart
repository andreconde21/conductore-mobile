import 'dart:convert';

import 'package:conduit/features/agent_attention/data/conductore_host_attention_provider.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/tasks/data/task_http.dart';
import 'package:conduit/features/tasks/domain/task_source.dart';

/// Runs `conductore-hostd tasks <op> -` on machine [hostId] with [input]
/// as its stdin; the decoded reply.
typedef CompanionTasksCall =
    Future<Map<String, Object?>> Function(
      String hostId,
      String op,
      Map<String, Object?> input,
    );

/// The open markdown tasks folder (docs/task-sources.md) on one machine,
/// through its companion's `tasks` command: the companion only touches
/// that folder.
class MarkdownFolderTaskSource implements TaskSource {
  MarkdownFolderTaskSource(this.config, {required this.call});

  @override
  final TaskSourceConfig config;
  final CompanionTasksCall call;

  /// Statuses seen by the last [list], after the format's defaults.
  List<String> _statuses = const [];

  @override
  TaskSourceCapabilities get capabilities => config.kind.capabilities;

  Future<Map<String, Object?>> _run(
    String op, [
    Map<String, Object?> extra = const {},
  ]) {
    final host = config['host'];
    final folder = config['folder'];
    if (host == null || folder == null) {
      throw const TaskSourceFailure(
        'bad-config',
        'Pick a machine and a folder.',
      );
    }
    return call(host, op, {'folder': folder, ...extra});
  }

  TaskItem _task(Map<Object?, Object?> json) {
    final status = str(json['status']);
    return TaskItem(
      sourceId: config.id,
      id: str(json['id']) ?? '',
      key: str(json['key']) ?? str(json['id']) ?? '',
      title: str(json['title']) ?? '',
      status: status == null || status.isEmpty
          ? null
          : TaskStatusOption.named(status),
      assignees: [
        if (json['assignees'] case final List<Object?> list)
          for (final a in list)
            if (a is String) a,
      ],
      labels: [
        if (json['labels'] case final List<Object?> list)
          for (final l in list)
            if (l is String) l,
      ],
      updatedAt:
          parseTime(json['updatedAt']) ??
          (json['mtimeMs'] is num
              ? DateTime.fromMillisecondsSinceEpoch(
                  (json['mtimeMs']! as num).toInt(),
                )
              : null),
      body: str(json['body']),
      comments: json['comments'] is List
          ? [
              for (final c in json['comments']! as List)
                if (c is Map)
                  TaskComment(
                    author: str(c['author']) ?? '?',
                    body: str(c['body']) ?? '',
                    at: parseTime(c['createdAt']),
                  ),
            ]
          : null,
      extra: {
        if (json['priority'] case final String p when p.isNotEmpty)
          'priority': p,
      },
    );
  }

  TaskItem _one(Map<String, Object?> json) {
    final task = json['task'];
    if (task is! Map) {
      throw const TaskSourceFailure('failed', 'The companion sent no task.');
    }
    return _task(task);
  }

  @override
  Future<List<TaskItem>> list() async {
    final json = await _run('list');
    _statuses = [
      if (json['statuses'] case final List<Object?> list)
        for (final s in list)
          if (s is String) s,
    ];
    final tasks = [
      if (json['tasks'] case final List<Object?> list)
        for (final t in list)
          if (t is Map) _task(t),
    ];
    tasks.sort(
      (a, b) =>
          (b.updatedAt ?? DateTime(0)).compareTo(a.updatedAt ?? DateTime(0)),
    );
    return tasks;
  }

  @override
  Future<TaskItem> read(TaskItem task) async =>
      _one(await _run('read', {'id': task.id}));

  @override
  Future<List<TaskStatusOption>> statusOptions(TaskItem task) async {
    if (_statuses.isEmpty) await list();
    return [
      for (final s in {..._statuses, ?task.status?.id})
        TaskStatusOption.named(s),
    ];
  }

  @override
  Future<TaskItem> updateStatus(TaskItem task, TaskStatusOption status) async =>
      _one(await _run('status', {'id': task.id, 'status': status.id}));

  @override
  Future<void> comment(TaskItem task, String text) async {
    await _run('comment', {'id': task.id, 'text': text});
  }
}

/// [CompanionTasksCall] over a machine's command runner: the JSON goes on
/// stdin, never in the command line.
Future<Map<String, Object?>> runCompanionTasks(
  AgentCommandRunner runner,
  String op,
  Map<String, Object?> input,
) => runCompanionJson(
  runner,
  'tasks $op -',
  stdin: input,
  outdated: 'Update the companion on that machine: it predates task folders.',
);

/// `conductore-hostd <args>` on [runner], [stdin] as JSON on its input;
/// the decoded reply, or a [TaskSourceFailure] with the companion's code.
Future<Map<String, Object?>> runCompanionJson(
  AgentCommandRunner runner,
  String args, {
  Map<String, Object?>? stdin,
  String outdated = 'Update the companion on that machine.',
  Duration timeout = const Duration(seconds: 20),
}) async {
  final command = ConductoreHostAttentionProvider.remoteCommand(args);
  final AgentCommandResult result;
  if (stdin != null) {
    if (runner is! StdinAgentCommandRunner) {
      throw const TaskSourceFailure(
        'unsupported',
        'This connection cannot pass data on stdin.',
      );
    }
    result = await runner.runWithStdin(
      command,
      stdin: jsonEncode(stdin),
      timeout: timeout,
    );
  } else {
    result = await runner.run(command, timeout: timeout);
  }
  final stderr = result.stderr.trim();
  if (result.exitCode == 127 || stderr.contains('not found')) {
    throw const TaskSourceFailure(
      'not-installed',
      'The Conductore companion is not installed on that machine.',
    );
  }
  Map<String, Object?>? json;
  try {
    final decoded = jsonDecode(result.stdout.trim().split('\n').last);
    if (decoded is Map) json = Map<String, Object?>.from(decoded);
  } catch (_) {}
  if (json == null) {
    throw TaskSourceFailure(
      'failed',
      stderr.isNotEmpty ? stderr : 'The companion gave no answer.',
    );
  }
  if (json['error'] case final String message) {
    if (message.startsWith('unknown command')) {
      throw TaskSourceFailure('outdated', outdated);
    }
    throw TaskSourceFailure(str(json['code']) ?? 'failed', message);
  }
  return json;
}
