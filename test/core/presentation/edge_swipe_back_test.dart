import 'dart:async';

import 'package:conduit/core/presentation/adaptive_page.dart';
import 'package:conduit/core/presentation/edge_swipe_back.dart';
import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/core/theme/app_theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _phones = TargetPlatformVariant({
  TargetPlatform.android,
  TargetPlatform.iOS,
});

const _desktops = TargetPlatformVariant({
  TargetPlatform.linux,
  TargetPlatform.windows,
  TargetPlatform.macOS,
});

void main() {
  late GlobalKey<NavigatorState> navigatorKey;

  /// The app's theme and the builder's desktop back handling over a home
  /// page; [page] is pushed on top with [pushAdaptivePage].
  Future<void> pumpApp(
    WidgetTester tester, {
    Size size = const Size(400, 800),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        theme: AppTheme.build(
          brightness: Brightness.dark,
          palette: AppPalette.everforest,
        ),
        builder: (context, child) =>
            DesktopBackNavigation(navigatorKey: navigatorKey, child: child!),
        home: const Scaffold(body: Text('home')),
      ),
    );
  }

  Future<void> push(
    WidgetTester tester,
    WidgetBuilder builder, {
    bool fullscreenDialog = false,
  }) async {
    unawaited(
      pushAdaptivePage<void>(
        navigatorKey.currentContext!,
        builder: builder,
        fullscreenDialog: fullscreenDialog,
      ),
    );
    await tester.pumpAndSettle();
  }

  Widget page(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Settings')),
    body: const TextField(key: ValueKey('page-field')),
  );

  Future<void> swipe(WidgetTester tester, Offset from, Offset by) async {
    final gesture = await tester.startGesture(from);
    await tester.pump();
    for (var i = 0; i < 8; i += 1) {
      await gesture.moveBy(by / 8);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();
  }

  group('edge swipe-back on phones', () {
    testWidgets('a swipe from the left edge pops a pushed page', (
      tester,
    ) async {
      await pumpApp(tester);
      await push(tester, page);
      expect(find.text('Settings'), findsOneWidget);

      await swipe(tester, const Offset(4, 400), const Offset(300, 0));

      expect(find.text('Settings'), findsNothing);
      expect(find.text('home'), findsOneWidget);
    }, variant: _phones);

    testWidgets('the same swipe away from the edge does nothing', (
      tester,
    ) async {
      await pumpApp(tester);
      await push(tester, page);

      await swipe(tester, const Offset(80, 400), const Offset(300, 0));

      expect(find.text('Settings'), findsOneWidget);
    }, variant: _phones);

    testWidgets('a short, slow swipe puts the page back', (tester) async {
      await pumpApp(tester);
      await push(tester, page);

      final gesture = await tester.startGesture(const Offset(4, 400));
      await tester.pump();
      for (var i = 0; i < 4; i += 1) {
        await gesture.moveBy(const Offset(15, 0));
        await tester.pump(const Duration(milliseconds: 200));
      }
      // Resting before the release: no fling.
      await tester.pump(const Duration(milliseconds: 300));
      await gesture.up();
      await tester.pumpAndSettle();

      expect(find.text('Settings'), findsOneWidget);
      // The page is back in place and still answers.
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('Settings'), findsNothing);
    }, variant: _phones);

    testWidgets(
      'a page whose PopScope refuses keeps the swipe from popping',
      (tester) async {
        await pumpApp(tester);
        await push(
          tester,
          (context) => PopScope<Object?>(canPop: false, child: page(context)),
        );

        await swipe(tester, const Offset(4, 400), const Offset(300, 0));

        expect(find.text('Settings'), findsOneWidget);
      },
      variant: _phones,
    );

    testWidgets('full-screen dialogs (forms) have no swipe-back', (
      tester,
    ) async {
      await pumpApp(tester);
      await push(tester, page, fullscreenDialog: true);

      await swipe(tester, const Offset(4, 400), const Offset(300, 0));

      expect(find.text('Settings'), findsOneWidget);
    }, variant: _phones);

    testWidgets('the home page has nothing to go back to', (tester) async {
      await pumpApp(tester);

      await swipe(tester, const Offset(4, 400), const Offset(300, 0));

      expect(find.text('home'), findsOneWidget);
    }, variant: _phones);

    testWidgets(
      'startsEdgeSwipeBack covers the left strip of a pushed page',
      (tester) async {
        await pumpApp(tester);
        await push(tester, page);
        final context = tester.element(
          find.byKey(const ValueKey('page-field')),
        );

        expect(startsEdgeSwipeBack(context, const Offset(4, 400)), isTrue);
        expect(
          startsEdgeSwipeBack(context, const Offset(edgeSwipeBackWidth, 400)),
          isFalse,
        );
      },
      variant: _phones,
    );
  });

  group('desktop back', () {
    Future<void> pressBackButton(WidgetTester tester) async {
      final gesture = await tester.startGesture(
        const Offset(640, 400),
        kind: PointerDeviceKind.mouse,
        buttons: kBackMouseButton,
      );
      await gesture.up();
      await tester.pumpAndSettle();
    }

    testWidgets('the mouse back button closes the page on top', (tester) async {
      await pumpApp(tester, size: const Size(1280, 800));
      await push(tester, page);
      expect(find.byKey(const ValueKey('desktop-page-frame')), findsOneWidget);

      await pressBackButton(tester);

      expect(find.text('Settings'), findsNothing);
      expect(find.text('home'), findsOneWidget);
      // Nothing left to close: the home page stays.
      await pressBackButton(tester);
      expect(find.text('home'), findsOneWidget);
    }, variant: _desktops);

    testWidgets('Alt+Left closes the page on top', (tester) async {
      await pumpApp(tester, size: const Size(1280, 800));
      await push(tester, page);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();

      expect(find.text('Settings'), findsNothing);
    }, variant: _desktops);

    testWidgets('Alt+Left in a text field stays with the field', (
      tester,
    ) async {
      await pumpApp(tester, size: const Size(1280, 800));
      await push(tester, page);
      await tester.tap(find.byKey(const ValueKey('page-field')));
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();

      expect(find.text('Settings'), findsOneWidget);
    }, variant: _desktops);

    testWidgets('a plain dialog is not closed by the back button', (
      tester,
    ) async {
      await pumpApp(tester, size: const Size(1280, 800));
      unawaited(
        showDialog<void>(
          context: navigatorKey.currentContext!,
          builder: (_) => const AlertDialog(content: Text('Sure?')),
        ),
      );
      await tester.pumpAndSettle();

      await pressBackButton(tester);

      expect(find.text('Sure?'), findsOneWidget);
    }, variant: _desktops);

    testWidgets('phones ignore the mouse back button', (tester) async {
      await pumpApp(tester);
      await push(tester, page);

      await pressBackButton(tester);

      expect(find.text('Settings'), findsOneWidget);
    });
  });
}
