// The desktop terminal renderer (CON-059): a cell grid on whole device
// pixels, lines recorded once and replayed, and glyph runs that draw the
// same pixels as one paragraph per glyph.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit_vt/conduit_vt.dart';
import 'package:conduit_vt/src/ui/painter.dart';
import 'package:conduit_vt/src/ui/render.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _font = 'JetBrainsMonoNerdFontMono';

Future<void> _loadFont() async {
  final loader = FontLoader(_font);
  for (final file in [
    'assets/fonts/JetBrainsMonoNerdFontMono-Regular.ttf',
    'assets/fonts/JetBrainsMonoNerdFontMono-Bold.ttf',
  ]) {
    loader.addFont(
      Future.value(ByteData.sublistView(File(file).readAsBytesSync())),
    );
  }
  await loader.load();
}

final _theme = AppPalette.catppuccin.terminalThemeFor(Brightness.dark);

TerminalPainter _painter(double dpr, {double fontSize = 14}) => TerminalPainter(
  theme: _theme,
  textStyle: TerminalStyle(fontFamily: _font, fontSize: fontSize),
  textScaler: TextScaler.noScaling,
)..devicePixelRatio = dpr;

bool _onDevicePixel(double logical, double dpr) {
  final device = logical * dpr;
  return (device - device.roundToDouble()).abs() < 1e-6;
}

