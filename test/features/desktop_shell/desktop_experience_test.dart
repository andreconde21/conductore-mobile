import 'dart:async';

import 'package:conduit/core/presentation/desktop_window.dart';
import 'package:conduit/features/desktop_shell/domain/layout_presets.dart';
import 'package:conduit/features/desktop_shell/domain/sidebar_tree.dart';
import 'package:conduit/features/desktop_shell/presentation/desktop_home.dart';
import 'package:conduit/features/desktop_shell/presentation/desktop_shell_controller.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'shell_harness.dart';

final _linux = TargetPlatformVariant.only(TargetPlatform.linux);

String _view(String hostId) => 'session:$hostId';

DesktopHomeState _home(WidgetTester tester) =>
    tester.state<DesktopHomeState>(find.byType(DesktopHome));

Future<void> _keys(
  WidgetTester tester,
  List<LogicalKeyboardKey> modifiers,
  LogicalKeyboardKey key,
) async {
  for (final modifier in modifiers) {
    await tester.sendKeyDownEvent(modifier);
  }
  await tester.sendKeyEvent(key);
  for (final modifier in modifiers.reversed) {
    await tester.sendKeyUpEvent(modifier);
  }
  await tester.pump();
  await tester.pump();
}

Future<void> _drag(WidgetTester tester, Offset from, Offset to) async {
  final gesture = await tester.startGesture(
    from,
    kind: PointerDeviceKind.mouse,
  );
  await gesture.moveBy(const Offset(12, 12));
  await tester.pump();
  await gesture.moveTo(to);
  await tester.pump();
  await gesture.up();
  await settleShell(tester);
}

