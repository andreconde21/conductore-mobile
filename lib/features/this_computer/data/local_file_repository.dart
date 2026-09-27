import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:conduit/core/app_failure.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/sftp/domain/sftp_entry.dart';
import 'package:conduit/features/sftp/domain/sftp_repository.dart';
import 'package:conduit/features/sftp/domain/sftp_save_result.dart';
import 'package:conduit/features/sftp/domain/sftp_session.dart';

/// The files of "This computer": the [SftpRepository] interface over the
/// local file system, so the file browser, viewer, image paste, share
/// uploads and the companion install work without SSH.
///
/// Paths use `/` like SFTP paths; `.` and `~` resolve to the home
/// directory.
class LocalFileRepository implements SftpRepository {
  const LocalFileRepository({this.home});

  /// The home directory; null means `$HOME` (`%USERPROFILE%` on Windows).
  final String? home;

  @override
  Future<SftpSession> connect(SavedHost host) async {
    final directory = home ?? localHomeDirectory();
    if (directory == null) {
      throw const AppFailure('Could not find the home directory.');
    }
    return LocalFileSession(home: directory);
  }
}

/// The home directory of the account the app runs as, or null.
String? localHomeDirectory() {
  final env = Platform.environment;
  final home = Platform.isWindows ? env['USERPROFILE'] : env['HOME'];
  if (home == null || home.isEmpty) return null;
  return home.replaceAll(r'\', '/');
}

class LocalFileSession implements SftpSession {
  LocalFileSession({required this.home});

  final String home;

  String _absolute(String path) {
    final trimmed = path.trim();
    if (trimmed.isEmpty || trimmed == '.' || trimmed == '~') return home;
    if (trimmed.startsWith('~/')) return '$home/${trimmed.substring(2)}';
    if (trimmed.startsWith('./')) return '$home/${trimmed.substring(2)}';
    if (_isAbsolute(trimmed)) return trimmed;
    return '$home/$trimmed';
  }

  static bool _isAbsolute(String path) =>
      path.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);

  @override
  Future<List<SftpEntry>> list(String path) async {
    final directory = Directory(_absolute(path));
    final entries = <SftpEntry>[];
    try {
      await for (final entity in directory.list(followLinks: false)) {
        final name = entity.path
            .replaceAll(r'\', '/')
            .split('/')
            .lastWhere((part) => part.isNotEmpty, orElse: () => entity.path);
        FileStat? stat;
        try {
          stat = await entity.stat();
        } catch (_) {
          stat = null;
        }
        final kind = switch (entity) {
          Link() => SftpEntryKind.symlink,
          Directory() => SftpEntryKind.directory,
          File() => SftpEntryKind.file,
          _ => SftpEntryKind.other,
        };
        entries.add(
          SftpEntry(
            name: name,
            path: _join(directory.path.replaceAll(r'\', '/'), name),
            kind: kind,
            size: kind == SftpEntryKind.file ? stat?.size : null,
            modifiedAt: stat?.modified,
            permissions: stat == null || Platform.isWindows
                ? null
                : stat.mode & 0xFFF,
          ),
        );
      }
    } on FileSystemException catch (error) {
      throw AppFailure('Could not list ${directory.path}.', error.message);
    }
    entries.sort((a, b) {
      if (a.isDirectory != b.isDirectory) {
        return a.isDirectory ? -1 : 1;
      }
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return entries;
  }

  @override
  Future<String> resolve(String path) async {
    final absolute = _absolute(path);
    try {
      return (await Directory(
        absolute,
      ).resolveSymbolicLinks()).replaceAll(r'\', '/');
    } on FileSystemException {
      return absolute;
    }
  }

  @override
  Future<Uint8List> read(
    String path, {
    void Function(int bytesRead, int? total)? onProgress,
    int? maxBytes,
  }) async {
    final file = File(_absolute(path));
    try {
      final total = await file.length();
      if (maxBytes != null && total > maxBytes) {
        final limitMb = (maxBytes / (1024 * 1024)).toStringAsFixed(0);
        throw AppFailure(
          'File is larger than $limitMb MB. Download it instead.',
        );
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in file.openRead()) {
        builder.add(chunk);
        if (maxBytes != null && builder.length > maxBytes) {
          throw const AppFailure('File grew past the size limit.');
        }
        onProgress?.call(builder.length, total);
      }
      return builder.takeBytes();
    } on FileSystemException catch (error) {
      throw AppFailure('Could not read ${file.path}.', error.message);
    }
  }

  @override
  Future<void> write(
    String path,
    Stream<Uint8List> data,
    int length, {
    void Function(int bytesSent)? onProgress,
  }) async {
    final file = File(_absolute(path));
    IOSink? sink;
    try {
      sink = file.openWrite();
      var sent = 0;
      await for (final chunk in data) {
        sink.add(chunk);
        sent += chunk.length;
        onProgress?.call(sent);
      }
      await sink.flush();
    } on FileSystemException catch (error) {
      throw AppFailure('Could not write ${file.path}.', error.message);
    } finally {
      await sink?.close();
    }
  }

  /// Local disks do not drop out mid-write the way a connection does, so
  /// this stays a plain write.
  @override
  Future<SftpSaveResult> save(String path, Uint8List bytes) async {
    await write(path, Stream.value(bytes), bytes.length);
    return const SftpSaveResult(SftpSaveMethod.inPlace);
  }

  @override
  Future<void> makeDirectory(String path) async {
    try {
      await Directory(_absolute(path)).create();
    } on FileSystemException catch (error) {
      throw AppFailure('Could not create $path.', error.message);
    }
  }

  @override
  Future<void> rename(String from, String to) async {
    final source = _absolute(from);
    try {
      final type = await FileSystemEntity.type(source, followLinks: false);
      final target = _absolute(to);
      switch (type) {
        case FileSystemEntityType.directory:
          await Directory(source).rename(target);
        case FileSystemEntityType.link:
          await Link(source).rename(target);
        default:
          await File(source).rename(target);
      }
    } on FileSystemException catch (error) {
      throw AppFailure('Could not rename $from.', error.message);
    }
  }

  /// Like SFTP `rmdir`, a directory must be empty.
  @override
  Future<void> delete(SftpEntry entry) async {
    final path = _absolute(entry.path);
    try {
      switch (entry.kind) {
        case SftpEntryKind.directory:
          await Directory(path).delete();
        case SftpEntryKind.symlink:
          await Link(path).delete();
        case SftpEntryKind.file || SftpEntryKind.other:
          await File(path).delete();
      }
    } on FileSystemException catch (error) {
      throw AppFailure('Could not delete ${entry.name}.', error.message);
    }
  }

  @override
  Future<void> close() async {}

  static String _join(String parent, String name) {
    if (parent.endsWith('/')) return '$parent$name';
    return '$parent/$name';
  }
}
