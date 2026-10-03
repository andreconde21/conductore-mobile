import 'package:conduit/core/app_failure.dart';
import 'package:conduit/core/presentation/multiplexer_icon.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/sessions/domain/new_workspace.dart';

/// Creates Herdr workspaces and tmux sessions on a host over an
/// [AgentCommandRunner] (a dedicated SSH exec channel, never the PTY).
class WorkspaceCreator {
  const WorkspaceCreator(this._runner, {this.mayMoveHerdrFocus = false});

  static const _timeout = Duration(seconds: 15);

  final AgentCommandRunner _runner;

  /// "Phone may move Herdr focus": a new Herdr workspace is focused only
  /// then. Otherwise it opens by id like any workspace, and the session
  /// offers "Take focus once" while Herdr shows another one.
  final bool mayMoveHerdrFocus;

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
    if (request.startClaude && created.paneId.isNotEmpty) {
      // The workspace is there either way: a failure here leaves a shell.
      try {
        await _runner.run(
          NewWorkspaceCommands.herdrStartClaude(created.paneId),
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
    // Neither a folder nor Claude: attach to it, creating it if needed,
    // as the picker always did.
    if (folder.isEmpty && !request.startClaude) {
      return ConnectTarget.tmux(session);
    }
    final result = await _runner.run(
      NewWorkspaceCommands.tmuxCreate(
        name: session,
        folder: folder,
        startClaude: request.startClaude,
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
