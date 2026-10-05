import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/sftp/domain/sftp_session.dart';
import 'package:conduit/features/sync/data/ssh_sync_hub.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

/// A shared runner that can carry SFTP on its connection.
class _SharedRunner extends ScriptedAgentCommandRunner
    implements SftpChannelRunner {
  _SharedRunner(this.session, {this.fails = false})
    : super([const AgentCommandResult(stdout: '', stderr: '', exitCode: 0)]);

  final FakeSftpSession session;
  final bool fails;
  int opened = 0;

  @override
  Future<SftpSession?> openSftp() async {
    opened += 1;
    if (fails) throw StateError('channel refused');
    return session;
  }
}

/// CON-089: every sync read and push opened a new SSH connection (key
/// exchange and sign-in) for SFTP, up to every 10 s while typing.
void main() {
  test('reads the bundle over the shared connection', () async {
    final session = FakeSftpSession(home: '/home/u', tree: {});
    final runner = _SharedRunner(session);
    final hub = SshSyncHub(
      host: buildHost('hub'),
      runner: runner,
      sftp: ThrowingSftpRepository(),
      deviceId: _vault,
    );
    await hub.readBundle(_vault);
    expect(runner.opened, 1);
    expect(session.readCalls, hasLength(1));
    expect(session.closeCalls, 1);
  });

  test('falls back to a connection of its own when that fails', () async {
    final own = FakeSftpSession(home: '/home/u', tree: {});
    final runner = _SharedRunner(
      FakeSftpSession(home: '/', tree: {}),
      fails: true,
    );
    final hub = SshSyncHub(
      host: buildHost('hub'),
      runner: runner,
      sftp: FakeSftpRepository(own),
      deviceId: _vault,
    );
    await hub.readBundle(_vault);
    expect(own.readCalls, hasLength(1));
  });
}

const _vault = '0123456789abcdef0123456789abcdef';
