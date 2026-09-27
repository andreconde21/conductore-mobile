import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:conduit/core/presentation/system_navigation_insets.dart';
import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/core/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Samsung Galaxy M53: 1080x2400 physical pixels at 2.625 px/dp, with the
/// status bar on top and the three-button navigation bar below.
const shotPhysicalSize = Size(1080, 2400);
const shotPixelRatio = 2.625;
const shotStatusBar = 24.0;
const shotNavigationBar = 48.0;

const shotPalette = AppPalette.everforest;

/// A desktop window at the size the Linux, Windows and macOS builds open
/// with, at 1 px/dp and without phone system bars.
const desktopWindowSize = Size(1280, 800);

/// Loads the fonts the app ships (JetBrains Mono Nerd Font, Atkynson Mono)
/// plus Roboto and the Material icons from the Flutter SDK, so text is
/// drawn with real glyphs instead of the test font's boxes.
Future<void> loadShotFonts() async {
  final sdk = _flutterRoot();
  final materialFonts = '$sdk/bin/cache/artifacts/material_fonts';
  final families = <String, List<String>>{
    'JetBrainsMonoNerdFontMono': [
      'assets/fonts/JetBrainsMonoNerdFontMono-Regular.ttf',
      'assets/fonts/JetBrainsMonoNerdFontMono-Bold.ttf',
    ],
    'AtkynsonMonoNerdFontMono': [
      'assets/fonts/AtkynsonMonoNerdFontMono-Regular.otf',
    ],
    'Roboto': [
      for (final weight in ['Regular', 'Medium', 'Bold', 'Italic'])
        '$materialFonts/Roboto-$weight.ttf',
    ],
    'monospace': [
      'assets/fonts/JetBrainsMonoNerdFontMono-Regular.ttf',
      'assets/fonts/JetBrainsMonoNerdFontMono-Bold.ttf',
    ],
    'MaterialIcons': ['$materialFonts/MaterialIcons-Regular.otf'],
  };
  for (final MapEntry(key: family, value: files) in families.entries) {
    final loader = FontLoader(family);
    for (final path in files) {
      final bytes = File(path).readAsBytesSync();
      loader.addFont(Future.value(ByteData.sublistView(bytes)));
    }
    await loader.load();
  }
}

String _flutterRoot() {
  final env = Platform.environment['FLUTTER_ROOT'];
  if (env != null && env.isNotEmpty) return env;
  // flutter_tester lives in <root>/bin/cache/artifacts/engine/<platform>/.
  var dir = File(Platform.resolvedExecutable).parent;
  while (dir.path != dir.parent.path) {
    if (Directory(
      '${dir.path}/bin/cache/artifacts/material_fonts',
    ).existsSync()) {
      return dir.path;
    }
    dir = dir.parent;
  }
  throw StateError('Cannot find the Flutter SDK for the Material fonts.');
}

/// Sizes the test view like the phone, insets included.
void usePhoneView(WidgetTester tester) {
  tester.view.physicalSize = shotPhysicalSize;
  tester.view.devicePixelRatio = shotPixelRatio;
  const padding = FakeViewPadding(
    top: shotStatusBar * shotPixelRatio,
    bottom: shotNavigationBar * shotPixelRatio,
  );
  tester.view.padding = padding;
  tester.view.viewPadding = padding;
  addTearDown(tester.view.reset);
}

/// Sizes the test view like a desktop window: 1280x800, no insets.
void useDesktopView(WidgetTester tester) {
  tester.view.physicalSize = desktopWindowSize;
  tester.view.devicePixelRatio = 1;
  tester.view.padding = FakeViewPadding.zero;
  tester.view.viewPadding = FakeViewPadding.zero;
  addTearDown(tester.view.reset);
}

const shotKey = ValueKey('screenshot');

