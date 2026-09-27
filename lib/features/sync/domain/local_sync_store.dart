import 'package:conduit/features/sync/domain/sync_category.dart';
import 'package:flutter/foundation.dart';

/// Which of this device's data a snapshot or apply covers.
@immutable
class LocalSyncOptions {
  const LocalSyncOptions({
    required this.categories,
    this.hubHostId,
    this.includeHardwareKeys = false,
  });

  final Set<SyncCategory> categories;

  /// The sync hub's saved machine. Its login (auth method and secrets)
  /// stays on each device: every device reaches the hub its own way.
  final String? hubHostId;

  /// Hardware-key stubs go into file backups with credentials, never into
  /// sync.
  final bool includeHardwareKeys;
}

/// This device's data as sync records (key to JSON value), and the way
/// back.
abstract interface class LocalSyncStore {
  /// Every record of [options]' categories as it is on this device now.
  /// Throws when the data cannot be read, so a failed read never looks
  /// like everything was deleted.
  Future<Map<String, Object?>> snapshot(LocalSyncOptions options);

  /// Brings the records under [changedKeys] into the app. [values] holds
  /// every live record of the enabled categories (not only the changed
  /// ones), so lists (machines, snippets) can be rebuilt in order; a
  /// changed key missing from [values] was deleted.
  ///
  /// With [replace] false (importing a backup) nothing is deleted and
  /// local items the values do not mention are kept.
  Future<void> apply(
    Map<String, Object?> values,
    Set<String> changedKeys,
    LocalSyncOptions options, {
    bool replace = true,
  });

  /// Moves this device's per-host data (connect memory, recent
  /// directories, the machine whose theme is followed) from each old id in
  /// [renamed] to its new one, after saved machines changed id.
  Future<void> renameHosts(Map<String, String> renamed);
}

class LocalSyncUnavailable implements Exception {
  const LocalSyncUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}
