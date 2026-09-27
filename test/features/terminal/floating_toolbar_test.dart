import 'dart:io';

import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/core/theme/terminal_appearance.dart';
import 'package:conduit/core/theme/terminal_pill_items.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/snippets/domain/terminal_snippet.dart';
import 'package:conduit/features/terminal/domain/herdr_keymap.dart';
import 'package:conduit/features/terminal/domain/herdr_navigator.dart';
import 'package:conduit/features/terminal/presentation/terminal_keyboard_bar.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:conduit/features/terminal/presentation/widgets/floating_toolbar.dart';
import 'package:conduit/features/terminal/presentation/widgets/toolbar_arrow_pad.dart';
import 'package:conduit_vt/conduit_vt.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';
import 'herdr/fake_herdr_runner.dart';

const _pill = ValueKey('floating-toolbar-pill');
const _arrows = ValueKey('toolbar-arrows');
const _withArrows = [
  TerminalPillItem.button(TerminalPillButton.ctrl),
  TerminalPillItem.button(TerminalPillButton.esc),
  TerminalPillItem.button(TerminalPillButton.arrows),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget buildToolbar({
    required _RecordingTerminalSessionController controller,
    required FocusNode focusNode,
    List<TerminalSnippet> globalSnippets = const [],
    bool composeActive = false,
    VoidCallback? onToggleCompose,
    Future<void> Function()? onReconnect,
    TerminalToolbarStyle style = TerminalToolbarStyle.floatingPill,
    List<TerminalPillItem> pillItems = defaultTerminalPillItems,
    ValueChanged<List<TerminalPillItem>>? onPillItemsChanged,
    PillCommandRunnerFactory? runnerFactory,
    List<TerminalKeyboardItem> extraRowItems = const [],
    MultiplexerPrefixKey prefix = MultiplexerPrefixKey.controlB,
    VoidCallback? onOpenRecentDirectories,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            Expanded(
              child: Focus(
                focusNode: focusNode,
                child: const SizedBox.expand(),
              ),
            ),
            TerminalKeyboardBar(
              controller: controller,
              focusNode: focusNode,
              palette: AppPalette.catppuccin,
              brightness: Brightness.dark,
              rows: [
                TerminalKeyboardRow(
                  items: [
                    const TerminalKeyboardItem.builtIn(
                      TerminalKeyboardAction.herdrMenu,
                    ),
                    const TerminalKeyboardItem.builtIn(
                      TerminalKeyboardAction.tmuxMenu,
                    ),
                    ...extraRowItems,
                  ],
                ),
              ],
              globalSnippets: globalSnippets,
              fullscreen: false,
              onToggleFullscreen: () {},
              composeActive: composeActive,
              onToggleCompose: onToggleCompose,
              onEnterTmuxScrollMode: () {},
              onExitTmuxScrollMode: () {},
              tmuxPrefixKey: prefix,
              tmuxScrollMode: false,
              onOpenRecentDirectories: onOpenRecentDirectories,
            ).withToolbarStyle(
              style,
              onReconnect: onReconnect,
              pillItems: pillItems,
              onPillItemsChanged: onPillItemsChanged,
              runnerFactory: runnerFactory,
            ),
          ],
        ),
      ),
    );
  }

  List<MethodCall> recordPlatformCalls(WidgetTester tester) {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        calls.add(call);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    return calls;
  }

  /// Swipes up starting on the Esc key: any spot on the pill works except the
  /// arrow pad, which claims its own drags.
  Future<void> swipeUp(WidgetTester tester) {
    return tester.dragFrom(
      tester.getCenter(find.text('Esc')),
      const Offset(0, -80),
    );
  }

  group('FloatingTerminalToolbar', () {
    testWidgets('long-press alternates: Esc sends Ctrl+C, Tab sends Shift+Tab, '
        'with haptic feedback', (tester) async {
      final controller = _RecordingTerminalSessionController();
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);
      addTearDown(controller.dispose);
      final platformCalls = recordPlatformCalls(tester);

      await tester.pumpWidget(
        buildToolbar(controller: controller, focusNode: focusNode),
      );

      await tester.tap(find.text('Esc'));
      await tester.tap(find.text('Tab'));
      expect(controller.sentKeys, [TerminalKey.escape, TerminalKey.tab]);
      expect(controller.sentControlKeys, isEmpty);
      expect(platformCalls.where(_isHaptic), isEmpty);

      await tester.longPress(find.text('Esc'));
      expect(controller.sentControlKeys, [TerminalKey.keyC]);
      expect(platformCalls.where(_isHaptic), hasLength(1));

      await tester.longPress(find.text('Tab'));
      expect(controller.sentKeys, [
        TerminalKey.escape,
        TerminalKey.tab,
        TerminalKey.backtab,
      ]);
      expect(platformCalls.where(_isHaptic), hasLength(2));
    });

    testWidgets(
      'desktop: right-click runs the long-press action, tooltips say so',
      (tester) async {
        final controller = _RecordingTerminalSessionController();
        final focusNode = FocusNode();
        addTearDown(focusNode.dispose);
        addTearDown(controller.dispose);
        recordPlatformCalls(tester);
        await tester.pumpWidget(
          buildToolbar(controller: controller, focusNode: focusNode),
        );
        expect(
          find.byTooltip('Escape. Right-click for Ctrl+C'),
          findsOneWidget,
        );
        await tester.tap(find.text('Esc'), buttons: kSecondaryButton);
        await tester.tap(find.text('Tab'), buttons: kSecondaryButton);
        expect(controller.sentControlKeys, [TerminalKey.keyC]);
        expect(controller.sentKeys, [TerminalKey.backtab]);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.linux,
        TargetPlatform.windows,
        TargetPlatform.macOS,
      }),
    );

    testWidgets('phone: right-click does nothing, tooltips say long-press', (
      tester,
    ) async {
      final controller = _RecordingTerminalSessionController();
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);
      addTearDown(controller.dispose);
      recordPlatformCalls(tester);
      await tester.pumpWidget(
        buildToolbar(controller: controller, focusNode: focusNode),
      );
      expect(find.byTooltip('Escape. Long-press for Ctrl+C'), findsOneWidget);
      await tester.tap(find.text('Esc'), buttons: kSecondaryButton);
      expect(controller.sentControlKeys, isEmpty);
      expect(controller.sentKeys, isEmpty);
    });

    testWidgets('Ctrl tap arms the next key, long-press latches until '
        'released', (tester) async {
      final controller = _RecordingTerminalSessionController();
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);
      addTearDown(controller.dispose);
      recordPlatformCalls(tester);

      await tester.pumpWidget(
        buildToolbar(controller: controller, focusNode: focusNode),
      );

      // One-shot: armed, consumed by the next key.
      await tester.tap(find.text('Ctrl'));
      await tester.pump();
      expect(controller.keyboard.ctrl, isTrue);
      expect(controller.keyboard.ctrlLatched, isFalse);
      await tester.tap(find.text('Esc'));
      await tester.pump();
      expect(controller.keyboard.ctrl, isFalse);

      // Latched: survives keys, highlighted, released by the next tap.
      await tester.longPress(find.text('Ctrl'));
      await tester.pump();
      expect(controller.keyboard.ctrlLatched, isTrue);
      expect(controller.keyboard.ctrl, isTrue);
      await tester.tap(find.text('Esc'));
      await tester.tap(find.text('Tab'));
      await tester.pump();
      expect(controller.keyboard.ctrl, isTrue);
      expect(controller.keyboard.ctrlLatched, isTrue);
      final latchedStyle = tester.widget<Text>(find.text('Ctrl')).style;
      expect(latchedStyle?.color, AppPalette.catppuccin.canvas);

      await tester.tap(find.text('Ctrl'));
      await tester.pump();
      expect(controller.keyboard.ctrlLatched, isFalse);
      expect(controller.keyboard.ctrl, isFalse);
      final releasedStyle = tester.widget<Text>(find.text('Ctrl')).style;
      expect(releasedStyle?.color, AppPalette.catppuccin.foreground);
    });

    testWidgets('arrow pad drag emits arrows proportional to the distance '
        'and repeats while held far out', (tester) async {
      final controller = _RecordingTerminalSessionController();
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        buildToolbar(
          controller: controller,
          focusNode: focusNode,
          pillItems: _withArrows,
        ),
      );

      final pad = find.byKey(_arrows);
      await tester.drag(pad, const Offset(90, 0));
      await tester.pump();
      expect(
        controller.sentKeys,
        List.filled(
          (90 / toolbarArrowPadStep).truncate(),
          TerminalKey.arrowRight,
        ),
      );

      controller.sentKeys.clear();
      await tester.drag(pad, const Offset(0, -40));
      await tester.pump();
      expect(controller.sentKeys, [TerminalKey.arrowUp, TerminalKey.arrowUp]);

      // Moving back toward the origin mirrors the finger.
      controller.sentKeys.clear();
      final gesture = await tester.startGesture(tester.getCenter(pad));
      await gesture.moveBy(const Offset(40, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(-40, 0));
      await tester.pump();
      expect(controller.sentKeys, [
        TerminalKey.arrowRight,
        TerminalKey.arrowRight,
        TerminalKey.arrowLeft,
        TerminalKey.arrowLeft,
      ]);

      // Resting past the hold radius auto-repeats the direction.
      controller.sentKeys.clear();
      await gesture.moveBy(const Offset(0, 70));
      await tester.pump();
      final immediate = controller.sentKeys.length;
      expect(immediate, greaterThan(0));
      expect(controller.sentKeys.toSet(), {TerminalKey.arrowDown});
      await tester.pump(toolbarArrowPadRepeatDelay);
      await tester.pump(toolbarArrowPadRepeatInterval);
      await tester.pump(toolbarArrowPadRepeatInterval);
      expect(controller.sentKeys.length, immediate + 2);
      expect(controller.sentKeys.toSet(), {TerminalKey.arrowDown});
      await gesture.up();
      await tester.pump(toolbarArrowPadRepeatInterval * 3);
      expect(controller.sentKeys.length, immediate + 2);
    });

    testWidgets('arrow pad taps: edges send a single arrow, the centre '
        'nothing', (tester) async {
      final controller = _RecordingTerminalSessionController();
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        buildToolbar(
          controller: controller,
          focusNode: focusNode,
          pillItems: _withArrows,
        ),
      );

      final pad = find.byKey(_arrows);
      final rect = tester.getRect(pad);
      await tester.tapAt(Offset(rect.center.dx, rect.top + 3));
      await tester.tapAt(Offset(rect.right - 3, rect.center.dy));
      await tester.tapAt(Offset(rect.center.dx, rect.bottom - 3));
      await tester.tapAt(Offset(rect.left + 3, rect.center.dy));
      await tester.tapAt(rect.center);
      await tester.pump();

      expect(controller.sentKeys, [
        TerminalKey.arrowUp,
        TerminalKey.arrowRight,
        TerminalKey.arrowDown,
        TerminalKey.arrowLeft,
      ]);
    });

    testWidgets('swipe up opens the palette; quick prompts type the line '
        'and press Enter separately', (tester) async {
      final controller = _RecordingTerminalSessionController();
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        buildToolbar(
          controller: controller,
          focusNode: focusNode,
          globalSnippets: const [
            TerminalSnippet(id: 'g1', label: 'Deploy', text: 'make deploy'),
          ],
        ),
      );
      expect(find.text('Quick prompts'), findsNothing);

      await swipeUp(tester);
      await tester.pumpAndSettle();

      expect(find.text('Quick prompts'), findsOneWidget);
      expect(find.text('/clear'), findsOneWidget);
      expect(find.text('/compact'), findsOneWidget);
      expect(find.text('Esc Esc'), findsOneWidget);
      expect(find.text('Ctrl+C'), findsOneWidget);
      expect(find.text('Deploy'), findsOneWidget);
      expect(controller.sentText, isEmpty);

      await tester.tap(find.text('/clear'));
      await tester.pump();
      expect(controller.sentText, ['/clear']);
      expect(controller.sentKeys, isEmpty);
      await tester.pump(floatingToolbarSubmitDelay);
      expect(controller.sentKeys, [TerminalKey.enter]);
      await tester.pumpAndSettle();
      expect(find.text('Quick prompts'), findsNothing);

      await swipeUp(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Esc Esc'));
      await tester.pumpAndSettle();
      expect(controller.sentKeys, [
        TerminalKey.enter,
        TerminalKey.escape,
        TerminalKey.escape,
      ]);

      await swipeUp(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ctrl+C'));
      await tester.pumpAndSettle();
      expect(controller.sentControlKeys, [TerminalKey.keyC]);

      await swipeUp(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Deploy'));
      await tester.pump();
      expect(controller.sentText, ['/clear', 'make deploy']);
      expect(controller.sentKeys.last, TerminalKey.escape);
      await tester.pump(floatingToolbarSubmitDelay);
      expect(controller.sentKeys.last, TerminalKey.enter);
      await tester.pumpAndSettle();
    });

    testWidgets('a short or sideways drag does not open the palette', (
      tester,
    ) async {
      final controller = _RecordingTerminalSessionController();
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        buildToolbar(controller: controller, focusNode: focusNode),
      );

      // Within the touch slop this is just a tap on Esc.
      await tester.dragFrom(
        tester.getCenter(find.text('Esc')),
        const Offset(0, -10),
      );
      await tester.pumpAndSettle();
      expect(find.text('Quick prompts'), findsNothing);
      expect(controller.sentKeys, [TerminalKey.escape]);
      controller.sentKeys.clear();

      await tester.dragFrom(
        tester.getCenter(find.text('Esc')),
        const Offset(-80, 0),
      );
      await tester.pumpAndSettle();
      expect(find.text('Quick prompts'), findsNothing);
      expect(controller.sentKeys, isEmpty);
      expect(controller.sentControlKeys, isEmpty);
    });

    testWidgets('sits above a three-button navigation bar', (tester) async {
      final controller = _RecordingTerminalSessionController();
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        buildToolbar(controller: controller, focusNode: focusNode),
      );
      final screenHeight =
          tester.view.physicalSize.height / tester.view.devicePixelRatio;
      final withoutInset = tester.getBottomRight(find.byKey(_pill)).dy;
      expect(withoutInset, lessThanOrEqualTo(screenHeight));

      // A three-button Android navigation bar with the keyboard hidden is
      // reported as bottom view padding (physical pixels).
      tester.view.viewPadding = const FakeViewPadding(bottom: 96);
      addTearDown(tester.view.resetViewPadding);
      tester.view.padding = const FakeViewPadding(bottom: 96);
      addTearDown(tester.view.resetPadding);
      await tester.pump();

      final inset = 96 / tester.view.devicePixelRatio;
      final withInset = tester.getBottomRight(find.byKey(_pill)).dy;
      expect(withInset, lessThanOrEqualTo(screenHeight - inset));
      expect(withInset, lessThanOrEqualTo(withoutInset - inset));
      // Exactly the pill gap above the navigation bar, like Moshi.
      expect(withInset, screenHeight - inset - floatingToolbarBottomGap);
      expect(tester.getSize(find.byKey(_pill)).height, 40);
    });

    testWidgets('the overflow button reveals and hides the key rows', (
      tester,
    ) async {
      final controller = _RecordingTerminalSessionController();
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        buildToolbar(controller: controller, focusNode: focusNode),
      );
      expect(find.text('Herdr'), findsNothing);
      expect(find.byType(TerminalKeyboardBar), findsNothing);

      await tester.tap(find.byKey(const ValueKey('toolbar-more')));
      await tester.pumpAndSettle();
      expect(find.text('Herdr'), findsOneWidget);
      expect(find.text('Tmux+'), findsOneWidget);
      // The rows sit above the pill, not below it.
      expect(
        tester.getBottomLeft(find.text('Herdr')).dy,
        lessThan(tester.getTopLeft(find.byKey(_pill)).dy),
      );

      await tester.tap(find.byKey(const ValueKey('toolbar-more')));
      await tester.pumpAndSettle();
      expect(find.text('Herdr'), findsNothing);
    });

    testWidgets('redraw sends Ctrl+L on tap and reconnects on long-press', (
      tester,
    ) async {
      final controller = _RecordingTerminalSessionController();
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);
      addTearDown(controller.dispose);
      recordPlatformCalls(tester);
      var reconnects = 0;

      await tester.pumpWidget(
        buildToolbar(
          controller: controller,
          focusNode: focusNode,
          onReconnect: () async => reconnects += 1,
        ),
      );

      await tester.tap(find.byKey(const ValueKey('toolbar-redraw')));
      expect(controller.sentControlKeys, [TerminalKey.keyL]);
      expect(reconnects, 0);

      await tester.longPress(find.byKey(const ValueKey('toolbar-redraw')));
      await tester.pump();
      expect(reconnects, 1);
      expect(controller.sentControlKeys, [TerminalKey.keyL]);
    });

    testWidgets('chat button toggles compose mode and reflects it', (
      tester,
    ) async {
      final controller = _RecordingTerminalSessionController();
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);
      addTearDown(controller.dispose);
      var toggles = 0;

      await tester.pumpWidget(
        buildToolbar(
          controller: controller,
          focusNode: focusNode,
          onToggleCompose: () => toggles += 1,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('toolbar-chat')));
      expect(toggles, 1);
    });

    testWidgets('keyboard button shows the soft keyboard when hidden and '
        'hides it when shown', (tester) async {
      final controller = _RecordingTerminalSessionController();
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);
      addTearDown(controller.dispose);
      final textInputCalls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.textInput,
        (call) async {
          textInputCalls.add(call.method);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.textInput,
          null,
        ),
      );

      await tester.pumpWidget(
        buildToolbar(controller: controller, focusNode: focusNode),
      );
      expect(find.byIcon(Icons.keyboard_rounded), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('toolbar-keyboard')));
      await tester.pump();
      expect(textInputCalls, ['TextInput.show']);
      expect(focusNode.hasFocus, isTrue);

      tester.view.viewInsets = const FakeViewPadding(bottom: 600);
      addTearDown(tester.view.resetViewInsets);
      await tester.pump();
      expect(find.byIcon(Icons.keyboard_hide_rounded), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('toolbar-keyboard')));
      await tester.pump();
      expect(textInputCalls, ['TextInput.show', 'TextInput.hide']);
    });

    testWidgets('default pill is Moshi-compact: 40 dp high, 36 dp buttons, '
        'Moshi set plus Herdr in order', (tester) async {
      final controller = _RecordingTerminalSessionController();
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        buildToolbar(controller: controller, focusNode: focusNode),
      );

      expect(tester.getSize(find.byKey(_pill)).height, 40);
      for (final key in ['toolbar-herdr', 'toolbar-paste', 'toolbar-more']) {
        expect(tester.getSize(find.byKey(ValueKey(key))), const Size(36, 36));
      }
      expect(
        tester.getSize(find.byKey(const ValueKey('toolbar-esc'))).height,
        36,
      );
      final order = [
        'toolbar-ctrl',
        'toolbar-esc',
        'toolbar-tab',
        'toolbar-herdr',
        'toolbar-redraw',
        'toolbar-paste',
        'toolbar-chat',
        'toolbar-keyboard',
        'toolbar-more',
      ];
      final xs = [
        for (final key in order) tester.getCenter(find.byKey(ValueKey(key))).dx,
      ];
      expect(xs, [...xs]..sort());
      expect(find.byKey(_arrows), findsNothing);
      final icon = tester.widget<Icon>(
        find.descendant(
          of: find.byKey(const ValueKey('toolbar-paste')),
          matching: find.byType(Icon),
        ),
      );
      expect(icon.size, 20);
    });

    testWidgets('configured buttons, custom keys and the Tmux key appear in '
        'the chosen order', (tester) async {
      final controller = _RecordingTerminalSessionController();
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        buildToolbar(
          controller: controller,
          focusNode: focusNode,
          pillItems: const [
            TerminalPillItem.custom('deploy'),
            TerminalPillItem.button(TerminalPillButton.tmux),
            TerminalPillItem.custom('gone'),
            TerminalPillItem.button(TerminalPillButton.esc),
          ],
          extraRowItems: const [
            TerminalKeyboardItem(
              id: 'deploy',
              kind: TerminalKeyboardItemKind.customText,
              label: 'Deploy',
              text: 'make deploy',
              submit: true,
            ),
          ],
        ),
      );

      expect(find.byKey(const ValueKey('toolbar-ctrl')), findsNothing);
      expect(find.byKey(const ValueKey('toolbar-custom-gone')), findsNothing);
      final deployX = tester.getCenter(find.text('Deploy')).dx;
      final tmuxX = tester
          .getCenter(find.byKey(const ValueKey('toolbar-tmux')))
          .dx;
      final escX = tester.getCenter(find.text('Esc')).dx;
      expect(deployX, lessThan(tmuxX));
      expect(tmuxX, lessThan(escX));

      await tester.tap(find.text('Deploy'));
      expect(controller.sentText, ['make deploy\r']);
    });

    testWidgets('long-press on ⋯ opens the configurator; reorder, remove and '
        'add are saved', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);
      final controller = _RecordingTerminalSessionController();
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);
      addTearDown(controller.dispose);
      final saved = <List<TerminalPillItem>>[];

      await tester.pumpWidget(
        buildToolbar(
          controller: controller,
          focusNode: focusNode,
          onPillItemsChanged: saved.add,
        ),
      );

      await tester.longPress(find.byKey(const ValueKey('toolbar-more')));
      await tester.pumpAndSettle();
      expect(find.text('Toolbar buttons'), findsOneWidget);

      // Drag Ctrl below Esc and Tab.
      final ctrlRow = find.byKey(const ValueKey('pill-config-item-ctrl'));
      final handle = find.descendant(
        of: ctrlRow,
        matching: find.byIcon(Icons.drag_indicator_rounded),
      );
      final rowHeight = tester.getSize(ctrlRow).height;
      final gesture = await tester.startGesture(tester.getCenter(handle));
      await tester.pump();
      for (var step = 0; step < 10; step += 1) {
        await gesture.moveBy(Offset(0, rowHeight * 1.8 / 10));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('pill-config-remove-paste')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('pill-config-add-arrows')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pill-config-add-arrows')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pill-config-save')));
      await tester.pumpAndSettle();

      expect(saved, hasLength(1));
      expect(saved.single.map((item) => item.encode()), [
        'esc',
        'tab',
        'ctrl',
        'herdr',
        'reconnect',
        'chat',
        'keyboard',
        'arrows',
      ]);
    });

    testWidgets('the configurator can be cancelled and is off without a '
        'save callback', (tester) async {
      final controller = _RecordingTerminalSessionController();
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        buildToolbar(controller: controller, focusNode: focusNode),
      );
      await tester.longPress(find.byKey(const ValueKey('toolbar-more')));
      await tester.pumpAndSettle();
      expect(find.text('Toolbar buttons'), findsNothing);
    });

    testWidgets('Herdr button lists panes, highlights the current one and '
        'switches with herdr agent focus', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);
      HerdrPaneListingCache.instance.clear();
      HerdrKeymapCache.instance.clear();
      final controller = _RecordingTerminalSessionController();
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);
      addTearDown(controller.dispose);
      final runners = <FakeHerdrRunner>[];

      await tester.pumpWidget(
        buildToolbar(
          controller: controller,
          focusNode: focusNode,
          runnerFactory: (host) {
            final runner = FakeHerdrRunner.withPanes();
            runners.add(runner);
            return runner;
          },
        ),
      );

      await tester.tap(find.byKey(const ValueKey('toolbar-herdr')));
      await tester.pumpAndSettle();

      expect(find.text('reviewer'), findsOneWidget);
      expect(find.text('fix-auth'), findsOneWidget);
      expect(find.text('logs'), findsOneWidget);
      expect(find.text('Current'), findsNWidgets(1));
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('herdr-pane-w1:p1')),
          matching: find.text('Current'),
        ),
        findsOneWidget,
      );
      expect(find.text('Needs input'), findsOneWidget);
      // Shortcuts follow the panes: the quick rows first, then the groups.
      expect(
        tester.getTopLeft(find.text('fix-auth')).dy,
        lessThan(tester.getTopLeft(find.textContaining('Jump to tab')).dy),
      );
      await tester.scrollUntilVisible(
        find.text('Splits'),
        200,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('herdr-navigator')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(find.text('Splits'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('fix-auth'),
        -200,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('herdr-navigator')),
              matching: find.byType(Scrollable),
            )
            .first,
      );

      await tester.tap(find.text('fix-auth'));
      await tester.pumpAndSettle();

      expect(runners, hasLength(1));
      expect(runners.single.commands.last, contains('agent focus w2:p1'));
      expect(runners.single.closed, isTrue);
      expect(controller.sentControlKeys, isEmpty);
      expect(controller.sentText, isEmpty);

      // The cached listing shows at once on the next open.
      await tester.tap(find.byKey(const ValueKey('toolbar-herdr')));
      await tester.pump();
      expect(find.text('reviewer'), findsOneWidget);
      await tester.pumpAndSettle();
    });

    testWidgets('"cd to…" appears in the Herdr navigator and the Tmux+ '
        'menu only when the page offers it', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);
      HerdrPaneListingCache.instance.clear();
      HerdrKeymapCache.instance.clear();
      final controller = _RecordingTerminalSessionController();
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);
      addTearDown(controller.dispose);
      var opened = 0;

      await tester.pumpWidget(
        buildToolbar(controller: controller, focusNode: focusNode),
      );
      await tester.tap(find.byKey(const ValueKey('toolbar-herdr')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('herdr-cd-to')), findsNothing);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      await tester.pumpWidget(
        buildToolbar(
          controller: controller,
          focusNode: focusNode,
          onOpenRecentDirectories: () => opened++,
          pillItems: const [
            TerminalPillItem.button(TerminalPillButton.herdr),
            TerminalPillItem.button(TerminalPillButton.tmux),
          ],
        ),
      );
      await tester.tap(find.byKey(const ValueKey('toolbar-herdr')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('herdr-cd-to')));
      await tester.pumpAndSettle();
      expect(opened, 1);

      await tester.tap(find.byKey(const ValueKey('toolbar-tmux')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('cd to…'));
      await tester.pumpAndSettle();
      expect(opened, 2);
      // Neither entry types anything into the session.
      expect(controller.sentText, isEmpty);
      expect(controller.sentControlKeys, isEmpty);
    });

    testWidgets('Herdr navigator says Herdr is not found and its shortcuts '
        'still send the host prefix', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);
      HerdrPaneListingCache.instance.clear();
      HerdrKeymapCache.instance.clear();
      final controller = _RecordingTerminalSessionController();
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        buildToolbar(
          controller: controller,
          focusNode: focusNode,
          prefix: MultiplexerPrefixKey.controlSpace,
          runnerFactory: (host) => FakeHerdrRunner.notInstalled(),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('toolbar-herdr')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('herdr-not-found')), findsOneWidget);
      expect(find.textContaining('prefix Ctrl+Space'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('herdr-shortcut-newTab')));
      await tester.pumpAndSettle();

      expect(controller.sentControlKeys, [TerminalKey.space]);
      expect(controller.sentText, ['c']);
    });

    testWidgets('picking a pane without a command channel falls back to '
        "Herdr's goto picker", (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);
      HerdrPaneListingCache.instance.clear();
      HerdrKeymapCache.instance.clear();
      final controller = _RecordingTerminalSessionController();
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        buildToolbar(
          controller: controller,
          focusNode: focusNode,
          runnerFactory: (host) => FakeHerdrRunner((command) {
            if (command.contains('focus')) {
              return const AgentCommandResult(
                stdout: '',
                stderr: 'unknown',
                exitCode: 2,
              );
            }
            return FakeHerdrRunner.panesResponse(command);
          }),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('toolbar-herdr')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('reviewer'));
      await tester.pumpAndSettle();

      expect(controller.sentControlKeys, [TerminalKey.keyB]);
      expect(controller.sentText, ['g']);
      expect(find.textContaining('goto picker'), findsOneWidget);
    });

    Future<_RecordingTerminalSessionController> openNavigator(
      WidgetTester tester, {
      MultiplexerPrefixKey prefix = MultiplexerPrefixKey.controlB,
      PillCommandRunnerFactory? runnerFactory,
    }) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);
      HerdrPaneListingCache.instance.clear();
      HerdrKeymapCache.instance.clear();
      final controller = _RecordingTerminalSessionController();
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        buildToolbar(
          controller: controller,
          focusNode: focusNode,
          prefix: prefix,
          runnerFactory: runnerFactory ?? (host) => FakeHerdrRunner.withPanes(),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('toolbar-herdr')));
      await tester.pumpAndSettle();
      return controller;
    }

    testWidgets('Herdr navigator tab buttons 1-9 send prefix and the digit', (
      tester,
    ) async {
      final controller = await openNavigator(
        tester,
        prefix: MultiplexerPrefixKey.controlSpace,
      );
      for (var number = 1; number <= 9; number += 1) {
        expect(find.byKey(ValueKey('herdr-tab-$number')), findsOneWidget);
      }
      expect(find.text('Jump to tab  ·  Ctrl+Space 1–9'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('herdr-tab-3')));
      await tester.pumpAndSettle();

      expect(controller.sentControlKeys, [TerminalKey.space]);
      expect(controller.sentText, ['3']);
    });

    testWidgets('Herdr quick actions are labelled with the host prefix', (
      tester,
    ) async {
      final controller = await openNavigator(
        tester,
        prefix: MultiplexerPrefixKey.controlA,
      );
      expect(find.text('Ctrl+A c'), findsOneWidget);
      expect(find.text('Ctrl+A w'), findsOneWidget);
      expect(find.text('Ctrl+A g'), findsOneWidget);
      expect(find.text('Ctrl+A z'), findsOneWidget);
      expect(find.text('Ctrl+A x'), findsOneWidget);
      expect(find.text('Ctrl+A q'), findsOneWidget);

      // Herdr detaches with q, not tmux's d.
      await tester.tap(find.byKey(const ValueKey('herdr-quick-detach')));
      await tester.pumpAndSettle();
      expect(controller.sentControlKeys, [TerminalKey.keyA]);
      expect(controller.sentText, ['q']);
    });

    testWidgets('Herdr quick zoom and jump send their bindings', (
      tester,
    ) async {
      var controller = await openNavigator(tester);
      await tester.tap(find.byKey(const ValueKey('herdr-quick-zoomPane')));
      await tester.pumpAndSettle();
      expect(controller.sentText, ['z']);

      controller = await openNavigator(tester);
      await tester.tap(find.byKey(const ValueKey('herdr-quick-gotoPicker')));
      await tester.pumpAndSettle();
      expect(controller.sentText, ['g']);
    });

    testWidgets('kill pane asks first, then closes the focused pane over '
        'the CLI', (tester) async {
      final runners = <FakeHerdrRunner>[];
      final controller = await openNavigator(
        tester,
        runnerFactory: (host) {
          final runner = FakeHerdrRunner((command) {
            if (command.contains('pane list')) {
              return const AgentCommandResult(
                stdout:
                    '{"result":{"panes":[{"pane_id":"w1:p1","focused":false},'
                    '{"pane_id":"w1:p2","focused":true}]}}',
                stderr: '',
                exitCode: 0,
              );
            }
            return FakeHerdrRunner.panesResponse(command);
          });
          runners.add(runner);
          return runner;
        },
      );

      await tester.tap(find.byKey(const ValueKey('herdr-quick-closePane')));
      await tester.pumpAndSettle();
      expect(find.text('Kill pane?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(
        runners.single.commands.where((c) => c.contains('pane close')),
        isEmpty,
      );
      expect(controller.sentText, isEmpty);

      await tester.tap(find.byKey(const ValueKey('toolbar-herdr')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('herdr-quick-closePane')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('herdr-confirm')));
      await tester.pumpAndSettle();

      expect(runners.last.commands.last, contains('pane close w1:p2'));
      expect(controller.sentText, isEmpty);
      expect(runners.last.closed, isTrue);
    });

    testWidgets('kill pane falls back to prefix x without a command channel', (
      tester,
    ) async {
      final controller = await openNavigator(
        tester,
        runnerFactory: (host) => FakeHerdrRunner.notInstalled(),
      );
      await tester.tap(find.byKey(const ValueKey('herdr-quick-closePane')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('herdr-confirm')));
      await tester.pumpAndSettle();

      expect(controller.sentControlKeys, [TerminalKey.keyB]);
      expect(controller.sentText, ['x']);
    });

    testWidgets('the navigator reads the machine\'s Herdr keymap and uses '
        'it for labels and keys', (tester) async {
      final config = File(
        'test/features/terminal/herdr/fixtures/herdr_config_dev_central.toml',
      ).readAsStringSync();
      final runners = <FakeHerdrRunner>[];
      var controller = await openNavigator(
        tester,
        runnerFactory: (host) {
          final runner = FakeHerdrRunner(
            (command) => command.contains('herdr/config.toml')
                ? AgentCommandResult(stdout: config, stderr: '', exitCode: 0)
                : FakeHerdrRunner.panesResponse(command),
          );
          runners.add(runner);
          return runner;
        },
      );

      expect(runners.single.commands.first, contains('herdr/config.toml'));
      // The machine's prefix (ctrl+space) and bindings, not the defaults.
      expect(find.text('Ctrl+Space d'), findsOneWidget);
      expect(find.text('Ctrl+Space f'), findsOneWidget);
      expect(find.text('Ctrl+Space q'), findsNothing);
      expect(find.text('Jump to tab  ·  Ctrl+Space 1–9'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('herdr-quick-detach')));
      await tester.pumpAndSettle();
      expect(controller.sentControlKeys, [TerminalKey.space]);
      expect(controller.sentText, ['d']);

      // Read once per machine: the next open does not ask again.
      controller = _RecordingTerminalSessionController();
      addTearDown(controller.dispose);
      await tester.tap(find.byKey(const ValueKey('toolbar-herdr')));
      await tester.pumpAndSettle();
      expect(
        runners.last.commands.where((c) => c.contains('config.toml')),
        isEmpty,
      );
      await tester.tap(
        find.byKey(const ValueKey('herdr-quick-workspacePicker')),
      );
      await tester.pumpAndSettle();
    });

    testWidgets('the key rows style bypasses the pill entirely', (
      tester,
    ) async {
      final controller = _RecordingTerminalSessionController();
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        buildToolbar(
          controller: controller,
          focusNode: focusNode,
          style: TerminalToolbarStyle.keyRows,
        ),
      );

      expect(find.byType(FloatingTerminalToolbar), findsNothing);
      expect(find.byKey(_pill), findsNothing);
      expect(find.text('Herdr'), findsOneWidget);
    });
  });
}

bool _isHaptic(MethodCall call) => call.method == 'HapticFeedback.vibrate';

class _RecordingTerminalSessionController extends TerminalSessionController {
  _RecordingTerminalSessionController({SavedHost? host})
    : super(
        host: host ?? buildHost('toolbar'),
        repository: NoNetworkTerminalRepository(),
      );

  final List<TerminalKey> sentKeys = <TerminalKey>[];
  final List<TerminalKey> sentControlKeys = <TerminalKey>[];
  final List<String> sentText = <String>[];

  @override
  void sendKey(TerminalKey key) {
    sentKeys.add(key);
    keyboard.clearModifiers();
  }

  @override
  void sendControl(TerminalKey key) {
    sentControlKeys.add(key);
    keyboard.clearModifiers();
  }

  @override
  void sendText(String text) {
    sentText.add(text);
    keyboard.clearModifiers();
  }
}
