// CON-094: the soft keyboard opening over the terminal must leave the
// terminal's live bottom rows (where Claude Code draws its permission
// dialog and question form) above the keyboard, the first time too.
import 'package:conduit_vt/conduit_vt.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<ScrollPosition> _pump(
  WidgetTester tester,
  Terminal terminal,
  FocusNode focus,
) async {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: TerminalView(terminal, focusNode: focus)),
    ),
  );
  await tester.pump();
  return tester.state<ScrollableState>(find.byType(Scrollable)).position;
}

/// The keyboard slides in over several frames, as on a phone.
Future<void> _openKeyboard(WidgetTester tester, {int steps = 6}) async {
  for (var i = 1; i <= steps; i++) {
    tester.view.viewInsets = FakeViewPadding(bottom: 300.0 * i / steps);
    await tester.pump(const Duration(milliseconds: 16));
  }
  await tester.pump(const Duration(milliseconds: 100));
}

Terminal _terminalWithScrollback() {
  final terminal = Terminal();
  for (var i = 0; i < 200; i++) {
    terminal.write('line $i\r\n');
  }
  terminal.write('DIALOG');
  return terminal;
}

void main() {
  for (final focusFirst in [true, false]) {
    testWidgets(
      'the live bottom ends above the keyboard (focus first: $focusFirst)',
      (tester) async {
        final terminal = _terminalWithScrollback();
        final focus = FocusNode();
        addTearDown(focus.dispose);
        final position = await _pump(tester, terminal, focus);
        expect(position.pixels, position.maxScrollExtent);
        if (focusFirst) focus.requestFocus();
        await _openKeyboard(tester);
        if (!focusFirst) {
          focus.requestFocus();
          await tester.pump();
        }
        await tester.pump(const Duration(milliseconds: 300));
        expect(position.pixels, position.maxScrollExtent);
      },
    );
  }

  testWidgets('a view left a little above the bottom comes back to it when '
      'the keyboard opens before the terminal has focus', (tester) async {
    final terminal = _terminalWithScrollback();
    final focus = FocusNode();
    addTearDown(focus.dispose);
    final position = await _pump(tester, terminal, focus);
    // A stray drag (a tap that moved) left it three lines up.
    position.jumpTo(position.maxScrollExtent - 50);
    await tester.pump();
    expect(position.pixels, lessThan(position.maxScrollExtent));

    await _openKeyboard(tester);
    focus.requestFocus();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(position.pixels, position.maxScrollExtent);
  });

  testWidgets('the remote redraw at the new size stays at the bottom', (
    tester,
  ) async {
    final terminal = _terminalWithScrollback();
    final focus = FocusNode();
    addTearDown(focus.dispose);
    // The remote app answers each resize by drawing its dialog again at
    // the bottom of the new size.
    terminal.onResize = (columns, rows, _, _) {
      Future<void>.delayed(const Duration(milliseconds: 40), () {
        terminal.write('\r\n' * 3);
        terminal.write('Do you want to proceed?\r\n1. Yes\r\n2. No');
      });
    };
    final position = await _pump(tester, terminal, focus);
    focus.requestFocus();
    await tester.pump();
    position.jumpTo(position.maxScrollExtent - 50);
    await tester.pump();

    await _openKeyboard(tester);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    expect(position.pixels, position.maxScrollExtent);
  });

  testWidgets('focus arriving while the keyboard is already up shows the '
      'bottom (back from the chat composer)', (tester) async {
    final terminal = _terminalWithScrollback();
    final focus = FocusNode();
    addTearDown(focus.dispose);
    final position = await _pump(tester, terminal, focus);
    await _openKeyboard(tester);
    position.jumpTo(position.maxScrollExtent - 200);
    await tester.pump();

    focus.requestFocus();
    await tester.pump();
    await tester.pump();

    expect(position.pixels, position.maxScrollExtent);
  });

  testWidgets('scrollback being read stays put while the keyboard closes', (
    tester,
  ) async {
    final terminal = _terminalWithScrollback();
    final focus = FocusNode();
    addTearDown(focus.dispose);
    final position = await _pump(tester, terminal, focus);
    focus.requestFocus();
    await _openKeyboard(tester);
    position.jumpTo(1000);
    await tester.pump();

    for (var i = 5; i >= 0; i--) {
      tester.view.viewInsets = FakeViewPadding(bottom: 300.0 * i / 6);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pump(const Duration(milliseconds: 100));

    expect(position.pixels, 1000);
  });
}
