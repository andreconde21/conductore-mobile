/// How long the app may stay in the background before it locks again.
///
/// The ones above 15 minutes ([lastsAcrossRestarts]) count from the last
/// unlock instead, and hold across app restarts (CON-118).
enum RelockDelay {
  immediately(Duration.zero, 'Immediately'),
  oneMinute(Duration(minutes: 1), 'After 1 minute'),
  fiveMinutes(Duration(minutes: 5), 'After 5 minutes'),
  fifteenMinutes(Duration(minutes: 15), 'After 15 minutes'),
  oneHour(Duration(hours: 1), 'After 1 hour'),
  fourHours(Duration(hours: 4), 'After 4 hours'),
  eightHours(Duration(hours: 8), 'After 8 hours'),
  oneDay(Duration(days: 1), 'After 1 day'),
  never(null, 'Only when it starts');

  const RelockDelay(this.duration, this.label);

  static const standard = RelockDelay.oneMinute;

  /// Null: the lock only comes back on the next start (or "Lock now").
  final Duration? duration;
  final String label;

  /// Longer than 15 minutes: the unlock holds for [duration] from the last
  /// unlock, across app restarts, and choosing it asks first.
  bool get lastsAcrossRestarts =>
      duration != null && duration! > const Duration(minutes: 15);

  /// "1 hour", "1 day": [duration] for the warning's text.
  String get spokenDuration => label.replaceFirst('After ', '');

  static RelockDelay fromName(String? name) => RelockDelay.values.firstWhere(
    (delay) => delay.name == name,
    orElse: () => standard,
  );
}

/// The last unlock by device authentication, kept so a restart within a
/// [RelockDelay] that [RelockDelay.lastsAcrossRestarts] does not ask again.
class AppUnlockStamp {
  const AppUnlockStamp({required this.at, this.sinceBoot});

  /// Wall-clock time of the unlock.
  final DateTime at;

  /// Time since the device booted at the unlock (Android's
  /// elapsedRealtime), or null where the platform does not say.
  final Duration? sinceBoot;

  /// Whether the unlock still holds [now] for [delay]. Not when the clock
  /// went back, nor after a reboot: either way the time since the unlock
  /// cannot be trusted. A reboot shows as a smaller time since boot, or as
  /// the boot moving (wall clock minus time since boot) by more than
  /// [bootDrift]; that also catches the clock being moved forward. Without
  /// a time since boot (iOS, desktops) only the wall clock is checked.
  bool holdsAt(
    DateTime now,
    Duration delay, {
    Duration? sinceBootNow,
    Duration bootDrift = const Duration(minutes: 2),
  }) {
    final wall = now.difference(at);
    if (wall.isNegative || wall >= delay) return false;
    final then = sinceBoot;
    if (then == null || sinceBootNow == null) return true;
    final uptime = sinceBootNow - then;
    if (uptime.isNegative || uptime >= delay) return false;
    return (wall - uptime).abs() <= bootDrift;
  }

  Map<String, Object?> toJson() => {
    'at': at.toUtc().millisecondsSinceEpoch,
    if (sinceBoot case final boot?) 'sinceBoot': boot.inMilliseconds,
  };

  static AppUnlockStamp? fromJson(Object? json) {
    if (json is! Map) return null;
    final at = json['at'];
    final boot = json['sinceBoot'];
    if (at is! int) return null;
    return AppUnlockStamp(
      at: DateTime.fromMillisecondsSinceEpoch(at, isUtc: true),
      sinceBoot: boot is int ? Duration(milliseconds: boot) : null,
    );
  }
}

abstract interface class AppLockPreferences {
  Future<RelockDelay> loadRelockDelay();

  Future<void> saveRelockDelay(RelockDelay delay);

  Future<AppUnlockStamp?> loadUnlockStamp();

  /// Null forgets it (a lock, or an unlock that expired).
  Future<void> saveUnlockStamp(AppUnlockStamp? stamp);
}
