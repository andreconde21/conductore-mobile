import 'dart:async';
import 'dart:io';

import 'package:conduit/core/presentation/edge_swipe_back.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/terminal/domain/herdr_keymap.dart';
import 'package:conduit/features/terminal/domain/herdr_remote_control.dart';
import 'package:conduit/features/terminal/domain/terminal_gesture_preferences.dart';
import 'package:conduit/features/terminal/presentation/gestures/terminal_gesture_layer.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:conduit_vt/conduit_vt.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/test_doubles.dart';
import '../herdr/fake_herdr_server.dart';

/// Stands in for the terminal view: it owns the same single-finger gestures
/// (tap, long press, vertical drag) that the real view competes with.
class _Competitor {
  int taps = 0;
  int longPresses = 0;
  double verticalDrag = 0;
}

class _RecordingSession extends TerminalSessionController {
  _RecordingSession({SavedHost? host})
    : super(
        host: host ?? buildHost('gestures'),
        repository: NoNetworkTerminalRepository(),
      );

  final List<String> log = <String>[];

  @override
  void sendKey(TerminalKey key) => log.add('key:${key.name}');

  @override
  void sendControl(TerminalKey key) => log.add('ctrl:${key.name}');

  @override
  void sendText(String text) => log.add('text:$text');
}

class _Harness {
  _Harness({
    this.preferences = TerminalGesturePreferences.defaults,
    SavedHost? host,
    this.withSessionGrid = true,
    this.withAgentPanel = true,
    this.target,
    this.herdrControl,
    this.scrollMode = false,
  }) : session = _RecordingSession(host: host);

  final TerminalWindowSwitchTarget? target;
  final HerdrRemoteControl? herdrControl;
  final workspacesFocused = <String>[];

  final TerminalGesturePreferences preferences;
  final _RecordingSession session;
  final competitor = _Competitor();
  final bool withSessionGrid;
  final bool withAgentPanel;
  final fontSizes = <double>[];
  int sessionGridOpens = 0;
  int agentPanelOpens = 0;
  int enterScrollMode = 0;
  int exitScrollMode = 0;
  bool scrollMode;

  Widget build() {
    return MaterialApp(
      home: Scaffold(
        body: Center(child: SizedBox(width: 400, height: 600, child: _layer())),
      ),
    );
  }

  /// The layer filling a page pushed over a home page, with the app's
  /// page transitions (the left-edge swipe-back).
  Widget buildPushed(GlobalKey<NavigatorState> navigatorKey) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      theme: ThemeData(pageTransitionsTheme: appPageTransitionsTheme),
      home: const Scaffold(body: Text('home')),
      onGenerateRoute: (_) =>
          MaterialPageRoute<void>(builder: (_) => Scaffold(body: _layer())),
    );
  }

  Widget _layer() {
    return StatefulBuilder(
      builder: (context, setState) {
        return TerminalGestureLayer(
          target: target,
          herdrControl: herdrControl,
          onHerdrWorkspaceFocused: workspacesFocused.add,
          preferences: preferences,
          session: session,
          fontSize: 14,
          onFontSizeChanged: fontSizes.add,
          scrollMode: scrollMode,
          onEnterScrollMode: () {
            enterScrollMode += 1;
            setState(() => scrollMode = true);
          },
          onExitScrollMode: () {
            exitScrollMode += 1;
            setState(() => scrollMode = false);
          },
          onOpenSessionGrid: withSessionGrid
              ? () => sessionGridOpens += 1
              : null,
          onOpenAgentPanel: withAgentPanel ? () => agentPanelOpens += 1 : null,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => competitor.taps += 1,
            onLongPress: () => competitor.longPresses += 1,
            onVerticalDragUpdate: (details) =>
                competitor.verticalDrag += details.delta.dy,
            child: const SizedBox.expand(),
          ),
        );
      },
    );
  }
}

// The layer is centred in an 800x600 test window: x from 200 to 600,
// y from 0 to 600.
const _layerLeft = 200.0;
const _layerTop = 0.0;
const _center = Offset(400, 300);

Future<void> _swipe(
  WidgetTester tester,
  Offset from,
  Offset by, {
  int steps = 6,
}) async {
  final gesture = await tester.startGesture(from);
  await tester.pump();
  for (var i = 0; i < steps; i += 1) {
    await gesture.moveBy(by / steps.toDouble());
    await tester.pump(const Duration(milliseconds: 16));
  }
  await gesture.up();
  await tester.pump();
}