void main() {
  setUp(DesktopWindow.reset);

  testWidgets('the layout picker lays out 2×2; a sidebar row dragged onto '
      'an empty pane opens there; a pane header dragged onto another '
      'swaps them', (tester) async {
    final h = await pumpShell(tester, size: const Size(1600, 1000));
    final a = await h.open(
      tester,
      workstation,
      const ConnectTarget.tmux('main'),
    );
    final b = await h.open(tester, buildBox, const ConnectTarget.tmux('ci'));
    h.shell.showHome = false;
    await settleShell(tester);

    await tester.tap(find.byKey(const ValueKey('shell-layout-picker')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('layout-preset-grid3x2')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('layout-preset-grid2x2')));
    await settleShell(tester);
    var layout = h.shell.layout.value;
    expect(ShellLayoutPreset.of(layout), ShellLayoutPreset.grid2x2);
    // The focused session leads, the other follows, two panes wait.
    expect(
      [for (final pane in layout.panes) pane.view],
      [_view(b.host.id), _view(a.host.id), null, null],
    );
    expect(find.byKey(const ValueKey('shell-empty-pane-p3')), findsOneWidget);

    // Drag the tmux session "build" from the sidebar onto pane 3.
    final row = find.byKey(
      ValueKey(
        'sidebar-row-machines-${SidebarKeys.tmuxSession('workstation', 'build')}',
      ),
    );
    await _drag(
      tester,
      tester.getCenter(row),
      tester.getCenter(find.byKey(const ValueKey('shell-pane-p3'))),
    );
    layout = h.shell.layout.value;
    expect(layout.panes.length, 4);
    expect(layout.panes[2].view, _view('workstation#tmux:build'));
    expect(h.workspace.sessions.length, 3);

    // Drag pane 1's header onto the middle of pane 2: they swap.
    await _drag(
      tester,
      tester.getCenter(find.byKey(const ValueKey('shell-pane-header-p1'))),
      tester.getCenter(find.byKey(const ValueKey('shell-pane-p2'))),
    );
    layout = h.shell.layout.value;
    expect(layout.panes[0].view, _view(a.host.id));
    expect(layout.panes[1].view, _view(b.host.id));
    await tearDownShell(tester);
  }, variant: _linux);

  testWidgets('Ctrl+Shift+P opens the palette on commands; it runs layouts, '
      'remembers them and saves named layouts', (tester) async {
    final h = await pumpShell(tester, size: const Size(1600, 1000));
    final a = await h.open(
      tester,
      workstation,
      const ConnectTarget.tmux('main'),
    );
    final b = await h.open(tester, buildBox, const ConnectTarget.tmux('ci'));
    h.shell.showHome = false;
    await settleShell(tester);

    await _keys(tester, [
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.shiftLeft,
    ], LogicalKeyboardKey.keyP);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('command-palette')), findsOneWidget);
    // Commands only: no sessions under ">".
    expect(
      find.byKey(ValueKey('palette-session:session-${a.host.id}')),
      findsNothing,
    );
    await tester.enterText(
      find.byKey(const ValueKey('command-palette-search')),
      '>side by side',
    );
    await tester.pump();
    expect(find.text('Layout: Two side by side'), findsOneWidget);
    // The shortcut shows next to commands that have one.
    await tester.enterText(
      find.byKey(const ValueKey('command-palette-search')),
      '>new session',
    );
    await tester.pump();
    expect(find.text('Ctrl+Shift+T'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('command-palette-search')),
      '>side by side',
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settleShell(tester);
    expect(find.byKey(const ValueKey('command-palette')), findsNothing);
    expect(
      ShellLayoutPreset.of(h.shell.layout.value),
      ShellLayoutPreset.sideBySide,
    );
    expect(h.shell.paletteRecents.first, 'layout:sideBySide');

    // Without a prefix the switcher's rows come first: the open sessions.
    await _keys(tester, [
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.shiftLeft,
    ], LogicalKeyboardKey.keyK);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('command-palette-search')),
      'ci',
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settleShell(tester);
    expect(h.workspace.activeSession, b);

    // Save the layout under a name, then restore it from the palette.
    _home(tester).applyPreset(ShellLayoutPreset.stacked);
    await settleShell(tester);
    final saved = h.shell.saveLayout('Morning check');
    _home(tester).applyPreset(ShellLayoutPreset.single);
    await settleShell(tester);
    expect(h.shell.layout.value.panes.length, 1);
    await _keys(tester, [
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.shiftLeft,
    ], LogicalKeyboardKey.keyP);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('command-palette-search')),
      '>morning',
    );
    await tester.pump();
    await tester.tap(find.byKey(ValueKey('palette-saved-layout:${saved.id}')));
    await settleShell(tester);
    expect(
      ShellLayoutPreset.of(h.shell.layout.value),
      ShellLayoutPreset.stacked,
    );
    await tearDownShell(tester);
  }, variant: _linux);

  testWidgets('a saved layout reopens the sessions it showed', (tester) async {
    final h = await pumpShell(tester, size: const Size(1600, 1000));
    final a = await h.open(
      tester,
      workstation,
      const ConnectTarget.tmux('main'),
    );
    await h.open(tester, buildBox, const ConnectTarget.tmux('ci'));
    h.shell.showHome = false;
    await settleShell(tester);
    _home(tester).applyPreset(ShellLayoutPreset.sideBySide);
    await settleShell(tester);
    final saved = h.shell.saveLayout('VTM work');
    // Close one session; restoring opens it again in its pane.
    unawaited(h.workspace.close(a));
    await settleShell(tester);
    expect(h.workspace.sessions.length, 1);
    unawaited(_home(tester).restoreLayout(saved));
    await settleShell(tester);
    expect(h.workspace.sessions.map((s) => s.host.id), contains(a.host.id));
    expect(
      {for (final pane in h.shell.layout.value.panes) pane.view},
      {for (final view in saved.views) view},
    );
    await tearDownShell(tester);
  }, variant: _linux);

  testWidgets('keyboard: Ctrl+Shift+B hides the sidebar; the window title '
      'follows the focused session', (tester) async {
    final h = await pumpShell(tester);
    expect(DesktopWindow.lastTitle, 'Conductore');
    await h.open(tester, buildBox, const ConnectTarget.tmux('ci'));
    h.shell.showHome = false;
    await settleShell(tester);
    expect(DesktopWindow.lastTitle, contains('— Conductore'));
    expect(DesktopWindow.lastTitle, contains('build-box'));
    h.shell.showHome = true;
    await settleShell(tester);
    expect(DesktopWindow.lastTitle, 'Conductore');

    expect(find.byKey(const ValueKey('shell-sidebar')), findsOneWidget);
    await _keys(tester, [
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.shiftLeft,
    ], LogicalKeyboardKey.keyB);
    await tester.pump();
    expect(find.byKey(const ValueKey('shell-sidebar')), findsNothing);
    expect(
      find.byKey(const ValueKey('shell-sidebar-collapsed')),
      findsOneWidget,
    );
    await tearDownShell(tester);
  }, variant: _linux);

  testWidgets('phones: no palette keys, no layout picker, the quick switcher '
      'as before', (tester) async {
    final h = await pumpShell(tester, size: const Size(400, 800));
    expect(find.byType(DesktopHome), findsNothing);
    await _keys(tester, [
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.shiftLeft,
    ], LogicalKeyboardKey.keyP);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('command-palette')), findsNothing);
    expect(find.byKey(const ValueKey('shell-layout-picker')), findsNothing);
    await _keys(tester, [
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.shiftLeft,
    ], LogicalKeyboardKey.keyK);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('quick-switcher')), findsOneWidget);
    expect(DesktopWindow.lastTitle, isNull);
    expect(h.shell.paletteRecents, isEmpty);
    await tearDownShell(tester);
  });

  testWidgets('the sidebar filter opens its first match on Enter and '
      'clears on Esc; Esc closes the right panel', (tester) async {
    final h = await pumpShell(tester);
    await tester.enterText(
      find.byKey(const ValueKey('sidebar-filter')),
      'build',
    );
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settleShell(tester);
    expect(h.workspace.sessions, isNotEmpty);
    await tester.tap(find.byKey(const ValueKey('sidebar-filter')));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(h.shell.filter, isEmpty);

    h.shell.rightPanel = ShellRightPanel.agents;
    h.shell.showHome = true;
    await settleShell(tester);
    await tester.tap(find.byKey(const ValueKey('shell-right-panel-agents')));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(h.shell.rightPanel, ShellRightPanel.none);
    await tearDownShell(tester);
  }, variant: _linux);
}
