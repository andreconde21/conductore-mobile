import 'dart:async';

import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/desktop_shell/domain/project_tree.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/quick_actions/data/project_files.dart';
import 'package:conduit/features/quick_actions/domain/quick_action.dart';
import 'package:flutter/foundation.dart';

/// A runner for a machine; the caller closes it only when `owned` (the
/// agent monitor's `runnerFor`).
typedef ProjectRunnerFor =
    (AgentCommandRunner, {bool owned}) Function(SavedHost host);

/// Reads each project's icon and `.code-workspace` quick actions from its
/// machine, once per session (or on [refresh]), and writes new actions
/// back. Loads are lazy: the Projects tab and the toolbar ask for what
/// they show.
class ProjectFilesController extends ChangeNotifier {
  ProjectFilesController({
    required this.runnerFor,
    required this.hostFor,
    this.maxConcurrent = 3,
  });

  final ProjectRunnerFor runnerFor;

  /// The saved machine of a machine id (null when it is gone).
  final SavedHost? Function(String machineId) hostFor;
  final int maxConcurrent;

  final Map<ProjectLocation, ProjectFiles?> _files = {};
  final Set<ProjectLocation> _loading = {};
  final List<ProjectLocation> _queue = [];
  bool _disposed = false;

  /// The files of [project]'s first location that has been read.
  ProjectFiles? filesFor(ProjectGroup project) {
    for (final location in project.locations) {
      final files = _files[location];
      if (files != null) return files;
    }
    return null;
  }

  /// Where [project]'s files were read from.
  ProjectLocation? locationOf(ProjectGroup project) {
    for (final location in project.locations) {
      if (_files[location] != null) return location;
    }
    return project.locations.firstOrNull;
  }

  bool isLoading(ProjectGroup project) =>
      project.locations.any(_loading.contains);

  /// Reads [project]'s files unless they were read (or tried) already.
  void ensure(ProjectGroup project) {
    for (final location in project.locations) {
      if (_files.containsKey(location) ||
          _loading.contains(location) ||
          _queue.contains(location)) {
        continue;
      }
      _queue.add(location);
      // One location per project is enough to start with.
      break;
    }
    _pump();
  }

  /// Reads [project]'s files again (after editing them elsewhere).
  void refresh(ProjectGroup project) {
    for (final location in project.locations) {
      _files.remove(location);
    }
    ensure(project);
    notifyListeners();
  }

  void _pump() {
    while (_loading.length < maxConcurrent && _queue.isNotEmpty) {
      final location = _queue.removeAt(0);
      _loading.add(location);
      unawaited(_load(location));
    }
  }

  Future<void> _load(ProjectLocation location) async {
    ProjectFiles? files;
    try {
      final host = hostFor(location.machineId);
      if (host != null) {
        final (runner, :owned) = runnerFor(host);
        try {
          files = await ProjectFilesCommands.load(runner, location.path);
        } finally {
          if (owned) unawaited(runner.close());
        }
      }
    } catch (_) {
      // Unreachable or no shell: the project keeps its monogram.
      files = null;
    } finally {
      _loading.remove(location);
    }
    if (_disposed) return;
    _files[location] = files;
    notifyListeners();
    _pump();
  }

  /// Writes [actions] into [project]'s `.code-workspace` file (created
  /// when missing) and reads it back.
  Future<void> saveActions(
    ProjectGroup project,
    List<QuickAction> actions,
  ) async {
    final location = locationOf(project);
    final files = filesFor(project);
    if (location == null || files == null) {
      throw StateError('The project folder of ${project.name} is not known.');
    }
    final host = hostFor(location.machineId);
    if (host == null) throw StateError('That machine is gone.');
    final content = updateCodeWorkspaceCommands(files.workspaceSource, actions);
    final (runner, :owned) = runnerFor(host);
    try {
      await ProjectFilesCommands.save(
        runner,
        root: files.root,
        file: files.workspaceFileOrDefault,
        content: content,
      );
    } finally {
      if (owned) unawaited(runner.close());
    }
    if (_disposed) return;
    _files[location] = ProjectFiles(
      root: files.root,
      icon: files.icon,
      iconPath: files.iconPath,
      workspaceFile: files.workspaceFileOrDefault,
      workspaceSource: content,
    );
    notifyListeners();
  }

  @visibleForTesting
  void debugSet(ProjectLocation location, ProjectFiles? files) {
    _files[location] = files;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
