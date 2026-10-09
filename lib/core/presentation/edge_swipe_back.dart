import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Width of the strip along the left edge where a swipe goes back, as on
/// iOS (`CupertinoPageRoute` uses the same 20 dp).
const double edgeSwipeBackWidth = 20;

/// The page transitions of the app's routes: on iOS the native slide with
/// its edge swipe-back; on Android predictive back (the system back
/// gesture animates the page away) plus the same left-edge swipe inside
/// the app, which phones with three-button navigation have no other way to
/// make. Desktops keep Flutter's defaults (their pages are dialogs, see
/// `pushAdaptivePage`).
const appPageTransitionsTheme = PageTransitionsTheme(
  builders: {
    TargetPlatform.android: EdgeSwipeBackPageTransitionsBuilder(),
    TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
    TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
    TargetPlatform.windows: ZoomPageTransitionsBuilder(),
    TargetPlatform.linux: ZoomPageTransitionsBuilder(),
  },
);

/// The strip's width in [context]'s view: wider on the side of a notch,
/// like the iOS gesture.
double edgeSwipeBackZoneWidth(BuildContext context) => math.max(
  MediaQueryData.fromView(View.of(context)).padding.left,
  edgeSwipeBackWidth,
);

/// Whether a touch going down at [globalPosition] can start the edge
/// swipe-back of the page [context] sits in: a phone, a pushed page that
/// may be popped right now (no `PopScope` holding it, not a full-screen
/// dialog), and a touch inside the left strip. Gesture handlers that would
/// otherwise claim such a touch (the terminal's window swipe) leave it to
/// the route. Call it from event handlers, not during build.
bool startsEdgeSwipeBack(BuildContext context, Offset globalPosition) {
  final platform = Theme.of(context).platform;
  if (platform != TargetPlatform.android && platform != TargetPlatform.iOS) {
    return false;
  }
  final route = ModalRoute.of(context);
  if (route is! PageRoute ||
      !route.isCurrent ||
      !route.popGestureEnabled ||
      route.popGestureInProgress) {
    return false;
  }
  return globalPosition.dx < edgeSwipeBackZoneWidth(context);
}

/// Android's predictive back transition ([PredictiveBackPageTransitionsBuilder])
/// with a left-edge swipe-back inside the app.
///
/// The swipe is reported to the framework exactly as Android reports its
/// own back gesture (`flutter/backgesture`: start, progress, commit or
/// cancel), so the page follows the finger with the same animation, and a
/// `PopScope` that refuses the pop gets its callback as with system back.
class EdgeSwipeBackPageTransitionsBuilder extends PageTransitionsBuilder {
  const EdgeSwipeBackPageTransitionsBuilder();

  static const _predictiveBack = PredictiveBackPageTransitionsBuilder();

  @override
  Duration get transitionDuration => _predictiveBack.transitionDuration;

  @override
  Duration get reverseTransitionDuration =>
      _predictiveBack.reverseTransitionDuration;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return _EdgeSwipeBackDetector(
      route: route,
      child: _predictiveBack.buildTransitions(
        route,
        context,
        animation,
        secondaryAnimation,
        child,
      ),
    );
  }
}

class _EdgeSwipeBackDetector extends StatefulWidget {
  const _EdgeSwipeBackDetector({required this.route, required this.child});

  final PageRoute<dynamic> route;
  final Widget child;

  @override
  State<_EdgeSwipeBackDetector> createState() => _EdgeSwipeBackDetectorState();
}

class _EdgeSwipeBackDetectorState extends State<_EdgeSwipeBackDetector> {
  /// Screen widths per second that decide a release on their own, like
  /// the iOS gesture.
  static const double _flingVelocity = 1;

  /// How far (a fraction of the width) a slow release has to have come to
  /// go back.
  static const double _commitProgress = 0.35;

  late final HorizontalDragGestureRecognizer _recognizer =
      HorizontalDragGestureRecognizer(
          debugOwner: this,
          supportedDevices: const {
            PointerDeviceKind.touch,
            PointerDeviceKind.stylus,
          },
        )
        ..onStart = _handleDragStart
        ..onUpdate = _handleDragUpdate
        ..onEnd = _handleDragEnd
        ..onCancel = _handleDragCancel;

  bool _active = false;
  double _progress = 0;

  @override
  void dispose() {
    if (_active) _send('cancelBackGesture');
    _recognizer.dispose();
    super.dispose();
  }

  bool get _enabled {
    final route = widget.route;
    return route.isCurrent &&
        route.popGestureEnabled &&
        !route.popGestureInProgress;
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (_enabled) _recognizer.addPointer(event);
  }

  double get _width => context.size?.width ?? 1;

  void _handleDragStart(DragStartDetails details) {
    _active = true;
    _progress = 0;
    _send('startBackGesture', _backEvent(details.globalPosition));
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    if (!_active) return;
    _progress = (_progress + details.primaryDelta! / _width).clamp(0.0, 1.0);
    _send('updateBackGestureProgress', _backEvent(details.globalPosition));
  }

  void _handleDragEnd(DragEndDetails details) {
    if (!_active) return;
    _active = false;
    final velocity = details.velocity.pixelsPerSecond.dx / _width;
    final commit = velocity.abs() >= _flingVelocity
        ? velocity > 0
        : _progress >= _commitProgress;
    _send(commit ? 'commitBackGesture' : 'cancelBackGesture');
  }

  void _handleDragCancel() {
    if (!_active) return;
    _active = false;
    _send('cancelBackGesture');
  }

  /// The event map Android sends: the touch point in physical pixels, the
  /// progress, and the left edge.
  Map<String, Object?> _backEvent(Offset globalPosition) {
    final ratio = View.of(context).devicePixelRatio;
    return {
      'touchOffset': [globalPosition.dx * ratio, globalPosition.dy * ratio],
      'progress': _progress,
      'swipeEdge': SwipeEdge.left.index,
    };
  }

  /// Delivers [method] on the back gesture channel as if Android sent it.
  void _send(String method, [Object? arguments]) {
    const channel = SystemChannels.backGesture;
    ServicesBinding.instance.channelBuffers.push(
      channel.name,
      channel.codec.encodeMethodCall(MethodCall(method, arguments)),
      (_) {},
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.passthrough,
      children: [
        widget.child,
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: edgeSwipeBackZoneWidth(context),
          child: Listener(
            onPointerDown: _handlePointerDown,
            behavior: HitTestBehavior.translucent,
          ),
        ),
      ],
    );
  }
}
