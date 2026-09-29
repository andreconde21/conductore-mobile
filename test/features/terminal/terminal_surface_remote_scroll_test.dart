import 'dart:convert';

import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/features/terminal/domain/terminal_remote_scroll.dart';
import 'package:conduit/features/terminal/presentation/session_input_hold.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:conduit/features/terminal/presentation/widgets/terminal_surface.dart';
import 'package:conduit_vt/conduit_vt.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

/// Screens as the remote programs set them up.
const _herdrLike = '\x1b[?1049h\x1b[?1000h\x1b[?1002h\x1b[?1006h';
const _legacyMouse = '\x1b[?1049h\x1b[?1000h';
const _altOnly = '\x1b[?1049h';
const _altScroll = '\x1b[?1049h\x1b[?1007h';

void main() {
  late TerminalSessionController session;
  late TrackableTerminalSession remote;
  late int enteredScrollMode;
  late int exitedScrollMode;

  Future<void> pumpSurface(
    WidgetTester tester, {
    String setup = '',
    bool dragScrollsRemote = true,
    bool multiplexer = false,
    bool scrollMode = false,
  }) async {
    remote = TrackableTerminalSession();
    session = TerminalSessionController(
      host: buildHost('scroll'),
      repository: ImmediateTerminalRepository(remote),
    );
    addTearDown(session.dispose);
    enteredScrollMode = 0;
    exitedScrollMode = 0;
    Widget surface(bool scrollMode) => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 700,
          height: 400,
          child: TerminalSurface(
            session: session,
            palette: AppPalette.catppuccin,
            brightness: Brightness.dark,
            fontFamily: 'monospace',
            fontSize: 14,
            predictiveEchoEnabled: false,
            terminalMouseInput: false,
            focusNode: null,
            tmuxScrollMode: scrollMode,
            onExitTmuxScrollMode: () => exitedScrollMode += 1,
            dragScrollsRemote: dragScrollsRemote,
            onEnterScrollMode: multiplexer
                ? () => enteredScrollMode += 1
                : null,
          ),
        ),
      ),
    );
    await tester.pumpWidget(surface(scrollMode));
    await tester.pump();
    session.terminal.write(
      '$setup${List.generate(60, (i) => 'line $i').join('\r\n')}',
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

  /// A slow drag (no fling): past the touch slop, then [steps] moves of
  /// exactly one notch each.
  Future<void> slowDrag(
    WidgetTester tester,
    Offset start, {
    required int steps,
    bool down = true,
  }) async {
    final sign = down ? 1.0 : -1.0;
    final gesture = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveBy(Offset(0, sign * 20));
    await tester.pump(const Duration(milliseconds: 100));
    for (var i = 0; i < steps; i += 1) {
      await gesture.moveBy(
        Offset(0, sign * RemoteScrollAccumulator.defaultStep),
      );
      await tester.pump(const Duration(milliseconds: 150));
    }
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 500));
  }

  final sgrNotch = RegExp(r'\x1b\[<(\d+);(\d+);(\d+)M');

  testWidgets('on the main screen without mouse reports the drag stays local', (
    tester,
  ) async {
    await pumpSurface(tester);
    await slowDrag(tester, cellCenter(tester, 10, 10), steps: 4);
    expect(sent(), isEmpty);
  });

  testWidgets('with SGR mouse reports a drag down sends wheel-up (64) at the '
      'finger, a drag up wheel-down (65)', (tester) async {
    await pumpSurface(tester, setup: _herdrLike);

    await slowDrag(tester, cellCenter(tester, 10, 8), steps: 4);
    final ups = sgrNotch.allMatches(sent()).toList();
    expect(ups.length, inInclusiveRange(4, 5));
    expect(ups.every((m) => m.group(1) == '64'), isTrue);
    // One-based column of the finger; the row follows it down the screen.
    expect(ups.every((m) => m.group(2) == '11'), isTrue);
    final rows = [for (final m in ups) int.parse(m.group(3)!)];
    expect(rows.first, greaterThanOrEqualTo(10));
    expect(rows.last, greaterThan(rows.first));
    // Nothing but wheel reports: no Shift+wheel (68), no arrows.
    expect(sent().replaceAll(sgrNotch, ''), isEmpty);

    remote.sent.clear();
    await slowDrag(tester, cellCenter(tester, 30, 16), steps: 3, down: false);
    final downs = sgrNotch.allMatches(sent()).toList();
    expect(downs.length, inInclusiveRange(3, 4));
    expect(downs.every((m) => m.group(1) == '65'), isTrue);
    expect(downs.every((m) => m.group(2) == '31'), isTrue);
  });

  testWidgets('wheel notches are not typed input: Herdr showing another '
      'workspace neither holds nor counts them (CON-056)', (tester) async {
    await pumpSurface(tester, setup: _herdrLike);
    var checks = 0;
    // Herdr's focus is elsewhere and this device may not move it: typed
    // keys would wait under the focus banner.
    session.inputCheck = (_) {
      checks += 1;
      return Future.value(InputHoldDecision.block);
    };

    await slowDrag(tester, cellCenter(tester, 10, 8), steps: 4);

    expect(session.inputHold.value, isNull);
    expect(checks, 0);
    expect(sgrNotch.allMatches(sent()).length, inInclusiveRange(4, 5));

    // Held input (a real keystroke) still waits, and a drag meanwhile is
    // neither queued behind it nor counted with it.
    session.sendText('x');
    await tester.pump();
    remote.sent.clear();
    await slowDrag(tester, cellCenter(tester, 10, 8), steps: 3);
    final held = session.inputHold.value;
    expect(held, isA<InputHoldBlocked>());
    expect((held! as InputHoldBlocked).queued, 1);
    expect(sent(), isEmpty);
  });

  testWidgets('a click on Herdr showing another workspace is dropped, '
      'not held or counted: it would move the shared focus (CON-056)', (
    tester,
  ) async {
    await pumpSurface(tester, setup: _herdrLike);
    session.inputCheck = (_) => Future.value(InputHoldDecision.block);

    session.terminal.textInput('\x1b[<0;5;5M\x1b[<0;5;5m');
    await tester.pump();

    expect(session.inputHold.value, isNull);
    expect(sent(), isEmpty);
  });

  test('isWheelReport: SGR wheel notches only', () {
    expect(TerminalSessionController.isWheelReport('\x1b[<64;3;4M'), isTrue);
    expect(
      TerminalSessionController.isWheelReport('\x1b[<65;3;4M\x1b[<69;3;4M'),
      isTrue,
    );
    expect(TerminalSessionController.isWheelReport('\x1b[<0;3;4M'), isFalse);
    expect(TerminalSessionController.isWheelReport('\x1b[<96;3;4M'), isFalse);
    expect(TerminalSessionController.isWheelReport('\x1b[<64;3;4Mx'), isFalse);
    expect(TerminalSessionController.isWheelReport(''), isFalse);
  });

  testWidgets('legacy mouse encoding sends ESC [ M with 32 + 64', (
    tester,
  ) async {
    await pumpSurface(tester, setup: _legacyMouse);
    await slowDrag(tester, cellCenter(tester, 4, 6), steps: 2);
    final bytes = remote.sent.expand((chunk) => chunk).toList();
    expect(bytes.length % 6, 0);
    expect(bytes.length ~/ 6, inInclusiveRange(2, 3));
    for (var i = 0; i < bytes.length; i += 6) {
      expect(bytes.sublist(i, i + 4), [0x1b, 0x5b, 0x4d, 32 + 64]);
      expect(bytes[i + 4], 32 + 5);
    }
  });

  testWidgets('alternate scroll (DECSET 1007) without mouse reports sends '
      'arrow keys, also for a multiplexer', (tester) async {
    await pumpSurface(tester, setup: _altScroll, multiplexer: true);
    await slowDrag(tester, cellCenter(tester, 10, 8), steps: 3);
    expect(sent(), matches(RegExp(r'^(\x1b\[A){3,4}$')));
    expect(enteredScrollMode, 0);

    remote.sent.clear();
    await slowDrag(tester, cellCenter(tester, 10, 8), steps: 2, down: false);
    expect(sent(), matches(RegExp(r'^(\x1b\[B){2,3}$')));
  });

  testWidgets('arrow keys follow the application cursor-key mode', (
    tester,
  ) async {
    // less and vim switch DECCKM (DECSET 1) on.
    await pumpSurface(tester, setup: '$_altScroll\x1b[?1h');
    await slowDrag(tester, cellCenter(tester, 10, 8), steps: 2);
    expect(sent(), matches(RegExp(r'^(\x1bOA){2,3}$')));
  });

  testWidgets('a plain full-screen program without 1007 still gets arrows', (
    tester,
  ) async {
    await pumpSurface(tester, setup: _altOnly);
    await slowDrag(tester, cellCenter(tester, 10, 8), steps: 2);
    expect(sent(), matches(RegExp(r'^(\x1b\[A){2,3}$')));
  });

  testWidgets('a multiplexer screen without mouse reports enters copy mode on '
      'the first drag and scrolls there with arrows', (tester) async {
    await pumpSurface(tester, setup: _altOnly, multiplexer: true);
    await slowDrag(tester, cellCenter(tester, 10, 8), steps: 3);
    expect(enteredScrollMode, 1);
    expect(sent(), matches(RegExp(r'^(\x1b\[A){3,4}$')));
  });

  testWidgets('a tap leaves the copy mode the drag entered', (tester) async {
    await pumpSurface(tester, setup: _altOnly, multiplexer: true);
    await slowDrag(tester, cellCenter(tester, 10, 8), steps: 1);
    expect(enteredScrollMode, 1);

    // The page flips its scroll-mode state in response.
    final surface = tester.widget<TerminalSurface>(
      find.byType(TerminalSurface),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 700,
            height: 400,
            child: TerminalSurface(
              session: session,
              palette: AppPalette.catppuccin,
              brightness: Brightness.dark,
              fontFamily: 'monospace',
              fontSize: 14,
              predictiveEchoEnabled: false,
              terminalMouseInput: false,
              focusNode: null,
              tmuxScrollMode: true,
              onExitTmuxScrollMode: surface.onExitTmuxScrollMode,
              onEnterScrollMode: surface.onEnterScrollMode,
            ),
          ),
        ),
      ),
    );
    remote.sent.clear();

    // Drags in copy mode belong to the existing scroll-mode overlay.
    await slowDrag(tester, cellCenter(tester, 10, 8), steps: 2);
    expect(enteredScrollMode, 1);
    expect(sent(), matches(RegExp(r'^(\x1b\[A)+$')));

    remote.sent.clear();
    await tester.tapAt(cellCenter(tester, 10, 8));
    await tester.pump(const Duration(milliseconds: 400));
    expect(sent(), 'q');
    expect(exitedScrollMode, 1);
  });

  testWidgets('a fling keeps scrolling after the finger lifts, within the '
      'bound, and a touch stops it', (tester) async {
    await pumpSurface(tester, setup: _herdrLike);
    final start = cellCenter(tester, 10, 4);

    await tester.flingFrom(start, const Offset(0, 140), 2500);
    final atLift = sgrNotch.allMatches(sent()).length;
    await tester.pump(const Duration(milliseconds: 48));
    await tester.pump(const Duration(milliseconds: 48));
    final early = sgrNotch.allMatches(sent()).length;
    expect(early, greaterThan(atLift));

    // A finger on the screen catches the fling.
    final hold = await tester.startGesture(cellCenter(tester, 40, 10));
    final caught = sgrNotch.allMatches(sent()).length;
    await tester.pump(const Duration(seconds: 2));
    expect(sgrNotch.allMatches(sent()).length, caught);
    await hold.up();
    await tester.pump(const Duration(milliseconds: 600));

    remote.sent.clear();
    await tester.flingFrom(start, const Offset(0, 140), 20000);
    await tester.pump(const Duration(seconds: 3));
    final total = sgrNotch.allMatches(sent()).length;
    // At most the drag's own ten notches plus the momentum cap.
    expect(total, lessThanOrEqualTo(10 + maxMomentumNotches));
    expect(total, greaterThan(10));
    expect(
      sgrNotch.allMatches(sent()).every((m) => m.group(1) == '64'),
      isTrue,
    );
  });

  testWidgets('a long press still selects text and sends no wheel', (
    tester,
  ) async {
    // Mouse reports on the main screen: drags go to the wheel, yet a
    // finger held still is a selection. (conduit_vt keeps no selection on
    // the alternate screen at all, with or without this setting.)
    await pumpSurface(tester, setup: '\x1b[?1000h\x1b[?1006h');
    await tester.longPressAt(cellCenter(tester, 2, 5));
    await tester.pump();
    final controller = tester
        .widget<TerminalView>(find.byType(TerminalView))
        .controller!;
    expect(controller.selection, isNotNull);
    expect(sgrNotch.hasMatch(sent()), isFalse);

    // The same drag setup still scrolls with the wheel.
    await slowDrag(tester, cellCenter(tester, 30, 12), steps: 2);
    expect(sgrNotch.allMatches(sent()).length, inInclusiveRange(2, 3));
  });

  testWidgets('a long press on the alternate screen sends no wheel', (
    tester,
  ) async {
    await pumpSurface(tester, setup: _herdrLike);
    await tester.longPressAt(cellCenter(tester, 2, 5));
    await tester.pump(const Duration(milliseconds: 500));
    expect(sent(), isEmpty);
  });

  testWidgets('with the setting off the surface leaves drags alone', (
    tester,
  ) async {
    await pumpSurface(tester, setup: _herdrLike, dragScrollsRemote: false);
    await slowDrag(tester, cellCenter(tester, 10, 8), steps: 3);
    // conduit_vt's own handler answers instead, with Shift+wheel.
    expect(
      sgrNotch.allMatches(sent()).every((m) => m.group(1) != '64'),
      isTrue,
    );
  });

  testWidgets('two fingers are left to the gesture layer', (tester) async {
    await pumpSurface(tester, setup: _herdrLike);
    final first = await tester.startGesture(cellCenter(tester, 10, 6));
    await tester.pump(const Duration(milliseconds: 20));
    final second = await tester.startGesture(
      cellCenter(tester, 30, 6),
      pointer: 7,
    );
    for (var i = 0; i < 6; i += 1) {
      await first.moveBy(const Offset(0, 14));
      await second.moveBy(const Offset(0, 14));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await first.up();
    await second.up();
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      sgrNotch.allMatches(sent()).where((m) => m.group(1) == '64'),
      isEmpty,
    );
  });
}
