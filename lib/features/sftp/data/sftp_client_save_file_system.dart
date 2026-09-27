import 'dart:typed_data';

import 'package:conduit/features/sftp/data/safe_remote_saver.dart';
import 'package:dartssh2/dartssh2.dart';

/// [SafeSaveFileSystem] over an SFTP connection. The atomic replace and the
/// flush are OpenSSH extensions, used only when the server advertises them.
class SftpClientSaveFileSystem implements SafeSaveFileSystem {
  SftpClientSaveFileSystem(this._sftp);

  final SftpClient _sftp;

  static const _posixRename = 'posix-rename@openssh.com';
  static const _fsync = 'fsync@openssh.com';

  @override
  Future<bool> supportsAtomicReplace() =>
      _sftp.supportsExtension(_posixRename, '1');

  @override
  Future<RemoteFileInfo?> lstat(String path) async {
    try {
      return _toInfo(await _sftp.stat(path, followLink: false));
    } on SftpStatusError catch (error) {
      if (error.code == SftpStatusCode.noSuchFile) {
        return null;
      }
      rethrow;
    }
  }

  @override
  Future<String> realpath(String path) => _sftp.absolute(path);

  /// SFTP v3 attributes carry no link count, but OpenSSH's directory
  /// listing has an `ls -l` style long name whose second column is it.
  @override
  Future<int?> linkCount(String path) async {
    final slash = path.lastIndexOf('/');
    final parent = slash <= 0 ? '/' : path.substring(0, slash);
    final name = path.substring(slash + 1);
    for (final entry in await _sftp.listdir(parent)) {
      if (entry.filename == name) {
        return parseLongNameLinkCount(entry.longname);
      }
    }
    return null;
  }

  @override
  Future<void> checkWritable(String path) async {
    final file = await _sftp.open(path, mode: SftpFileOpenMode.write);
    await file.close();
  }

  @override
  Future<SafeSaveHandle> createExclusive(String path) async {
    final file = await _create(
      path,
      SftpFileOpenMode.create |
          SftpFileOpenMode.exclusive |
          SftpFileOpenMode.write,
    );
    return _SftpSaveHandle(
      file,
      canSync: await _sftp.supportsExtension(_fsync, '1'),
    );
  }

  @override
  Future<void> writeInPlace(String path, Uint8List bytes) async {
    final file = await _sftp.open(
      path,
      mode:
          SftpFileOpenMode.create |
          SftpFileOpenMode.write |
          SftpFileOpenMode.truncate,
    );
    try {
      await file.writeBytes(bytes);
    } finally {
      await file.close();
    }
  }

  @override
  Future<void> copy(String from, String to, {int? mode}) async {
    final source = await _sftp.open(from);
    try {
      final destination = await _create(
        to,
        SftpFileOpenMode.create |
            SftpFileOpenMode.write |
            SftpFileOpenMode.truncate,
      );
      try {
        if (mode != null) {
          await destination.setStat(
            SftpFileAttrs(mode: SftpFileMode.value(mode)),
          );
        }
        var offset = 0;
        await for (final chunk in source.read()) {
          await destination.writeBytes(chunk, offset: offset);
          offset += chunk.length;
        }
      } finally {
        await destination.close();
      }
    } finally {
      await source.close();
    }
  }

  /// Opens [path] with [mode], reporting a refusal from the server as a
  /// [CannotCreateFileError]. Transport failures stay as they are.
  Future<SftpFile> _create(String path, SftpFileOpenMode mode) async {
    try {
      return await _sftp.open(path, mode: mode);
    } on SftpStatusError catch (error) {
      if (error.code == SftpStatusCode.permissionDenied ||
          error.code == SftpStatusCode.failure) {
        throw CannotCreateFileError(error);
      }
      rethrow;
    }
  }

  @override
  Future<void> setAttributes(
    String path, {
    int? mode,
    int? userId,
    int? groupId,
  }) {
    return _sftp.setStat(
      path,
      SftpFileAttrs(
        mode: mode == null ? null : SftpFileMode.value(mode),
        userID: userId,
        groupID: groupId,
      ),
    );
  }

  @override
  Future<void> replace(String from, String to) => _sftp.posixRename(from, to);

  @override
  Future<void> remove(String path) => _sftp.remove(path);
}

class _SftpSaveHandle implements SafeSaveHandle {
  _SftpSaveHandle(this._file, {required this.canSync});

  final SftpFile _file;
  final bool canSync;

  @override
  Future<RemoteFileInfo> stat() async => _toInfo(await _file.stat());

  @override
  Future<void> setMode(int mode) =>
      _file.setStat(SftpFileAttrs(mode: SftpFileMode.value(mode)));

  @override
  Future<void> write(Uint8List bytes) => _file.writeBytes(bytes);

  @override
  Future<void> sync() async {
    if (canSync) {
      await _file.fsync();
    }
  }

  @override
  Future<void> close() => _file.close();
}

RemoteFileInfo _toInfo(SftpFileAttrs attrs) {
  return RemoteFileInfo(
    type: switch (attrs.type) {
      SftpFileType.regularFile => RemoteFileType.file,
      SftpFileType.directory => RemoteFileType.directory,
      SftpFileType.symbolicLink => RemoteFileType.symlink,
      _ => RemoteFileType.other,
    },
    mode: attrs.mode == null ? null : attrs.mode!.value & 0xFFF,
    userId: attrs.userID,
    groupId: attrs.groupID,
  );
}

/// The link count from an `ls -l` style SFTP long name
/// (`-rw-r--r--    2 user group ...`), or null when it has another shape.
int? parseLongNameLinkCount(String longName) {
  final match = RegExp(r'^[-a-zA-Z?]\S{9,}\s+(\d+)\s').firstMatch(longName);
  return match == null ? null : int.tryParse(match.group(1)!);
}
