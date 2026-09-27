import 'package:conduit/features/app_lock/presentation/app_lock_controller.dart';
import 'package:flutter/material.dart';

/// Covers the whole app, pushed routes and dialogs included, with
/// [lockPage] while [controller] is locked, and tells it when the app
/// leaves and returns to the screen so it can lock again after its grace
/// period ([AppLockController.relockDelay]).
///
/// [child] (the app's Navigator) stays mounted but offstage while locked,
/// so unlocking returns to the same screen.
class AppLockGate extends StatefulWidget {
  const AppLockGate({
    required this.controller,
    required this.lockPage,
    required this.child,
    super.key,
  });

  final AppLockController controller;
  final WidgetBuilder lockPage;
  final Widget child;

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.hidden || AppLifecycleState.paused:
        widget.controller.appBackgrounded();
      case AppLifecycleState.resumed:
        widget.controller.appResumed();
      case AppLifecycleState.inactive || AppLifecycleState.detached:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, child) {
        final locked = !widget.controller.isUnlocked;
        return Stack(
          fit: StackFit.expand,
          children: [
            Offstage(
              offstage: locked,
              // No keyboard input reaches a terminal behind the lock.
              child: ExcludeFocus(
                excluding: locked,
                child: TickerMode(enabled: !locked, child: child!),
              ),
            ),
            if (locked)
              // Its own Navigator: the lock page's sheets and tooltips must
              // not open on the app's route stack underneath.
              HeroControllerScope.none(
                child: Navigator(
                  onGenerateRoute: (_) =>
                      MaterialPageRoute<void>(builder: widget.lockPage),
                ),
              ),
          ],
        );
      },
      child: widget.child,
    );
  }
}
