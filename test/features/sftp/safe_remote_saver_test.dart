import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:conduit/core/app_failure.dart';
import 'package:conduit/features/sftp/data/safe_remote_saver.dart';
import 'package:conduit/features/sftp/data/sftp_client_save_file_system.dart';
import 'package:conduit/features/sftp/domain/sftp_save_result.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late _MemoryFs fs;
  late SafeRemoteSaver saver;

  Uint8List bytes(String text) => Uint8List.fromList(utf8.encode(text));

  setUp(() {
    fs = _MemoryFs();
    saver = SafeRemoteSaver(fs, random: Random(1));
  });

  test('replaces the file through a temp file and a rename', () async {
    fs.addFile('/srv/app.conf', 'old', mode: 0x1A0); // 0640

    final result = await saver.save('/srv/app.conf', bytes('new'));

    expect(result.method, SftpSaveMethod.atomic);
    expect(result.notice, isNull);
    expect(fs.text('/srv/app.conf'), 'new');
    expect(fs.node('/srv/app.conf').mode, 0x1A0);
    expect(fs.renames.single.$2, '/srv/app.conf');
    expect(
      fs.renames.single.$1,
      matches(RegExp(r'^/srv/\.app\.conf\.conductore-[0-9a-f]{8}\.tmp$')),
    );
    expect(fs.synced, isTrue);
    expect(fs.paths, ['/srv/app.conf']);
  });

  test('a failure mid-write leaves the original untouched', () async {
    fs.addFile('/srv/app.conf', 'old');
    fs.failWriteAfter = 2;

    await expectLater(
      saver.save('/srv/app.conf', bytes('new contents')),
      throwsA(
        isA<AppFailure>().having(
          (f) => f.message,
          'message',
          'Could not save app.conf. The file on the server is unchanged.',
        ),
      ),
    );

    expect(fs.text('/srv/app.conf'), 'old');
    expect(fs.paths, ['/srv/app.conf'], reason: 'temp file cleaned up');
    expect(fs.openHandles, 0);
  });

  test('a failed rename leaves the original and removes the temp', () async {
    fs.addFile('/srv/app.conf', 'old');
    fs.failRename = true;

    await expectLater(
      saver.save('/srv/app.conf', bytes('new')),
      throwsA(isA<AppFailure>()),
    );

    expect(fs.text('/srv/app.conf'), 'old');
    expect(fs.paths, ['/srv/app.conf']);
  });

  test('keeps setuid and similar bits, set after the content', () async {
    fs.addFile('/bin/tool', 'old', mode: 0x9ED); // 04755

    await saver.save('/bin/tool', bytes('new'));

    expect(fs.node('/bin/tool').mode, 0x9ED);
  });

  test('the temp file never has wider permissions than the original', () {
    fs.addFile('/home/me/.netrc', 'secret', mode: 0x180); // 0600
    fs.onWrite = (path, node) {
      if (path.endsWith('.tmp')) expect(node.mode, 0x180);
    };

    return saver.save('/home/me/.netrc', bytes('secret 2'));
  });

  test('writes the target of a symlink and keeps the link', () async {
    fs.addFile('/etc/real.conf', 'old', mode: 0x1A4);
    fs.addLink('/home/me/app.conf', '/etc/real.conf');

    final result = await saver.save('/home/me/app.conf', bytes('new'));

    expect(result.method, SftpSaveMethod.atomic);
    expect(fs.text('/etc/real.conf'), 'new');
    expect(fs.node('/home/me/app.conf').linkTo, '/etc/real.conf');
    expect(fs.renames.single.$1, startsWith('/etc/.real.conf.conductore-'));
  });

  test('writes through a dangling symlink', () async {
    fs.addLink('/home/me/app.conf', '/etc/missing.conf');

    final result = await saver.save('/home/me/app.conf', bytes('new'));

    expect(result.method, SftpSaveMethod.inPlace);
    expect(fs.node('/home/me/app.conf').linkTo, '/etc/missing.conf');
    expect(fs.text('/etc/missing.conf'), 'new');
  });

  test('writes a hard-linked file in place and says why', () async {
    fs.addFile('/srv/a', 'old');
    fs.files['/srv/b'] = fs.node('/srv/a');

    final result = await saver.save('/srv/a', bytes('new'));

    expect(result.method, SftpSaveMethod.inPlaceHardLinked);
    expect(result.notice, contains('hard links'));
    expect(identical(fs.node('/srv/a'), fs.node('/srv/b')), isTrue);
    expect(fs.text('/srv/b'), 'new');
    expect(fs.renames, isEmpty);
  });

  test('without an atomic rename, backs up first and says so once', () async {
    fs.atomicReplace = false;
    fs.addFile('/srv/app.conf', 'old', mode: 0x180);
    final backupsDuringWrites = <String>[];
    fs.onWrite = (path, _) {
      if (path == '/srv/app.conf') {
        backupsDuringWrites.add(fs.text('/srv/.app.conf.conductore-bak'));
        expect(fs.node('/srv/.app.conf.conductore-bak').mode, 0x180);
      }
    };

    final first = await saver.save('/srv/app.conf', bytes('new'));
    final second = await saver.save('/srv/app.conf', bytes('newer'));

    expect(backupsDuringWrites, ['old', 'new']);
    expect(first.method, SftpSaveMethod.inPlaceWithBackup);
    expect(first.notice, contains('.app.conf.conductore-bak'));
    expect(second.notice, isNull);
    expect(fs.text('/srv/app.conf'), 'newer');
    expect(fs.paths, ['/srv/app.conf'], reason: 'backup removed');
  });

  test('without an atomic rename, a failed write keeps the backup', () async {
    fs.atomicReplace = false;
    fs.addFile('/srv/app.conf', 'old');
    fs.failWriteAfter = 1;

    await expectLater(
      saver.save('/srv/app.conf', bytes('new contents')),
      throwsA(
        isA<AppFailure>().having(
          (f) => f.message,
          'message',
          contains('previous version is in .app.conf.conductore-bak'),
        ),
      ),
    );

    expect(fs.text('/srv/.app.conf.conductore-bak'), 'old');
  });

  test('keeps a foreign owner by writing in place when chown fails', () async {
    fs.addFile('/srv/shared.txt', 'old', mode: 0x1B6, userId: 0, groupId: 50);

    final result = await saver.save('/srv/shared.txt', bytes('new'));

    expect(result.method, SftpSaveMethod.inPlaceWithBackup);
    expect(result.notice, contains('keep its owner'));
    final node = fs.node('/srv/shared.txt');
    expect((node.userId, node.groupId), (0, 50));
    expect(fs.text('/srv/shared.txt'), 'new');
    expect(fs.paths, ['/srv/shared.txt']);
  });

  test('as root, restores the owner on the replacement', () async {
    fs.root = true;
    fs.addFile('/srv/shared.txt', 'old', mode: 0x1A4, userId: 33, groupId: 33);

    final result = await saver.save('/srv/shared.txt', bytes('new'));

    expect(result.method, SftpSaveMethod.atomic);
    final node = fs.node('/srv/shared.txt');
    expect((node.userId, node.groupId, node.mode), (33, 33, 0x1A4));
  });

  test('refuses a file an in-place write could not change', () async {
    fs.addFile('/srv/locked', 'old', mode: 0x124); // 0444

    await expectLater(
      saver.save('/srv/locked', bytes('new')),
      throwsA(isA<AppFailure>()),
    );
    expect(fs.text('/srv/locked'), 'old');
  });

  test('writes in place when the folder takes no new files', () async {
    fs.addFile('/srv/app.conf', 'old');
    fs.lockedDirs.add('/srv');

    final result = await saver.save('/srv/app.conf', bytes('new'));

    expect(result.method, SftpSaveMethod.inPlace);
    expect(result.notice, contains('folder'));
    expect(fs.text('/srv/app.conf'), 'new');
  });

  test('creates a file that does not exist yet', () async {
    final result = await saver.save('/srv/new.txt', bytes('hi'));

    expect(result.method, SftpSaveMethod.atomic);
    expect(fs.text('/srv/new.txt'), 'hi');
  });

  test('reads the link count from an ls -l style long name', () {
    expect(
      parseLongNameLinkCount(
        '-rw-r--r--    2 andre    staff        12 Sep 27 10:00 a.txt',
      ),
      2,
    );
    expect(parseLongNameLinkCount('-rw-r--r--+ 1 u g 1 Jan 1 2026 f'), 1);
    expect(parseLongNameLinkCount('a.txt'), isNull);
    expect(parseLongNameLinkCount(''), isNull);
  });
}

