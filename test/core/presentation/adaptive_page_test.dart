import 'dart:async';

import 'package:conduit/core/presentation/adaptive_page.dart';
import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/core/theme/app_theme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _desktops = TargetPlatformVariant({
  TargetPlatform.linux,
  TargetPlatform.windows,
  TargetPlatform.macOS,
});

void main() {
  late GlobalKey<NavigatorState> navigatorKey;

  Future<BuildContext> pumpApp(
    WidgetTester tester, {
    Size size = const Size(1280, 800),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    navigatorKey = GlobalKey<NavigatorState>();
    late BuildContext homeContext;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        builder: (context, child) =>
            DesktopEscapeToPop(navigatorKey: navigatorKey, child: child!),
        home: Builder(
          builder: (context) {
            homeContext = context;
            return const Scaffold(body: Text('home'));
          },
        ),
      ),
    );
    return homeContext;
  }

  Widget page(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Settings')),
    body: const TextField(key: ValueKey('page-field')),
  );

  testWidgets('phones push the page full screen, as before', (tester) async {
    final context = await pumpApp(tester, size: const Size(400, 800));
    final result = pushAdaptivePage<void>(context, builder: page);
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);
    expect(find.byKey(const ValueKey('desktop-page-frame')), findsNothing);
    // The page covers the whole screen.
    expect(tester.getSize(find.byType(Scaffold).last), const Size(400, 800));
    // Esc does not close pages on a phone.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);
    navigatorKey.currentState!.pop();
    await result;
  });

  testWidgets('a landscape phone keeps the full-screen page', (tester) async {
    final context = await pumpApp(tester, size: const Size(915, 412));
    unawaited(pushAdaptivePage<void>(context, builder: page));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('desktop-page-frame')), findsNothing);
  });

  testWidgets('desktop opens the page as a dialog that Esc closes', (
    tester,
  ) async {
    final context = await pumpApp(tester);
    unawaited(pushAdaptivePage<void>(context, builder: page));
    await tester.pumpAndSettle();
    final frame = find.byKey(const ValueKey('desktop-page-frame'));
    expect(frame, findsOneWidget);
    expect(tester.getSize(frame).width, 960);
    // Home stays behind the dialog.
    expect(find.text('home', skipOffstage: false), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(frame, findsNothing);
  }, variant: _desktops);

  testWidgets(
    'desktop: Esc pops a pushed page, but not a dialog that stays open',
    (tester) async {
      final context = await pumpApp(tester);
      unawaited(
        Navigator.of(context).push(MaterialPageRoute<void>(builder: page)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Settings'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Settings'), findsNothing);

      unawaited(
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (_) => const AlertDialog(content: Text('Working…')),
        ),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Working…'), findsOneWidget);
      navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();
      // Nothing to pop on the home page: the key is left alone.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('home'), findsOneWidget);
    },
    variant: _desktops,
  );

  testWidgets(
    'desktop theme: visible hover, no ripple, a wider scrollbar',
    (tester) async {
      final theme = AppTheme.build(
        brightness: Brightness.dark,
        palette: AppPalette.everforest,
      );
      expect(theme.splashFactory, NoSplash.splashFactory);
      expect(theme.hoverColor.a, closeTo(0.08, 0.005));
      expect(theme.scrollbarTheme.thickness!.resolve(const {}), 6);
      expect(
        theme.scrollbarTheme.thickness!.resolve(const {WidgetState.hovered}),
        9,
      );
    },
    variant: _desktops,
  );

  test('phone theme is unchanged', () {
    final theme = AppTheme.build(
      brightness: Brightness.dark,
      palette: AppPalette.everforest,
    );
    expect(theme.splashFactory, InkRipple.splashFactory);
    expect(theme.hoverColor.a, closeTo(0.04, 0.005));
    expect(theme.scrollbarTheme.thickness!.resolve(const {}), 3);
  });
}
