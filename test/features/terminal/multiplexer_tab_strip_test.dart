import 'dart:async';

import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/core/theme/terminal_appearance.dart';
import 'package:conduit/core/theme/theme_controller.dart';
import 'package:conduit/core/theme/theme_preferences_repository.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/hosts/presentation/hosts_controller.dart';
import 'package:conduit/features/sessions/domain/connect_preferences.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/sessions/presentation/session_connect_flow.dart';
import 'package:conduit/features/terminal/domain/multiplexer_tabs.dart';
import 'package:conduit/features/terminal/presentation/multiplexer_tabs_controller.dart';
import 'package:conduit/features/terminal/presentation/terminal_page.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:conduit/features/terminal/presentation/widgets/multiplexer_tab_actions.dart';
import 'package:conduit/features/terminal/presentation/widgets/multiplexer_tab_strip.dart';
import 'package:conduit_vt/conduit_vt.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

import '../../support/test_doubles.dart';
import 'multiplexer_tabs_fakes.dart';

class _NoopWakelock extends WakelockPlusPlatformInterface {
  @override
  Future<void> toggle({required bool enable}) async {}

  @override
  Future<bool> get enabled async => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  WakelockPlusPlatformInterface.instance = _NoopWakelock();

  final strip = find.byKey(const ValueKey('multiplexer-tab-strip'));
  Finder chip(String id) => find.byKey(ValueKey('mux-tab-$id'));

  test('a desktop gets the strip, a phone the compact mode by default', () {
    MultiplexerTabsLayout layout(
      MultiplexerTabsMode mode, {
      bool desktop = false,
    }) => multiplexerTabsLayout(mode, desktop: desktop);
    expect(layout(MultiplexerTabsMode.compact), MultiplexerTabsLayout.compact);
    expect(
      layout(MultiplexerTabsMode.compact, desktop: true),
      MultiplexerTabsLayout.strip,
    );
    expect(layout(MultiplexerTabsMode.strip), MultiplexerTabsLayout.strip);
    expect(layout(MultiplexerTabsMode.off), MultiplexerTabsLayout.hidden);
    expect(
      layout(MultiplexerTabsMode.off, desktop: true),
      MultiplexerTabsLayout.hidden,
    );
  });

  test('the setting is kept, compact by default', () async {
    final storage = InMemorySecureStorage();
    final first = ThemeController(ThemePreferencesRepository(storage));
    await first.load();
    expect(first.multiplexerTabs, MultiplexerTabsMode.compact);
    await first.setMultiplexerTabs(MultiplexerTabsMode.strip);
    final again = ThemeController(ThemePreferencesRepository(storage));
    await again.load();
    expect(again.multiplexerTabs, MultiplexerTabsMode.strip);
  });