class _Node {
  _Node(
    this.content, {
    this.mode = 0x1A4,
    this.userId = 1000,
    this.groupId = 1000,
  });

  _Node.link(String target)
    : linkTo = target,
      content = const [],
      mode = 0x1FF,
      userId = 1000,
      groupId = 1000;

  List<int> content;
  int mode;
  int userId;
  int groupId;
  String? linkTo;
}

/// A tiny POSIX-ish file system: paths map to nodes, and two paths sharing
/// a node are hard links.
class _MemoryFs implements SafeSaveFileSystem {
  final Map<String, _Node> files = {};
  final List<(String, String)> renames = [];
  final Set<String> lockedDirs = {};
  bool atomicReplace = true;
  bool root = false;
  bool failRename = false;
  bool synced = false;
  int openHandles = 0;

  /// Fails the write once this many bytes have landed.
  int? failWriteAfter;
  void Function(String path, _Node node)? onWrite;

  void addFile(
    String path,
    String text, {
    int mode = 0x1A4,
    int userId = 1000,
    int groupId = 1000,
  }) {
    files[path] = _Node(
      utf8.encode(text),
      mode: mode,
      userId: userId,
      groupId: groupId,
    );
  }

  void addLink(String path, String target) => files[path] = _Node.link(target);

  _Node node(String path) => files[path]!;

