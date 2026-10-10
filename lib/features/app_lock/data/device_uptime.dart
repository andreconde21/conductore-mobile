import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const _channel = MethodChannel('conduit/device_clock');

/// Time since the device booted, deep sleep included (Android's
/// SystemClock.elapsedRealtime), so the app lock can tell a reboot from an
/// app restart. Null on other platforms, or when it cannot be read.
Future<Duration?> deviceUptime() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
  try {
    final millis = await _channel.invokeMethod<int>('elapsedRealtime');
    return millis == null ? null : Duration(milliseconds: millis);
  } on Exception {
    return null;
  }
}
