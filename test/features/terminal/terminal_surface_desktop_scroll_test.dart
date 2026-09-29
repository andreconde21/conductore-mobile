// Desktop mouse wheel and trackpad scrolling (CON-059): a program that
// asked for mouse reports gets one real wheel report per notch, as from a
// native terminal; the main screen keeps its own scrollback.
import 'dart:convert';

import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/features/terminal/domain/terminal_remote_scroll.dart';
import 'package:conduit/features/terminal/presentation/gestures/desktop_wheel_zoom.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:conduit/features/terminal/presentation/widgets/terminal_surface.dart';
import 'package:conduit_vt/conduit_vt.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

const _herdrLike = '\x1b[?1049h\x1b[?1000h\x1b[?1002h\x1b[?1006h';
const _altOnly = '\x1b[?1049h';

/// One wheel notch on Linux, in Flutter's pixels.
const _notch = 53.0;

final _desktop = TargetPlatformVariant.only(TargetPlatform.linux);

void main() {
  late TerminalSessionController session;
  late TrackableTerminalSession remote;
  late int enteredScrollMode;
  late List<double> zoomedTo;

  Future<void> pumpSurface(
    WidgetTester tester, {
    String setup = '',
    bool multiplexer = false,
  }) async {
    remote = TrackableTerminalSession();
    session = TerminalSessionController(
      host: buildHost('wheel'),
      repository: ImmediateTerminalRepository(remote),
    );
    addTearDown(session.dispose);
    enteredScrollMode = 0;
    zoomedTo = [];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 700,
            height: 400,
            // As in TerminalGestureLayer: Ctrl+wheel zooms.
            child: DesktopWheelZoom(
              fontSize: 14,
              onFontSizeChanged: zoomedTo.add,
              child: TerminalSurface(
                session: session,
                palette: AppPalette.catppuccin,
                brightness: Brightness.dark,
                fontFamily: 'monospace',
                fontSize: 14,
                predictiveEchoEnabled: false,
                terminalMouseInput: false,
                focusNode: null,
                tmuxScrollMode: false,
                onExitTmuxScrollMode: () {},
                onEnterScrollMode: multiplexer
                    ? () => enteredScrollMode += 1
                    : null,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    session.terminal.write(
      '$setup${List.generate(200, (i) => 'line $i').join('\r\n')}',
    );
    await tester.pump();
    remote.sent.clear();
  }

  String sent() => remote.sent.map(utf8.decode).join();

  Offset cellCenter(WidgetTester tester, int column, int row) {
    final state = tester.state<TerminalViewState>(find.byType(TerminalView));
    final render = state.renderTerminal;
    final cell = render.cellSize;
    final origin = render.getOffset(
      CellOffset(column, row + session.terminal.buffer.scrollBack),
    );
    return render.localToGlobal(
      origin + Offset(cell.width / 2, cell.height / 2),
    );
  }

  Future<void> wheel(WidgetTester tester, Offset at, double dy) async {
    final mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(at));
    await tester.sendEventToBinding(mouse.scroll(Offset(0, dy)));
    await tester.pump();
  }

  final sgrNotch = RegExp(r'\x1b\[<(\d+);(\d+);(\d+)M');

  testWidgets(
    'with mouse reports one wheel notch is one wheel report at the pointer',
    (tester) async {
      await pumpSurface(tester, setup: _herdrLike);

      await wheel(tester, cellCenter(tester, 10, 8), -_notch);
      final ups = sgrNotch.allMatches(sent()).toList();
      // Button 64 (not Shift+wheel, 68), one-based column 11, row 9.
      expect(ups.map((m) => m.group(0)), ['\x1b[<64;11;9M']);
      expect(sent().replaceAll(sgrNotch, ''), isEmpty);

      remote.sent.clear();
      await wheel(tester, cellCenter(tester, 30, 16), _notch);
      expect(sent(), '\x1b[<65;31;17M');

      // Three notches, three reports.
      remote.sent.clear();
      for (var i = 0; i < 3; i++) {
        await wheel(tester, cellCenter(tester, 30, 16), -_notch);
      }
      expect(sgrNotch.allMatches(sent()).length, 3);
    },
    variant: _desktop,
  );

  testWidgets(
    'a trackpad sends one report per wheel notch of travel, and a fling '
    'adds a bounded few',
    (tester) async {
      await pumpSurface(tester, setup: _herdrLike);
      final pad = TestPointer(2, PointerDeviceKind.trackpad);
      final at = cellCenter(tester, 5, 5);

      await tester.sendEventToBinding(pad.panZoomStart(at));
      var pan = Offset.zero;
      // Slowly, well past the pan slop: 4 notches of travel downwards.
      for (var i = 0; i < 40; i++) {
        pan += const Offset(0, desktopWheelStep / 10);
        await tester.sendEventToBinding(pad.panZoomUpdate(at, pan: pan));
        await tester.pump(const Duration(milliseconds: 100));
      }
      final ups = sgrNotch.allMatches(sent()).toList();
      expect(ups.length, inInclusiveRange(3, 4));
      expect(ups.every((m) => m.group(1) == '64'), isTrue);
      await tester.sendEventToBinding(pad.panZoomEnd());
      await tester.pumpAndSettle();

      // A fast flick upwards: wheel-down reports, capped.
      remote.sent.clear();
      await tester.sendEventToBinding(pad.panZoomStart(at));
      pan = Offset.zero;
      for (var i = 1; i <= 6; i++) {
        pan += const Offset(0, -60);
        await tester.sendEventToBinding(
          pad.panZoomUpdate(
            at,
            pan: pan,
            timeStamp: Duration(milliseconds: 10000 + 8 * i),
          ),
        );
        await tester.pump(const Duration(milliseconds: 8));
      }
      final dragged = sgrNotch.allMatches(sent()).length;
      await tester.sendEventToBinding(pad.panZoomEnd());
      await tester.pump(const Duration(seconds: 2));
      final downs = sgrNotch.allMatches(sent()).toList();
      expect(downs.every((m) => m.group(1) == '65'), isTrue);
      expect(dragged, inInclusiveRange(6, 7));
      expect(downs.length, greaterThan(dragged));
      expect(downs.length, lessThanOrEqualTo(dragged + maxMomentumNotches));
    },
    variant: _desktop,
  );

  testWidgets(
    'on the main screen the wheel scrolls the local history and sends nothing',
    (tester) async {
      await pumpSurface(tester);
      final view = tester.state<TerminalViewState>(find.byType(TerminalView));
      final before = view.renderTerminal.getOffset(const CellOffset(0, 0)).dy;

      await wheel(tester, cellCenter(tester, 10, 8), -_notch);

      expect(sent(), isEmpty);
      final after = view.renderTerminal.getOffset(const CellOffset(0, 0)).dy;
      expect(after - before, closeTo(_notch, 1));
    },
    variant: _desktop,
  );

  testWidgets(
    'on the alternate screen without mouse reports a notch is 3 arrows',
    (tester) async {
      await pumpSurface(tester, setup: _altOnly);

      await wheel(tester, cellCenter(tester, 10, 8), -_notch);
      expect(sent(), '\x1b[A' * desktopArrowsPerNotch);

      remote.sent.clear();
      await wheel(tester, cellCenter(tester, 10, 8), _notch);
      expect(sent(), '\x1b[B' * desktopArrowsPerNotch);
    },
    variant: _desktop,
  );

  testWidgets(
    'tmux without mouse reports: the wheel opens copy mode, as a drag does',
    (tester) async {
      await pumpSurface(tester, setup: _altOnly, multiplexer: true);

      await wheel(tester, cellCenter(tester, 10, 8), -_notch);

      expect(enteredScrollMode, 1);
      expect(sent(), '\x1b[A' * desktopArrowsPerNotch);
    },
    variant: _desktop,
  );

  testWidgets('Ctrl+wheel is left to the zoom, not sent to the program', (
    tester,
  ) async {
    await pumpSurface(tester, setup: _herdrLike);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await wheel(tester, cellCenter(tester, 10, 8), -_notch);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

    expect(sent(), isEmpty);
    expect(zoomedTo, isNotEmpty);
  }, variant: _desktop);
}
