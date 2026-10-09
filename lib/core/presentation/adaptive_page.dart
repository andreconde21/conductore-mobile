import 'dart:math' as math;

import 'package:conduit/core/platform_features.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Whether full pages under [context] open as desktop dialogs: desktops,
/// and tablets that get the desktop shell (at least 900 dp wide with a
/// shortest side of 600, like `usesDesktopShell`). Phones never do, in
/// landscape neither.
bool useDesktopPages(BuildContext context) {
  if (PlatformFeatures.isDesktop) return true;
  final size = MediaQuery.maybeSizeOf(context);
  return size != null && size.width >= 900 && size.shortestSide >= 600;
}

/// Opens a full page ([builder] returns its Scaffold) the way the platform
/// expects: pushed full screen on phones, exactly as
/// `Navigator.push(MaterialPageRoute(builder: builder))` did; on desktop a
/// large centred dialog over the window, so the sidebar and the tabs stay
/// in sight. Esc and a click outside close it (a page's `PopScope` still
/// gets its say), and its app bar's back button pops it like before.
///
/// [desktopMaxWidth] caps the dialog's width (a form wants less than the
/// settings' two panes).
Future<T?> pushAdaptivePage<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  double desktopMaxWidth = 960,
  bool fullscreenDialog = false,
  RouteSettings? settings,
}) {
  final navigator = Navigator.of(context);
  if (!useDesktopPages(context)) {
    return navigator.push<T>(
      MaterialPageRoute<T>(
        builder: builder,
        fullscreenDialog: fullscreenDialog,
        settings: settings,
      ),
    );
  }
  return navigator.push<T>(
    DesktopPageRoute<T>(
      builder: builder,
      maxWidth: desktopMaxWidth,
      settings: settings,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    ),
  );
}

/// A page shown as a large dialog (see [pushAdaptivePage]).
class DesktopPageRoute<T> extends RawDialogRoute<T> {
  DesktopPageRoute({
    required WidgetBuilder builder,
    double maxWidth = 960,
    super.settings,
    super.barrierLabel,
  }) : super(
         barrierDismissible: true,
         barrierColor: Colors.black.withValues(alpha: 0.45),
         transitionDuration: const Duration(milliseconds: 140),
         pageBuilder: (context, _, _) => DesktopPageFrame(
           maxWidth: maxWidth,
           child: Builder(builder: builder),
         ),
         transitionBuilder: (context, animation, _, child) {
           final curved = CurvedAnimation(
             parent: animation,
             curve: Curves.easeOut,
           );
           return FadeTransition(
             opacity: curved,
             child: ScaleTransition(
               scale: Tween(begin: 0.98, end: 1.0).animate(curved),
               child: child,
             ),
           );
         },
       );
}

/// The card a [DesktopPageRoute] draws its page in: centred, at most
/// [maxWidth] wide and 90% of the window high, with rounded corners.
class DesktopPageFrame extends StatelessWidget {
  const DesktopPageFrame({
    required this.maxWidth,
    required this.child,
    super.key,
  });

  final double maxWidth;
  final Widget child;

  static const _margin = 24.0;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final width = math.min(maxWidth, size.width - 2 * _margin);
    final height = math.max(320.0, size.height * 0.9);
    return Center(
      child: SizedBox(
        key: const ValueKey('desktop-page-frame'),
        width: math.max(width, 280),
        height: math.min(height, size.height - _margin),
        child: Material(
          elevation: 16,
          shadowColor: Colors.black54,
          borderRadius: BorderRadius.circular(14),
          clipBehavior: Clip.antiAlias,
          child: MediaQuery.removePadding(
            context: context,
            removeTop: true,
            removeBottom: true,
            removeLeft: true,
            removeRight: true,
            child: child,
          ),
        ),
      ),
    );
  }
}

