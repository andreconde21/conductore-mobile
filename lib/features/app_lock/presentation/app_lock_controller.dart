import 'package:conduit/features/app_lock/domain/app_authenticator.dart';
import 'package:conduit/features/app_lock/domain/app_lock_preferences.dart';
import 'package:flutter/foundation.dart';

enum AppLockStatus { locked, checking, unlocked, unavailable }

/// What the platform side needs to refuse actions taken while the app is
/// in the background (notification buttons, the launcher): whether the app
/// is locked, and when it locks again if it stays away (null: it does not).
@immutable
class AppLockActionState {
  const AppLockActionState({required this.locked, this.relockAt});

  final bool locked;
  final DateTime? relockAt;

  @override
  bool operator ==(Object other) =>
      other is AppLockActionState &&
      other.locked == locked &&
      other.relockAt == relockAt;

  @override
  int get hashCode => Object.hash(locked, relockAt);
}

class AppLockController extends ChangeNotifier {
  /// [enabled] false (a platform without device authentication, see
  /// `PlatformFeatures.appLock`) starts unlocked and never locks, instead of
  /// greeting every launch with "Continue without auth".
  AppLockController(
    this._authenticator, {
    this.enabled = true,
    this._preferences,
    DateTime Function()? clock,
  }) : _status = enabled ? AppLockStatus.locked : AppLockStatus.unlocked,
       _clock = clock ?? DateTime.now {
    actionState = ValueNotifier(_actionState());
    addListener(_publish);
  }

  final AppAuthenticator _authenticator;
  final bool enabled;
  final AppLockPreferences? _preferences;
  final DateTime Function() _clock;

  AppLockStatus _status;
  String? _message;

  /// Unlocked by device authentication, not "Continue without auth" (a
  /// device without a screen lock has nothing to lock again with).
  bool _authenticated = false;
  DateTime? _backgroundedAt;
  RelockDelay _relockDelay = RelockDelay.standard;

  /// How long the app may stay in the background before it locks again.
  RelockDelay get relockDelay => _relockDelay;

  AppLockStatus get status => _status;
  String? get message => _message;
  bool get isUnlocked => _status == AppLockStatus.unlocked;

  /// The lock as actions from outside the app must see it; changes when
  /// the app locks, unlocks, leaves the screen or comes back, without
  /// rebuilding what listens to the controller itself.
  late final ValueNotifier<AppLockActionState> actionState;

  /// When the app locks again if it stays in the background (null: it is
  /// on screen, or does not lock again).
  DateTime? get relockAt {
    final since = _backgroundedAt;
    final delay = _relockDelay.duration;
    if (since == null || delay == null) return null;
    return since.add(delay);
  }

  /// Whether an action taken from outside the app (a notification button,
  /// the launcher, the voice guide) may run now: never while the app lock
  /// is shown, nor once the app has been away for [relockDelay] (it locks
  /// here, as it would on coming back).
  bool admitsActions() {
    if (!enabled) return true;
    if (!isUnlocked) return false;
    final deadline = relockAt;
    if (deadline != null && _authenticated && !_clock().isBefore(deadline)) {
      lock();
      return false;
    }
    return true;
  }

  AppLockActionState _actionState() => AppLockActionState(
    locked: enabled && !isUnlocked,
    relockAt: enabled && isUnlocked && _authenticated ? relockAt : null,
  );

  void _publish() => actionState.value = _actionState();

  Future<void> unlock() async {
    if (_status == AppLockStatus.checking) {
      return;
    }

    _status = AppLockStatus.checking;
    _message = null;
    notifyListeners();

    final canAuthenticate = await _canAuthenticate();
    if (!canAuthenticate) {
      _status = AppLockStatus.unavailable;
      _message =
          'Device authentication is not configured. '
          'Set a screen lock to keep saved hosts private.';
      notifyListeners();
      return;
    }

    final result = await _authenticate();
    switch (result) {
      case AppAuthenticationResult.success:
        _status = AppLockStatus.unlocked;
        _message = null;
        _authenticated = true;
        _backgroundedAt = null;
      case AppAuthenticationResult.cancelled:
        _status = AppLockStatus.locked;
        _message = 'Authentication was cancelled.';
      case AppAuthenticationResult.unavailable:
        _status = AppLockStatus.unavailable;
        _message =
            'Device authentication is unavailable on this device. '
            'Set a screen lock for better protection.';
    }
    notifyListeners();
  }

  Future<bool> _canAuthenticate() async {
    try {
      return await _authenticator.canAuthenticate();
    } catch (_) {
      return false;
    }
  }

  Future<AppAuthenticationResult> _authenticate() async {
    try {
      return await _authenticator.authenticate();
    } catch (_) {
      return AppAuthenticationResult.cancelled;
    }
  }

  void continueWithoutAuth() {
    if (_status != AppLockStatus.unavailable) {
      return;
    }
    _status = AppLockStatus.unlocked;
    notifyListeners();
  }

  void lock() {
    if (!enabled) return;
    _status = AppLockStatus.locked;
    _message = null;
    _authenticated = false;
    _backgroundedAt = null;
    notifyListeners();
  }

  /// Reads the saved [relockDelay].
  Future<void> loadPreferences() async {
    final preferences = _preferences;
    if (preferences == null) return;
    try {
      _relockDelay = await preferences.loadRelockDelay();
      notifyListeners();
    } catch (_) {
      // Unreadable: keep the default.
    }
  }

  Future<void> setRelockDelay(RelockDelay delay) async {
    if (delay == _relockDelay) return;
    _relockDelay = delay;
    notifyListeners();
    await _preferences?.saveRelockDelay(delay);
  }

  /// The app left the screen (hidden or paused).
  void appBackgrounded() {
    if (!enabled || !isUnlocked || !_authenticated) return;
    _backgroundedAt ??= _clock();
    _publish();
  }

  /// The app is back on screen: locks again when it was away for at least
  /// [relockDelay].
  void appResumed() {
    final since = _backgroundedAt;
    _backgroundedAt = null;
    _publish();
    final delay = _relockDelay.duration;
    if (since == null || delay == null) return;
    if (!enabled || !isUnlocked || !_authenticated) return;
    if (_clock().difference(since) >= delay) lock();
  }

  @override
  void dispose() {
    removeListener(_publish);
    actionState.dispose();
    super.dispose();
  }
}
