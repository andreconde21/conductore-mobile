import 'dart:io';

import 'package:conduit/core/presentation/adaptive_page.dart';
import 'package:conduit/features/sync/presentation/sync_controller.dart';
import 'package:conduit/features/sync/presentation/sync_page.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Makes the app's [SyncController] reachable from Settings.
class SyncScope extends InheritedWidget {
  const SyncScope({required this.controller, required super.child, super.key});

  final SyncController controller;

  static SyncController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SyncScope>()?.controller;

  @override
  bool updateShouldNotify(SyncScope oldWidget) =>
      controller != oldWidget.controller;
}

/// Opens Settings › Sync. Does nothing in a build without sync.
Future<void> showSyncPage(
  BuildContext context, {
  SyncController? controller,
}) async {
  final resolved = controller ?? SyncScope.maybeOf(context);
  if (resolved == null) return;
  // A dialog over Settings on desktop, a full-screen page on phones.
  await pushAdaptivePage<void>(
    context,
    desktopMaxWidth: 760,
    builder: (_) => SyncPage(controller: resolved),
  );
}

/// The name a new device offers in the hub's device list.
String defaultSyncDeviceName() {
  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
      return 'Android device';
    case TargetPlatform.iOS:
      return 'iPhone or iPad';
    case TargetPlatform.linux:
    case TargetPlatform.macOS:
    case TargetPlatform.windows:
      try {
        return Platform.localHostname;
      } catch (_) {
        return defaultTargetPlatform.name;
      }
    case TargetPlatform.fuchsia:
      return 'This device';
  }
}
