import 'dart:convert';

import 'package:conduit/features/usage/domain/usage_explorer.dart';
import 'package:conduit/features/usage/domain/usage_range.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Usage settings of this device. Never synced or backed up: an alert that
/// fires on the phone need not fire on the desktop too.
class UsagePreferences {
  const UsagePreferences({
    this.alertEnabled = false,
    this.barCollapsed = false,
    this.alertedWindow,
    this.explorerRange = UsageRangePreset.last7,
    this.explorerCustom,
    this.explorerMetric = UsageMetric.tokens,
  });

  /// Settings › Agents: "Alert at 80% of the 5-hour window".
  final bool alertEnabled;

  /// The home usage bar shows one line instead of its details.
  final bool barCollapsed;

  /// The 5-hour window the last alert was for, so a restart does not alert
  /// again.
  final DateTime? alertedWindow;

  /// The usage explorer's last range, custom dates and measure.
  final UsageRangePreset explorerRange;
  final UsageDateRange? explorerCustom;
  final UsageMetric explorerMetric;

  UsagePreferences copyWith({
    bool? alertEnabled,
    bool? barCollapsed,
    DateTime? alertedWindow,
    UsageRangePreset? explorerRange,
    UsageDateRange? explorerCustom,
    UsageMetric? explorerMetric,
  }) => UsagePreferences(
    alertEnabled: alertEnabled ?? this.alertEnabled,
    barCollapsed: barCollapsed ?? this.barCollapsed,
    alertedWindow: alertedWindow ?? this.alertedWindow,
    explorerRange: explorerRange ?? this.explorerRange,
    explorerCustom: explorerCustom ?? this.explorerCustom,
    explorerMetric: explorerMetric ?? this.explorerMetric,
  );

  Map<String, Object?> toJson() => {
    'alertEnabled': alertEnabled,
    'barCollapsed': barCollapsed,
    if (alertedWindow case final window?)
      'alertedWindow': window.millisecondsSinceEpoch,
    'explorerRange': explorerRange.name,
    if (explorerCustom case final custom?)
      'explorerCustom': [custom.from, custom.to],
    'explorerMetric': explorerMetric.name,
  };

  static UsagePreferences fromJson(Object? json) {
    if (json is! Map) {
      return const UsagePreferences();
    }
    final window = json['alertedWindow'];
    final custom = json['explorerCustom'];
    return UsagePreferences(
      alertEnabled: json['alertEnabled'] == true,
      barCollapsed: json['barCollapsed'] == true,
      alertedWindow: window is int
          ? DateTime.fromMillisecondsSinceEpoch(window, isUtc: true)
          : null,
      explorerRange:
          UsageRangePreset.byName(json['explorerRange']) ??
          UsageRangePreset.last7,
      explorerCustom:
          custom is List &&
              custom.length == 2 &&
              custom[0] is String &&
              custom[1] is String &&
              parseUsageDate(custom[0] as String) != null &&
              parseUsageDate(custom[1] as String) != null
          ? UsageDateRange(custom[0] as String, custom[1] as String)
          : null,
      explorerMetric:
          UsageMetric.byName(json['explorerMetric']) ?? UsageMetric.tokens,
    );
  }
}

abstract class UsagePreferencesStore {
  Future<UsagePreferences> load();
  Future<void> save(UsagePreferences preferences);
}

/// In secure storage under its own key, outside every sync record.
class SecureUsagePreferencesStore implements UsagePreferencesStore {
  const SecureUsagePreferencesStore(this._storage);

  static const storageKey = 'usage_preferences_v1';

  final FlutterSecureStorage _storage;

  @override
  Future<UsagePreferences> load() async {
    try {
      final raw = await _storage.read(key: storageKey);
      if (raw == null || raw.isEmpty) {
        return const UsagePreferences();
      }
      return UsagePreferences.fromJson(jsonDecode(raw));
    } on Object {
      return const UsagePreferences();
    }
  }

  @override
  Future<void> save(UsagePreferences preferences) =>
      _storage.write(key: storageKey, value: jsonEncode(preferences.toJson()));
}

/// For tests and platforms without secure storage.
class MemoryUsagePreferencesStore implements UsagePreferencesStore {
  MemoryUsagePreferencesStore([this.value = const UsagePreferences()]);

  UsagePreferences value;

  @override
  Future<UsagePreferences> load() async => value;

  @override
  Future<void> save(UsagePreferences preferences) async => value = preferences;
}
