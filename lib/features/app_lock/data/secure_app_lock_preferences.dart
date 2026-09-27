import 'package:conduit/features/app_lock/domain/app_lock_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureAppLockPreferences implements AppLockPreferences {
  const SecureAppLockPreferences(this._storage);

  static const _relockKey = 'conduit.app_lock.relock_delay.v1';

  final FlutterSecureStorage _storage;

  @override
  Future<RelockDelay> loadRelockDelay() async =>
      RelockDelay.fromName(await _storage.read(key: _relockKey));

  @override
  Future<void> saveRelockDelay(RelockDelay delay) =>
      _storage.write(key: _relockKey, value: delay.name);
}
