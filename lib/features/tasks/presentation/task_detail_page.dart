import 'dart:async';

import 'package:conduit/features/tasks/domain/task_source.dart';
import 'package:conduit/features/tasks/presentation/task_sources_controller.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// One task: its description, status (changeable when the source allows),
/// labels, assignees and comments, with a field to add one.
class TaskDetailPage extends StatefulWidget {
  const TaskDetailPage({
    required this.controller,
    required this.task,
    this.actions = const [],
    super.key,
  });

  final TaskSourcesController controller;
  final TaskItem task;

  /// Extra buttons under the title (Start, from CON-037).
  final List<Widget> actions;

  @override
  State<TaskDetailPage> createState() => _TaskDetailPageState();
}

class _TaskDetailPageState extends State<TaskDetailPage> {
  late TaskItem _task = widget.task;
  final _comment = TextEditingController();
  String? _error;
  bool _loading = true;
  bool _busy = false;

  TaskSourcesController get _c => widget.controller;

  TaskSourceCapabilities get _caps => _c.capabilitiesOf(_task.sourceId);

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    try {
      final full = await _c.read(_task);
      if (!mounted) return;
      setState(() {
        _task = full;
        _error = null;
      });
    } on Object catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _changeStatus() async {
    List<TaskStatusOption> options;
    try {
      options = await _c.statusOptions(_task);
    } on Object catch (e) {
      _snack('$e');
      return;
    }
    if (!mounted) return;
    if (options.isEmpty) {
      _snack('No other status is available for this task.');
      return;
    }
    final picked = await showModalBottomSheet<TaskStatusOption>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final o in options)
              ListTile(
                key: ValueKey('task-status-option-${o.label}'),
                title: Text(o.label),
                subtitle: Text(o.category.label),
                trailing: o.label == _task.status?.label
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => Navigator.of(context).pop(o),
              ),
          ],
        ),
      ),
    );
    if (picked == null || picked.label == _task.status?.label) return;
    setState(() => _busy = true);
    try {
      final next = await _c.updateStatus(_task, picked);
      if (mounted) setState(() => _task = next.copyWith(body: _task.body));
    } on Object catch (e) {
      _snack('$e');
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _sendComment() async {
    final text = _comment.text.trim();
    if (text.isEmpty) return;
    setState(() => _busy = true);
    try {
      await _c.comment(_task, text);
      _comment.clear();
      await _reload();
    } on Object catch (e) {
      _snack('$e');
    }
    if (mounted) setState(() => _busy = false);
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final task = _task;
    final source = _c.sourceById(task.sourceId);
    final caps = _caps;
    return Scaffold(
      appBar: AppBar(
        title: Text(task.key),
        actions: [
          if (task.url case final url?)
            IconButton(
              tooltip: 'Open in browser',
              icon: const Icon(Icons.open_in_new),
              onPressed: () => unawaited(
                launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
              ),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SelectableText(task.title, style: theme.textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            [
              ?source?.name,
              if (task.updatedAt case final at?) _when(at),
            ].join(' · '),
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (caps.statuses)
                ActionChip(
                  key: const ValueKey('task-status'),
                  avatar: _busy
                      ? const SizedBox.square(
                          dimension: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.swap_horiz, size: 16),
                  label: Text(task.status?.label ?? 'No status'),
                  onPressed: _busy ? null : () => unawaited(_changeStatus()),
                ),
              if (caps.assignees)
                for (final a in task.assignees)
                  Chip(
                    avatar: const Icon(Icons.person_outline, size: 16),
                    label: Text(a),
                  ),
              if (caps.labels)
                for (final l in task.labels)
                  Chip(
                    avatar: const Icon(Icons.label_outline, size: 16),
                    label: Text(l),
                  ),
            ],
          ),
          if (widget.actions.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: widget.actions),
          ],
          const Divider(height: 24),
          if (_error case final error?)
            Text(error, style: TextStyle(color: theme.colorScheme.error)),
          if (_loading && task.body == null)
            const LinearProgressIndicator()
          else
            SelectableText(
              (task.body ?? '').trim().isEmpty
                  ? 'No description.'
                  : task.body!.trim(),
              key: const ValueKey('task-body'),
            ),
          if (caps.comments) ...[
            const Divider(height: 24),
            Text('Comments', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            for (final c in task.comments ?? const <TaskComment>[])
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      [
                        c.author,
                        if (c.at case final at?) _when(at),
                      ].join(' · '),
                      style: theme.textTheme.labelMedium,
                    ),
                    SelectableText(c.body),
                  ],
                ),
              ),
            if (!_loading && (task.comments ?? const []).isEmpty)
              Text('No comments.', style: theme.textTheme.bodySmall),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('task-comment-field'),
              controller: _comment,
              minLines: 1,
              maxLines: 6,
              decoration: InputDecoration(
                hintText: 'Add a comment',
                suffixIcon: IconButton(
                  key: const ValueKey('task-comment-send'),
                  tooltip: 'Send',
                  icon: const Icon(Icons.send),
                  onPressed: _busy ? null : () => unawaited(_sendComment()),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  static String _when(DateTime at) {
    final l = at.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
  }
}
