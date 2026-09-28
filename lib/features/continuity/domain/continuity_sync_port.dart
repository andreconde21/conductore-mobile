/// Continuity's side of device sync: what `AppLocalSyncStore` writes as
/// this device's `continuity:<device id>` record, and where it hands the
/// other devices' records.
abstract interface class ContinuitySyncPort {
  /// This device's record as JSON, or null while there is nothing to
  /// share (continuity not loaded yet).
  Future<Object?> ownRecord(String deviceId);

  /// The other devices' records (sync key to value), all of them as the
  /// hub holds them now.
  Future<void> receive(
    Map<String, Object?> records, {
    required String deviceId,
  });
}
