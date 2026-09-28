import 'package:conduit/core/app_failure.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/share_target/domain/shared_payload.dart';

class ShareUploadProgress {
  const ShareUploadProgress({
    required this.fileName,
    required this.index,
    required this.count,
    required this.sent,
    required this.total,
  });

  final String fileName;
  final int index;
  final int count;
  final int sent;
  final int total;

  double? get fraction => total <= 0 ? null : (sent / total).clamp(0.0, 1.0);
}

/// Copies shared files to a host and reports where they landed.
abstract class ShareUploader {
  Future<List<String>> upload(
    SavedHost host,
    List<SharedFile> files, {
    void Function(ShareUploadProgress progress)? onProgress,
  });
}

/// A shared file whose phone-side copy is gone (the cache was cleared, or
/// it was never readable), so retrying cannot help: it must be shared
/// again.
class ShareFileUnavailable extends AppFailure {
  const ShareFileUnavailable(super.message);
}
