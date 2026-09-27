import 'package:conduit/features/app_lock/domain/app_authenticator.dart';
import 'package:conduit/features/app_lock/domain/app_lock_preferences.dart';
import 'package:flutter/foundation.dart';

enum AppLockStatus { locked, checking, unlocked, unavailable }

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
       _clock = clock ?? DateTime.now;

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
  }

  /// The app is back on screen: locks again when it was away for at least
  /// [relockDelay].
  void appResumed() {
    final since = _backgroundedAt;
    _backgroundedAt = null;
    final delay = _relockDelay.duration;
    if (since == null || delay == null) return;
    if (!enabled || !isUnlocked || !_authenticated) return;
    if (_clock().difference(since) >= delay) lock();
  }
}
