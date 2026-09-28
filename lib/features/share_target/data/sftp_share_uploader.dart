import 'dart:async';
import 'dart:io';

import 'package:conduit/core/app_failure.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/sftp/domain/sftp_repository.dart';
import 'package:conduit/features/sftp/domain/sftp_session.dart';
import 'package:conduit/features/sftp/presentation/sftp_browser_controller.dart';
import 'package:conduit/features/share_target/domain/share_inbox.dart';
import 'package:conduit/features/share_target/domain/share_uploader.dart';
import 'package:conduit/features/share_target/domain/shared_payload.dart';

/// Uploads shared files into the host's inbox directory over SFTP, creating
/// the directory when missing. Cached copies are deleted once uploaded.
///
/// Nothing here waits forever: connecting is bounded by the repository's
/// SSH timeouts, every SFTP request by [operationTimeout], and a file
/// transfer fails once no bytes were acknowledged for [stallTimeout] (a
/// connection that died while the phone switched networks never errors on
/// its own). A progress report with nothing sent marks the end of
/// connecting, so the caller can tell the two apart.
///
/// Local-shell hosts share the app sandbox with the cached copy, so the
/// cache path itself is returned and nothing is transferred.
class SftpShareUploader implements ShareUploader {
  const SftpShareUploader(
    this._repository, {
    this.operationTimeout = const Duration(seconds: 30),
    this.stallTimeout = const Duration(seconds: 30),
  });

  final SftpRepository _repository;
  final Duration operationTimeout;
  final Duration stallTimeout;

  @override
  Future<List<String>> upload(
    SavedHost host,
    List<SharedFile> files, {
    void Function(ShareUploadProgress progress)? onProgress,
  }) async {
    if (files.isEmpty) {
      return const [];
    }
    for (final file in files) {
      if (!await File(file.path).exists()) {
        throw ShareFileUnavailable(
          '${file.name} is no longer on the phone. Share it again.',
        );
      }
    }
    if (host.isLocal) {
      return [for (final file in files) file.path];
    }
    final session = await _repository.connect(host);
    try {
      final home = await _bounded(host, session.resolve('.'));
      final inbox = resolveShareInboxPath(
        configured: host.shareInboxDirectory,
        home: home,
      );
      final existing = await _ensureDirectory(host, session, inbox);
      final names = planShareFileNames(files, existing);
      final remotePaths = <String>[];
      for (var index = 0; index < files.length; index += 1) {
        final file = files[index];
        final upload = SftpUploadFile.local(
          localPath: file.path,
          name: names[index],
          size: file.size,
        );
        final remotePath = shareRemotePath(inbox, names[index]);
        void report(int sent) => onProgress?.call(
          ShareUploadProgress(
            fileName: names[index],
            index: index,
            count: files.length,
            sent: sent,
            total: file.size,
          ),
        );
        report(0);
        try {
          await _writeWatched(session, remotePath, upload, report);
        } on TimeoutException {
          throw AppFailure(
            'The upload of ${file.name} to ${host.name} stalled: nothing '
            'was acknowledged for ${stallTimeout.inSeconds} s. Check the '
            'connection and retry.',
          );
        } catch (error) {
          throw AppFailure('Could not upload ${file.name}.', error);
        }
        remotePaths.add(remotePath);
        await _discardCache(file);
      }
      return remotePaths;
    } finally {
      // A dead connection may never confirm the close; the files are
      // already where they belong (or the error above says why not).
      try {
        await session.close().timeout(const Duration(seconds: 5));
      } catch (_) {}
    }
  }

  /// [request] within [operationTimeout], as a user-facing failure.
  Future<T> _bounded<T>(SavedHost host, Future<T> request) => request.timeout(
    operationTimeout,
    onTimeout: () => throw AppFailure(
      '${host.name} stopped responding to file requests. Check the '
      'connection and retry.',
    ),
  );

  /// Writes [upload] to [path], failing with a [TimeoutException] once no
  /// progress arrived for [stallTimeout].
  Future<void> _writeWatched(
    SftpSession session,
    String path,
    SftpUploadFile upload,
    void Function(int sent) onSent,
  ) {
    final done = Completer<void>();
    Timer? watchdog;
    void arm() {
      watchdog?.cancel();
      watchdog = Timer(stallTimeout, () {
        if (!done.isCompleted) {
          done.completeError(TimeoutException('upload stalled', stallTimeout));
        }
      });
    }

    arm();
    session
        .write(
          path,
          upload.openRead(),
          upload.size,
          onProgress: (sent) {
            if (done.isCompleted) return;
            arm();
            onSent(sent);
          },
        )
        .then(
          (_) {
            if (!done.isCompleted) done.complete();
          },
          onError: (Object error, StackTrace stack) {
            if (!done.isCompleted) done.completeError(error, stack);
          },
        );
    return done.future.whenComplete(() => watchdog?.cancel());
  }

  /// Creates [path] (and parents) when missing; returns the names already
  /// inside it so uploads can avoid overwriting.
  Future<Set<String>> _ensureDirectory(
    SavedHost host,
    SftpSession session,
    String path,
  ) async {
    try {
      final entries = await _bounded(host, session.list(path));
      return {for (final entry in entries) entry.name};
    } on AppFailure {
      rethrow;
    } catch (_) {
      // Missing (or unreadable): create it, parents first.
    }
    final parent = path.substring(0, path.lastIndexOf('/'));
    if (parent.isNotEmpty && parent != path) {
      await _ensureDirectory(host, session, parent);
    }
    try {
      await _bounded(host, session.makeDirectory(path));
    } on AppFailure {
      rethrow;
    } catch (error) {
      throw AppFailure('Could not create the inbox directory $path.', error);
    }
    return {};
  }

  Future<void> _discardCache(SharedFile file) async {
    try {
      final cached = File(file.path);
      if (await cached.exists()) {
        await cached.delete();
      }
      final parent = cached.parent;
      if (await parent.exists() && (await parent.list().isEmpty)) {
        await parent.delete();
      }
    } catch (_) {
      // Cache cleanup is best-effort; the native side prunes stale copies.
    }
  }
}
