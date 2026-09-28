import 'package:conduit/features/continuity/domain/continuity_preferences.dart';
import 'package:conduit/features/continuity/domain/continuity_record.dart';
import 'package:flutter/foundation.dart';

/// What continuity keeps on this device between runs: its preferences,
/// its own record, the other devices' records as last synced (so the sync
/// sees them unchanged at start), and the offers and drafts already
/// handled.
@immutable
class ContinuityState {
  const ContinuityState({
    this.preferences = const ContinuityPreferences(),
    this.activeAt,
    this.context,
    this.recent = const [],
    this.drafts = const {},
    this.remote = const {},
    this.dismissed = const [],
    this.handledDrafts = const [],
  });

  static const maxDismissed = 40;
  static const maxHandled = 80;

  final ContinuityPreferences preferences;
  final DateTime? activeAt;
  final ContinuityContext? context;
  final List<ContinuityContext> recent;
  final Map<String, ContinuityDraft> drafts;

  /// Sync record key to value, exactly as synced.
  final Map<String, Object?> remote;

  /// Offer keys dismissed here, oldest first.
  final List<String> dismissed;

  /// Draft keys adopted or turned down here, oldest first.
  final List<String> handledDrafts;

  Map<String, Object?> toJson() => {
    'preferences': preferences.toJson(),
    if (activeAt case final at?) 'activeAt': at.millisecondsSinceEpoch,
    if (context case final context?) 'context': context.toJson(),
    'recent': [for (final context in recent) context.toJson()],
    'drafts': {
      for (final MapEntry(:key, :value) in drafts.entries) key: value.toJson(),
    },
    'remote': remote,
    'dismissed': dismissed,
    'handledDrafts': handledDrafts,
  };

  static ContinuityState fromJson(Object? json) {
    if (json is! Map) return const ContinuityState();
    final activeAt = json['activeAt'];
    final drafts = json['drafts'];
    final remote = json['remote'];
    List<String> strings(Object? raw) => [
      for (final item in (raw as List?) ?? const [])
        if (item is String) item,
    ];
    return ContinuityState(
      preferences: ContinuityPreferences.fromJson(json['preferences']),
      activeAt: activeAt is int
          ? DateTime.fromMillisecondsSinceEpoch(activeAt)
          : null,
      context: ContinuityContext.fromJson(json['context']),
      recent: [
        for (final item in (json['recent'] as List?) ?? const [])
          ?ContinuityContext.fromJson(item),
      ],
      drafts: {
        if (drafts is Map)
          for (final MapEntry(:key, :value) in drafts.entries)
            if (key is String) key: ?ContinuityDraft.fromJson(value),
      },
      remote: {
        if (remote is Map)
          for (final MapEntry(:key, :value) in remote.entries)
            if (key is String && value != null) key: value,
      },
      dismissed: strings(json['dismissed']),
      handledDrafts: strings(json['handledDrafts']),
    );
  }
}

/// Where [ContinuityState] is kept.
abstract interface class ContinuityStore {
  Future<ContinuityState> load();

  Future<void> save(ContinuityState state);
}

/// A [ContinuityStore] for one app run (tests).
class InMemoryContinuityStore implements ContinuityStore {
  InMemoryContinuityStore([this.stored = const ContinuityState()]);

  ContinuityState stored;
  int saves = 0;

  @override
  Future<ContinuityState> load() async => stored;

  @override
  Future<void> save(ContinuityState state) async {
    saves += 1;
    stored = state;
  }
}
