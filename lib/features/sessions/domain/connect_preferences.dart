import 'package:conduit/features/sessions/domain/connect_target.dart';

/// Per-host memory of the connect picker.
class ConnectPreferences {
  const ConnectPreferences({
    this.rememberChoice = false,
    this.lastTarget,
    this.recents = const [],
    this.lastAgent,
  });

  /// When true and [lastTarget] is set, connecting skips the picker.
  final bool rememberChoice;

  final ConnectTarget? lastTarget;

  /// Most recent first, deduplicated by target key, capped at [maxRecents].
  final List<ConnectTarget> recents;

  static const maxRecents = 8;

  /// The agent a new workspace or session started last time on this
  /// machine (an agent kind, `''` for none); null before the first one.
  final String? lastAgent;

  /// Records a chosen target as the latest and pushes it to the top of the
  /// recents. A plain shell is not worth remembering as a recent, and
  /// directories have their own "Recent dirs" list.
  ConnectPreferences withChoice(
    ConnectTarget target, {
    required bool remember,
  }) {
    final updated = [
      if (target.kind != ConnectTargetKind.shell &&
          target.kind != ConnectTargetKind.directory)
        target,
      for (final recent in recents)
        if (recent.key != target.key) recent,
    ];
    return ConnectPreferences(
      rememberChoice: remember,
      lastTarget: target,
      recents: updated.take(maxRecents).toList(growable: false),
      lastAgent: lastAgent,
    );
  }

  ConnectPreferences copyWith({bool? rememberChoice, String? lastAgent}) =>
      ConnectPreferences(
        rememberChoice: rememberChoice ?? this.rememberChoice,
        lastTarget: lastTarget,
        recents: recents,
        lastAgent: lastAgent ?? this.lastAgent,
      );

  Map<String, Object?> toJson() => {
    'rememberChoice': rememberChoice,
    'lastTarget': lastTarget?.toJson(),
    'recents': [for (final recent in recents) recent.toJson()],
    if (lastAgent != null) 'lastAgent': lastAgent,
  };

  static ConnectPreferences fromJson(Object? json) {
    if (json is! Map) {
      return const ConnectPreferences();
    }
    final recentsRaw = json['recents'];
    return ConnectPreferences(
      rememberChoice: json['rememberChoice'] == true,
      lastTarget: ConnectTarget.fromJson(json['lastTarget']),
      recents: recentsRaw is List
          ? recentsRaw
                .map(ConnectTarget.fromJson)
                .whereType<ConnectTarget>()
                .take(maxRecents)
                .toList(growable: false)
          : const [],
      lastAgent: json['lastAgent'] is String
          ? json['lastAgent'] as String
          : null,
    );
  }
}

/// Stores [ConnectPreferences] per saved host id.
abstract interface class ConnectPreferencesRepository {
  Future<ConnectPreferences> load(String hostId);

  Future<void> save(String hostId, ConnectPreferences preferences);
}

/// Keeps preferences for the lifetime of the process; used by tests and as
/// the fallback when no storage is wired.
class InMemoryConnectPreferencesRepository
    implements ConnectPreferencesRepository {
  final Map<String, ConnectPreferences> _store = {};

  @override
  Future<ConnectPreferences> load(String hostId) async =>
      _store[hostId] ?? const ConnectPreferences();

  @override
  Future<void> save(String hostId, ConnectPreferences preferences) async {
    _store[hostId] = preferences;
  }
}
