import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:flutter/foundation.dart';

/// One open session as remembered between app runs: which saved machine,
/// what it attaches to and the name the user gave it.
///
/// Only identifiers are kept. Secrets (passwords, keys, Mosh session keys)
/// and terminal contents never go in here.
@immutable
class SessionSnapshotEntry {
  const SessionSnapshotEntry({
    required this.hostId,
    required this.target,
    this.customTitle,
    this.title = '',
    this.workspaceGoneAt,
  });

  /// The saved host id (never a derived `<hostId>#<key>` id).
  final String hostId;

  /// What the session was attached to: a shell, a tmux session, a Herdr
  /// workspace (and tab) or a directory.
  final ConnectTarget target;

  /// The name from long-press › Rename, or null.
  final String? customTitle;

  /// The title the tile last showed, used while the machine is not loaded.
  final String title;

  /// When the app first found the Herdr workspace gone (closed in Herdr,
  /// CON-103), or null while it is not known to be gone. A tab restored
  /// more than a day after that closes on launch (CON-115).
  final DateTime? workspaceGoneAt;

  /// The derived session host id this entry reopens as.
  String get sessionHostId => target.kind == ConnectTargetKind.shell
      ? hostId
      : '$hostId${ConnectTarget.idSeparator}${target.key}';

  Map<String, Object?> toJson() => {
    'hostId': hostId,
    'target': target.toJson(),
    if (customTitle != null) 'customTitle': customTitle,
    if (title.isNotEmpty) 'title': title,
    if (workspaceGoneAt case final gone?)
      'workspaceGoneAt': gone.toUtc().toIso8601String(),
  };

  static SessionSnapshotEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final hostId = json['hostId'];
    final target = ConnectTarget.fromJson(json['target']);
    if (hostId is! String || hostId.isEmpty || target == null) return null;
    final customTitle = json['customTitle'];
    final title = json['title'];
    final gone = json['workspaceGoneAt'];
    return SessionSnapshotEntry(
      hostId: hostId,
      target: target,
      customTitle: customTitle is String && customTitle.trim().isNotEmpty
          ? customTitle
          : null,
      title: title is String ? title : '',
      workspaceGoneAt: gone is String ? DateTime.tryParse(gone) : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SessionSnapshotEntry &&
      other.hostId == hostId &&
      other.target == target &&
      other.customTitle == customTitle &&
      other.title == title &&
      other.workspaceGoneAt == workspaceGoneAt;

  @override
  int get hashCode =>
      Object.hash(hostId, target, customTitle, title, workspaceGoneAt);
}

/// The app's open sessions, in tab order, and which one was active.
@immutable
class SessionSnapshot {
  const SessionSnapshot({this.entries = const [], this.activeIndex = 0});

  static const empty = SessionSnapshot();

  static const version = 1;

  final List<SessionSnapshotEntry> entries;

  /// Index into [entries] of the session that was in front.
  final int activeIndex;

  bool get isEmpty => entries.isEmpty;

  Map<String, Object?> toJson() => {
    'version': version,
    'active': activeIndex,
    'sessions': [for (final entry in entries) entry.toJson()],
  };

  static SessionSnapshot fromJson(Object? json) {
    if (json is! Map || json['version'] != version) return empty;
    final raw = json['sessions'];
    final entries = <SessionSnapshotEntry>[
      if (raw is List)
        for (final item in raw) ?SessionSnapshotEntry.fromJson(item),
    ];
    final active = json['active'];
    return SessionSnapshot(
      entries: entries,
      activeIndex: active is int && active >= 0 && active < entries.length
          ? active
          : 0,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SessionSnapshot &&
      other.activeIndex == activeIndex &&
      listEquals(other.entries, entries);

  @override
  int get hashCode => Object.hash(activeIndex, Object.hashAll(entries));
}

/// Where the open-session list is kept between app runs.
abstract interface class SessionSnapshotRepository {
  Future<SessionSnapshot> load();

  Future<void> save(SessionSnapshot snapshot);

  Future<void> clear();
}

/// A [SessionSnapshotRepository] that lives only as long as the app run.
class InMemorySessionSnapshotRepository implements SessionSnapshotRepository {
  InMemorySessionSnapshotRepository([this.stored = SessionSnapshot.empty]);

  SessionSnapshot stored;
  int saves = 0;

  @override
  Future<SessionSnapshot> load() async => stored;

  @override
  Future<void> save(SessionSnapshot snapshot) async {
    saves += 1;
    stored = snapshot;
  }

  @override
  Future<void> clear() async => stored = SessionSnapshot.empty;
}
