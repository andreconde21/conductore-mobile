/// What sync carries, as the switches of Settings › Sync.
///
/// Every record key starts with a prefix that names its category (see
/// [SyncCategory.ofKey]); a key this build does not know is kept and passed
/// on untouched, so a newer app's records survive an older device.
enum SyncCategory {
  /// Saved machines with their per-machine settings, their order and the
  /// trusted host keys.
  machines,

  /// Passwords, private keys, key passphrases and hidden snippet text.
  /// Off by default; hardware-key stubs never sync.
  credentials,

  /// The global terminal snippets.
  snippets,

  /// Theme, font, keyboard rows, pill layout, gestures, speech and the
  /// other app preferences.
  appearance,

  /// Connect-picker choices, recent targets and recent directories.
  connections,

  /// The open-session list the app restores on launch.
  sessions,

  /// Where each device is (session, view, Chat View position), its recent
  /// places and its unsent Chat View drafts, so another device can offer
  /// to continue there. One record per device, written only by that
  /// device (see [SyncKeys.continuity]).
  continuity;

  String get label => switch (this) {
    SyncCategory.machines => 'Saved machines',
    SyncCategory.credentials => 'SSH keys and passwords',
    SyncCategory.snippets => 'Snippets',
    SyncCategory.appearance => 'Appearance and terminal settings',
    SyncCategory.connections => 'Connect preferences and recents',
    SyncCategory.sessions => 'Session list',
    SyncCategory.continuity => 'Continue where you left off',
  };

  String get description => switch (this) {
    SyncCategory.machines =>
      'Hostnames, ports, users, transport and per-machine settings, plus '
          'trusted host keys.',
    SyncCategory.credentials =>
      'Passwords, private keys and their passphrases, and hidden snippets. '
          'Hardware-key stubs never sync.',
    SyncCategory.snippets => 'Terminal snippets shared by every machine.',
    SyncCategory.appearance =>
      'Theme, font, keyboard rows, pill layout, gestures and speech.',
    SyncCategory.connections =>
      'Remembered connect choices, recent sessions and directories.',
    SyncCategory.sessions => 'The sessions reopened when the app starts.',
    SyncCategory.continuity =>
      'Where you are on each device and your unsent Chat View drafts, so '
          'another device offers to open the same place.',
  };

  /// Categories a new sync setup turns on: everything except credentials.
  static const defaults = {
    SyncCategory.machines,
    SyncCategory.snippets,
    SyncCategory.appearance,
    SyncCategory.connections,
    SyncCategory.sessions,
    SyncCategory.continuity,
  };

  /// Categories added after sync shipped that a setup made before them
  /// turns on too (see `SyncConfig.fromJson`).
  static const addedOn = {SyncCategory.continuity};

  /// Categories whose records are one per device (`<prefix>:<device id>`):
  /// each device writes its own and only reads the others' (see
  /// [SyncKeys.isForeign]).
  static const perDevice = {SyncCategory.continuity};

  /// Categories never written to backup files: they describe a moment,
  /// not settings to bring back.
  static const notBackedUp = {SyncCategory.continuity};

  static SyncCategory? parse(Object? raw) =>
      SyncCategory.values.where((c) => c.name == raw).firstOrNull;

  /// The category of a record key, or null for a prefix this build does
  /// not know (kept as is, never applied).
  static SyncCategory? ofKey(String key) {
    final prefix = key.split(':').first;
    return switch (prefix) {
      SyncKeys.hostPrefix ||
      SyncKeys.knownHostPrefix ||
      SyncKeys.hostListPrefix => SyncCategory.machines,
      SyncKeys.secretPrefix => SyncCategory.credentials,
      SyncKeys.snippetPrefix => SyncCategory.snippets,
      SyncKeys.settingPrefix => SyncCategory.appearance,
      SyncKeys.connectPrefix ||
      SyncKeys.recentDirsPrefix => SyncCategory.connections,
      SyncKeys.sessionsKey => SyncCategory.sessions,
      SyncKeys.continuityPrefix => SyncCategory.continuity,
      _ => null,
    };
  }
}

/// Record key spelling, shared by the local adapter and the tests.
abstract final class SyncKeys {
  static const hostPrefix = 'host';
  static const knownHostPrefix = 'knownHost';
  static const hostListPrefix = 'hosts';
  static const secretPrefix = 'secret';
  static const snippetPrefix = 'snippet';
  static const settingPrefix = 'setting';
  static const connectPrefix = 'connect';
  static const recentDirsPrefix = 'recentDirs';
  static const sessionsKey = 'sessions';
  static const continuityPrefix = 'continuity';

  static String host(String id) => '$hostPrefix:$id';
  static String hostSecret(String id) => '$secretPrefix:host:$id';
  static String snippetSecret(String id) => '$secretPrefix:snippet:$id';
  static String knownHost(String host, int port) =>
      '$knownHostPrefix:$host:$port';
  static const hostSortMode = '$hostListPrefix:sortMode';
  static const hostManualOrder = '$hostListPrefix:manualOrder';
  static String snippet(String id) => '$snippetPrefix:$id';
  static String setting(String name) => '$settingPrefix:$name';
  static String connect(String hostId) => '$connectPrefix:$hostId';
  static String recentDirs(String hostId) => '$recentDirsPrefix:$hostId';
  static String continuity(String deviceId) => '$continuityPrefix:$deviceId';

  /// Whether [key] is another device's record of a per-device category:
  /// this device reads it and passes it on, never edits or deletes it.
  static bool isForeign(String key, String deviceId) {
    final category = SyncCategory.ofKey(key);
    if (category == null || !SyncCategory.perDevice.contains(category)) {
      return false;
    }
    return key != '${key.split(':').first}:$deviceId';
  }

  /// The part after the first `prefix:`.
  static String idOf(String key, String prefix) =>
      key.substring(prefix.length + 1);
}
