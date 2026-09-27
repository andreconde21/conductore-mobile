import 'dart:typed_data';

import 'package:conduit/features/sftp/domain/sftp_entry.dart';
import 'package:conduit/features/sftp/domain/sftp_save_result.dart';

abstract class SftpSession {
  Future<List<SftpEntry>> list(String path);

  Future<String> resolve(String path);

  /// Reads the whole file. When [maxBytes] is set the read fails with an
  /// `AppFailure` instead of buffering a file larger than that.
  Future<Uint8List> read(
    String path, {
    void Function(int bytesRead, int? total)? onProgress,
    int? maxBytes,
  });

  Future<void> write(
    String path,
    Stream<Uint8List> data,
    int length, {
    void Function(int bytesSent)? onProgress,
  });

  /// Replaces the contents of the existing (or new) file at [path] with
  /// [bytes], the way an editor saves: where the server allows it through a
  /// temporary file and an atomic rename, so a dropped connection cannot
  /// leave the file half-written. Unlike [write], which truncates in place.
  Future<SftpSaveResult> save(String path, Uint8List bytes);

  Future<void> makeDirectory(String path);

  Future<void> rename(String from, String to);

  Future<void> delete(SftpEntry entry);

  Future<void> close();
}
