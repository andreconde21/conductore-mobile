/// How long the app may stay in the background before it locks again.
enum RelockDelay {
  immediately(Duration.zero, 'Immediately'),
  oneMinute(Duration(minutes: 1), 'After 1 minute'),
  fiveMinutes(Duration(minutes: 5), 'After 5 minutes'),
  fifteenMinutes(Duration(minutes: 15), 'After 15 minutes'),
  never(null, 'Only when it starts');

  const RelockDelay(this.duration, this.label);

  static const standard = RelockDelay.oneMinute;

  /// Null: the lock only comes back on the next start (or "Lock now").
  final Duration? duration;
  final String label;

  static RelockDelay fromName(String? name) => RelockDelay.values.firstWhere(
    (delay) => delay.name == name,
    orElse: () => standard,
  );
}

abstract interface class AppLockPreferences {
  Future<RelockDelay> loadRelockDelay();

  Future<void> saveRelockDelay(RelockDelay delay);
}
