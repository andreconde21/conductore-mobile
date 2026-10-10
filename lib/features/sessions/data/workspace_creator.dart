import 'package:conduit/core/app_failure.dart';
import 'package:conduit/core/presentation/multiplexer_icon.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/agent_attention/domain/agent_kinds.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/sessions/domain/new_workspace.dart';
import 'package:flutter/foundation.dart';

/// Creates Herdr workspaces and tmux sessions on a host over an
/// [AgentCommandRunner] (a dedicated SSH exec channel, never the PTY).
class WorkspaceCreator {
  WorkspaceCreator(
    this._runner, {
    this.mayMoveHerdrFocus = false,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  static const _timeout = Duration(seconds: 15);

  final AgentCommandRunner _runner;

  /// "Phone may move Herdr focus": a new Herdr workspace is focused only
  /// then. Otherwise it opens by id like any workspace, and the session
  /// offers "Take focus once" while Herdr shows another one.
  final bool mayMoveHerdrFocus;

  /// Which of [candidates] are installed on the machine (their command on
  /// PATH), in [candidates]' order. Remembered per [hostId] for
  /// [detectionTtl], so reopening the dialog asks nothing. Throws when the
  /// machine cannot be asked.
  Future<List<KnownAgentKind>> installedAgents(
    String hostId,
    List<KnownAgentKind> candidates,
  ) async {
    final commands = [for (final agent in candidates) agent.command];
    final key = '$hostId\u0000${commands.join(' ')}';
    final cached = _detected[key];
    final Set<String> found;
    if (cached != null && _clock().difference(cached.at) < detectionTtl) {
      found = cached.found;
    } else {
      final result = await _runner.run(
        NewWorkspaceCommands.detectAgents(commands),
        timeout: _timeout,
      );
      if (result.exitCode != null && result.exitCode != 0) {
        throw NewWorkspaceFailure(
          _failure(result, 'Could not check which agents are installed.'),
        );
      }
      found = NewWorkspaceCommands.parseInstalledAgents(result.stdout);
      _detected[key] = (at: _clock(), found: found);
    }
    return [
      for (final agent in candidates)
        if (found.contains(agent.command)) agent,
    ];
  }

  /// How long a machine's installed agents are remembered.
  static const detectionTtl = Duration(minutes: 10);

  static final _detected = <String, ({DateTime at, Set<String> found})>{};

  @visibleForTesting
  static void clearDetectedAgents() => _detected.clear();

  /// The folders a starting folder can be picked from (see
  /// [NewWorkspaceCommands.listFolders]): the project roots when [folder]
  /// is null, else [folder]'s subfolders. Throws a [NewWorkspaceFailure]
  /// when the machine cannot be asked.
  Future<List<String>> listFolders([String? folder]) async {
    final AgentCommandResult result;
    try {
      result = await _runner.run(
        NewWorkspaceCommands.listFolders(folder),
        timeout: _listTimeout,
      );
    } catch (error) {
      throw NewWorkspaceFailure(error.toString());
    }
    if (result.exitCode == NewWorkspaceCommands.missingFolderExit) {
      throw const NewWorkspaceFailure('That folder does not exist.');
    }
    if (result.exitCode != null && result.exitCode != 0) {
      throw NewWorkspaceFailure(
        _failure(result, 'Could not list the folders.'),
      );
    }
    return NewWorkspaceCommands.parseFolders(result.stdout);
  }

  static const _listTimeout = Duration(seconds: 10);

  /// Creates what [request] asks for and returns the target that opens
  /// it. Throws a [NewWorkspaceFailure] that says what went wrong.
  Future<ConnectTarget> create(NewWorkspaceRequest request) async {
    final folder = request.folder.trim();
    var name = request.name.trim();
    if (name.isEmpty) name = NewWorkspaceCommands.folderName(folder);
    try {
      return switch (request.kind) {
        MultiplexerKind.herdr => await _herdr(name, folder, request),
        MultiplexerKind.tmux => await _tmux(name, folder, request),
      };
    } on NewWorkspaceFailure {
      rethrow;
    } on AppFailure catch (failure) {
      throw NewWorkspaceFailure(failure.toString());
    } catch (error) {
      throw NewWorkspaceFailure(error.toString());
    }
  }

  Future<ConnectTarget> _herdr(
    String label,
    String folder,
    NewWorkspaceRequest request,
  ) async {
    final result = await _runner.run(
      NewWorkspaceCommands.herdrCreate(
        label: label,
        folder: folder,
        focus: mayMoveHerdrFocus,
      ),
      timeout: _timeout,
    );
    _checkFolder(result);
    final created = NewWorkspaceCommands.parseHerdrCreated(result.stdout);
    if (created == null) {
      throw NewWorkspaceFailure(
        NewWorkspaceCommands.herdrError(result.stdout) ??
            NewWorkspaceCommands.herdrError(result.stderr) ??
            _failure(result, 'Herdr could not create the workspace.'),
      );
    }
    if (request.agent case final agent? when created.paneId.isNotEmpty) {
      // The workspace is there either way: a failure here leaves a shell.
      try {
        await _runner.run(
          NewWorkspaceCommands.herdrStartAgent(created.paneId, agent.command),
          timeout: _timeout,
        );
      } catch (_) {}
    }
    return ConnectTarget.herdr(
      workspaceId: created.workspaceId,
      label: created.label.isNotEmpty ? created.label : label,
    );
  }

  Future<ConnectTarget> _tmux(
    String name,
    String folder,
    NewWorkspaceRequest request,
  ) async {
    final session = NewWorkspaceCommands.tmuxName(name);
    if (session.isEmpty) {
      throw const NewWorkspaceFailure('Give the session a name.');
    }
    // Neither a folder nor an agent: attach to it, creating it if needed,
    // as the picker always did.
    if (folder.isEmpty && request.agent == null) {
      return ConnectTarget.tmux(session);
    }
    final result = await _runner.run(
      NewWorkspaceCommands.tmuxCreate(
        name: session,
        folder: folder,
        agentCommand: request.agent?.command,
      ),
      timeout: _timeout,
    );
    _checkFolder(result);
    if (result.exitCode != null && result.exitCode != 0) {
      final stderr = result.stderr.trim();
      if (stderr.contains('duplicate session')) {
        throw NewWorkspaceFailure(
          'A tmux session named "$session" already exists.',
        );
      }
      throw NewWorkspaceFailure(
        _failure(result, 'tmux could not create the session.'),
      );
    }
    return ConnectTarget.tmux(session);
  }

  static void _checkFolder(AgentCommandResult result) {
    if (result.exitCode == NewWorkspaceCommands.missingFolderExit) {
      final stderr = result.stderr.trim();
      throw NewWorkspaceFailure(
        stderr.isEmpty ? 'That folder does not exist.' : stderr,
      );
    }
  }

  static String _failure(AgentCommandResult result, String headline) {
    final stderr = result.stderr.trim();
    if (result.exitCode == 127) {
      return '$headline It is not installed on this machine.';
    }
    return stderr.isEmpty ? headline : '$headline $stderr';
  }
}