/// The app's MaterialApp shell (theme, navigation bar background) with a
/// fake Android status bar and three-button navigation bar on top, unless
/// [systemBars] is false (desktop windows).
Widget shotApp({
  required Widget home,
  AppPalette palette = shotPalette,
  bool systemBars = true,
}) {
  return RepaintBoundary(
    key: shotKey,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: _systemSans(
        AppTheme.build(brightness: Brightness.light, palette: palette),
      ),
      darkTheme: _systemSans(
        AppTheme.build(brightness: Brightness.dark, palette: palette),
      ),
      themeMode: palette.brightness == Brightness.dark
          ? ThemeMode.dark
          : ThemeMode.light,
      builder: (context, child) {
        if (!systemBars) return child ?? const SizedBox.shrink();
        return Stack(
          children: [
            child ?? const SizedBox.shrink(),
            AndroidThreeButtonNavigationBackground(
              color: Theme.of(context).scaffoldBackgroundColor,
            ),
            const _FakeSystemBars(),
          ],
        );
      },
      home: home,
    ),
  );
}

/// Popup menu items use a text style without a font family, which a
/// device draws in its system sans but flutter_test in boxes: name Roboto.
/// Symbols Roboto lacks (✓, ✗) fall back to JetBrains Mono, as a device
/// falls back to its symbol font.
ThemeData _systemSans(ThemeData theme) {
  const fallback = ['JetBrainsMonoNerdFontMono'];
  final menu = theme.popupMenuTheme;
  final style = menu.textStyle?.copyWith(fontFamily: 'Roboto');
  return theme.copyWith(
    textTheme: theme.textTheme.apply(fontFamilyFallback: fallback),
    primaryTextTheme: theme.primaryTextTheme.apply(
      fontFamilyFallback: fallback,
    ),
    popupMenuTheme: menu.copyWith(
      textStyle: style,
      labelTextStyle: WidgetStatePropertyAll(style),
    ),
  );
}

class _FakeSystemBars extends StatelessWidget {
  const _FakeSystemBars();

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.viewPaddingOf(context);
    final color = Theme.of(context).colorScheme.onSurface;
    final style = TextStyle(
      color: color,
      fontFamily: 'Roboto',
      fontSize: 13,
      fontWeight: FontWeight.w500,
    );
    return IgnorePointer(
      child: Material(
        type: MaterialType.transparency,
        child: Stack(
          children: [
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: padding.top,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 22),
                child: Row(
                  children: [
                    Text('10:24', style: style),
                    const Spacer(),
                    Icon(Icons.wifi_rounded, size: 15, color: color),
                    const SizedBox(width: 4),
                    Icon(
                      Icons.signal_cellular_alt_rounded,
                      size: 15,
                      color: color,
                    ),
                    const SizedBox(width: 4),
                    Text('82%', style: style.copyWith(fontSize: 12)),
                    const SizedBox(width: 2),
                    Icon(Icons.battery_5_bar_rounded, size: 15, color: color),
                  ],
                ),
              ),
            ),
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              height: padding.bottom,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  RotatedBox(
                    quarterTurns: 1,
                    child: Icon(Icons.menu_rounded, size: 22, color: color),
                  ),
                  Icon(Icons.crop_square_rounded, size: 24, color: color),
                  Icon(
                    Icons.arrow_back_ios_new_rounded,
                    size: 18,
                    color: color,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Pushes [page] over an empty route, the way the app opens it, so its app
/// bar shows the back button.
Future<void> pushPage(WidgetTester tester, Widget page) async {
  final navigator = tester.state<NavigatorState>(find.byType(Navigator));
  unawaited(navigator.push(MaterialPageRoute<void>(builder: (_) => page)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// Writes the current frame, at the phone's physical resolution (or
/// [pixelRatio]), to `docs/screenshots/<name>.png`.
Future<void> saveShot(
  WidgetTester tester,
  String name, {
  double pixelRatio = shotPixelRatio,
}) async {
  // flutter_test draws elevation as a solid black outline; repaint with
  // real shadows for the capture, then restore the test default.
  debugDisableShadows = false;
  for (final view in tester.binding.renderViews) {
    view.reassemble();
  }
  await tester.pump();
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(shotKey),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: pixelRatio);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    File('docs/screenshots/$name.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes!.buffer.asUint8List());
  });
  debugDisableShadows = true;
  for (final view in tester.binding.renderViews) {
    view.reassemble();
  }
  await tester.pump();
}

/// Pumps a few frames without waiting for spinners to settle.
Future<void> pumpFrames(WidgetTester tester, [int count = 4]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