  group('the strip', () {
    late FakeTmux tmux;
    late MultiplexerTabsController controller;

    Future<void> pumpStrip(
      WidgetTester tester, {
      List<String> windows = const ['zsh', 'claude', 'logs'],
      bool desktop = false,
    }) async {
      tmux = FakeTmux(windows, active: windows.length > 1 ? 1 : 0);
      controller = MultiplexerTabsController(
        backend: TmuxTabsBackend(
          channel: SerialCommandChannel(runnerFactory: () => tmux),
          sessionName: 'work',
        ),
      );
      final palette = AppPalette.fromStoredId(null);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                MultiplexerTabStrip(
                  controller: controller,
                  palette: palette,
                  brightness: Brightness.dark,
                  desktop: desktop,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.runAsync(controller.refresh);
      await tester.pump();
    }

    tearDown(() => controller.dispose());

    Future<void> settle(WidgetTester tester) async {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.runAsync(controller.refresh);
      await tester.pumpAndSettle();
    }

    testWidgets('one chip per window, the active one marked', (tester) async {
      await pumpStrip(tester);
      expect(strip, findsOneWidget);
      expect(tester.getSize(strip).height, MultiplexerTabStrip.height);
      expect(find.text('zsh'), findsOneWidget);
      expect(find.text('claude'), findsOneWidget);
      expect(find.text('logs'), findsOneWidget);
      expect(
        tester.getSemantics(chip('@1').first),
        isSemantics(isSelected: true, label: 'claude'),
      );
      expect(
        tester.getSemantics(chip('@0').first),
        isSemantics(isSelected: false),
      );
    });

    testWidgets('shows even a single window', (tester) async {
      await pumpStrip(tester, windows: ['zsh']);
      expect(strip, findsOneWidget);
    });

    testWidgets('tap switches, + opens a new window', (tester) async {
      await pumpStrip(tester);
      await tester.tap(find.text('logs'));
      await settle(tester);
      expect(tmux.commands, contains(TmuxWindowCommands.select('@2')));
      expect(controller.active?.id, '@2');

      await tester.tap(find.byKey(const ValueKey('mux-tab-new')));
      await settle(tester);
      expect(
        tmux.commands,
        contains(TmuxWindowCommands.create(afterWindowId: '@2')),
      );
      expect(controller.tabs, hasLength(4));
    });

    testWidgets('long-press renames, moves and closes (after asking)', (
      tester,
    ) async {
      await pumpStrip(tester);
      await tester.longPress(find.text('zsh'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mux-tab-rename')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('mux-tab-name')),
        'shell',
      );
      await tester.tap(find.text('Rename'));
      await settle(tester);
      expect(tmux.commands, contains(TmuxWindowCommands.rename('@0', 'shell')));
      expect(find.text('shell'), findsOneWidget);

      await tester.longPress(find.text('shell'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mux-tab-move-right')));
      await settle(tester);
      expect(
        tmux.commands,
        contains(TmuxWindowCommands.swap('@0', '@1', activeWindowId: '@1')),
      );
      expect([for (final tab in controller.tabs) tab.id], ['@1', '@0', '@2']);

      await tester.longPress(find.text('logs'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mux-tab-close')));
      await tester.pumpAndSettle();
      expect(find.text('Close "logs"?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('mux-tab-close-confirm')));
      await settle(tester);
      expect(tmux.commands, contains(TmuxWindowCommands.kill('@2')));
      expect(find.text('logs'), findsNothing);
    });

    const desktops = TargetPlatformVariant({
      TargetPlatform.linux,
      TargetPlatform.windows,
      TargetPlatform.macOS,
    });

    testWidgets('desktop: right-click opens the actions at the pointer', (
      tester,
    ) async {
      await pumpStrip(tester, desktop: true);
      await tester.tap(find.text('zsh'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('adaptive-modal-popover')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('mux-tab-rename')), findsOneWidget);
      // A right-click does not switch.
      expect(controller.active?.id, '@1');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(minutes: 3));
    }, variant: desktops);

    testWidgets(
      'desktop: hover close button and middle-click close after asking',
      (tester) async {
        await pumpStrip(tester, desktop: true);
        final close = find.byKey(const ValueKey('mux-tab-close-button-@2'));
        expect(
          tester
              .widget<Visibility>(
                find
                    .ancestor(of: close, matching: find.byType(Visibility))
                    .first,
              )
              .visible,
          isFalse,
        );
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: tester.getCenter(find.text('logs')));
        await tester.pump();
        expect(
          tester
              .widget<Visibility>(
                find
                    .ancestor(of: close, matching: find.byType(Visibility))
                    .first,
              )
              .visible,
          isTrue,
        );
        await tester.tap(close);
        await tester.pumpAndSettle();
        expect(find.text('Close "logs"?'), findsOneWidget);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        await mouse.removePointer();

        await tester.tap(
          find.text('zsh'),
          buttons: kMiddleMouseButton,
          kind: PointerDeviceKind.mouse,
        );
        await tester.pumpAndSettle();
        expect(find.text('Close "zsh"?'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('mux-tab-close-confirm')));
        await settle(tester);
        expect(tmux.commands, contains(TmuxWindowCommands.kill('@0')));
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(minutes: 3));
      },
      variant: desktops,
    );

    testWidgets('desktop: a double-click renames', (tester) async {
      await pumpStrip(tester, desktop: true);
      await tester.tap(find.text('claude'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('claude'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('mux-tab-name')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(minutes: 3));
    }, variant: desktops);

    testWidgets('phone: no close button, right-click and double-tap do '
        'nothing extra', (tester) async {
      await pumpStrip(tester);
      expect(find.byTooltip('Close window'), findsNothing);
      await tester.tap(find.text('zsh'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('mux-tab-rename')), findsNothing);
      await tester.tap(find.text('claude'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('claude'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('mux-tab-name')), findsNothing);
    });

    Future<void> openSheet(WidgetTester tester) async {
      await pumpStrip(tester);
      final context = tester.element(strip);
      unawaited(
        showMultiplexerTabsSheet(context, controller, sessionLabel: 'work'),
      );
      await tester.pumpAndSettle();
    }

    testWidgets(
      'desktop: list rows have a more button and a right-click menu',
      (tester) async {
        await openSheet(tester);
        expect(find.byTooltip('Window actions'), findsNWidgets(3));
        await tester.tap(
          find.byKey(const ValueKey('mux-tabs-sheet-@0')),
          buttons: kSecondaryButton,
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('mux-tab-rename')), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(minutes: 3));
      },
      variant: desktops,
    );

    testWidgets('phone: list rows keep long-press only', (tester) async {
      await openSheet(tester);
      expect(find.byTooltip('Window actions'), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('mux-tabs-sheet-@0')),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('mux-tab-rename')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(minutes: 3));
    });

    testWidgets('dragging a chip reorders on a desktop', (tester) async {
      await pumpStrip(tester, desktop: true);
      expect(
        find.byKey(const ValueKey('mux-tabs-reorderable')),
        findsOneWidget,
      );
      final from = tester.getCenter(find.text('zsh'));
      final to = tester.getCenter(find.text('logs'));
      // A mouse, as on a desktop: a touch drag scrolls the strip.
      final gesture = await tester.startGesture(
        from,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      for (var i = 1; i <= 10; i += 1) {
        await gesture.moveTo(
          Offset.lerp(from, to + const Offset(30, 0), i / 10)!,
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      // The drop animation, then the swaps it asked for.
      await tester.pumpAndSettle();
      await settle(tester);
      expect(
        tmux.commands.where((command) => command.contains('swap-window')),
        hasLength(2),
      );
      expect([for (final tab in controller.tabs) tab.id], ['@1', '@2', '@0']);
      await gesture.removePointer();
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(minutes: 3));
    });
  });

  group('on the terminal page', () {
    late ThemeController themeController;

    setUp(() async {
      themeController = ThemeController(InMemoryThemePreferences());
      await themeController.load();
    });

    Future<(TerminalWorkspaceController, SessionConnectFlow)> pumpPage(
      WidgetTester tester,
      ConnectTarget? target, {
      AgentCommandRunner? runner,
    }) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.6;
      addTearDown(tester.view.reset);
      final workspace = TerminalWorkspaceController(
        ImmediateTerminalRepository(TrackableTerminalSession()),
      );
      addTearDown(workspace.dispose);
      final host = buildHost('a');
      final flow = SessionConnectFlow(
        hostsController: HostsController(FakeHostsRepository()),
        workspace: workspace,
        runnerFactory: (_) => runner ?? FakeTmux(['zsh', 'claude'], active: 1),
        preferences: InMemoryConnectPreferencesRepository(),
      );
      workspace.open(target == null ? host : target.apply(host));
      await tester.pumpWidget(
        MaterialApp(
          home: TerminalPage(
            workspace: workspace,
            themeController: themeController,
            sftpRepository: NoNetworkSftpRepository(),
            connectFlow: flow,
          ),
        ),
      );
      await tester.pump();
      for (var i = 0; i < 4; i += 1) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump(const Duration(milliseconds: 100));
      }
      return (workspace, flow);
    }

    Future<void> finish(WidgetTester tester, SessionConnectFlow flow) async {
      await tester.pumpWidget(const SizedBox());
      await flow.herdr.dispose();
    }

    final inline = find.byKey(const ValueKey('mux-inline-label'));
    final overlay = find.byKey(const ValueKey('mux-tab-overlay'));

    Future<void> run(WidgetTester tester, [int rounds = 3]) async {
      for (var i = 0; i < rounds; i += 1) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    double terminalHeight(WidgetTester tester) =>
        tester.getSize(find.byType(TerminalView)).height;

    testWidgets('a plain shell has neither strip nor label', (tester) async {
      final (_, flow) = await pumpPage(tester, null);
      expect(strip, findsNothing);
      expect(inline, findsNothing);
      await finish(tester, flow);
    });

    testWidgets('on a phone a tmux session names its window in the session '
        'tab, with no extra row', (tester) async {
      final tmux = FakeTmux(['zsh', 'claude', 'logs'], active: 1)
        ..windows[2].unread = true;
      final (_, flow) = await pumpPage(
        tester,
        const ConnectTarget.tmux('work'),
        runner: tmux,
      );
      expect(strip, findsNothing);
      expect(tmux.commands.first, TmuxWindowCommands.list('work'));
      expect(inline, findsOneWidget);
      expect(
        find.descendant(of: inline, matching: find.text('claude')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: inline, matching: find.text('2/3')),
        findsOneWidget,
      );
      await finish(tester, flow);
    });

    testWidgets('the phone layout keeps its height: compact costs nothing, '
        'only the strip takes a row', (tester) async {
      await themeController.setMultiplexerTabs(MultiplexerTabsMode.off);
      var (_, flow) = await pumpPage(tester, const ConnectTarget.tmux('work'));
      final off = terminalHeight(tester);
      expect(inline, findsNothing);
      await finish(tester, flow);

      await themeController.setMultiplexerTabs(MultiplexerTabsMode.compact);
      (_, flow) = await pumpPage(tester, const ConnectTarget.tmux('work'));
      expect(inline, findsOneWidget);
      expect(terminalHeight(tester), off);
      await finish(tester, flow);

      await themeController.setMultiplexerTabs(MultiplexerTabsMode.strip);
      (_, flow) = await pumpPage(tester, const ConnectTarget.tmux('work'));
      expect(strip, findsOneWidget);
      expect(terminalHeight(tester), off - MultiplexerTabStrip.height);
      await finish(tester, flow);
    });

    testWidgets('the label opens the list: tap switches, New window adds '
        'one, long-press closes after asking', (tester) async {
      final tmux = FakeTmux(['zsh', 'claude', 'logs'], active: 1);
      final (_, flow) = await pumpPage(
        tester,
        const ConnectTarget.tmux('work'),
        runner: tmux,
      );
      await tester.tap(inline);
      await tester.pumpAndSettle();
      final sheet = find.byKey(const ValueKey('mux-tabs-sheet'));
      expect(sheet, findsOneWidget);
      expect(find.text('work · 3 windows'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('mux-tabs-sheet-@2')));
      await tester.pumpAndSettle();
      await run(tester);
      expect(sheet, findsNothing);
      expect(tmux.commands, contains(TmuxWindowCommands.select('@2')));

      await tester.tap(inline);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mux-tabs-sheet-new')));
      await tester.pumpAndSettle();
      await run(tester);
      expect(
        tmux.commands,
        contains(TmuxWindowCommands.create(afterWindowId: '@2')),
      );

      await tester.tap(inline);
      await tester.pumpAndSettle();
      await tester.longPress(find.byKey(const ValueKey('mux-tabs-sheet-@0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mux-tab-close')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mux-tab-close-confirm')));
      await tester.pumpAndSettle();
      await run(tester);
      expect(tmux.commands, contains(TmuxWindowCommands.kill('@0')));
      await finish(tester, flow);
    });

    testWidgets('switching windows elsewhere (a swipe) shows a brief overlay', (
      tester,
    ) async {
      final tmux = FakeTmux(['zsh', 'claude', 'logs'], active: 1);
      final (_, flow) = await pumpPage(
        tester,
        const ConnectTarget.tmux('work'),
        runner: tmux,
      );
      // The first listing is where the session was: no overlay.
      expect(overlay, findsNothing);

      // What a swipe does: keys into tmux, then the strip's quick check.
      await tmux.run(TmuxWindowCommands.select('@2'), timeout: Duration.zero);
      final tapAt = tester.getCenter(find.byType(TerminalView));
      await tester.tapAt(tapAt);
      await tester.pump(const Duration(milliseconds: 300));
      await run(tester);
      expect(overlay, findsOneWidget);
      expect(
        find.descendant(of: overlay, matching: find.text('logs · 3/3')),
        findsOneWidget,
      );
      // Gone after about a second, without layout space taken meanwhile.
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 400));
      expect(overlay, findsNothing);
      await finish(tester, flow);
    });

    testWidgets('the compact label lists every 5 s, the open list every '
        '2 s', (tester) async {
      final tmux = FakeTmux(['zsh', 'claude']);
      final (_, flow) = await pumpPage(
        tester,
        const ConnectTarget.tmux('work'),
        runner: tmux,
      );
      int lists() =>
          tmux.commands.where((c) => c.contains('list-windows')).length;
      final start = lists();
      await tester.pump(const Duration(milliseconds: 4500));
      await run(tester, 1);
      expect(lists(), start);
      await tester.pump(const Duration(seconds: 1));
      await run(tester, 1);
      expect(lists(), start + 1);

      await tester.tap(inline);
      await tester.pumpAndSettle();
      await run(tester, 1);
      final open = lists();
      await tester.pump(const Duration(milliseconds: 2100));
      await run(tester, 1);
      expect(lists(), greaterThan(open));
      await finish(tester, flow);
    });

    testWidgets('Ctrl+PageDown moves to the next window', (tester) async {
      final tmux = FakeTmux(['zsh', 'claude', 'logs']);
      final (_, flow) = await pumpPage(
        tester,
        const ConnectTarget.tmux('work'),
        runner: tmux,
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await run(tester);
      expect(tmux.commands, contains(TmuxWindowCommands.select('@1')));
      await finish(tester, flow);
    });

    testWidgets('a Herdr session names the focused workspace\'s tab', (
      tester,
    ) async {
      final (_, flow) = await pumpPage(
        tester,
        const ConnectTarget.herdr(workspaceId: 'w4'),
        runner: FakeHerdr(),
      );
      expect(
        find.descendant(of: inline, matching: find.text('review')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: inline, matching: find.text('2/3')),
        findsOneWidget,
      );
      await finish(tester, flow);
    });

    testWidgets('the strip setting shows the full strip on a phone', (
      tester,
    ) async {
      await themeController.setMultiplexerTabs(MultiplexerTabsMode.strip);
      final (_, flow) = await pumpPage(
        tester,
        const ConnectTarget.herdr(workspaceId: 'w4'),
        runner: FakeHerdr(),
      );
      expect(strip, findsOneWidget);
      expect(inline, findsNothing);
      expect(find.text('Infrastructure'), findsOneWidget);
      await finish(tester, flow);
    });
  });
}
