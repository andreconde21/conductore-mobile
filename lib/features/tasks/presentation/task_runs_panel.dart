import 'dart:async';

import 'package:conduit/features/agent_attention/domain/agent_kinds.dart';
import 'package:conduit/features/tasks/domain/task_run.dart';
import 'package:conduit/features/tasks/presentation/task_runs_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Started tasks grouped by batch (CON-037), each batch with its progress:
/// how many finished, run, wait or failed, and every run's state. Nothing
/// when there are none, so the Agents dashboard can always mount it.
class TaskBatchesPanel extends StatefulWidget {
  const TaskBatchesPanel({
    required this.controller,
    required this.hostName,
    this.limit = 5,
    this.watch = true,
    super.key,
  });

  final TaskRunsController controller;
  final String Function(String hostId) hostName;

  /// Batches shown, newest first.
  final int limit;

  /// Starts following the machines' runs when shown.
  final bool watch;

  @override
  State<TaskBatchesPanel> createState() => _TaskBatchesPanelState();
}

class _TaskBatchesPanelState extends State<TaskBatchesPanel> {
  TaskRunsController get controller => widget.controller;
  int get limit => widget.limit;
  String Function(String hostId) get hostName => widget.hostName;

  @override
  void initState() {
    super.initState();
    if (widget.watch) unawaited(controller.watch());
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final batches = controller.batches.take(limit).toList();
      if (batches.isEmpty) return const SizedBox.shrink();
      return Column(
        key: const ValueKey('task-batches'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
            child: Text(
              'Started tasks',
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          for (final b in batches)
            TaskBatchCard(
              key: ValueKey('task-batch-${b.batchId}'),
              batch: b,
              hostName: hostName(b.hostId),
              controller: controller,
            ),
        ],
      );
    },
  );
}

/// One batch: progress, then its runs.
class TaskBatchCard extends StatelessWidget {
  const TaskBatchCard({
    required this.batch,
    required this.hostName,
    required this.controller,
    super.key,
  });

  final TaskRunBatch batch;
  final String hostName;
  final TaskRunsController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final runs = batch.runs;
    int count(bool Function(TaskRun r) test) => runs.where(test).length;
    final finished = count((r) => r.status == TaskRunStatus.finished);
    final failed = count(
      (r) =>
          r.status == TaskRunStatus.failed ||
          r.status == TaskRunStatus.cancelled ||
          (r.status == TaskRunStatus.finished && !r.succeeded),
    );
    final running = count((r) => r.active);
    final queued = count((r) => r.status == TaskRunStatus.queued);
    final over = runs.length - running - queued;
    final first = runs.first;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${runs.length} run${runs.length == 1 ? '' : 's'} · '
              '${agentKindLabel(first.agent)} · $hostName · '
              '${first.place.label}',
              style: theme.textTheme.labelLarge,
            ),
            const SizedBox(height: 6),
            LinearProgressIndicator(
              key: ValueKey('task-batch-progress-${batch.batchId}'),
              value: runs.isEmpty ? 0 : over / runs.length,
            ),
            const SizedBox(height: 4),
            Text(
              [
                '$finished finished',
                if (running > 0) '$running running',
                if (queued > 0) '$queued waiting',
                if (failed > 0) '$failed failed or stopped',
              ].join(' · '),
              key: ValueKey('task-batch-summary-${batch.batchId}'),
              style: theme.textTheme.bodySmall,
            ),
            for (final r in runs)
              _RunTile(run: r, hostId: batch.hostId, controller: controller),
          ],
        ),
      ),
    );
  }
}

class _RunTile extends StatelessWidget {
  const _RunTile({
    required this.run,
    required this.hostId,
    required this.controller,
  });

  final TaskRun run;
  final String hostId;
  final TaskRunsController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, color, label) = switch (run.status) {
      TaskRunStatus.queued => (
        Icons.schedule,
        theme.colorScheme.outline,
        'Waiting',
      ),
      TaskRunStatus.starting => (
        Icons.hourglass_top,
        theme.colorScheme.primary,
        'Starting',
      ),
      TaskRunStatus.running => (
        Icons.play_circle_outline,
        theme.colorScheme.primary,
        run.agentState == null ? 'Started' : 'Running (${run.agentState})',
      ),
      TaskRunStatus.finished when run.succeeded => (
        Icons.check_circle_outline,
        Colors.green,
        'Finished',
      ),
      TaskRunStatus.finished => (
        Icons.error_outline,
        theme.colorScheme.error,
        'Ended (${run.outcome ?? '?'})',
      ),
      TaskRunStatus.failed => (
        Icons.error_outline,
        theme.colorScheme.error,
        'Failed',
      ),
      TaskRunStatus.cancelled => (
        Icons.block,
        theme.colorScheme.outline,
        'Cancelled',
      ),
    };
    final sync = controller.syncErrorOf(hostId, run.id);
    final details = [
      label,
      if (run.attempts > 1) 'attempt ${run.attempt}',
      ?run.branch,
      ?run.error,
      if (sync != null) 'not marked done: $sync',
    ].join(' · ');
    return ListTile(
      key: ValueKey('task-run-${run.id}'),
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: color, size: 20),
      title: Text(
        '${run.taskKey ?? ''}  ${run.taskTitle ?? ''}'.trim(),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(details, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: PopupMenuButton<String>(
        tooltip: 'Run actions',
        onSelected: (action) => unawaited(switch (action) {
          'copy' => Clipboard.setData(ClipboardData(text: run.command ?? '')),
          'cancel' => controller.cancel(hostId, run.id),
          _ => controller.forget(hostId, run.id),
        }),
        itemBuilder: (context) => [
          if (run.command != null)
            const PopupMenuItem(value: 'copy', child: Text('Copy command')),
          if (run.active || run.status == TaskRunStatus.queued)
            const PopupMenuItem(value: 'cancel', child: Text('Stop following'))
          else
            const PopupMenuItem(
              value: 'forget',
              child: Text('Remove from list'),
            ),
        ],
      ),
    );
  }
}

/// Every started task (Tasks › Runs).
class TaskRunsPage extends StatelessWidget {
  const TaskRunsPage({
    required this.controller,
    required this.hostName,
    required this.hostIds,
    super.key,
  });

  final TaskRunsController controller;
  final String Function(String hostId) hostName;
  final List<String> Function() hostIds;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Started tasks')),
    body: RefreshIndicator(
      onRefresh: () => controller.refreshAll(hostIds()),
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) => ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(12),
          children: [
            if (controller.batches.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: Text('No tasks started yet.')),
              ),
            TaskBatchesPanel(
              controller: controller,
              hostName: hostName,
              limit: 1000,
            ),
          ],
        ),
      ),
    ),
  );
}
