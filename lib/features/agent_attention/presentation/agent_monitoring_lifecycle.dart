import 'package:flutter/widgets.dart';

/// Whether agent monitoring runs in app lifecycle [state] on [platform].
///
/// Android keeps it on in the background: the keepalive service holds the
/// connections open, which is when notifications matter most. A desktop
/// keeps it on unfocused and minimized too: its sockets live on, and the
/// user works in another window (CON-089: `inactive` stopped it, so no
/// notification arrived while another window had focus). iOS pauses it in
/// the background, where sockets die anyway.
bool agentMonitoringActive(AppLifecycleState state, TargetPlatform platform) {
  if (state == AppLifecycleState.detached) return false;
  final keepsSockets = switch (platform) {
    TargetPlatform.android ||
    TargetPlatform.linux ||
    TargetPlatform.macOS ||
    TargetPlatform.windows => true,
    TargetPlatform.iOS || TargetPlatform.fuchsia => false,
  };
  return keepsSockets ||
      state == AppLifecycleState.resumed ||
      state == AppLifecycleState.inactive;
}