/// [picture] rasterized at [dpr], as RGBA bytes.
Future<Uint8List> _pixels(ui.Picture picture, Size size, double dpr) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder)
    ..scale(dpr)
    ..drawPicture(picture);
  final scaled = recorder.endRecording();
  final image = await scaled.toImage(
    (size.width * dpr).ceil(),
    (size.height * dpr).ceil(),
  );
  final bytes = await image.toByteData();
  image.dispose();
  scaled.dispose();
  return bytes!.buffer.asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(_loadFont);
  tearDown(() => TerminalPainter.debugDisableGlyphRuns = false);

  test('equal terminal styles are equal, so a rebuild keeps the caches', () {
    const a = TerminalStyle(fontFamily: _font, fontSize: 14);
    // Not const: a rebuild creates a new instance each time.
    // ignore: prefer_const_constructors
    final b = TerminalStyle(fontFamily: _font, fontSize: 14.0 + 0);
    expect(identical(a, b), isFalse);
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(a == a.copyWith(fontSize: 15), isFalse);
  });

  test('cells are a whole number of device pixels at every scale', () {
    for (final dpr in [1.0, 1.25, 1.5, 1.75, 2.0, 3.0]) {
      for (final fontSize in [11.0, 13.0, 14.0, 15.5, 18.0]) {
        final cell = _painter(dpr, fontSize: fontSize).cellSize;
        expect(
          _onDevicePixel(cell.width, dpr) && _onDevicePixel(cell.height, dpr),
          isTrue,
          reason: '$cell at ${dpr}x, ${fontSize}px',
        );
      }
    }
  });

  test(
    'a glyph run draws the same pixels as one paragraph per glyph',
    () async {
      final terminal = Terminal()..resize(60, 3);
      terminal.write(
        r'$ git status --short -- lib/{a,b}.dart  # ok [1] "q" 100%'
        '\r\n'
        '\x1b[1;34mbold blue\x1b[0m plain \x1b[32mgreen\x1b[0m '
        '\x1b[7minverse\x1b[0m café ✓ end\r\n'
        '\x1b[2mfaint text\x1b[0m and ~!@#^&*()_+=|<>?,./',
      );
      for (final dpr in [1.0, 1.25, 1.5, 2.0]) {
        final painter = _painter(dpr);
        final size = Size(60 * painter.cellSize.width, painter.cellSize.height);
        for (var row = 0; row < 3; row++) {
          final line = terminal.buffer.lines[row];
          TerminalPainter.debugDisableGlyphRuns = true;
          final perGlyph = painter.recordLine(line);
          TerminalPainter.debugDisableGlyphRuns = false;
          final runs = painter.recordLine(line);
          final a = await _pixels(perGlyph, size, dpr);
          final b = await _pixels(runs, size, dpr);
          perGlyph.dispose();
          runs.dispose();
          var differing = 0;
          var worst = 0;
          for (var i = 0; i < a.length; i++) {
            final d = (a[i] - b[i]).abs();
            if (d > 8) differing++;
            if (d > worst) worst = d;
          }
          expect(
            differing,
            0,
            reason:
                'row $row at ${dpr}x: $differing bytes differ (worst $worst)',
          );
        }
      }
    },
  );

  group('TerminalView', () {
    late Terminal terminal;
    late ScrollController scroll;
    late ValueNotifier<int> rebuild;

    Future<RenderTerminal> pumpView(WidgetTester tester, double dpr) async {
      tester.view.physicalSize = const Size(1000, 600);
      tester.view.devicePixelRatio = dpr;
      addTearDown(tester.view.reset);
      terminal = Terminal();
      scroll = ScrollController();
      rebuild = ValueNotifier(0);
      addTearDown(scroll.dispose);
      addTearDown(rebuild.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<int>(
              valueListenable: rebuild,
              builder: (context, _, _) => TerminalView(
                terminal,
                scrollController: scroll,
                theme: _theme,
                // A new instance on every build, as TerminalSurface does.
                // ignore: prefer_const_constructors
                textStyle: TerminalStyle(fontFamily: _font, fontSize: 14),
              ),
            ),
          ),
        ),
      );
      terminal.write(
        List.generate(
          300,
          (i) => 'line $i \x1b[33mwith colour\x1b[0m',
        ).join('\r\n'),
      );
      await tester.pump();
      return tester
          .state<TerminalViewState>(find.byType(TerminalView))
          .renderTerminal;
    }

    testWidgets(
      'lines are recorded once they stay, then replayed; only new lines record',
      (tester) async {
        final render = await pumpView(tester, 1.25);
        final screen = terminal.viewHeight;

        // Output draws its lines straight away: fast output replaces them
        // before a recording would pay off.
        final afterOutput = render.debugLinesRecorded;
        expect(afterOutput, lessThanOrEqualTo(1));

        // Painted again unchanged (a small scroll): now they are recorded,
        // and the line the scroll exposed at the top is drawn directly.
        scroll.jumpTo(scroll.offset - 5);
        await tester.pump();
        final recordedScreen = render.debugLinesRecorded - afterOutput;
        expect(recordedScreen, inInclusiveRange(screen - 1, screen + 1));

        // Further scrolling replays them and records only the lines that
        // are new on screen.
        var before = render.debugLinesRecorded;
        scroll.jumpTo(scroll.offset - 5);
        await tester.pump();
        expect(render.debugLinesRecorded - before, lessThanOrEqualTo(1));

        // A rebuild with an equal (but new) style keeps every recording.
        before = render.debugLinesRecorded;
        rebuild.value++;
        await tester.pump();
        scroll.jumpTo(scroll.offset - 1);
        await tester.pump();
        expect(render.debugLinesRecorded - before, lessThanOrEqualTo(1));

        // Back to the bottom: those lines are still recorded.
        scroll.jumpTo(scroll.position.maxScrollExtent);
        await tester.pump();
        before = render.debugLinesRecorded;
        scroll.jumpTo(scroll.offset - 2);
        await tester.pump();
        scroll.jumpTo(scroll.position.maxScrollExtent);
        await tester.pump();
        expect(render.debugLinesRecorded - before, lessThanOrEqualTo(1));

        // New output changes one or two lines; the rest stay recorded.
        before = render.debugLinesRecorded;
        terminal.write('\r\nnew line');
        await tester.pump();
        scroll.jumpTo(scroll.offset - 1);
        await tester.pump();
        expect(render.debugLinesRecorded - before, inInclusiveRange(1, 3));
      },
      variant: TargetPlatformVariant.only(TargetPlatform.linux),
    );

    testWidgets(
      'a line drawn directly and its recording draw the same pixels',
      (tester) async {
        await tester.runAsync(() async {
          final terminal = Terminal()..resize(60, 2);
          terminal.write(
            '\x1b[1;34mbold blue\x1b[0m plain \x1b[32mgreen\x1b[0m '
            // Not underlines: one paragraph per cell overlaps them by the
            // advance's rounding at cell edges, a run draws them evenly.
            '\x1b[7minverse\x1b[0m café ✓ \x1b[3mitalic\x1b[0m\r\n'
            '\x1b[48;5;236m background run \x1b[0m ~!@#^&*()_+=|<>?,./',
          );
          for (final dpr in [1.0, 1.25, 2.0]) {
            final painter = _painter(dpr);
            final size = Size(
              60 * painter.cellSize.width,
              painter.cellSize.height,
            );
            for (var row = 0; row < 2; row++) {
              final line = terminal.buffer.lines[row];
              final recorder = ui.PictureRecorder();
              painter.paintLine(Canvas(recorder), Offset.zero, line);
              final direct = recorder.endRecording();
              final recorded = painter.recordLine(line);
              final a = await _pixels(direct, size, dpr);
              final b = await _pixels(recorded, size, dpr);
              direct.dispose();
              recorded.dispose();
              var differing = 0;
              for (var i = 0; i < a.length; i++) {
                if ((a[i] - b[i]).abs() > 8) differing++;
              }
              expect(differing, 0, reason: 'row $row at ${dpr}x');
            }
          }
        });
      },
    );

    testWidgets(
      'a trackpad scrolls by the pixel and lines stay on device pixels',
      (tester) async {
        const dpr = 1.25;
        final render = await pumpView(tester, dpr);
        final pad = TestPointer(1, PointerDeviceKind.trackpad);
        final at = tester.getCenter(find.byType(TerminalView));
        await tester.sendEventToBinding(pad.panZoomStart(at));
        // Past the pan slop first.
        var pan = const Offset(0, 20);
        await tester.sendEventToBinding(pad.panZoomUpdate(at, pan: pan));
        await tester.pump();
        for (var step = 0; step < 6; step++) {
          final before = scroll.offset;
          pan += const Offset(0, 3.3);
          await tester.sendEventToBinding(pad.panZoomUpdate(at, pan: pan));
          await tester.pump();
          // Fingers moving down show older lines, by exactly the travel:
          // no snapping to whole lines.
          expect(scroll.offset, closeTo(before - 3.3, 1e-6));
          final top = render.getOffset(
            CellOffset(0, terminal.buffer.lines.length - terminal.viewHeight),
          );
          expect(_onDevicePixel(top.dy, dpr), isTrue, reason: '${top.dy}');
          expect(_onDevicePixel(render.cellSize.height, dpr), isTrue);
        }
        await tester.sendEventToBinding(pad.panZoomEnd());
        await tester.pumpAndSettle();
      },
      variant: TargetPlatformVariant.only(TargetPlatform.linux),
    );
  });
}
