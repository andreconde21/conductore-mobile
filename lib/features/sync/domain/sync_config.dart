import 'package:conduit/features/sync/domain/sync_category.dart';
import 'package:flutter/foundation.dart';

/// This device's sync setup. The key lives apart from it (see
/// `SyncStateStore.loadKey`).
@immutable
class SyncConfig {
  const SyncConfig({
    required this.vaultId,
    required this.hubHostId,
    required this.deviceId,
    required this.deviceName,
    this.categories = SyncCategory.defaults,
    this.initialized = const {},
    this.lastSyncAt,
    this.lastRevision = 0,
    this.counter = 0,
    this.unpushed = false,
    this.devicePublicKey,
    this.pendingRevocations = const [],
    this.dirtySince,
  });

  final String vaultId;

  /// The saved machine holding the bundle.
  final String hubHostId;
  final String deviceId;
  final String deviceName;
  final Set<SyncCategory> categories;

  /// Categories that have synced at least once on this device.
  final Set<SyncCategory> initialized;
  final DateTime? lastSyncAt;

  /// The hub's meta version this device last pulled or pushed.
  final int lastRevision;

  /// Highest Lamport counter seen.
  final int counter;

  /// A merge produced changes the hub has not stored yet.
  final bool unpushed;

  /// The key "Add a device" installed for this device, if any.
  final String? devicePublicKey;

  /// Device ids removed here, for the next push to record in the meta.
  final List<String> pendingRevocations;

  /// When the app first noticed a local change not merged yet: the time
  /// its edits are stamped with.
  final DateTime? dirtySince;

  SyncConfig copyWith({
    String? hubHostId,
    String? deviceName,
    Set<SyncCategory>? categories,
    Set<SyncCategory>? initialized,
    DateTime? lastSyncAt,
    int? lastRevision,
    int? counter,
    bool? unpushed,
    String? devicePublicKey,
    List<String>? pendingRevocations,
    DateTime? dirtySince,
    bool clearDirtySince = false,
  }) {
    return SyncConfig(
      vaultId: vaultId,
      hubHostId: hubHostId ?? this.hubHostId,
      deviceId: deviceId,
      deviceName: deviceName ?? this.deviceName,
      categories: categories ?? this.categories,
      initialized: initialized ?? this.initialized,
      lastSyncAt: lastSyncAt ?? this.lastSyncAt,
      lastRevision: lastRevision ?? this.lastRevision,
      counter: counter ?? this.counter,
      unpushed: unpushed ?? this.unpushed,
      devicePublicKey: devicePublicKey ?? this.devicePublicKey,
      pendingRevocations: pendingRevocations ?? this.pendingRevocations,
      dirtySince: clearDirtySince ? null : dirtySince ?? this.dirtySince,
    );
  }

  Map<String, Object?> toJson() => {
    'vaultId': vaultId,
    'hubHostId': hubHostId,
    'deviceId': deviceId,
    'deviceName': deviceName,
    'categories': [for (final c in categories) c.name],
    // Every category this build knows, so a later build can tell the
    // ones this setup never saw (see [SyncCategory.addedOn]).
    'known': [for (final c in SyncCategory.values) c.name],
    'initialized': [for (final c in initialized) c.name],
    if (lastSyncAt != null) 'lastSyncAt': lastSyncAt!.toUtc().toIso8601String(),
    'lastRevision': lastRevision,
    'counter': counter,
    'unpushed': unpushed,
    if (devicePublicKey != null) 'devicePublicKey': devicePublicKey,
    'pendingRevocations': pendingRevocations,
    if (dirtySince != null) 'dirtySince': dirtySince!.toUtc().toIso8601String(),
  };

  static SyncConfig? fromJson(Object? json) {
    if (json is! Map) return null;
    final vaultId = json['vaultId'];
    final hubHostId = json['hubHostId'];
    final deviceId = json['deviceId'];
    if (vaultId is! String || hubHostId is! String || deviceId is! String) {
      return null;
    }
    Set<SyncCategory> categories(Object? raw) => {
      for (final name in (raw as List?) ?? const []) ?SyncCategory.parse(name),
    };
    // A category added since this setup was saved starts on when new
    // setups start with it on.
    final known = {
      for (final name in (json['known'] as List?) ?? const []) ?name,
    };
    final enabled = categories(json['categories'])
      ..addAll([
        for (final category in SyncCategory.addedOn)
          if (!known.contains(category.name) &&
              SyncCategory.defaults.contains(category))
            category,
      ]);
    final deviceName = json['deviceName'];
    final lastRevision = json['lastRevision'];
    final counter = json['counter'];
    final publicKey = json['devicePublicKey'];
    return SyncConfig(
      vaultId: vaultId,
      hubHostId: hubHostId,
      deviceId: deviceId,
      deviceName: deviceName is String ? deviceName : 'Device',
      categories: enabled,
      initialized: categories(json['initialized']),
      lastSyncAt: DateTime.tryParse(json['lastSyncAt'] as String? ?? ''),
      lastRevision: lastRevision is int ? lastRevision : 0,
      counter: counter is int ? counter : 0,
      unpushed: json['unpushed'] == true,
      devicePublicKey: publicKey is String ? publicKey : null,
      pendingRevocations: [
        for (final id in (json['pendingRevocations'] as List?) ?? const [])
          if (id is String) id,
      ],
      dirtySince: DateTime.tryParse(json['dirtySince'] as String? ?? ''),
    );
  }
}

enum SyncActivityKind { synced, conflict, error, info }

/// One line of Settings › Sync › Sync activity.
@immutable
class SyncActivityEntry {
  const SyncActivityEntry({
    required this.at,
    required this.kind,
    required this.message,
    this.key,
    this.lostValue,
    this.canRestore = false,
  });

  final DateTime at;
  final SyncActivityKind kind;
  final String message;

  /// The record a conflict was about.
  final String? key;

  /// This device's value that lost a conflict (null for a delete).
  final Object? lostValue;

  /// Whether "Keep mine" can put [lostValue] back.
  final bool canRestore;

  SyncActivityEntry resolved() =>
      SyncActivityEntry(at: at, kind: kind, message: message, key: key);

  Map<String, Object?> toJson() => {
    'at': at.toUtc().toIso8601String(),
    'kind': kind.name,
    'message': message,
    if (key != null) 'key': key,
    if (canRestore) 'lost': lostValue,
    if (canRestore) 'canRestore': true,
  };

  static SyncActivityEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final at = DateTime.tryParse(json['at'] as String? ?? '');
    final kind = SyncActivityKind.values
        .where((k) => k.name == json['kind'])
        .firstOrNull;
    final message = json['message'];
    if (at == null || kind == null || message is! String) return null;
    final key = json['key'];
    return SyncActivityEntry(
      at: at,
      kind: kind,
      message: message,
      key: key is String ? key : null,
      lostValue: json['lost'],
      canRestore: json['canRestore'] == true,
    );
  }
}
