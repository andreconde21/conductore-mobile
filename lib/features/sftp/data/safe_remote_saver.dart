import 'dart:math';
import 'dart:typed_data';

import 'package:conduit/core/app_failure.dart';
import 'package:conduit/features/sftp/domain/sftp_save_result.dart';
import 'package:dartssh2/dartssh2.dart';

enum RemoteFileType { file, directory, symlink, other }

class RemoteFileInfo {
  const RemoteFileInfo({
    required this.type,
    this.mode,
    this.userId,
    this.groupId,
  });

  final RemoteFileType type;

  /// Permission bits including setuid, setgid and sticky (07777).
  final int? mode;
  final int? userId;
  final int? groupId;
}

/// The remote operations [SafeRemoteSaver] is built from.
/// [SftpClientSaveFileSystem] maps them onto an SFTP connection.
abstract class SafeSaveFileSystem {
  /// Whether a rename may atomically replace an existing file.
  Future<bool> supportsAtomicReplace();

  /// Null when nothing exists at [path]. Does not follow a symlink.
  Future<RemoteFileInfo?> lstat(String path);

  /// [path] with every symlink resolved. Fails for a dangling link.
  Future<String> realpath(String path);

  /// The file's hard link count, or null when the server does not say.
  Future<int?> linkCount(String path);

  /// Fails when the file at [path] cannot be opened for writing.
  Future<void> checkWritable(String path);

  /// Creates a new file, failing if [path] already exists.
  Future<SafeSaveHandle> createExclusive(String path);

  /// Truncates the file at [path] (creating it when missing) and writes
  /// [bytes] into it.
  Future<void> writeInPlace(String path, Uint8List bytes);

  /// Copies [from] to [to], replacing [to]; [mode] is applied to [to] before
  /// any content lands in it.
  Future<void> copy(String from, String to, {int? mode});

  Future<void> setAttributes(
    String path, {
    int? mode,
    int? userId,
    int? groupId,
  });

  /// Renames [from] over [to], replacing it atomically.
  Future<void> replace(String from, String to);

  Future<void> remove(String path);
}

abstract class SafeSaveHandle {
  Future<RemoteFileInfo> stat();

  Future<void> setMode(int mode);

  Future<void> write(Uint8List bytes);

  /// Flushes to stable storage where the server supports it; a no-op
  /// otherwise.
  Future<void> sync();

  Future<void> close();
}

/// Saves edited files without risking a half-written original (L8).
///
/// With an atomic rename the new contents go to a hidden temporary file
/// next to the original, which takes over the original's mode (and owner,
/// where allowed), is flushed, and is then renamed over it. Any failure
/// removes the temporary file and leaves the original as it was.
///
/// Cases where a replacement would change the file in ways an in-place
/// write does not fall back to writing in place: a file with other hard
/// links, whose links would be detached; and a file whose owner cannot be
/// kept, which would silently become ours. Servers without an atomic rename
/// also write in place, after copying the original to a backup file that
/// only survives a failed save.
///
/// One saver per session: the no-atomic-rename notice is shown once.
class SafeRemoteSaver {
  SafeRemoteSaver(this._fs, {Random? random})
    : _random = random ?? Random.secure();

  final SafeSaveFileSystem _fs;
  final Random _random;
  bool _toldAboutBackups = false;

  Future<SftpSaveResult> save(String path, Uint8List bytes) async {
    final name = _basename(path);
    try {
      final target = await _resolveLink(path);
      if (target == null) {
        // A dangling symlink: writing through it creates its target and
        // keeps the link, where a rename would replace the link itself.
        await _fs.writeInPlace(path, bytes);
        return const SftpSaveResult(SftpSaveMethod.inPlace);
      }
      final original = await _fs.lstat(target);
      if (original != null) {
        if (original.type == RemoteFileType.directory) {
          throw AppFailure('Could not save $name: it is a folder.');
        }
        // A replacement ignores the original's permissions, so make sure an
        // in-place write would have been allowed.
        await _fs.checkWritable(target);
      }
      if (!await _fs.supportsAtomicReplace()) {
        return await _saveWithBackup(target, bytes, original);
      }
      if (original != null && (await _fs.linkCount(target) ?? 1) > 1) {
        await _fs.writeInPlace(target, bytes);
        return const SftpSaveResult(
          SftpSaveMethod.inPlaceHardLinked,
          notice:
              'It has other hard links, so it was written in place to keep '
              'them: an interrupted save can leave it incomplete.',
        );
      }
      return await _saveAtomically(target, bytes, original);
    } on AppFailure {
      rethrow;
    } catch (error) {
      throw AppFailure('Could not save $name.', describeSaveError(error));
    }
  }

  /// [path] itself, its target when it is a symlink, or null when it is a
  /// symlink that points nowhere.
  Future<String?> _resolveLink(String path) async {
    final info = await _fs.lstat(path);
    if (info?.type != RemoteFileType.symlink) {
      return path;
    }
    try {
      final target = await _fs.realpath(path);
      final resolved = await _fs.lstat(target);
      return resolved?.type == RemoteFileType.symlink ? null : target;
    } catch (_) {
      return null;
    }
  }

