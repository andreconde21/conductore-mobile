import 'dart:convert';

import 'package:conduit/core/presentation/multiplexer_icon.dart';
import 'package:conduit/features/agent_attention/data/remote_tool_command.dart';

/// A Herdr workspace or tmux session to create on a machine (the connect
/// picker's "New workspace" and "New session").
class NewWorkspaceRequest {
  const NewWorkspaceRequest({
    required this.kind,
    required this.name,
    this.folder = '',
    this.startClaude = false,
  });

  final MultiplexerKind kind;

  /// The workspace label or tmux session name, as typed.
  final String name;

  /// The starting folder, as typed (`~` is the home folder); empty for the
  /// default.
  final String folder;

  /// Whether to start Claude in it once it is created.
  final bool startClaude;
}

/// Why a workspace could not be created, in words for the user.
class NewWorkspaceFailure implements Exception {
  const NewWorkspaceFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

/// What `herdr workspace create` reports about the new workspace.
typedef HerdrCreatedWorkspace = ({
  String workspaceId,
  String label,
  String paneId,
});

/// The commands that create a workspace, and the parsing of their answers.
///
/// Names and folders come from the user: every one of them is quoted, and
/// the scripts run under POSIX sh whatever the login shell is (see
/// [posixShellCommand]).
abstract final class NewWorkspaceCommands {
  /// Exit status of a create script whose folder does not exist.
  static const missingFolderExit = 3;

  /// The agent "start Claude" runs.
  static const claudeCommand = 'claude';

  /// [folder] as one sh word: quoted, with a leading `~` read as the home
  /// folder.
  static String folderWord(String folder) {
    if (folder == '~') return r'"$HOME"';
    if (folder.startsWith('~/')) {
      final rest = folder.substring(2);
      return rest.isEmpty ? r'"$HOME"' : '"\$HOME"/${shellQuoteArgument(rest)}';
    }
    return shellQuoteArgument(folder);
  }

  /// The basename of [folder], to name a workspace after it.
  static String folderName(String folder) {
    final parts = folder
        .split('/')
        .where((part) => part.isNotEmpty && part != '~');
    return parts.isEmpty ? '' : parts.last;
  }

  /// [name] as tmux will keep it: tmux turns `.` and `:` into `_`.
  static String tmuxName(String name) =>
      name.trim().replaceAll(RegExp(r'[.:]'), '_');

  static String _script(String folder, List<String> commands) {
    final lines = [
      'PATH="${remoteToolExtraPathDirs.join(':')}:\$PATH"',
      if (folder.isNotEmpty) ...[
        'dir=${folderWord(folder)}',
        'if [ ! -d "\$dir" ]; then '
            'printf \'No such folder: %s\\n\' "\$dir" >&2; '
            'exit $missingFolderExit; fi',
      ],
      ...commands,
    ];
    return posixShellCommand(lines.join('\n'));
  }

  /// `herdr workspace create` in [folder] labelled [label]. Focused only
  /// with [focus] ("Phone may move Herdr focus" on): Herdr's focus is
  /// shared, so focusing it would move the laptop's view too.
  static String herdrCreate({
    required String label,
    String folder = '',
    bool focus = false,
  }) => _script(folder, [
    [
      'exec herdr workspace create',
      if (folder.isNotEmpty) '--cwd "\$dir"',
      if (label.isNotEmpty) '--label ${shellQuoteArgument(label)}',
      if (focus) '--focus' else '--no-focus',
    ].join(' '),
  ]);

  /// Types Claude's command into the new workspace's first pane.
  static String herdrStartClaude(String paneId) => remoteToolCommand(
    'herdr',
    'pane run ${shellQuoteArgument(paneId)} $claudeCommand',
  );

  /// `tmux new-session -d` named [name] in [folder], then Claude typed into
  /// it when [startClaude].
  static String tmuxCreate({
    required String name,
    String folder = '',
    bool startClaude = false,
  }) {
    final session = shellQuoteArgument(name);
    return _script(folder, [
      [
        'tmux new-session -d -s $session',
        if (folder.isNotEmpty) '-c "\$dir"',
      ].join(' '),
      if (startClaude)
        'tmux send-keys -t ${shellQuoteArgument('=$name:')} '
            '$claudeCommand Enter',
    ]);
  }

  /// The workspace in `herdr workspace create`'s JSON answer; null when it
  /// is not one.
  static HerdrCreatedWorkspace? parseHerdrCreated(String stdout) {
    final result = _decode(stdout)?['result'];
    if (result is! Map) return null;
    final workspace = result['workspace'];
    final pane = result['root_pane'];
    if (workspace is! Map) return null;
    final id = workspace['workspace_id'];
    if (id is! String || id.isEmpty) return null;
    final label = workspace['label'];
    final paneId = pane is Map ? pane['pane_id'] : null;
    return (
      workspaceId: id,
      label: label is String ? label : '',
      paneId: paneId is String ? paneId : '',
    );
  }

  /// The error in a Herdr JSON answer (`{"error": {"code", "message"}}`),
  /// in words for the user; null when there is none.
  static String? herdrError(String output) {
    final error = _decode(output)?['error'];
    if (error is! Map) return null;
    if (error['code'] == 'server_not_running') {
      return 'Herdr is not running on this machine. Start it with "herdr" '
          'first.';
    }
    final message = error['message'];
    return message is String && message.isNotEmpty
        ? message
        : 'Herdr answered with an error.';
  }

  static Map<String, Object?>? _decode(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    try {
      final decoded = jsonDecode(text);
      return decoded is Map<String, Object?> ? decoded : null;
    } on FormatException {
      return null;
    }
  }
}
