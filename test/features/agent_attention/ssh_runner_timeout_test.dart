import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:conduit/core/app_failure.dart';
import 'package:conduit/features/agent_attention/data/ssh_agent_command_runner.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

/// CON-089: one command timing out dropped the shared connection, cutting
/// the agent long-poll, the live feed and every other feature on it. Now
/// only its channel closes. Against the real OpenSSH (`sshd -i` on a pipe,
/// as in safe_save_openssh_test).
void main() {
  final skip = _skipReason();
  late Directory root;

  setUpAll(() async {
    if (skip != null) return;
    root = Directory('/tmp').createTempSync('conductore-runner-');
    await _run('chmod', ['755', root.path]);
    for (final name in ['host', 'key']) {
      await _run('ssh-keygen', [
        '-q',
        '-t',
        'ed25519',
        '-N',
        '',
        '-f',
        '${root.path}/$name',
      ]);
    }
    File('${root.path}/key.pub').copySync('${root.path}/authorized_keys');
    await _run('chmod', ['644', '${root.path}/authorized_keys']);
    File('${root.path}/sshd_config').writeAsStringSync('''
HostKey ${root.path}/host
AuthorizedKeysFile ${root.path}/authorized_keys
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
PidFile none
LogLevel ERROR
''');
  });

  tearDownAll(() {
    if (skip != null) return;
    root.deleteSync(recursive: true);
  });

  test('a timed-out command keeps the connection for the next one', () async {
    var connects = 0;
    final processes = <Process>[];
    // Runs after the runner closed (tear-downs run last first).
    addTearDown(() {
      for (final process in processes) {
        process.kill(ProcessSignal.sigkill);
      }
    });
    final runner = SshAgentCommandRunner(
      NoopVerifier(),
      buildHost('h'),
      connect: () async {
        connects += 1;
        final process = await Process.start('/usr/sbin/sshd', [
          '-i',
          '-f',
          '${root.path}/sshd_config',
        ]);
        processes.add(process);
        unawaited(process.stderr.drain<void>());
        return SSHClient(
          _ProcessSocket(process),
          username: 'root',
          identities: SSHKeyPair.fromPem(
            File('${root.path}/key').readAsStringSync(),
          ),
          keepAliveInterval: null,
        );
      },
    );
    addTearDown(runner.close);

    expect((await runner.run('echo one', timeout: _long)).stdout, 'one\n');
    await expectLater(
      runner.run('sleep 5', timeout: const Duration(milliseconds: 500)),
      throwsA(isA<AppFailure>()),
    );
    // The ping that checks the link answers; nothing is dropped.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect((await runner.run('echo two', timeout: _long)).stdout, 'two\n');
    expect(connects, 1);
  }, skip: skip);
}

const _long = Duration(seconds: 20);

String? _skipReason() {
  if (!Platform.isLinux) return 'needs Linux';
  if (!File('/usr/sbin/sshd').existsSync()) return 'needs OpenSSH sshd';
  final uid = Process.runSync('id', ['-u']).stdout.toString().trim();
  if (uid != '0') return 'sshd -i needs root';
  return null;
}

Future<void> _run(String executable, List<String> arguments) async {
  final result = await Process.run(executable, arguments);
  if (result.exitCode != 0) {
    throw StateError('$executable ${arguments.join(' ')}: ${result.stderr}');
  }
}

class _ProcessSocket implements SSHSocket {
  _ProcessSocket(this._process);

  final Process _process;

  @override
  Stream<Uint8List> get stream => _process.stdout.map(Uint8List.fromList);

  @override
  StreamSink<List<int>> get sink => _process.stdin;

  @override
  Future<void> get done => _process.exitCode;

  @override
  Future<void> close() async {
    await _process.stdin.close();
  }

  @override
  void destroy() => _process.kill(ProcessSignal.sigkill);
}
