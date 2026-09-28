import 'package:conduit/features/agent_attention/data/herdr_attention_provider.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/desktop_shell/domain/project_tree.dart';
import 'package:conduit/features/quick_actions/presentation/project_files_controller.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:conduit/features/this_computer/data/host_channels.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

class _Connection implements StdinAgentCommandRunner {
  int commands = 0;

  @override
  Future<AgentCommandResult> run(
    String command, {
    required Duration timeout,
  }) async {
    commands += 1;
    return const AgentCommandResult(stdout: '', stderr: '', exitCode: 1);
  }

  @override
  Future<AgentCommandResult> runWithStdin(
    String command, {
    required String stdin,
    required Duration timeout,
    Future<void>? cancel,
  }) => run(command, timeout: timeout);

  @override
  Future<void> close() async {}
}

void main() {
  test('desktop project reads (icons, quick actions) share the machine '
      'connection with the rest', () async {
    final opened = <_Connection>[];
    final channels = HostChannels(
      hostKeyVerifier: NoopVerifier(),
      localRunner: () => throw StateError('no local machine'),
      sshFiles: NoNetworkSftpRepository(),
      localFiles: NoNetworkSftpRepository(),
      sshRunner: (_) {
        final connection = _Connection();
        opened.add(connection);
        return connection;
      },
    );
    final workspace = TerminalWorkspaceController(FreshTerminalRepository());
    addTearDown(workspace.dispose);
    final attention = AgentAttentionController(
      workspace: workspace,
      runnerFactory: channels.runner,
      provider: const HerdrAttentionProvider(),
    );
    addTearDown(attention.dispose);
    final host = buildHost('box');
    final files = ProjectFilesController(
      runnerFor: attention.runnerFor,
      hostFor: (_) => host,
    );
    addTearDown(files.dispose);
    // The home board of the same machine is open too.
    final board = channels.runner(host);
    await board.run('tmux list-sessions', timeout: const Duration(seconds: 1));
    for (final name in ['api', 'web', 'docs']) {
      files.ensure(
        ProjectGroup(
          key: name,
          name: name,
          members: const [],
          locations: [ProjectLocation('box', '/home/me/$name')],
        ),
      );
    }
    await pumpEventQueue();
    expect(opened, hasLength(1));
    expect(opened.single.commands, greaterThan(1));
    await board.close();
  });
}
