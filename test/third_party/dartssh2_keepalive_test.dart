import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
// ignore: implementation_imports
import 'package:dartssh2/src/ssh_keepalive.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

/// The vendored dartssh2 keep-alive (CON-089): its interval changes on a
/// live connection, pings never pile up, and a ping with no reply closes
/// the connection instead of waiting for the TCP timeout.
void main() {
  group('SSHKeepAlive', () {
    test('skips a tick while the last ping waits for its reply', () {
      fakeAsync((async) {
        var pings = 0;
        final reply = Completer<void>();
        final keepAlive = SSHKeepAlive(
          ping: () {
            pings += 1;
            return reply.future;
          },
        )..start();
        async.elapse(const Duration(seconds: 45));
        expect(pings, 1, reason: 'the first ping never got its reply');
        reply.complete();
        async.elapse(const Duration(seconds: 10));
        expect(pings, 2);
        keepAlive.stop();
      });
    });

    test('a failed ping is not an unhandled error', () {
      fakeAsync((async) {
        var pings = 0;
        final keepAlive = SSHKeepAlive(
          ping: () async {
            pings += 1;
            throw StateError('closed');
          },
          interval: const Duration(seconds: 1),
        )..start();
        async.elapse(const Duration(seconds: 3));
        expect(pings, 3);
        keepAlive.stop();
      });
    });

    test('the interval changes while running; null pauses it', () {
      fakeAsync((async) {
        var pings = 0;
        final keepAlive = SSHKeepAlive(ping: () async => pings += 1)..start();
        async.elapse(const Duration(seconds: 30));
        expect(pings, 3);
        keepAlive.interval = const Duration(seconds: 60);
        async.elapse(const Duration(seconds: 59));
        expect(pings, 3);
        async.elapse(const Duration(seconds: 1));
        expect(pings, 4);
        keepAlive.interval = null;
        async.elapse(const Duration(minutes: 10));
        expect(pings, 4);
        keepAlive.interval = const Duration(seconds: 30);
        async.elapse(const Duration(seconds: 30));
        expect(pings, 5);
        keepAlive.stop();
        keepAlive.interval = const Duration(seconds: 1);
        async.elapse(const Duration(seconds: 5));
        expect(pings, 5, reason: 'a stopped keep-alive stays stopped');
      });
    });
  });

  group('SSHClient.ping against OpenSSH', () {
    final skip = _skipReason();
    late Directory root;

    setUpAll(() async {
      if (skip != null) return;
      root = Directory('/tmp').createTempSync('conductore-keepalive-');
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

    Future<(SSHClient, Process)> connect() async {
      final process = await Process.start('/usr/sbin/sshd', [
        '-i',
        '-f',
        '${root.path}/sshd_config',
      ]);
      addTearDown(() => process.kill(ProcessSignal.sigkill));
      unawaited(process.stderr.drain<void>());
      final client = SSHClient(
        _ProcessSocket(process),
        username: 'root',
        identities: SSHKeyPair.fromPem(
          File('${root.path}/key').readAsStringSync(),
        ),
        keepAliveInterval: null,
        keepAliveTimeout: const Duration(seconds: 1),
      );
      addTearDown(client.close);
      await client.authenticated;
      return (client, process);
    }

    test('a live server answers', () async {
      final (client, _) = await connect();
      await client.ping();
      expect(client.isClosed, isFalse);
    }, skip: skip);

    test('no reply in time closes the connection with an error', () async {
      final (client, process) = await connect();
      // A half-dead link: the server stops answering.
      process.kill(ProcessSignal.sigstop);
      final stopwatch = Stopwatch()..start();
      await expectLater(client.ping(), throwsA(isA<SSHSocketError>()));
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
      await expectLater(client.done, throwsA(isA<SSHSocketError>()));
      expect(client.isClosed, isTrue);
    }, skip: skip);
  });
}

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
