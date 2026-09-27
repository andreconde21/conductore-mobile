import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:conduit/core/app_failure.dart';
import 'package:conduit/features/sftp/data/dart_ssh_sftp_repository.dart';
import 'package:conduit/features/sftp/domain/sftp_save_result.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';

/// The safe save against the real OpenSSH SFTP server: `sshd -i` (inetd
/// mode) runs on a pipe with a throwaway host key and authorized key, so no
/// port and no system configuration is involved. Needs root and a Linux
/// sshd; skipped elsewhere.
void main() {
  final skip = _skipReason();
  late Directory root;
  late Directory home;
  late String privateKey;

  setUpAll(() async {
    if (skip != null) return;
    // Under /tmp and world-traversable, so sshd can read the authorized
    // keys as `nobody` too.
    root = Directory('/tmp').createTempSync('conductore-sftpsave-');
    home = Directory('${root.path}/files')..createSync();
    await _run('chmod', ['755', root.path, home.path]);
    await _run('ssh-keygen', [
      '-q',
      '-t',
      'ed25519',
      '-N',
      '',
      '-f',
      '${root.path}/host',
    ]);
    await _run('ssh-keygen', [
      '-q',
      '-t',
      'ed25519',
      '-N',
      '',
      '-f',
      '${root.path}/key',
    ]);
    File('${root.path}/key.pub').copySync('${root.path}/authorized_keys');
    await _run('chmod', ['644', '${root.path}/authorized_keys']);
    privateKey = File('${root.path}/key').readAsStringSync();
  });

  tearDownAll(() {
    if (skip != null) return;
    root.deleteSync(recursive: true);
  });

  Future<DartSshSftpSession> connect({
    String user = 'root',
    String sftpFlags = '',
  }) async {
    final config = File('${root.path}/sshd_config_${_configs++}')
      ..writeAsStringSync('''
HostKey ${root.path}/host
AuthorizedKeysFile ${root.path}/authorized_keys
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
Subsystem sftp internal-sftp $sftpFlags
PidFile none
LogLevel ERROR
''');
    final process = await Process.start('/usr/sbin/sshd', [
      '-i',
      '-f',
      config.path,
    ]);
    unawaited(process.stderr.drain<void>());
    final client = SSHClient(
      _ProcessSocket(process),
      username: user,
      identities: SSHKeyPair.fromPem(privateKey),
    );
    final session = DartSshSftpSession(
      client: client,
      sftp: await client.sftp(),
    );
    addTearDown(session.close);
    return session;
  }

  File file(String name, String text, {String mode = '644'}) {
    final f = File('${home.path}/$name')..writeAsStringSync(text);
    Process.runSync('chmod', [mode, f.path]);
    return f;
  }

  Uint8List bytes(String text) => Uint8List.fromList(utf8.encode(text));

  String stat(String format, String path) =>
      (Process.runSync('stat', ['-c', format, path]).stdout as String).trim();

  List<String> leftovers() => home
      .listSync()
      .map((e) => e.path.split('/').last)
      .where((name) => name.contains('.conductore-'))
      .toList();

  setUp(() {
    if (skip != null) return;
    for (final entry in home.listSync()) {
      entry.deleteSync(recursive: true);
    }
  });

  test('replaces the file atomically and keeps its mode', () async {
    final f = file('app.conf', 'old', mode: '640');
    final inode = stat('%i', f.path);
    final session = await connect();

    final result = await session.save(f.path, bytes('new'));

    expect(result.method, SftpSaveMethod.atomic);
    expect(f.readAsStringSync(), 'new');
    expect(stat('%a', f.path), '640');
    expect(stat('%i', f.path), isNot(inode), reason: 'a new file took over');
    expect(leftovers(), isEmpty);
  }, skip: skip);

  test('keeps setuid bits and a foreign owner as root', () async {
    final f = file('tool', 'old');
    // chown clears setuid, so the mode goes on last.
    await _run('chown', ['65534:65534', f.path]);
    await _run('chmod', ['4750', f.path]);
    final session = await connect();

    final result = await session.save(f.path, bytes('new'));

    expect(result.method, SftpSaveMethod.atomic);
    expect(stat('%a %u:%g', f.path), '4750 65534:65534');
  }, skip: skip);

  test('writes the target of a symlink and keeps the link', () async {
    final target = file('real.conf', 'old');
    final link = Link('${home.path}/link.conf')..createSync(target.path);
    final session = await connect();

    await session.save(link.path, bytes('new'));

    expect(FileSystemEntity.isLinkSync(link.path), isTrue);
    expect(target.readAsStringSync(), 'new');
    expect(leftovers(), isEmpty);
  }, skip: skip);

  test('writes a hard-linked file in place', () async {
    final a = file('a', 'old');
    await _run('ln', [a.path, '${home.path}/b']);
    final session = await connect();

    final result = await session.save(a.path, bytes('new'));

    expect(result.method, SftpSaveMethod.inPlaceHardLinked);
    expect(File('${home.path}/b').readAsStringSync(), 'new');
    expect(stat('%h', a.path), '2');
  }, skip: skip);

  test('a write that fails leaves the original and no temp file', () async {
    final f = file('app.conf', 'old');
    final session = await connect(sftpFlags: '-P write');

    await expectLater(
      session.save(f.path, bytes('new')),
      throwsA(
        isA<AppFailure>().having(
          (e) => e.message,
          'message',
          contains('unchanged'),
        ),
      ),
    );

    expect(f.readAsStringSync(), 'old');
    expect(leftovers(), isEmpty);
  }, skip: skip);

  test('without posix-rename, writes in place after a backup', () async {
    final f = file('app.conf', 'old', mode: '600');
    // Denied requests are also left out of the advertised extensions.
    final session = await connect(sftpFlags: '-P posix-rename');

    final first = await session.save(f.path, bytes('new'));
    final second = await session.save(f.path, bytes('newer'));

    expect(first.method, SftpSaveMethod.inPlaceWithBackup);
    expect(first.notice, contains('.app.conf.conductore-bak'));
    expect(second.notice, isNull);
    expect(f.readAsStringSync(), 'newer');
    expect(stat('%a', f.path), '600');
    expect(leftovers(), isEmpty);
  }, skip: skip);

  test('without posix-rename, a failed backup leaves the file', () async {
    final f = file('app.conf', 'old');
    final session = await connect(sftpFlags: '-P posix-rename,write');

    // Writes are refused, so the backup copy fails before the original is
    // touched.
    await expectLater(
      session.save(f.path, bytes('new')),
      throwsA(
        isA<AppFailure>().having(
          (e) => e.message,
          'message',
          contains('unchanged'),
        ),
      ),
    );

    expect(f.readAsStringSync(), 'old');
    expect(leftovers(), isEmpty);
  }, skip: skip);

  test('as another user, keeps the owner by writing in place', () async {
    await _run('chown', ['65534:65534', home.path]);
    addTearDown(() => _run('chown', ['0:0', home.path]));
    final f = file('shared.txt', 'old', mode: '666');
    final session = await connect(user: 'nobody');

    final result = await session.save(f.path, bytes('new'));

    expect(result.method, SftpSaveMethod.inPlaceWithBackup);
    expect(result.notice, contains('keep its owner'));
    expect(f.readAsStringSync(), 'new');
    expect(stat('%u:%g %a', f.path), '0:0 666');
    expect(leftovers(), isEmpty);
  }, skip: skip);
}

var _configs = 0;

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
    await _process.exitCode;
  }

  @override
  void destroy() => _process.kill();
}
