import 'package:conduit/features/continuity/presentation/continuity_controller.dart';
import 'package:conduit/features/sync/domain/sync_category.dart';
import 'package:conduit/features/sync/presentation/sync_controller.dart';
import 'package:flutter/foundation.dart';

/// [ContinuitySyncLink] over the app's [SyncController], set once both
/// exist ([controller]): the sync store reads continuity, and continuity
/// asks sync to push.
class SyncControllerContinuityLink extends ChangeNotifier
    implements ContinuitySyncLink {
  SyncController? _controller;

  set controller(SyncController controller) {
    _controller?.removeListener(notifyListeners);
    _controller = controller..addListener(notifyListeners);
    notifyListeners();
  }

  @override
  String? get deviceId {
    final controller = _controller;
    return controller != null && controller.enabled
        ? controller.config?.deviceId
        : null;
  }

  @override
  String get deviceName => _controller?.config?.deviceName ?? '';

  @override
  bool get sharing =>
      _controller?.config?.categories.contains(SyncCategory.continuity) ??
      false;

  @override
  DateTime? get lastSyncAt => _controller?.config?.lastSyncAt;

  @override
  void push() => _controller?.flushNow();

  @override
  void pull() {
    final controller = _controller;
    if (controller != null && controller.enabled) {
      // Errors show in Settings › Sync.
      controller.syncNow().ignore();
    }
  }

  @override
  void dispose() {
    _controller?.removeListener(notifyListeners);
    super.dispose();
  }
}
