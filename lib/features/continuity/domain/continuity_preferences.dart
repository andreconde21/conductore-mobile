import 'package:flutter/foundation.dart';

/// What this device shares with (and takes from) the others, under
/// Settings › Sync › Continue where you left off. Kept on this device.
@immutable
class ContinuityPreferences {
  const ContinuityPreferences({
    this.sessions = true,
    this.drafts = true,
    this.scroll = true,
  });

  /// Where this device is and its recent places, and the offers to
  /// continue elsewhere's.
  final bool sessions;

  /// Unsent Chat View prompts. They can hold anything typed, so they only
  /// ever travel inside the end-to-end encrypted sync data.
  final bool drafts;

  /// Chat View's scroll position.
  final bool scroll;

  ContinuityPreferences copyWith({
    bool? sessions,
    bool? drafts,
    bool? scroll,
  }) => ContinuityPreferences(
    sessions: sessions ?? this.sessions,
    drafts: drafts ?? this.drafts,
    scroll: scroll ?? this.scroll,
  );

  Map<String, Object?> toJson() => {
    'sessions': sessions,
    'drafts': drafts,
    'scroll': scroll,
  };

  static ContinuityPreferences fromJson(Object? json) {
    if (json is! Map) return const ContinuityPreferences();
    return ContinuityPreferences(
      sessions: json['sessions'] != false,
      drafts: json['drafts'] != false,
      scroll: json['scroll'] != false,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ContinuityPreferences &&
      other.sessions == sessions &&
      other.drafts == drafts &&
      other.scroll == scroll;

  @override
  int get hashCode => Object.hash(sessions, drafts, scroll);
}