/// On desktop, Esc closes the page on top (a pushed settings page, a
/// form) when nothing focused used the key: the terminal, a find bar or a
/// dialog answer it first (the key bubbles up the focus tree to here).
/// Sits above the Navigator, in `MaterialApp.builder`. Phones are left as
/// they are.
class DesktopEscapeToPop extends StatelessWidget {
  const DesktopEscapeToPop({
    required this.navigatorKey,
    required this.child,
    super.key,
  });

  /// The app's navigator; without one (tests) nothing changes.
  final GlobalKey<NavigatorState>? navigatorKey;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final navigatorKey = this.navigatorKey;
    if (!PlatformFeatures.isDesktop || navigatorKey == null) return child;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent ||
            event.logicalKey != LogicalKeyboardKey.escape ||
            HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isShiftPressed ||
            HardwareKeyboard.instance.isAltPressed ||
            HardwareKeyboard.instance.isMetaPressed) {
          return KeyEventResult.ignored;
        }
        final navigator = navigatorKey.currentState;
        if (navigator == null || !_topIsPushedPage(navigator)) {
          return KeyEventResult.ignored;
        }
        navigator.maybePop();
        return KeyEventResult.handled;
      },
      child: child,
    );
  }

  /// Only a pushed page: dialogs close through their own barrier action,
  /// and one that chose not to (a progress dialog) keeps the key.
  static bool _topIsPushedPage(NavigatorState navigator) {
    if (!navigator.canPop()) return false;
    Route<Object?>? top;
    navigator.popUntil((route) {
      top = route;
      return true;
    });
    return top is PageRoute && !top!.isFirst;
  }
}

/// On desktop, the mouse's back button (XButton1) and Alt+Left close the
/// page on top, like a browser's back: a pushed page or a page opened as a
/// dialog ([DesktopPageRoute]), never a plain dialog. A page's `PopScope`
/// still gets its say. Alt+Left reaches here only when nothing focused used
/// it: the terminal sends it to the remote program, and a text field keeps
/// it for moving the cursor. Sits above the Navigator, in
/// `MaterialApp.builder`. Phones are left as they are.
class DesktopBackNavigation extends StatelessWidget {
  const DesktopBackNavigation({
    required this.navigatorKey,
    required this.child,
    super.key,
  });

  /// The app's navigator; without one (tests) nothing changes.
  final GlobalKey<NavigatorState>? navigatorKey;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final navigatorKey = this.navigatorKey;
    if (!PlatformFeatures.isDesktop || navigatorKey == null) return child;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) {
        if (event.kind == PointerDeviceKind.mouse &&
            event.buttons & kBackMouseButton != 0) {
          _back(navigatorKey);
        }
      },
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent ||
              event.logicalKey != LogicalKeyboardKey.arrowLeft ||
              !HardwareKeyboard.instance.isAltPressed ||
              HardwareKeyboard.instance.isControlPressed ||
              HardwareKeyboard.instance.isShiftPressed ||
              HardwareKeyboard.instance.isMetaPressed ||
              _editingText()) {
            return KeyEventResult.ignored;
          }
          return _back(navigatorKey)
              ? KeyEventResult.handled
              : KeyEventResult.ignored;
        },
        child: child,
      ),
    );
  }

  /// Whether the focus is in a text field, whose own Alt+Left (the
  /// platform's cursor move) would otherwise reach here first.
  static bool _editingText() =>
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorStateOfType<EditableTextState>() !=
      null;

  /// Pops the page on top, if there is one; true when it asked.
  static bool _back(GlobalKey<NavigatorState> navigatorKey) {
    final navigator = navigatorKey.currentState;
    if (navigator == null || !navigator.canPop()) return false;
    Route<Object?>? top;
    navigator.popUntil((route) {
      top = route;
      return true;
    });
    final page = (top is PageRoute || top is DesktopPageRoute) && !top!.isFirst;
    if (!page) return false;
    navigator.maybePop();
    return true;
  }
}
