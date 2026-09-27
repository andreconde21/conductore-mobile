import 'package:conduit/features/agent_attention/data/shared_command_runners.dart';
import 'package:conduit/features/agent_attention/data/ssh_agent_command_runner.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/live_preview/data/ssh_port_forwarder.dart';
import 'package:conduit/features/live_preview/domain/port_forward.dart';
import 'package:conduit/features/sftp/domain/sftp_repository.dart';
import 'package:conduit/features/sftp/domain/sftp_session.dart';
import 'package:conduit/features/terminal/domain/host_key_verifier.dart';
import 'package:conduit/features/this_computer/data/local_port_forwarder.dart';

/// The side channels of a machine, next to its terminal: commands (agent
/// status, listing, git), files and port forwards. SSH for saved
/// machines; the desktop itself for "This computer".
class HostChannels {
  HostChannels({
    required this._hostKeyVerifier,
    required this._localRunner,
    required SftpRepository sshFiles,
    required SftpRepository localFiles,
    Stream<void>? networkChanges,
    StdinAgentCommandRunner Function(SavedHost host)? sshRunner,
  }) : files = RoutingSftpRepository(ssh: sshFiles, local: localFiles) {
    _sshRunners = SharedCommandRunners(
      sshRunner ?? (host) => SshAgentCommandRunner(_hostKeyVerifier, host),
      networkChanges: networkChanges,
    );
  }

  final HostKeyVerifier _hostKeyVerifier;
  final AgentCommandRunner Function() _localRunner;

  /// Every side channel of a saved machine shares one SSH connection.
  late final SharedCommandRunners _sshRunners;

  /// Files of any machine: SFTP, or the local file system for "This
  /// computer".
  final SftpRepository files;

  /// A command runner for [host]; the caller closes it. Runners of one
  /// machine share its connection (see [SharedCommandRunners]).
  AgentCommandRunner runner(SavedHost host) =>
      host.isThisComputer ? _localRunner() : _sshRunners.lease(host);

  /// A port forwarder for the live preview of [host]; the caller closes it.
  PortForwarder portForwarder(SavedHost host) => host.isThisComputer
      ? LocalPortForwarder()
      : SshPortForwarder(_hostKeyVerifier, host);
}

/// Sends "This computer" to the local file system and every other machine
/// to SFTP.
class RoutingSftpRepository implements SftpRepository {
  const RoutingSftpRepository({required this.ssh, required this.local});

  final SftpRepository ssh;
  final SftpRepository local;

  @override
  Future<SftpSession> connect(SavedHost host) =>
      (host.isThisComputer ? local : ssh).connect(host);
}
