// Desktop terminal (CON-059): a 1920×1080 window on Linux with the bundled
// JetBrains Mono, as André runs it on Omarchy. Reports the frame time of
// big output (`seq 1 200000`, a coloured build log), of mouse-wheel and
// trackpad scrolling through 10,000 lines of scrollback, and the raster
// time of one full terminal frame (the layer rasterized to an image).
import 'dart:io';

import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:conduit/features/terminal/presentation/widgets/terminal_surface.dart';
import 'package:conduit_vt/conduit_vt.dart';
import 'package:conduit_vt/src/ui/render.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/test_doubles.dart';
import 'perf_probe.dart';

const _font = 'JetBrainsMonoNerdFontMono';

Future<void> _loadFont() async {
  final loader = FontLoader(_font)
    ..addFont(
      Future.value(
        ByteData.sublistView(
          File(
            'assets/fonts/JetBrainsMonoNerdFontMono-Regular.ttf',
          ).readAsBytesSync(),
        ),
      ),
    );
  await loader.load();
}

/// 10,000 lines of coloured output like a build log or `ls --color`.
String _colouredLog(int lines) {
  final text = StringBuffer();
  for (var i = 0; i < lines; i++) {
    switch (i % 4) {
      case 0:
        text.write(
          '\x1b[01;34mdrwxr-xr-x\x1b[0m  2 dev dev  4096 Sep 27 12:00 '
          '\x1b[01;34mpackage_$i\x1b[0m\r\n',
        );
      case 1:
        text.write(
          '[${i.toString().padLeft(6)}] Compiling lib/features/module_$i.dart '
          '… ok (${i % 97} ms) and a longer tail so the line fills more of '
          'a wide desktop window\r\n',
        );
      case 2:
        text.write('\x1b[32m✓\x1b[0m test $i passed — café naïve\r\n');
      case 3:
        text.write(
          '\x1b[48;5;236m plain log line number $i with a background '
          'colour and ordinary words in it \x1b[0m\r\n',
        );
    }
  }
  return text.toString();
}

List<String> _chunks(String text, int size) => [
  for (var start = 0; start < text.length; start += size)
    text.substring(
      start,
      start + size > text.length ? text.length : start + size,
    ),
];

class _Frames {
  final List<int> us = [];
  void add(int micros) => us.add(micros);
  String get avg =>
      (us.fold(0, (a, b) => a + b) / us.length / 1000).toStringAsFixed(2);
  String get p90 {
    final sorted = [...us]..sort();
    return (sorted[(sorted.length * 0.9).floor()] / 1000).toStringAsFixed(2);
  }
}

