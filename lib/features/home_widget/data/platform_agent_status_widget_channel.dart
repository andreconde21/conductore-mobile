import 'package:conduit/features/home_widget/domain/agent_status_snapshot.dart';
import 'package:conduit/features/home_widget/domain/agent_status_widget_channel.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android implementation over the `conduit/agent_status_widget` method
/// channel (see `AgentStatusWidgetChannel.kt`).
///
/// Dart → native:
/// - `push(String json)`: the encoded [AgentStatusSnapshot].
/// - `consumeLaunchTarget()` → `String?` naming an [AgentStatusLaunchTarget]
///   (`"dashboard"`, `"usage"`, ...), cleared on read. A tap on one of the
///   widget's agent lines never comes this way: the native side checks its
///   token and hands the agent to the notification deep link.
/// - `requestAddTile()` → `String` naming an [AddTileResult].
///
/// Native → Dart:
/// - `launchTargetAvailable()`: a new intent carried a launch target.
///
/// Elsewhere (iOS, tests) every call is a no-op.
class PlatformAgentStatusWidgetChannel implements AgentStatusWidgetChannel {
  PlatformAgentStatusWidgetChannel._() {
    if (_supported) {
      _channel.setMethodCallHandler(_handleNativeCall);
    }
  }

  /// One instance per app: the native side has a single handler slot, so a
  /// second instance would silently take over the launch-target callback.
  static final instance = PlatformAgentStatusWidgetChannel._();

  static const _channel = MethodChannel('conduit/agent_status_widget');

  void Function()? _launchTargetListener;

  bool get _supported => defaultTargetPlatform == TargetPlatform.android;

  @override
  Future<void> push(AgentStatusSnapshot snapshot) async {
    if (!_supported) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('push', snapshot.encode());
    } on MissingPluginException {
      // No native handler registered (e.g. tests); the widget is optional.
    } on PlatformException {
      // A widget refresh failure must never affect the dashboard itself.
    }
  }

  @override
  Future<AgentStatusLaunchTarget?> consumeLaunchTarget() async {
    if (!_supported) {
      return null;
    }
    try {
      final target = await _channel.invokeMethod<String>('consumeLaunchTarget');
      return AgentStatusLaunchTarget.values
          .where((value) => value.name == target)
          .firstOrNull;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  void setLaunchTargetListener(void Function()? listener) {
    _launchTargetListener = listener;
  }

  @override
  Future<AddTileResult> requestAddTile() async {
    if (!_supported) {
      return AddTileResult.unsupported;
    }
    try {
      final result = await _channel.invokeMethod<String>('requestAddTile');
      return AddTileResult.values
              .where((value) => value.name == result)
              .firstOrNull ??
          AddTileResult.failed;
    } on MissingPluginException {
      return AddTileResult.unsupported;
    } on PlatformException {
      return AddTileResult.failed;
    }
  }

  Future<Object?> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'launchTargetAvailable':
        _launchTargetListener?.call();
        return null;
      default:
        throw MissingPluginException();
    }
  }
}
