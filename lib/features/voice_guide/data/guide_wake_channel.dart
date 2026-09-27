import 'package:flutter/services.dart';

/// "Wake with headset button" (see GuideWakeBridge.kt): turns the native
/// media-button and voice-command routes on or off and reports a long
/// press. Without a native side (iOS, desktop, tests) it does nothing.
class GuideWakeChannel {
  GuideWakeChannel({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('conduit/guide_wake');

  final MethodChannel _channel;
  bool? _headsetWake;

  /// [onWake] runs on a headset long press; null stops listening.
  void setListener(VoidCallback? onWake) {
    _channel.setMethodCallHandler(
      onWake == null
          ? null
          : (call) async {
              if (call.method == 'wake') onWake();
            },
    );
  }

  Future<void> setHeadsetWake(bool enabled) async {
    if (_headsetWake == enabled) return;
    _headsetWake = enabled;
    try {
      await _channel.invokeMethod<bool>('setHeadsetWake', enabled);
    } on MissingPluginException {
      // No native side.
    } on PlatformException {
      // Best effort.
    }
  }
}
