import 'package:conduit/features/sftp/domain/sftp_session.dart';

/// Result of one non-interactive remote command.
class AgentCommandResult {
  const AgentCommandResult({
    required this.stdout,
    required this.stderr,
    this.exitCode,
  });

  final String stdout;
  final String stderr;

  /// Null when the remote side reported no exit status.
  final int? exitCode;
}

/// Runs short non-interactive commands on a host, independent of the
/// interactive terminal PTY, so polling never types into the user's session.
abstract class AgentCommandRunner {
  Future<AgentCommandResult> run(String command, {required Duration timeout});

  /// Closes any underlying connection. The runner must not be used after.
  Future<void> close();
}

/// A runner that can also feed a command's standard input and stop it
/// while it runs (the SSH and local runners).
abstract interface class StdinAgentCommandRunner implements AgentCommandRunner {
  /// Runs [command] with [stdin] as its input (then end of file), so long
  /// or private text never lands in the command line. Completing [cancel]
  /// stops waiting and throws [AgentCommandCancelled]. A local process is
  /// killed; over SSH the channel is closed, but the remote process may
  /// run on until its own time limit, so bound it there.
  Future<AgentCommandResult> runWithStdin(
    String command, {
    required String stdin,
    required Duration timeout,
    Future<void>? cancel,
  });
}

/// A runner whose connection can also carry an SFTP channel, so file
/// transfers reuse it instead of a new handshake (CON-089).
abstract interface class SftpChannelRunner {
  /// An SFTP session on the runner's connection; closing it closes only
  /// its channel. Null when this runner cannot carry one.
  Future<SftpSession?> openSftp();
}

/// The caller cancelled a [StdinAgentCommandRunner.runWithStdin] call.
class AgentCommandCancelled implements Exception {
  const AgentCommandCancelled();

  @override
  String toString() => 'The command was cancelled.';
}
