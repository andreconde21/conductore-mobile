import 'dart:async';

import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/hosts/presentation/hosts_controller.dart';
import 'package:conduit/features/tasks/data/markdown_folder_task_source.dart';
import 'package:conduit/features/tasks/data/task_source_factory.dart';
import 'package:conduit/features/tasks/domain/task_source.dart';
import 'package:conduit/features/tasks/presentation/task_sources_controller.dart';
import 'package:conduit/features/tasks/presentation/task_sources_page.dart';
import 'package:conduit/features/tasks/presentation/tasks_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Where task sources (CON-039) meet the rest of the app.

/// The app's task sources: secure storage on this device (never synced),
/// the trackers over HTTPS, markdown folders through the machine's
/// companion.
TaskSourcesController createAppTaskSources({
  required FlutterSecureStorage storage,
  required HostsController hosts,
  required AgentAttentionController attention,
}) {
  Future<Map<String, Object?>> companion(
    String hostId,
    String op,
    Map<String, Object?> input,
  ) async {
    final host = hosts.findById(hostId);
    if (host == null) {
      throw const TaskSourceFailure(
        'bad-config',
        'The machine of this task folder is gone; pick another.',
      );
    }
    final (runner, :owned) = attention.runnerFor(host);
    try {
      return await runCompanionTasks(runner, op, input);
    } finally {
      if (owned) unawaited(runner.close());
    }
  }

  return TaskSourcesController(
    store: SecureTaskSourcesStore(storage),
    build: (config, token) =>
        createTaskSource(config, token: token, companion: companion),
  );
}

/// The machines a markdown folder can be on.
List<TaskMachine> taskMachines(HostsController? hosts) => [
  for (final host in hosts?.sortedHosts ?? const <SavedHost>[])
    (id: host.id, name: host.name),
];

/// The task list.
Future<void> showTasksPage(
  BuildContext context, {
  required TaskSourcesController controller,
  HostsController? hosts,
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) =>
        TasksPage(controller: controller, machines: () => taskMachines(hosts)),
  ),
);

/// Settings › Agents › Tasks (inside a SettingsCard).
class TasksSettingsTile extends StatelessWidget {
  const TasksSettingsTile({required this.controller, this.hosts, super.key});

  final TaskSourcesController controller;
  final HostsController? hosts;

  @override
  Widget build(BuildContext context) => ListTile(
    key: const ValueKey('settings-tasks'),
    leading: const Icon(Icons.task_alt_outlined),
    title: const Text('Tasks'),
    subtitle: const Text(
      'Tasks from a markdown folder, GitHub, GitLab, Jira, Linear or '
      'Azure Boards: list, open, move, comment.',
    ),
    trailing: const Icon(Icons.chevron_right_rounded),
    onTap: () =>
        unawaited(showTasksPage(context, controller: controller, hosts: hosts)),
  );
}
