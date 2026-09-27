import 'dart:io';

import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/sftp/domain/sftp_entry.dart';
import 'package:conduit/features/sftp/domain/sftp_repository.dart';
import 'package:conduit/features/sftp/domain/sftp_session.dart';
import 'package:conduit/features/sftp/presentation/sftp_browser_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../support/test_doubles.dart';

void main() {
  group('SftpEntry', () {
    SftpEntry withMode(String octal) => SftpEntry(
      name: 'f',
      path: '/f',
      kind: SftpEntryKind.file,
      permissions: int.parse(octal, radix: 8),
    );

    test('formats permission bits like ls', () {
      expect(withMode('755').permissionString, 'rwxr-xr-x');
      expect(withMode('644').permissionString, 'rw-r--r--');
      expect(withMode('000').permissionString, '---------');
    });

    test('directories and symlinks are navigable; files are not', () {
      expect(entry(SftpEntryKind.directory).isNavigable, isTrue);
      expect(entry(SftpEntryKind.symlink).isNavigable, isTrue);
      expect(entry(SftpEntryKind.file).isNavigable, isFalse);
    });
  });

  group('SftpBrowserController', () {
    late FakeSftpSession session;
    late SftpBrowserController controller;
    late RecordingFileExport export;

    const dir = SftpEntry(
      name: 'docs',
      path: '/home/user/docs',
      kind: SftpEntryKind.directory,
    );
    const file = SftpEntry(
      name: 'a.txt',
      path: '/home/user/a.txt',
      kind: SftpEntryKind.file,
      size: 3,
    );

    setUp(() {
      session = FakeSftpSession(
        home: '/home/user',
        tree: {
          '/home/user': [dir, file],
          '/home/user/docs': <SftpEntry>[],
        },
      );
      export = RecordingFileExport();
      controller = SftpBrowserController(
        host: buildHost('files'),
        repository: FakeSftpRepository(session),
        fileExport: export,
      );
    });

    tearDown(() => controller.dispose());

    test('connect resolves the home directory and lists it', () async {
      await controller.connect();
      expect(controller.status, SftpBrowserStatus.ready);
      expect(controller.path, '/home/user');
      expect(controller.entries, hasLength(2));
      expect(controller.canGoUp, isTrue);
    });

    test('open navigates into a directory and goUp returns', () async {
      await controller.connect();
      await controller.open(dir);
      expect(controller.path, '/home/user/docs');
      await controller.goUp();
      expect(controller.path, '/home/user');
    });

    test('download reads the file and saves it to downloads', () async {
      await controller.connect();
      final location = await controller.download(file);
      expect(location, 'Downloads/a.txt');
      expect(export.saved.single.$1, 'a.txt');
    });

    test('download archives folders recursively', () async {
      session.tree['/home/user/docs'] = [
        const SftpEntry(
          name: 'nested.txt',
          path: '/home/user/docs/nested.txt',
          kind: SftpEntryKind.file,
          size: 3,
        ),
      ];

      await controller.connect();
      final location = await controller.download(dir);

      expect(location, 'Downloads/docs.tar');
      expect(export.saved.single.$1, 'docs.tar');
      expect(
        String.fromCharCodes(export.saved.single.$2),
        contains('nested.txt'),
      );
    });

    test('makeDirectory issues the join under the current path', () async {
      await controller.connect();
      await controller.makeDirectory('new');
      expect(session.madeDirectories.single, '/home/user/new');
    });

    test('uploads multiple files under the current path', () async {
      final tempDir = await Directory.systemTemp.createTemp('conduit_sftp_');
      addTearDown(() => tempDir.delete(recursive: true));
      final first = File('${tempDir.path}/one.txt');
      final second = File('${tempDir.path}/two.txt');
      await first.writeAsBytes([1, 2]);
      await second.writeAsBytes([3, 4, 5]);

      await controller.connect();
      await controller.uploadFiles([
        SftpUploadFile.local(localPath: first.path, name: 'one.txt', size: 2),
        SftpUploadFile.local(localPath: second.path, name: 'two.txt', size: 3),
      ]);

      expect(session.writtenFiles['/home/user/one.txt'], [1, 2]);
      expect(session.writtenFiles['/home/user/two.txt'], [3, 4, 5]);
      expect(session.listCalls['/home/user'], 2);
      expect(controller.transfer, isNull);
      expect(controller.busy, isFalse);
    });

    test(
      'search filters current folder entries by name and metadata',
      () async {
        await controller.connect();

        controller.setSearchQuery('txt');
        expect(controller.visibleEntries, [file]);

        controller.setSearchQuery('directory');
        expect(controller.visibleEntries, [dir]);

        controller.clearSearch();
        expect(controller.visibleEntries, [dir, file]);
      },
    );

    test(
      'sort keeps folders first and orders files by selected mode',
      () async {
        final older = SftpEntry(
          name: 'older.log',
          path: '/home/user/older.log',
          kind: SftpEntryKind.file,
          size: 200,
          modifiedAt: DateTime(2024),
        );
        final newer = SftpEntry(
          name: 'newer.log',
          path: '/home/user/newer.log',
          kind: SftpEntryKind.file,
          size: 100,
          modifiedAt: DateTime(2025),
        );
        session.tree['/home/user'] = [older, dir, newer];

        await controller.connect();
        controller.setSortMode(SftpSortMode.modified);
        expect(controller.visibleEntries, [dir, newer, older]);

        controller.setSortMode(SftpSortMode.size);
        expect(controller.visibleEntries, [dir, older, newer]);
      },
    );

    test('connect failure surfaces an error status', () async {
      final failing = SftpBrowserController(
        host: buildHost('bad'),
        repository: ThrowingSftpRepository(),
        fileExport: export,
      );
      addTearDown(failing.dispose);
      await failing.connect();
      expect(failing.status, SftpBrowserStatus.failed);
      expect(failing.errorMessage, isNotNull);
    });

    test('Retry closes the session that could not list', () async {
      // Connects, but listing the home directory fails.
      final sessions = <FakeSftpSession>[];
      final retrying = SftpBrowserController(
        host: buildHost('files'),
        repository: _NewSessionSftpRepository(sessions),
        fileExport: export,
      );
      addTearDown(retrying.dispose);
      await retrying.connect();
      expect(retrying.status, SftpBrowserStatus.failed);

      await retrying.connect();
      expect(sessions, hasLength(2));
      expect(sessions.first.closeCalls, 1);
      expect(sessions.last.closeCalls, 0);
    });
  });
}

/// A new session per connection, with nothing to list.
class _NewSessionSftpRepository implements SftpRepository {
  _NewSessionSftpRepository(this.sessions);

  final List<FakeSftpSession> sessions;

  @override
  Future<SftpSession> connect(SavedHost host) async {
    final session = FakeSftpSession(home: '/home/user', tree: {});
    sessions.add(session);
    return session;
  }
}
