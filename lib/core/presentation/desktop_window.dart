import 'package:conduit/core/platform_features.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The desktop window itself, through the runner's `conductore/window`
/// channel (linux/runner, windows/runner, macos/Runner). A runner without
/// it (an older build) is ignored; phones never call it.
abstract final class DesktopWindow {
  static const _channel = MethodChannel('conductore/window');

  static String? _title;

  /// The title last asked for (tests).
  @visibleForTesting
  static String? get lastTitle => _title;

  @visibleForTesting
  static void reset() => _title = null;

  /// Sets the window's title (the task bar, Alt+Tab, a tiling bar), e.g.
  /// "api · omarchy — Conductore". Repeats are skipped.
  static Future<void> setTitle(String title) async {
    if (!PlatformFeatures.isDesktop || title == _title) return;
    _title = title;
    try {
      await _channel.invokeMethod<void>('setTitle', title);
    } on MissingPluginException {
      // A runner without the channel keeps its fixed title.
    } on PlatformException {
      // Same: the title is a nicety.
    }
  }
}

/// The window title for the focused view's [label] (null on the
/// dashboard).
String desktopWindowTitle(String? label) {
  final trimmed = label?.trim() ?? '';
  return trimmed.isEmpty ? 'Conductore' : '$trimmed — Conductore';
}
