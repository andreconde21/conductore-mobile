import 'dart:async';
import 'dart:convert';

import 'package:conduit/features/agent_attention/domain/agent_kinds.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/hosts/presentation/hosts_controller.dart';
import 'package:conduit/features/sessions/data/workspace_creator.dart';
import 'package:conduit/features/tasks/data/markdown_folder_task_source.dart';
import 'package:conduit/features/tasks/data/task_source_factory.dart';
import 'package:conduit/features/tasks/domain/task_source.dart';
import 'package:conduit/features/tasks/presentation/start_tasks_page.dart';
import 'package:conduit/features/tasks/presentation/task_runs_controller.dart';
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

/// The app's machines and agents for Start (main sets it).
TaskStartEnvironment? appTaskStartEnvironment;

/// The capability of companions that start tasks (`task-start`).
const taskRunsCapability = 'task-runs';

/// The app's started tasks: through each machine's companion; the runs
/// already marked done and Start's choices stay on this device.
TaskRunsController createAppTaskRuns({
  required FlutterSecureStorage storage,
  required AgentAttentionController attention,
  required TaskSourcesController sources,
}) {
  Future<Map<String, Object?>> call(
    String hostId,
    String args, {
    Map<String, Object?>? stdin,
  }) async {
    final host = _monitored(attention, hostId);
    if (host == null) {
      throw const TaskSourceFailure(
        'not-found',
        'That machine is not connected; open a session to it first.',
      );
    }
    final (runner, :owned) = attention.runnerFor(host);
    try {
      return await runCompanionJson(
        runner,
        args,
        stdin: stdin,
        outdated:
            'Update the companion on that machine: it predates task '
            'runs.',
        timeout: const Duration(seconds: 90),
      );
    } finally {
      if (owned) unawaited(runner.close());
    }
  }

  const syncedKey = 'conductore.task_runs_synced.v1';
  const defaultsKey = 'conductore.task_start_defaults.v1';
  return TaskRunsController(
    call: call,
    sources: sources,
    loadSynced: () async {
      try {
        final raw = await storage.read(key: syncedKey);
        final list = raw == null ? null : jsonDecode(raw);
        return [
          if (list is List)
            for (final id in list)
              if (id is String) id,
        ];
      } catch (_) {
        return const [];
      }
    },
    // The last 500 are enough to never sync a run twice.
    saveSynced: (ids) => storage.write(
      key: syncedKey,
      value: jsonEncode(ids.length > 500 ? ids.sublist(ids.length - 500) : ids),
    ),
    hosts: () => [
      for (final host in attention.monitoredHosts)
        if (attention.companionSupports(host.id, taskRunsCapability)) host.id,
    ],
    loadDefaults: () => storage.read(key: defaultsKey),
    saveDefaults: (json) => storage.write(key: defaultsKey, value: json),
  );
}

SavedHost? _monitored(AgentAttentionController attention, String hostId) {
  for (final host in attention.monitoredHosts) {
    if (host.id == hostId) return host;
  }
  return null;
}

/// Monitored machines whose companion starts tasks, and their agents (the
/// New workspace picker's detection).
TaskStartEnvironment taskStartEnvironment(AgentAttentionController attention) {
  final creators = <String, WorkspaceCreator>{};
  return TaskStartEnvironment(
    machines: () {
      final seen = <String>{};
      return [
        for (final host in attention.monitoredHosts)
          if (attention.companionSupports(host.id, taskRunsCapability) &&
              seen.add(host.id))
            (id: host.id, name: host.name),
      ];
    },
    agentsOn: (hostId) async {
      final host = _monitored(attention, hostId);
      if (host == null) return const [];
      final (runner, :owned) = attention.runnerFor(host);
      try {
        // One creator per machine keeps its detection cache.
        final creator = owned
            ? WorkspaceCreator(runner)
            : creators[hostId] ??= WorkspaceCreator(runner);
        return await creator.installedAgents(
          hostId,
          agentLaunchCandidates(attention.agentKinds(hostId)),
        );
      } finally {
        if (owned) unawaited(runner.close());
      }
    },
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
    builder: (_) => TasksPage(
      controller: controller,
      machines: () => taskMachines(hosts),
      runs: TaskRunsController.instance,
      startEnvironment: appTaskStartEnvironment,
      hostName: (id) => hosts?.findById(id)?.name ?? id,
    ),
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