  String text(String path) => utf8.decode(files[path]!.content);

  List<String> get paths => files.keys.toList()..sort();

  String _dir(String path) => path.substring(0, path.lastIndexOf('/'));

  void _put(String path, List<int> data) {
    final target = files[path];
    onWrite?.call(path, target ?? _Node(const []));
    final limit = failWriteAfter;
    if (limit != null && data.length > limit) {
      target?.content = data.sublist(0, limit);
      throw StateError('connection lost');
    }
    target!.content = List.of(data);
  }

  @override
  Future<bool> supportsAtomicReplace() async => atomicReplace;

  @override
  Future<RemoteFileInfo?> lstat(String path) async {
    final n = files[path];
    if (n == null) return null;
    return RemoteFileInfo(
      type: n.linkTo != null ? RemoteFileType.symlink : RemoteFileType.file,
      mode: n.mode,
      userId: n.userId,
      groupId: n.groupId,
    );
  }

  @override
  Future<String> realpath(String path) async {
    var current = path;
    while (files[current]?.linkTo != null) {
      current = files[current]!.linkTo!;
    }
    if (!files.containsKey(current)) throw StateError('No such file');
    return current;
  }

  @override
  Future<int?> linkCount(String path) async {
    final n = files[path];
    return files.values.where((other) => identical(other, n)).length;
  }

  @override
  Future<void> checkWritable(String path) async {
    final n = files[path]!;
    if (!root && n.mode & 0x080 == 0 && n.mode & 0x002 == 0) {
      throw StateError('Permission denied');
    }
  }

  @override
  Future<SafeSaveHandle> createExclusive(String path) async {
    if (lockedDirs.contains(_dir(path))) throw StateError('Permission denied');
    if (files.containsKey(path)) throw StateError('Exists');
    files[path] = _Node(
      [],
      mode: 0x1A4,
      userId: root ? 0 : 1000,
      groupId: root ? 0 : 1000,
    );
    openHandles++;
    return _MemoryHandle(this, path);
  }

  @override
  Future<void> writeInPlace(String path, Uint8List bytes) async {
    var target = path;
    while (files[target]?.linkTo != null) {
      target = files[target]!.linkTo!;
    }
    files.putIfAbsent(target, () => _Node([]));
    files[target]!.content = [];
    _put(target, bytes);
  }

  @override
  Future<void> copy(String from, String to, {int? mode}) async {
    files[to] = _Node(List.of(files[from]!.content), mode: mode ?? 0x1A4);
  }

  @override
  Future<void> setAttributes(
    String path, {
    int? mode,
    int? userId,
    int? groupId,
  }) async {
    final n = files[path]!;
    if (userId != null || groupId != null) {
      if (!root) throw StateError('Operation not permitted');
      n.userId = userId ?? n.userId;
      n.groupId = groupId ?? n.groupId;
    }
    if (mode != null) n.mode = mode;
  }

  @override
  Future<void> replace(String from, String to) async {
    if (failRename) throw StateError('rename failed');
    renames.add((from, to));
    files[to] = files.remove(from)!;
  }

  @override
  Future<void> remove(String path) async {
    files.remove(path);
  }
}

class _MemoryHandle implements SafeSaveHandle {
  _MemoryHandle(this.fs, this.path);

  final _MemoryFs fs;
  final String path;

  @override
  Future<RemoteFileInfo> stat() async => (await fs.lstat(path))!;

  @override
  Future<void> setMode(int mode) async => fs.files[path]!.mode = mode;

  @override
  Future<void> write(Uint8List bytes) async => fs._put(path, bytes);

  @override
  Future<void> sync() async => fs.synced = true;

  @override
  Future<void> close() async => fs.openHandles--;
}
