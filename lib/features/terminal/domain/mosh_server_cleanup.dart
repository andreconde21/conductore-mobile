import 'dart:async';

import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';

/// How long a mosh-server waits without hearing from its client before it
/// exits on its own (`MOSH_SERVER_NETWORK_TMOUT`): 24 hours. mosh-server's
/// default is to wait forever, so every client that vanished (an app
/// killed in the background, a phone that lost its network while closing)
/// left a server, and its shell or Herdr client, running for good. A
/// phone that comes back within a day finds its session; after that it
/// reconnects to a new one (Herdr and tmux keep the work either way).
const moshServerNetworkTimeout = Duration(hours: 24);

/// How long without its client a mosh-server must be before SIGUSR1 ends
/// it (`MOSH_SERVER_SIGNAL_TMOUT`): 1 hour. Unset, SIGUSR1 ends any
/// mosh-server, connected or not; set, a cleanup script can run
/// `pkill -USR1 -u "$USER" mosh-server` and end only the servers whose
/// client has been gone this long.
const moshServerSignalTimeout = Duration(hours: 1);

/// Prefix for the `mosh-server new` bootstrap that gives the server both
/// timeouts (mosh-server reads them from its environment).
String get moshServerTimeoutEnv =>
    'MOSH_SERVER_NETWORK_TMOUT=${moshServerNetworkTimeout.inSeconds} '
    'MOSH_SERVER_SIGNAL_TMOUT=${moshServerSignalTimeout.inSeconds}';

/// The mosh-server a session started, as far as the bootstrap told us.
class MoshServerHandle {
  const MoshServerHandle({required this.port, this.pid, this.portArgument});

  /// The UDP port it listens on (from `MOSH CONNECT <port> <key>`).
  final int port;

  /// Its pid, from `[mosh-server detached, pid = N]`; null when missing.
  final int? pid;

  /// The `-p` argument the bootstrap passed (`60001` or `60001:60999`).
  final String? portArgument;

  static final _pidPattern = RegExp(r'mosh-server detached, pid = (\d+)');

  /// Reads the pid from the bootstrap's combined stdout and stderr.
  static int? parsePid(String bootstrapOutput) {
    final match = _pidPattern.firstMatch(bootstrapOutput);
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  /// The shell command that stops exactly this server, or null when it
  /// cannot be identified safely.
  ///
  /// With the pid: SIGTERM it only if that pid is still a mosh-server
  /// (pids are reused; `kill` only reaches the user's own processes, and
  /// macOS's `ps` prints the full path). Without it: `pkill` on the user's
  /// `mosh-server new` processes whose `-p` names this port alone (a port
  /// range does not say which server got which port, so nothing is killed
  /// then).
  String? killCommand() {
    final pid = this.pid;
    if (pid != null) {
      return 'case "\$(ps -o comm= -p $pid 2>/dev/null)" in '
          '*mosh-server) kill $pid;; esac';
    }
    if (portArgument == '$port') {
      return 'pkill -u "\$(id -un)" -f '
          "'^([^ ]*/)?mosh-server new .*-p $port( |\$)'";
    }
    return null;
  }
}

/// One command that ends every server in [handles] it can identify, its
/// output and failures silenced; empty when there is none.
String killAllCommand(Iterable<MoshServerHandle> handles) {
  final commands = [for (final handle in handles) ?handle.killCommand()];
  if (commands.isEmpty) return '';
  return '{ ${commands.join('; ')}; } >/dev/null 2>&1; ';
}

/// Runs [handle]'s kill command over a runner from [runnerFactory], then
/// closes the runner. Best effort: every failure is swallowed. True when
/// the command ran (the server is gone, or was not there any more).
Future<bool> reapMoshServer(
  MoshServerHandle handle,
  AgentCommandRunner Function() runnerFactory, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final command = handle.killCommand();
  if (command == null) {
    return false;
  }
  AgentCommandRunner? runner;
  try {
    runner = runnerFactory();
    await runner.run(command, timeout: timeout);
    return true;
  } catch (_) {
    // The machine may be unreachable.
    return false;
  } finally {
    try {
      await runner?.close();
    } catch (_) {}
  }
}
