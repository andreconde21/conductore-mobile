import 'dart:async';

import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/features/sessions/presentation/terminal_preview.dart';
import 'package:conduit/features/terminal/presentation/session_input_hold.dart';
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
    bool showAgentView = false,
    HerdrFocusActions? herdrActions,
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
            showAgentView: showAgentView,
            herdrActions: herdrActions,
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

  // CON-062: an agent opened while this device may not move Herdr's focus
  // showed the live screen, which mirrors another workspace.
  testWidgets('an agent opened here shows its own screen and "Show here", '
      'with the banner above', (tester) async {
    session.terminal.write('agent screen');
    session
      ..sharedViewSnapshot = SharedViewSnapshot.capture(
        session.terminal,
        label: 'api',
        at: DateTime(2026, 10, 3, 8, 15),
      )
      ..focusElsewhereLabel = 'Projects';
    var taken = 0;
    final taps = await pumpPane(
      tester,
      showSharedView: false,
      showAgentView: true,
      herdrActions: HerdrFocusActions(
        typeInComposer: (_) {},
        takeFocusOnce: () async => taken += 1,
        useShownWorkspace: () async {},
      ),
    );
    expect(find.byKey(const ValueKey('shared-view-cover')), findsOneWidget);
    expect(
      find.textContaining('agent screen', findRichText: true),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('herdr-focus-banner')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('agent-view-show-here')));
    expect(taken, 1);
    expect(taps.terminalTaps, isEmpty);
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

  group('when this device may not move Herdr focus', () {
    late List<String> calls;
    late HerdrFocusActions actions;

    setUp(() {
      calls = [];
      actions = HerdrFocusActions(
        typeInComposer: (held) => calls.add('composer:$held'),
        takeFocusOnce: () async => calls.add('take'),
        useShownWorkspace: () async => calls.add('use'),
      );
    });

    testWidgets('the banner says what Herdr shows, with its actions', (
      tester,
    ) async {
      await pumpPane(tester, showSharedView: false, herdrActions: actions);
      expect(find.byKey(const ValueKey('herdr-focus-banner')), findsNothing);

      session.focusElsewhereLabel = 'Projects';
      await tester.pump();
      expect(
        find.text('Herdr is showing Projects (another screen has focus).'),
        findsOneWidget,
      );
      expect(find.text('Type in composer'), findsOneWidget);
      expect(find.text('Take focus once'), findsOneWidget);
      expect(find.text('Use Projects here'), findsOneWidget);
      // Nothing typed yet: nothing to discard.
      expect(find.text('Discard'), findsNothing);

      // Typed keys are held.
      session
        ..decideInput(
          Future.value(InputHoldDecision.block),
          blockedLabel: () => 'Projects',
        )
        ..sendText('ls');
      await tester.pump();
      await tester.pump();
      expect(
        find.text(
          'Herdr is showing Projects (another screen has focus). '
          '2 typed characters are waiting.',
        ),
        findsOneWidget,
      );

      await tester.tap(find.text('Take focus once'));
      await tester.tap(find.text('Use Projects here'));
      await tester.tap(find.text('Type in composer'));
      await tester.pump();
      expect(calls, ['take', 'use', 'composer:ls']);
      // The composer took the held keys.
      expect(session.inputHold.value, isNull);

      session.sendText('x');
      session.decideInput(
        Future.value(InputHoldDecision.block),
        blockedLabel: () => 'Projects',
      );
      await tester.pump();
      await tester.pump();
      await tester.tap(find.text('Discard'));
      await tester.pump();
      expect(session.inputHold.value, isNull);
      expect(find.text('Discard'), findsNothing);
    });

    testWidgets('a split pane\'s cover offers "Take focus" instead of taking '
        'it', (tester) async {
      session.sharedViewSnapshot = SharedViewSnapshot(
        preview: StyledTerminalPreview.empty,
        capturedAt: DateTime(2026),
      );
      final taps = await pumpPane(
        tester,
        showSharedView: true,
        herdrActions: actions,
      );
      expect(find.text('Click to focus.'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('shared-view-take-focus')));
      await tester.pump();
      expect(calls, ['take']);
      expect(taps.terminalTaps, isEmpty);
    });
  });
}
