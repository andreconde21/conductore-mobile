import 'package:conduit/features/continuity/presentation/continuity_controller.dart';
import 'package:flutter/widgets.dart';

/// Makes the app's [ContinuityController] reachable from every route:
/// home's banner, Chat View's drafts, Settings › Sync.
class ContinuityScope extends InheritedWidget {
  const ContinuityScope({
    required this.controller,
    required super.child,
    super.key,
  });

  final ContinuityController controller;

  static ContinuityController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ContinuityScope>()?.controller;

  @override
  bool updateShouldNotify(ContinuityScope oldWidget) =>
      controller != oldWidget.controller;
}
