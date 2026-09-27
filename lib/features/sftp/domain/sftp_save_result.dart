/// How [SftpSession.save] wrote a file.
enum SftpSaveMethod {
  /// Written to a temporary file that then replaced the original in one
  /// step, so a dropped connection leaves the original untouched.
  atomic,

  /// Written in place because the file has other hard links, which a
  /// replacement would detach.
  inPlaceHardLinked,

  /// Written in place after copying the original to a backup file, which is
  /// deleted once the write finishes.
  inPlaceWithBackup,

  /// Written in place with no safety net.
  inPlace,
}

class SftpSaveResult {
  const SftpSaveResult(this.method, {this.notice});

  final SftpSaveMethod method;

  /// Something the user should know about how the file was saved, or null.
  final String? notice;
}
