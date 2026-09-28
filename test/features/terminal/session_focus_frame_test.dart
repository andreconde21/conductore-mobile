import 'dart:async';

import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/features/sessions/presentation/terminal_preview.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:conduit/features/terminal/presentation/widgets/session_focus_frame.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

void main() {
  late TerminalSessionController session;

  setUp(() {
    session = TerminalSessionController(
      host: buildHost('dev'),
      repository: NoNetworkTerminalRepository(),
    );
  });

  tearDown(() => session.dispose());

  /// A desktop split pane: the shell focuses a pane on pointer down.
  Future<({List<int> paneDowns, List<int> terminalTaps})> pumpPane(
    WidgetTester tester, {
    required bool showSharedView,
  }) async {
    final paneDowns = <int>[];
    final terminalTaps = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Listener(
          onPointerDown: (_) => paneDowns.add(1),
          child: SessionFocusFrame(
            session: session,
            palette: AppPalette.defaultPalette,
            brightness: Brightness.dark,
            fontFamily: 'monospace',
            showSharedView: showSharedView,
            child: GestureDetector(
              key: const ValueKey('terminal'),
              behavior: HitTestBehavior.opaque,
              onTap: () => terminalTaps.add(1),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
    return (paneDowns: paneDowns, terminalTaps: terminalTaps);
  }

  group('desktop split pane', () {
    testWidgets('a pane mirroring another session\'s Herdr workspace shows '
        'its own last screen, and a click only focuses the pane', (
      tester,
    ) async {
      session.terminal.write('own workspace');
      session.sharedViewSnapshot = SharedViewSnapshot.capture(
        session.terminal,
        label: 'Projects',
        at: DateTime(2026, 9, 28, 5, 54),
      );
      final taps = await pumpPane(tester, showSharedView: true);

      expect(find.byKey(const ValueKey('shared-view-cover')), findsOneWidget);
      expect(
        find.text('Shared Herdr view · as of 05:54. Click to focus.'),
        findsOneWidget,
      );
      expect(
        find.textContaining('own workspace', findRichText: true),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('shared-view-cover')));
      expect(taps.paneDowns, [1]);
      // Nothing reached the terminal, which shows the other workspace.
      expect(taps.terminalTaps, isEmpty);

      // The pane took the focus: the session owns Herdr's focus again.
      session.sharedViewSnapshot = null;
      await tester.pump();
      expect(find.byKey(const ValueKey('shared-view-cover')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('terminal')));
      expect(taps.terminalTaps, [1]);
    });

    testWidgets('the focused pane and the phone never show the cover', (
      tester,
    ) async {
      session.sharedViewSnapshot = SharedViewSnapshot(
        preview: StyledTerminalPreview.empty,
        capturedAt: DateTime(2026),
      );
      await pumpPane(tester, showSharedView: false);
      expect(find.byKey(const ValueKey('shared-view-cover')), findsNothing);
    });
  });

  testWidgets('held input shows "switching", then says what was not sent', (
    tester,
  ) async {
    await pumpPane(tester, showSharedView: false);
    final ready = Completer<bool>();
    session
      ..holdInput(ready.future, label: 'Projects')
      ..sendText('ab');

    await tester.pump(const Duration(milliseconds: 100));
    // A quick switch shows nothing.
    expect(find.textContaining('Switching Herdr'), findsNothing);
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Switching Herdr to Projects…'), findsOneWidget);

    ready.complete(false);
    await tester.pump();
    await tester.pump();
    expect(
      find.text('Herdr did not switch to Projects: 2 characters not sent'),
      findsOneWidget,
    );

    await tester.pump(const Duration(seconds: 6));
    expect(find.textContaining('Herdr did not switch'), findsNothing);
  });
}