void main() {
  setUpAll(_loadFont);

  late TerminalSessionController session;

  Future<RenderTerminal> pumpDesktop(WidgetTester tester, double dpr) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = dpr;
    addTearDown(tester.view.reset);
    session = TerminalSessionController(
      host: buildHost('bench'),
      repository: ImmediateTerminalRepository(TrackableTerminalSession()),
    );
    addTearDown(session.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalSurface(
            session: session,
            palette: AppPalette.catppuccin,
            brightness: Brightness.dark,
            fontFamily: _font,
            fontSize: 14,
            predictiveEchoEnabled: false,
            terminalMouseInput: false,
            focusNode: null,
            tmuxScrollMode: false,
            onExitTmuxScrollMode: () {},
          ),
        ),
      ),
    );
    await tester.pump();
    return tester
        .state<TerminalViewState>(find.byType(TerminalView))
        .renderTerminal;
  }

  Future<int> rasterMicros(WidgetTester tester, RenderTerminal render) async {
    final layer = render.debugLayer! as OffsetLayer;
    final dpr = tester.view.devicePixelRatio;
    return (await tester.runAsync(() async {
      final watch = Stopwatch()..start();
      final image = await layer.toImage(
        Offset.zero & render.size,
        pixelRatio: dpr,
      );
      image.dispose();
      return watch.elapsedMicroseconds;
    }))!;
  }

  for (final dpr in [1.0, 1.25, 2.0]) {
    testWidgets(
      'output: seq 1 200000 and a coloured log at ${dpr}x',
      (tester) async {
        final render = await pumpDesktop(tester, dpr);
        final seq = _chunks(
          [for (var i = 1; i <= 200000; i++) '$i\r\n'].join(),
          16 * 1024,
        );
        final log = _chunks(_colouredLog(10000), 32 * 1024);
        final probe = FrameProbe()..install();
        final frames = _Frames();
        final writes = _Frames();
        try {
          for (final chunk in [...seq, ...log]) {
            var watch = Stopwatch()..start();
            session.terminal.write(chunk);
            writes.add(watch.elapsedMicroseconds);
            watch = Stopwatch()..start();
            await tester.pump(const Duration(milliseconds: 16));
            frames.add(watch.elapsedMicroseconds);
          }
        } finally {
          probe.uninstall();
        }
        final raster = _Frames();
        for (var i = 0; i < 10; i++) {
          raster.add(await rasterMicros(tester, render));
        }
        perfReport('desktop_terminal.output', {
          'dpr': dpr,
          'grid':
              '${session.terminal.viewWidth}x${session.terminal.viewHeight}',
          'cell': '${render.cellSize.width}x${render.cellSize.height}',
          'frames': frames.us.length,
          'frame_ms': frames.avg,
          'frame_p90_ms': frames.p90,
          'vt_write_ms': writes.avg,
          'raster_ms': raster.avg,
          'builds': probe.builds,
          'paints': probe.paints,
          'top': probe.topPaints(3).replaceAll(' ', ','),
        });
      },
      variant: TargetPlatformVariant.only(TargetPlatform.linux),
    );

    testWidgets(
      'mouse wheel through scrollback at ${dpr}x',
      (tester) async {
        final render = await pumpDesktop(tester, dpr);
        session.terminal.write(_colouredLog(10000));
        await tester.pump();
        final wheel = TestPointer(1, PointerDeviceKind.mouse);
        final at = tester.getCenter(find.byType(TerminalView));
        await tester.sendEventToBinding(wheel.hover(at));
        final probe = FrameProbe()..install();
        final frames = _Frames();
        final raster = _Frames();
        try {
          for (var i = 0; i < 240; i++) {
            // Linux GTK sends 53 px per wheel notch; three notches up then
            // one down, like a hand going through history.
            final dy = i % 4 == 3 ? 53.0 : -53.0;
            await tester.sendEventToBinding(wheel.scroll(Offset(0, dy)));
            final watch = Stopwatch()..start();
            await tester.pump(const Duration(milliseconds: 16));
            frames.add(watch.elapsedMicroseconds);
            if (i % 24 == 0) raster.add(await rasterMicros(tester, render));
          }
        } finally {
          probe.uninstall();
        }
        perfReport('desktop_terminal.wheel', {
          'dpr': dpr,
          'frames': frames.us.length,
          'frame_ms': frames.avg,
          'frame_p90_ms': frames.p90,
          'raster_ms': raster.avg,
          'builds': probe.builds,
          'paints': probe.paints,
          'top': probe.topPaints(3).replaceAll(' ', ','),
        });
      },
      variant: TargetPlatformVariant.only(TargetPlatform.linux),
    );

    testWidgets(
      'trackpad scrolling through scrollback at ${dpr}x',
      (tester) async {
        final render = await pumpDesktop(tester, dpr);
        session.terminal.write(_colouredLog(10000));
        await tester.pump();
        final pad = TestPointer(2, PointerDeviceKind.trackpad);
        final at = tester.getCenter(find.byType(TerminalView));
        final probe = FrameProbe()..install();
        final frames = _Frames();
        try {
          await tester.sendEventToBinding(pad.panZoomStart(at));
          var pan = Offset.zero;
          for (var i = 0; i < 240; i++) {
            // Fingers moving down scroll back, 3.5 px per event.
            pan += const Offset(0, 3.5);
            await tester.sendEventToBinding(pad.panZoomUpdate(at, pan: pan));
            final watch = Stopwatch()..start();
            await tester.pump(const Duration(milliseconds: 8));
            frames.add(watch.elapsedMicroseconds);
          }
          await tester.sendEventToBinding(pad.panZoomEnd());
          await tester.pumpAndSettle();
        } finally {
          probe.uninstall();
        }
        perfReport('desktop_terminal.trackpad', {
          'dpr': dpr,
          'frames': frames.us.length,
          'frame_ms': frames.avg,
          'frame_p90_ms': frames.p90,
          'raster_ms': (await rasterMicros(tester, render) / 1000)
              .toStringAsFixed(2),
          'builds': probe.builds,
          'paints': probe.paints,
          'top': probe.topPaints(3).replaceAll(' ', ','),
        });
      },
      variant: TargetPlatformVariant.only(TargetPlatform.linux),
    );
  }
}
