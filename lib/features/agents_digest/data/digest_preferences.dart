import 'dart:convert';

import 'package:conduit/features/agents_digest/domain/agents_digest.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Stuck thresholds the dashboard passes to the companion; null keeps the
/// companion's default (30 min, 3 failures, 5 repeats, 60 min).
class DigestThresholds {
  const DigestThresholds({
    this.workingMinutes,
    this.sameFailures,
    this.sameCommands,
    this.approvalMinutes,
  });

  final int? workingMinutes;
  final int? sameFailures;
  final int? sameCommands;
  final int? approvalMinutes;

  static const defaults = (
    workingMinutes: 30,
    sameFailures: 3,
    sameCommands: 5,
    approvalMinutes: 60,
  );

  bool get isDefault =>
      workingMinutes == null &&
      sameFailures == null &&
      sameCommands == null &&
      approvalMinutes == null;

  /// The companion's `--stuck-*` flags for the values that are set.
  String get arguments => [
    if (workingMinutes case final v?) '--stuck-working-min $v',
    if (sameFailures case final v?) '--stuck-errors $v',
    if (sameCommands case final v?) '--stuck-repeats $v',
    if (approvalMinutes case final v?) '--stuck-approval-min $v',
  ].join(' ');

  Map<String, Object?> toJson() => {
    'workingMinutes': ?workingMinutes,
    'sameFailures': ?sameFailures,
    'sameCommands': ?sameCommands,
    'approvalMinutes': ?approvalMinutes,
  };

  static DigestThresholds fromJson(Object? json) {
    if (json is! Map) return const DigestThresholds();
    int? n(String key) {
      final v = json[key];
      return v is int && v > 0 ? v : null;
    }

    return DigestThresholds(
      workingMinutes: n('workingMinutes'),
      sameFailures: n('sameFailures'),
      sameCommands: n('sameCommands'),
      approvalMinutes: n('approvalMinutes'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DigestThresholds &&
      other.workingMinutes == workingMinutes &&
      other.sameFailures == sameFailures &&
      other.sameCommands == sameCommands &&
      other.approvalMinutes == approvalMinutes;

  @override
  int get hashCode =>
      Object.hash(workingMinutes, sameFailures, sameCommands, approvalMinutes);
}

/// Dashboard settings of this device (never synced: the last check is
/// per device).
class DigestPreferences {
  const DigestPreferences({
    this.summariesEnabled = true,
    this.window = DigestWindow.sinceLastCheck,
    this.lastSeen,
    this.thresholds = const DigestThresholds(),
  });

  /// Settings › Agents › Dashboard: "Summaries with Claude".
  final bool summariesEnabled;
  final DigestWindow window;

  /// When the user last looked (or pressed "Mark all seen").
  final DateTime? lastSeen;
  final DigestThresholds thresholds;

  DigestPreferences copyWith({
    bool? summariesEnabled,
    DigestWindow? window,
    DateTime? lastSeen,
    DigestThresholds? thresholds,
  }) => DigestPreferences(
    summariesEnabled: summariesEnabled ?? this.summariesEnabled,
    window: window ?? this.window,
    lastSeen: lastSeen ?? this.lastSeen,
    thresholds: thresholds ?? this.thresholds,
  );

  Map<String, Object?> toJson() => {
    'summaries': summariesEnabled,
    'window': window.name,
    if (lastSeen case final seen?) 'lastSeen': seen.millisecondsSinceEpoch,
    if (!thresholds.isDefault) 'thresholds': thresholds.toJson(),
  };

  static DigestPreferences fromJson(Object? json) {
    if (json is! Map) return const DigestPreferences();
    final seen = json['lastSeen'];
    return DigestPreferences(
      summariesEnabled: json['summaries'] != false,
      window: DigestWindow.parse(json['window']),
      lastSeen: seen is int
          ? DateTime.fromMillisecondsSinceEpoch(seen, isUtc: true)
          : null,
      thresholds: DigestThresholds.fromJson(json['thresholds']),
    );
  }
}

abstract class DigestPreferencesStore {
  Future<DigestPreferences> load();
  Future<void> save(DigestPreferences preferences);
}

/// In secure storage under its own key, outside every sync record.
class SecureDigestPreferencesStore implements DigestPreferencesStore {
  const SecureDigestPreferencesStore(this._storage);

  static const storageKey = 'digest_preferences_v1';

  final FlutterSecureStorage _storage;

  @override
  Future<DigestPreferences> load() async {
    try {
      final raw = await _storage.read(key: storageKey);
      if (raw == null || raw.isEmpty) return const DigestPreferences();
      return DigestPreferences.fromJson(jsonDecode(raw));
    } on Object {
      return const DigestPreferences();
    }
  }

  @override
  Future<void> save(DigestPreferences preferences) =>
      _storage.write(key: storageKey, value: jsonEncode(preferences.toJson()));
}

/// For tests and platforms without secure storage.
class MemoryDigestPreferencesStore implements DigestPreferencesStore {
  MemoryDigestPreferencesStore([this.value = const DigestPreferences()]);

  DigestPreferences value;

  @override
  Future<DigestPreferences> load() async => value;

  @override
  Future<void> save(DigestPreferences preferences) async => value = preferences;
}