  Future<SftpSaveResult> _saveAtomically(
    String target,
    Uint8List bytes,
    RemoteFileInfo? original,
  ) async {
    final name = _basename(target);
    final temp = '${_dirname(target)}/.$name.conductore-${_tag()}.tmp';
    final SafeSaveHandle handle;
    try {
      handle = await _fs.createExclusive(temp);
    } catch (_) {
      // The file is writable but its folder takes no new files.
      try {
        await _fs.writeInPlace(target, bytes);
      } catch (error) {
        throw AppFailure(
          'Could not save $name. The file on the server may be incomplete.',
          describeSaveError(error),
        );
      }
      return const SftpSaveResult(
        SftpSaveMethod.inPlace,
        notice:
            'Its folder does not allow new files, so it was written in '
            'place without a safety copy.',
      );
    }
    var handleOpen = true;
    try {
      final mode = original?.mode;
      final created = await handle.stat();
      // Plain permission bits first, so the new contents are never more
      // visible than the original's; setuid and friends go on at the end,
      // as a write or a chown would clear them.
      if (mode != null) {
        await handle.setMode(mode & 0x1FF);
      }
      await handle.write(bytes);
      await handle.sync();
      handleOpen = false;
      await handle.close();

      final userId = original?.userId;
      final groupId = original?.groupId;
      final ownerDiffers =
          userId != null &&
          groupId != null &&
          (userId != created.userId || groupId != created.groupId);
      if (ownerDiffers && !await _tryChown(temp, userId, groupId)) {
        // Not root and not in the file's group: replacing it would make the
        // file ours. Keep its owner by writing in place instead.
        await _removeQuietly(temp);
      } else {
        if (mode != null && (ownerDiffers || mode & 0xE00 != 0)) {
          await _fs.setAttributes(temp, mode: mode);
        }
        await _fs.replace(temp, target);
        return const SftpSaveResult(SftpSaveMethod.atomic);
      }
    } catch (error) {
      if (handleOpen) {
        await handle.close().catchError((Object _) {});
      }
      await _removeQuietly(temp);
      throw AppFailure(
        'Could not save $name. The file on the server is unchanged.',
        describeSaveError(error),
      );
    }
    // Only the owner-keeping fallback gets here.
    return _saveWithBackup(
      target,
      bytes,
      original,
      notice:
          'It belongs to another user or group, so it was written in place '
          'to keep its owner.',
    );
  }

  Future<bool> _tryChown(String path, int userId, int groupId) async {
    try {
      await _fs.setAttributes(path, userId: userId, groupId: groupId);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<SftpSaveResult> _saveWithBackup(
    String target,
    Uint8List bytes,
    RemoteFileInfo? original, {
    String? notice,
  }) async {
    final name = _basename(target);
    final backupName = '.$name.conductore-bak';
    String? backup;
    if (original != null) {
      final candidate = '${_dirname(target)}/$backupName';
      try {
        await _fs.copy(target, candidate, mode: _plainMode(original.mode));
        backup = candidate;
      } catch (_) {
        await _removeQuietly(candidate);
      }
    }
    try {
      await _fs.writeInPlace(target, bytes);
    } catch (error) {
      throw AppFailure(
        backup == null
            ? 'Could not save $name. The file on the server may be incomplete.'
            : 'Could not save $name. The file on the server may be '
                  'incomplete; its previous version is in $backupName.',
        describeSaveError(error),
      );
    }
    if (backup != null) {
      await _removeQuietly(backup);
    }
    if (original != null && backup == null) {
      return SftpSaveResult(
        SftpSaveMethod.inPlace,
        notice: [?notice, 'No backup copy could be made first.'].join(' '),
      );
    }
    if (notice == null && !_toldAboutBackups && original != null) {
      _toldAboutBackups = true;
      notice =
          'This server cannot replace files in one step, so saves write in '
          'place and keep a backup copy ($backupName) until they finish.';
    }
    return SftpSaveResult(SftpSaveMethod.inPlaceWithBackup, notice: notice);
  }

  Future<void> _removeQuietly(String path) async {
    try {
      await _fs.remove(path);
    } catch (_) {}
  }

  String _tag() =>
      List.generate(8, (_) => _random.nextInt(16).toRadixString(16)).join();

  static int? _plainMode(int? mode) => mode == null ? null : mode & 0x1FF;

  static String _basename(String path) =>
      path.substring(path.lastIndexOf('/') + 1);

  static String _dirname(String path) {
    final slash = path.lastIndexOf('/');
    if (slash < 0) return '.';
    if (slash == 0) return '';
    return path.substring(0, slash);
  }
}

/// The server's own words for an SFTP failure, else the error itself.
String describeSaveError(Object error) => switch (error) {
  SftpError(:final message) => message,
  AppFailure(:final message) => message,
  _ => '$error',
};