Future<void> _twoFingerMove(
  WidgetTester tester, {
  required Offset firstFrom,
  required Offset firstTo,
  required Offset secondFrom,
  required Offset secondTo,
  int steps = 6,
  bool lift = true,
  Duration hold = Duration.zero,
}) async {
  final first = await tester.createGesture(pointer: 11);
  final second = await tester.createGesture(pointer: 12);
  await first.down(firstFrom);
  await second.down(secondFrom);
  await tester.pump();
  if (hold > Duration.zero) {
    await tester.pump(hold);
  }
  final firstStep = (firstTo - firstFrom) / steps.toDouble();
  final secondStep = (secondTo - secondFrom) / steps.toDouble();
  for (var i = 0; i < steps; i += 1) {
    await first.moveBy(firstStep);
    await second.moveBy(secondStep);
    await tester.pump(const Duration(milliseconds: 16));
  }
  if (lift) {
    await first.up();
    await second.up();
    await tester.pump();
  }
}

void main() {
  group('horizontal swipe', () {
    testWidgets('swipe left sends the tmux prefix and n', (tester) async {
      final harness = _Harness();
      addTearDown(harness.session.dispose);
      await tester.pumpWidget(harness.build());

      await _swipe(tester, _center, const Offset(-120, 4));

      expect(harness.session.log, ['ctrl:keyB', 'text:n']);
      expect(harness.competitor.taps, 0);
      expect(harness.competitor.verticalDrag, 0);
    });

    testWidgets('swipe right sends the tmux prefix and p', (tester) async {
      final harness = _Harness();
      addTearDown(harness.session.dispose);
      await tester.pumpWidget(harness.build());

      await _swipe(tester, _center, const Offset(120, -6));

      expect(harness.session.log, ['ctrl:keyB', 'text:p']);
    });

    testWidgets('tmux target follows the host prefix key', (tester) async {
      final harness = _Harness(
        host: buildHost(
          'a',
        ).copyWith(tmuxPrefixKey: MultiplexerPrefixKey.controlA),
      );
      addTearDown(harness.session.dispose);
      await tester.pumpWidget(harness.build());

      await _swipe(tester, _center, const Offset(-120, 0));

      expect(harness.session.log, ['ctrl:keyA', 'text:n']);
    });

    testWidgets('Herdr target follows the host prefix key too', (tester) async {
      final harness = _Harness(
        host: buildHost(
          'a',
        ).copyWith(tmuxPrefixKey: MultiplexerPrefixKey.controlSpace),
        preferences: const TerminalGesturePreferences(
          windowSwitchTarget: TerminalWindowSwitchTarget.herdr,
        ),
      );
      addTearDown(harness.session.dispose);
      await tester.pumpWidget(harness.build());

      await _swipe(tester, _center, const Offset(-120, 0));

      expect(harness.session.log, ['ctrl:space', 'text:n']);
    });

    testWidgets('a short swipe does nothing', (tester) async {
      final harness = _Harness();
      addTearDown(harness.session.dispose);
      await tester.pumpWidget(harness.build());

      await _swipe(tester, _center, const Offset(-40, 0));

      expect(harness.session.log, isEmpty);
    });

    testWidgets('a diagonal drag stays with the terminal', (tester) async {
      final harness = _Harness();
      addTearDown(harness.session.dispose);
      await tester.pumpWidget(harness.build());

      await _swipe(tester, _center, const Offset(-90, 100));

      expect(harness.session.log, isEmpty);
      expect(harness.competitor.verticalDrag, isNot(0));
    });

    testWidgets('is off while in scroll mode', (tester) async {
      final harness = _Harness()..scrollMode = true;
      addTearDown(harness.session.dispose);
      await tester.pumpWidget(harness.build());

      await _swipe(tester, _center, const Offset(-120, 0));

      expect(harness.session.log, isEmpty);
    });

    testWidgets('can be switched off', (tester) async {
      final harness = _Harness(
        preferences: const TerminalGesturePreferences(
          swipeSwitchesWindow: false,
        ),
      );
      addTearDown(harness.session.dispose);
      await tester.pumpWidget(harness.build());

      await _swipe(tester, _center, const Offset(-120, 0));

      expect(harness.session.log, isEmpty);
    });
  });

  group('arbitration with the terminal view', () {
    testWidgets('taps, long presses and vertical drags reach the terminal', (
      tester,
    ) async {
      final harness = _Harness();
      addTearDown(harness.session.dispose);
      await tester.pumpWidget(harness.build());

      await tester.tap(find.byType(GestureDetector));
      await tester.pump(const Duration(milliseconds: 400));
      expect(harness.competitor.taps, 1);

      await tester.longPress(find.byType(GestureDetector));
      await tester.pump(const Duration(milliseconds: 400));
      expect(harness.competitor.longPresses, 1);

      await _swipe(tester, _center, const Offset(0, -150));
      expect(harness.competitor.verticalDrag, lessThan(-80));

      expect(harness.session.log, isEmpty);
      expect(harness.sessionGridOpens, 0);
      expect(harness.agentPanelOpens, 0);
      expect(harness.fontSizes, isEmpty);
    });
  });

  group('pinch', () {
    testWidgets('spreading two fingers grows the font size', (tester) async {
      final harness = _Harness();
      addTearDown(harness.session.dispose);
      await tester.pumpWidget(harness.build());

      await _twoFingerMove(
        tester,
        firstFrom: _center.translate(-40, 0),
        firstTo: _center.translate(-60, 0),
        secondFrom: _center.translate(40, 0),
        secondTo: _center.translate(60, 0),
      );

      expect(harness.fontSizes, isNotEmpty);
      expect(harness.fontSizes.last, greaterThan(14));
      expect(harness.fontSizes.last, closeTo(14 * 120 / 80, 0.5));
      expect(harness.session.log, isEmpty);
      expect(harness.competitor.verticalDrag, 0);
    });

    testWidgets('pinching in shrinks and clamps the font size', (tester) async {
      final harness = _Harness();
      addTearDown(harness.session.dispose);
      await tester.pumpWidget(harness.build());

      await _twoFingerMove(
        tester,
        firstFrom: _center.translate(-150, 0),
        firstTo: _center.translate(-4, 0),
        secondFrom: _center.translate(150, 0),
        secondTo: _center.translate(4, 0),
      );

      expect(harness.fontSizes.last, lessThan(14));
      expect(harness.fontSizes.last, greaterThanOrEqualTo(4));
    });

    testWidgets('can be switched off', (tester) async {
      final harness = _Harness(
        preferences: const TerminalGesturePreferences(pinchZoom: false),
      );
      addTearDown(harness.session.dispose);
      await tester.pumpWidget(harness.build());

      await _twoFingerMove(
        tester,
        firstFrom: _center.translate(-40, 0),
        firstTo: _center.translate(-100, 0),
        secondFrom: _center.translate(40, 0),
        secondTo: _center.translate(100, 0),
      );

      expect(harness.fontSizes, isEmpty);
    });
  });

  group('two-finger scroll', () {
    testWidgets('swiping down enters scrollback and scrolls by lines', (
      tester,
    ) async {
      final harness = _Harness();
      addTearDown(harness.session.dispose);
      await tester.pumpWidget(harness.build());

      await _twoFingerMove(
        tester,
        firstFrom: _center.translate(-30, -100),
        firstTo: _center.translate(-30, 40),
        secondFrom: _center.translate(30, -100),
        secondTo: _center.translate(30, 40),
      );

      expect(harness.enterScrollMode, 1);
      expect(harness.scrollMode, isTrue);
      expect(harness.session.log.take(2), ['ctrl:keyB', 'text:[']);
      final ups = harness.session.log
          .skip(2)
          .where((entry) => entry == 'key:arrowUp')
          .length;
      // 140px of travel at 14px a line.
      expect(ups, inInclusiveRange(9, 10));
      expect(
        harness.session.log.skip(2).every((e) => e == 'key:arrowUp'),
        isTrue,
      );
      expect(harness.fontSizes, isEmpty);
      expect(harness.competitor.verticalDrag, 0);
    });

    testWidgets('swiping up scrolls forward, then leaves past the bottom', (
      tester,
    ) async {
      final harness = _Harness();
      addTearDown(harness.session.dispose);
      await tester.pumpWidget(harness.build());

      // Scroll back four lines (56px).
      await _twoFingerMove(
        tester,
        firstFrom: _center.translate(-30, -100),
        firstTo: _center.translate(-30, -44),
        secondFrom: _center.translate(30, -100),
        secondTo: _center.translate(30, -44),
      );
      expect(harness.scrollMode, isTrue);
      harness.session.log.clear();

      // Come back four lines, then keep going past the bottom far enough to
      // leave scrollback: 56px forward + 56px exit distance.
      await _twoFingerMove(
        tester,
        firstFrom: _center.translate(-30, 100),
        firstTo: _center.translate(-30, -20),
        secondFrom: _center.translate(30, 100),
        secondTo: _center.translate(30, -20),
        steps: 12,
      );

      final downs = harness.session.log
          .where((entry) => entry == 'key:arrowDown')
          .length;
      expect(downs, 4);
      expect(harness.session.log.last, 'text:q');
      expect(harness.exitScrollMode, 1);
      expect(harness.scrollMode, isFalse);
    });

    testWidgets('swiping up outside scrollback does nothing', (tester) async {
      final harness = _Harness();
      addTearDown(harness.session.dispose);
      await tester.pumpWidget(harness.build());

      await _twoFingerMove(
        tester,
        firstFrom: _center.translate(-30, 100),
        firstTo: _center.translate(-30, -60),
        secondFrom: _center.translate(30, 100),
        secondTo: _center.translate(30, -60),
      );

      expect(harness.session.log, isEmpty);
      expect(harness.enterScrollMode, 0);
      expect(harness.exitScrollMode, 0);
    });

    testWidgets('can be switched off', (tester) async {
      final harness = _Harness(
        preferences: const TerminalGesturePreferences(twoFingerScroll: false),
      );
      addTearDown(harness.session.dispose);
      await tester.pumpWidget(harness.build());

      await _twoFingerMove(
        tester,
        firstFrom: _center.translate(-30, -100),
        firstTo: _center.translate(-30, 40),
        secondFrom: _center.translate(30, -100),
        secondTo: _center.translate(30, 40),
      );

      expect(harness.session.log, isEmpty);
      expect(harness.enterScrollMode, 0);
    });
  });

  group('header swipe', () {
    const headerStart = Offset(_layerLeft + 200, _layerTop + 20);

    testWidgets('swipe down from the top strip opens the session grid', (
      tester,
    ) async {
      final harness = _Harness();
      addTearDown(harness.session.dispose);
      await tester.pumpWidget(harness.build());

      await _swipe(tester, headerStart, const Offset(0, 120));

      expect(harness.sessionGridOpens, 1);
      expect(harness.competitor.verticalDrag, 0);
      expect(harness.session.log, isEmpty);
    });

    testWidgets('swipe down from the body scrolls the terminal instead', (
      tester,
    ) async {
      final harness = _Harness();
      addTearDown(harness.session.dispose);
      await tester.pumpWidget(harness.build());

      await _swipe(tester, _center, const Offset(0, 120));

      expect(harness.sessionGridOpens, 0);
      expect(harness.competitor.verticalDrag, greaterThan(80));
    });

    testWidgets('swipe up from the top strip scrolls the terminal', (
      tester,
    ) async {
      final harness = _Harness();
      addTearDown(harness.session.dispose);
      await tester.pumpWidget(harness.build());

      await _swipe(tester, headerStart, const Offset(0, 120));
      harness.sessionGridOpens = 0;
      harness.competitor.verticalDrag = 0;

      await _swipe(tester, headerStart.translate(0, 20), const Offset(0, -120));

      expect(harness.sessionGridOpens, 0);
      expect(harness.competitor.verticalDrag, lessThan(-80));
    });

    testWidgets('can be switched off', (tester) async {
      final harness = _Harness(
        preferences: const TerminalGesturePreferences(
          headerSwipeOpensSessions: false,
        ),
      );
      addTearDown(harness.session.dispose);
      await tester.pumpWidget(harness.build());

      await _swipe(tester, headerStart, const Offset(0, 120));

      expect(harness.sessionGridOpens, 0);
      expect(harness.competitor.verticalDrag, greaterThan(80));
    });

    testWidgets('is off without a session grid callback', (tester) async {
      final harness = _Harness(withSessionGrid: false);
      addTearDown(harness.session.dispose);
      await tester.pumpWidget(harness.build());

      await _swipe(tester, headerStart, const Offset(0, 120));

      expect(harness.competitor.verticalDrag, greaterThan(80));
    });
  });

  group('edge swipe', () {
    const edgeStart = Offset(_layerLeft + 400 - 8, 300);

    testWidgets('swipe in from the right edge opens the agent panel', (
      tester,
    ) async {
      final harness = _Harness();
      addTearDown(harness.session.dispose);
      await tester.pumpWidget(harness.build());

      await _swipe(tester, edgeStart, const Offset(-120, 0));

      expect(harness.agentPanelOpens, 1);
      // The edge swipe must not double as a window switch.
      expect(harness.session.log, isEmpty);
    });

    testWidgets('a swipe from the edge never switches windows', (tester) async {
      final harness = _Harness(
        preferences: const TerminalGesturePreferences(
          edgeSwipeOpensAgents: false,
        ),
      );
      addTearDown(harness.session.dispose);
      await tester.pumpWidget(harness.build());

      await _swipe(tester, edgeStart, const Offset(-120, 0));

      expect(harness.agentPanelOpens, 0);
      expect(harness.session.log, isEmpty);
    });

    testWidgets('is off without an agent panel callback', (tester) async {
      final harness = _Harness(withAgentPanel: false);
      addTearDown(harness.session.dispose);
      await tester.pumpWidget(harness.build());

      await _swipe(tester, edgeStart, const Offset(-120, 0));

      expect(harness.agentPanelOpens, 0);
      expect(harness.session.log, isEmpty);
    });
  });

  group('TerminalHeaderSwipeArea', () {
    testWidgets('a downward swipe on the header fires the callback', (
      tester,
    ) async {
      var opens = 0;
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalHeaderSwipeArea(
              onSwipeDown: () => opens += 1,
              child: SizedBox(
                height: 56,
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back),
                      onPressed: () => taps += 1,
                    ),
                    const Expanded(child: Text('host')),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pump();
      expect(taps, 1);
      expect(opens, 0);

      await _swipe(
        tester,
        tester.getCenter(find.text('host')),
        const Offset(0, 100),
      );
      expect(opens, 1);

      await _swipe(
        tester,
        tester.getCenter(find.text('host')),
        const Offset(0, 30),
      );
      expect(opens, 1);
    });
  });

  group('Herdr', () {
    const herdrPreferences = TerminalGesturePreferences(
      windowSwitchTarget: TerminalWindowSwitchTarget.herdr,
    );
    // Pane zoom on pinch is opt-in; font size is the default.
    const herdrZoomPreferences = TerminalGesturePreferences(
      windowSwitchTarget: TerminalWindowSwitchTarget.herdr,
      herdrPinch: HerdrPinchAction.zoomPane,
    );

    Future<void> twoFingerSwipe(WidgetTester tester, Offset by) {
      return _twoFingerMove(
        tester,
        firstFrom: _center.translate(-30, 0),
        firstTo: _center.translate(-30, 0) + by,
        secondFrom: _center.translate(30, 0),
        secondTo: _center.translate(30, 0) + by,
      );
    }

    Future<void> pinch(WidgetTester tester, {required bool out}) {
      return _twoFingerMove(
        tester,
        firstFrom: _center.translate(out ? -40 : -120, 0),
        firstTo: _center.translate(out ? -120 : -40, 0),
        secondFrom: _center.translate(out ? 40 : 120, 0),
        secondTo: _center.translate(out ? 120 : 40, 0),
      );
    }

    group('over the Herdr CLI', () {
      late FakeHerdrServer server;
      late HerdrRemoteControl control;

      // Built inside the test body: futures created in setUp would live
      // outside the widget test's fake-async zone and never run.
      Future<_Harness> pump(
        WidgetTester tester, {
        TerminalGesturePreferences preferences = herdrPreferences,
        TerminalWindowSwitchTarget? target,
      }) async {
        server = FakeHerdrServer();
        control = HerdrRemoteControl(runnerFactory: server.runner);
        final harness = _Harness(
          preferences: preferences,
          target: target,
          herdrControl: control,
        );
        addTearDown(harness.session.dispose);
        await tester.pumpWidget(harness.build());
        return harness;
      }

      testWidgets('two-finger left and right focus the neighbouring pane', (
        tester,
      ) async {
        final harness = await pump(tester);

        await twoFingerSwipe(tester, const Offset(-120, 0));
        await twoFingerSwipe(tester, const Offset(120, 4));
        await tester.pump();

        expect(server.herdrArgs, [
          'pane focus --direction right',
          'pane focus --direction left',
        ]);
        expect(harness.session.log, isEmpty);
        expect(harness.competitor.verticalDrag, 0);
        await control.close();
      });

      testWidgets('two-finger up and down switch workspaces', (tester) async {
        final harness = await pump(tester);

        await twoFingerSwipe(tester, const Offset(0, -120));
        await tester.pump();
        expect(server.focusedWorkspace, 'w2');
        await twoFingerSwipe(tester, const Offset(0, 120));
        await tester.pump();
        expect(server.focusedWorkspace, 'w1');

        expect(server.herdrArgs, [
          'workspace list',
          'workspace focus w2',
          'workspace list',
          'workspace focus w1',
        ]);
        expect(harness.workspacesFocused, ['w2', 'w1']);
        expect(harness.session.log, isEmpty);
        expect(harness.enterScrollMode, 0);
        await control.close();
      });

      testWidgets('by default a pinch changes the font size, not the pane', (
        tester,
      ) async {
        final harness = await pump(tester);

        await pinch(tester, out: true);
        await tester.pump();

        expect(server.commands, isEmpty);
        expect(harness.fontSizes.last, greaterThan(14));
        expect(harness.session.log, isEmpty);
        await control.close();
      });

      testWidgets('pinch out zooms the focused pane, pinch in restores', (
        tester,
      ) async {
        final harness = await pump(tester, preferences: herdrZoomPreferences);

        await pinch(tester, out: true);
        await pinch(tester, out: false);
        await tester.pump();

        expect(server.herdrArgs, ['pane zoom --on', 'pane zoom --off']);
        expect(harness.fontSizes, isEmpty);
        expect(harness.session.log, isEmpty);
        await control.close();
      });

      testWidgets('a pinch with one finger anchored still zooms', (
        tester,
      ) async {
        await pump(tester, preferences: herdrZoomPreferences);

        await _twoFingerMove(
          tester,
          firstFrom: _center.translate(-40, 0),
          firstTo: _center.translate(-40, 0),
          secondFrom: _center.translate(40, 0),
          secondTo: _center.translate(140, 0),
        );
        await tester.pump();

        expect(server.herdrArgs, ['pane zoom --on']);
        await control.close();
      });

      testWidgets('a session opened on a Herdr target uses the Herdr map', (
        tester,
      ) async {
        // The preference says tmux; the session knows better.
        await pump(
          tester,
          preferences: TerminalGesturePreferences.defaults,
          target: TerminalWindowSwitchTarget.herdr,
        );

        await twoFingerSwipe(tester, const Offset(-120, 0));
        await tester.pump();

        expect(server.herdrArgs, ['pane focus --direction right']);
        await control.close();
      });

      testWidgets('each mapping follows its setting', (tester) async {
        final harness = await pump(
          tester,
          preferences: herdrPreferences.copyWith(
            herdrTwoFingerPanes: false,
            herdrPinch: HerdrPinchAction.fontSize,
            herdrTwoFingerVertical: HerdrVerticalSwipe.scrollback,
          ),
        );

        await twoFingerSwipe(tester, const Offset(-120, 0));
        await pinch(tester, out: true);
        await twoFingerSwipe(tester, const Offset(0, 60));
        await tester.pump();

        expect(server.commands, isEmpty);
        expect(harness.fontSizes.last, greaterThan(14));
        // Vertical scrolls back straight away, like tmux.
        expect(harness.enterScrollMode, 1);
        expect(harness.session.log.take(2), ['ctrl:keyB', 'text:[']);
        await control.close();
      });
    });

    group('scrollback', () {
      testWidgets('resting two fingers, then dragging, scrolls back', (
        tester,
      ) async {
        final harness = _Harness(preferences: herdrPreferences);
        addTearDown(harness.session.dispose);
        await tester.pumpWidget(harness.build());

        await _twoFingerMove(
          tester,
          firstFrom: _center.translate(-30, -100),
          firstTo: _center.translate(-30, 40),
          secondFrom: _center.translate(30, -100),
          secondTo: _center.translate(30, 40),
          hold:
              TerminalGestureLayer.holdToScrollDelay +
              const Duration(milliseconds: 50),
        );

        expect(harness.enterScrollMode, 1);
        expect(harness.session.log.take(2), ['ctrl:keyB', 'text:[']);
        expect(
          harness.session.log.skip(2).where((e) => e == 'key:arrowUp').length,
          inInclusiveRange(9, 10),
        );
      });

      testWidgets('in scroll mode a plain two-finger drag scrolls', (
        tester,
      ) async {
        final harness = _Harness(
          preferences: herdrPreferences,
          scrollMode: true,
        );
        addTearDown(harness.session.dispose);
        await tester.pumpWidget(harness.build());

        await twoFingerSwipe(tester, const Offset(0, 70));

        // Already in copy mode: no prefix, no workspace switch.
        expect(harness.session.log, List.filled(5, 'key:arrowUp'));
        expect(harness.workspacesFocused, isEmpty);
      });
    });

    group('without the CLI (security-key hosts)', () {
      Future<_Harness> pump(
        WidgetTester tester, {
        TerminalGesturePreferences preferences = herdrPreferences,
      }) async {
        final harness = _Harness(preferences: preferences);
        addTearDown(harness.session.dispose);
        await tester.pumpWidget(harness.build());
        return harness;
      }

      testWidgets('two-finger swipes send Herdr\'s default pane keys', (
        tester,
      ) async {
        final harness = await pump(tester);

        await twoFingerSwipe(tester, const Offset(-120, 0));
        await twoFingerSwipe(tester, const Offset(120, 0));

        expect(harness.session.log, [
          'ctrl:keyB',
          'text:l',
          'ctrl:keyB',
          'text:h',
        ]);
      });

      testWidgets('a workspace swipe opens the workspace navigator', (
        tester,
      ) async {
        final harness = await pump(tester);

        await twoFingerSwipe(tester, const Offset(0, -120));

        expect(harness.session.log, ['ctrl:keyB', 'text:w']);
        expect(harness.enterScrollMode, 0);
      });

      testWidgets('pinch toggles zoom only when it should flip', (
        tester,
      ) async {
        final harness = await pump(tester, preferences: herdrZoomPreferences);

        await pinch(tester, out: true);
        await pinch(tester, out: true);
        await pinch(tester, out: false);

        expect(harness.session.log, [
          'ctrl:keyB',
          'text:z',
          'ctrl:keyB',
          'text:z',
        ]);
        expect(harness.fontSizes, isEmpty);
      });
    });

    testWidgets('a plain shell keeps two-finger horizontal swipes inert', (
      tester,
    ) async {
      final harness = _Harness();
      addTearDown(harness.session.dispose);
      await tester.pumpWidget(harness.build());

      await twoFingerSwipe(tester, const Offset(-120, 0));

      expect(harness.session.log, isEmpty);
    });
  });

  group('tmux session', () {
    Future<_Harness> pump(
      WidgetTester tester, {
      TerminalGesturePreferences preferences =
          TerminalGesturePreferences.defaults,
      bool scrollMode = false,
    }) async {
      final harness = _Harness(
        preferences: preferences,
        target: TerminalWindowSwitchTarget.tmux,
        scrollMode: scrollMode,
      );
      addTearDown(harness.session.dispose);
      await tester.pumpWidget(harness.build());
      return harness;
    }

    Future<void> twoFingerSwipe(WidgetTester tester, Offset by) {
      return _twoFingerMove(
        tester,
        firstFrom: _center.translate(-30, 0),
        firstTo: _center.translate(-30, 0) + by,
        secondFrom: _center.translate(30, 0),
        secondTo: _center.translate(30, 0) + by,
      );
    }

    testWidgets('one-finger swipes switch windows with prefix n / p', (
      tester,
    ) async {
      final harness = await pump(tester);

      await _swipe(tester, _center, const Offset(-120, 4));
      await _swipe(tester, _center, const Offset(120, -4));

      expect(harness.session.log, [
        'ctrl:keyB',
        'text:n',
        'ctrl:keyB',
        'text:p',
      ]);
    });

    testWidgets('two-finger left and right select the neighbouring pane '
        'with prefix Right / Left', (tester) async {
      final harness = await pump(tester);

      await twoFingerSwipe(tester, const Offset(-120, 0));
      await twoFingerSwipe(tester, const Offset(120, 4));

      expect(harness.session.log, [
        'ctrl:keyB',
        'key:arrowRight',
        'ctrl:keyB',
        'key:arrowLeft',
      ]);
      expect(harness.fontSizes, isEmpty);
      expect(harness.enterScrollMode, 0);
    });

    testWidgets('two-finger up and down stay scrollback in copy mode', (
      tester,
    ) async {
      final harness = await pump(tester);

      await twoFingerSwipe(tester, const Offset(0, 140));

      expect(harness.enterScrollMode, 1);
      expect(harness.session.log.take(2), ['ctrl:keyB', 'text:[']);
      expect(
        harness.session.log.skip(2).every((entry) => entry == 'key:arrowUp'),
        isTrue,
      );
    });

    testWidgets('pinch still changes the font size', (tester) async {
      final harness = await pump(tester);

      await _twoFingerMove(
        tester,
        firstFrom: _center.translate(-40, 0),
        firstTo: _center.translate(-120, 0),
        secondFrom: _center.translate(40, 0),
        secondTo: _center.translate(120, 0),
      );

      expect(harness.fontSizes, isNotEmpty);
      expect(harness.session.log, isEmpty);
    });

    testWidgets('no pane switch while in scrollback', (tester) async {
      final harness = await pump(tester, scrollMode: true);

      await twoFingerSwipe(tester, const Offset(-120, 0));

      expect(harness.session.log, isEmpty);
    });

    testWidgets('follows the two-finger pane setting', (tester) async {
      final harness = await pump(
        tester,
        preferences: const TerminalGesturePreferences(
          herdrTwoFingerPanes: false,
        ),
      );

      await twoFingerSwipe(tester, const Offset(-120, 0));

      expect(harness.session.log, isEmpty);
    });
  });

  group('with the machine\'s Herdr keymap', () {
    setUp(() {
      HerdrKeymapCache.instance.put(
        'gestures',
        HerdrKeymap.parseConfig(
          File(
            'test/features/terminal/herdr/fixtures/'
            'herdr_config_dev_central.toml',
          ).readAsStringSync(),
        ),
      );
    });
    tearDown(HerdrKeymapCache.instance.clear);

    Future<_Harness> pump(WidgetTester tester) async {
      final harness = _Harness(
        preferences: const TerminalGesturePreferences(
          windowSwitchTarget: TerminalWindowSwitchTarget.herdr,
        ),
      );
      addTearDown(harness.session.dispose);
      await tester.pumpWidget(harness.build());
      return harness;
    }

    testWidgets('tab swipes use its prefix', (tester) async {
      final harness = await pump(tester);
      await _swipe(tester, _center, const Offset(-120, 0));
      expect(harness.session.log, ['ctrl:space', 'text:n']);
    });

    testWidgets('pane swipes without the CLI use its ctrl+alt+arrows, not '
        'prefix+h (a split there)', (tester) async {
      final harness = await pump(tester);
      await _twoFingerMove(
        tester,
        firstFrom: _center.translate(-30, 0),
        firstTo: _center.translate(-150, 0),
        secondFrom: _center.translate(30, 0),
        secondTo: _center.translate(-90, 0),
      );
      expect(harness.session.log, ['text:\x1b[1;7C']);
    });

    testWidgets('the workspace fallback opens its workspace picker', (
      tester,
    ) async {
      final harness = await pump(tester);
      await _twoFingerMove(
        tester,
        firstFrom: _center.translate(-30, 0),
        firstTo: _center.translate(-30, -120),
        secondFrom: _center.translate(30, 0),
        secondTo: _center.translate(30, -120),
      );
      expect(harness.session.log, ['ctrl:space', 'text:f']);
    });
  });

  group('left-edge swipe-back on a pushed terminal page', () {
    Future<_Harness> pumpPushed(WidgetTester tester) async {
      final harness = _Harness();
      addTearDown(harness.session.dispose);
      final navigatorKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(harness.buildPushed(navigatorKey));
      unawaited(navigatorKey.currentState!.pushNamed<void>('terminal'));
      await tester.pumpAndSettle();
      expect(find.byType(TerminalGestureLayer), findsOneWidget);
      return harness;
    }

    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      testWidgets('a swipe from the edge goes back (${platform.name})', (
        tester,
      ) async {
        debugDefaultTargetPlatformOverride = platform;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        final harness = await pumpPushed(tester);

        await _swipe(tester, const Offset(4, 300), const Offset(500, 0));
        await tester.pumpAndSettle();

        expect(find.byType(TerminalGestureLayer), findsNothing);
        expect(find.text('home'), findsOneWidget);
        // Not also a window swipe.
        expect(harness.session.log, isEmpty);
        debugDefaultTargetPlatformOverride = null;
      });

      testWidgets('the same swipe off the edge switches the window '
          '(${platform.name})', (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        final harness = await pumpPushed(tester);

        await _swipe(tester, const Offset(120, 300), const Offset(500, 0));
        await tester.pumpAndSettle();

        expect(find.byType(TerminalGestureLayer), findsOneWidget);
        expect(harness.session.log, ['ctrl:keyB', 'text:p']);
        debugDefaultTargetPlatformOverride = null;
      });
    }

    testWidgets('scrolling, taps and long presses at the edge stay with the '
        'terminal', (tester) async {
      final harness = await pumpPushed(tester);

      await _swipe(tester, const Offset(4, 200), const Offset(0, 160));
      await tester.tapAt(const Offset(4, 300));
      await tester.longPressAt(const Offset(4, 400));
      await tester.pumpAndSettle();

      expect(find.byType(TerminalGestureLayer), findsOneWidget);
      expect(harness.competitor.verticalDrag, greaterThan(100));
      expect(harness.competitor.taps, 1);
      expect(harness.competitor.longPresses, 1);
    });
  });
}
