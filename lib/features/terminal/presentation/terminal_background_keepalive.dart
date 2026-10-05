import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

class TerminalBackgroundKeepalive {
  const TerminalBackgroundKeepalive();

  static const _channel = MethodChannel('conduit/background_keepalive');

  Future<void> start({required int sessionCount}) async {
    await _channel.invokeMethod<void>('start', {'sessionCount': sessionCount});
  }

  Future<void> stop() async {
    await _channel.invokeMethod<void>('stop');
  }

  Future<void> requestNotificationPermission() async {
    await _channel.invokeMethod<void>('requestNotificationPermission');
  }
}

/// Runs the Android keepalive service exactly while the app is in the
/// background with live sessions (CON-089).
class BackgroundKeepaliveSync {
  /// Stops a service left running by an earlier engine (the process
  /// survived, the Dart side did not): a fresh start never assumes that
  /// nothing is running.
  BackgroundKeepaliveSync({required this._start, required this._stop}) {
    unawaited(_stop().catchError((_) {}));
  }

  final Future<void> Function(int sessionCount) _start;
  final Future<void> Function() _stop;
  bool _running = false;
  int _sessionCount = 0;

  /// Whether the service was last asked to run.
  bool get running => _running;

  void sync({required int sessionCount, required AppLifecycleState lifecycle}) {
    final shouldRun =
        sessionCount > 0 &&
        (lifecycle == AppLifecycleState.hidden ||
            lifecycle == AppLifecycleState.paused);
    if (shouldRun == _running &&
        (!shouldRun || sessionCount == _sessionCount)) {
      return;
    }
    _running = shouldRun;
    _sessionCount = shouldRun ? sessionCount : 0;
    unawaited(
      (shouldRun ? _start(sessionCount) : _stop()).catchError((_) {
        _running = !shouldRun;
        _sessionCount = 0;
      }),
    );
  }

  void dispose() {
    unawaited(_stop().catchError((_) {}));
  }
}
