import 'dart:async';
import 'dart:io';

import 'package:conduit/core/presentation/multiplexer_icon.dart';
import 'package:conduit/core/telemetry/telemetry.dart';
import 'package:conduit/core/telemetry/telemetry_config.dart';
import 'package:conduit/core/telemetry/telemetry_preferences.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_launcher.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_page.dart';
import 'package:conduit/features/desktop_shell/data/desktop_shell_store.dart';
import 'package:conduit/features/desktop_shell/domain/shell_layout.dart';
import 'package:conduit/features/desktop_shell/domain/sidebar_tree.dart';
import 'package:conduit/features/desktop_shell/presentation/desktop_home.dart';
import 'package:conduit/features/desktop_shell/presentation/desktop_shell_controller.dart';
import 'package:conduit/features/desktop_shell/presentation/terminal_shell_embedding.dart';
import 'package:conduit/features/desktop_shell/presentation/widgets/shell_tab_strip.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/usage/data/usage_preferences.dart';
import 'package:conduit/features/usage/presentation/usage_controller.dart';
import 'package:conduit/features/usage/presentation/usage_explorer_view.dart';
import 'package:conduit/features/usage/presentation/usage_widgets.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../usage/usage_fakes.dart';
import 'shell_harness.dart';

final _linux = TargetPlatformVariant.only(TargetPlatform.linux);

Finder _row(String key, {String section = 'machines'}) =>
    find.byKey(ValueKey('sidebar-row-$section-$key'));

Finder _tab(String viewId) => find.byKey(ValueKey('shell-tab-$viewId'));

DesktopHomeState _home(WidgetTester tester) =>
    tester.state<DesktopHomeState>(find.byType(DesktopHome));

String _view(String hostId) => 'session:$hostId';

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

void main() {
  group('who gets the shell', () {
    test('desktops always, tablets from 900 dp, never phones', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      expect(usesDesktopShell(const Size(900, 600)), isTrue);
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(usesDesktopShell(const Size(390, 844)), isFalse);
      // A phone in landscape stays on the phone home.
      expect(usesDesktopShell(const Size(915, 412)), isFalse);
      expect(usesDesktopShell(const Size(800, 1280)), isFalse);
      expect(usesDesktopShell(const Size(1280, 800)), isTrue);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('phones and narrow tablets keep the phone home', (
      tester,
    ) async {
      for (final size in const [Size(390, 844), Size(800, 1280)]) {
        await pumpShell(tester, size: size, pixelRatio: 2);
        expect(find.byKey(const ValueKey('home-scroll')), findsOneWidget);
        expect(find.byKey(const ValueKey('shell-sidebar')), findsNothing);
        expect(find.byType(DesktopHome), findsNothing);
        await tearDownShell(tester);
      }
    });
  });

  group('sidebar', () {
    testWidgets('machines, workspaces with logos, and Needs you first', (
      tester,
    ) async {
      final h = await pumpShell(tester);
      expect(find.byKey(const ValueKey('shell-dashboard')), findsOneWidget);
      final infra = SidebarKeys.herdrWorkspace('workstation', 'w1');
      expect(_row(SidebarKeys.machine('workstation')), findsOneWidget);
      expect(_row(SidebarKeys.machine('build-box')), findsOneWidget);
      expect(
        find.descendant(
          of: _row(infra),
          matching: find.byType(MultiplexerIcon),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: _row(infra), matching: find.text('Infrastructure')),
        findsOneWidget,
      );
      // The waiting agent's tab is pinned on top, by its human name.
      expect(
        find.byKey(const ValueKey('sidebar-header-needsYou-')),
        findsOneWidget,
      );
      final review = SidebarKeys.herdrTab('workstation', 'w1', 'w1:t2');
      expect(_row(review, section: 'needsYou'), findsOneWidget);
      expect(
        find.descendant(
          of: _row(review, section: 'needsYou'),
          matching: find.byKey(const ValueKey('state-dot-needsYou')),
        ),
        findsOneWidget,
      );

      // Workspaces start closed; the chevron shows their tabs.
      expect(_row(review), findsNothing);
      await tester.tap(find.byKey(ValueKey('sidebar-chevron-$infra')));
      await tester.pump();
      expect(_row(review), findsOneWidget);

      // tmux windows are listed when the session is opened.
      final main = SidebarKeys.tmuxSession('workstation', 'main');
      await tester.tap(find.byKey(ValueKey('sidebar-chevron-$main')));
      await settleShell(tester);
      expect(
        _row(SidebarKeys.tmuxWindow('workstation', 'main', 1)),
        findsOneWidget,
      );
      expect(find.text('1: claude'), findsOneWidget);

      // The filter keeps matches and their parents.
      await tester.enterText(
        find.byKey(const ValueKey('sidebar-filter')),
        'calendar',
      );
      await tester.pump();
      expect(
        _row(SidebarKeys.herdrWorkspace('workstation', 'w2')),
        findsOneWidget,
      );
      expect(_row(infra), findsNothing);
      expect(_row(SidebarKeys.machine('build-box')), findsNothing);
      expect(h.shell.filter, 'calendar');
      await tearDownShell(tester);
    }, variant: _linux);

    testWidgets('drag reorders machines; pins and groups persist', (
      tester,
    ) async {
      final h = await pumpShell(tester);
      final workstationRow = _row(SidebarKeys.machine('workstation'));
      final buildBoxRow = _row(SidebarKeys.machine('build-box'));
      // The machine list's order: alphabetical.
      expect(
        tester.getTopLeft(buildBoxRow).dy,
        lessThan(tester.getTopLeft(workstationRow).dy),
      );
      // Drag workstation above build-box.
      final gesture = await tester.startGesture(
        tester.getCenter(workstationRow),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(0, -30));
      await tester.pump();
      await gesture.moveTo(
        tester.getTopLeft(buildBoxRow) + const Offset(40, 4),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('sidebar-drop-line')), findsOneWidget);
      await gesture.up();
      await settleShell(tester);
      expect(h.shell.prefs.machineOrder.first, 'workstation');
      expect(
        tester.getTopLeft(_row(SidebarKeys.machine('workstation'))).dy,
        lessThan(tester.getTopLeft(_row(SidebarKeys.machine('build-box'))).dy),
      );

      // Pin a workspace and group a machine from the prefs API the
      // context menu uses; both are saved.
      final calendar = SidebarKeys.herdrWorkspace('workstation', 'w2');
      h.shell.updatePrefs((prefs) => prefs.togglePin(calendar));
      await tester.pump();
      expect(_row(calendar, section: 'pinned'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 50));
      final saved = h.store.state!['sidebar']! as Map;
      expect(saved['pinned'], [calendar]);
      expect(saved['machineOrder'], ['workstation', 'build-box']);
      await tearDownShell(tester);
    }, variant: _linux);

    testWidgets('the context menu makes groups and pins', (tester) async {
      final h = await pumpShell(tester);
      await tester.tap(
        _row(SidebarKeys.machine('build-box')),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('New group…'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('group-name-field')),
        'Infra',
      );
      await tester.tap(find.byKey(const ValueKey('group-name-save')));
      await tester.pumpAndSettle();
      expect(h.shell.prefs.groups.single.name, 'Infra');
      expect(h.shell.prefs.groupOf('build-box')?.name, 'Infra');
      expect(find.text('INFRA'), findsOneWidget);
      expect(find.text('MACHINES'), findsOneWidget);

      await tester.tap(
        _row(SidebarKeys.machine('workstation')),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pin'));
      await tester.pumpAndSettle();
      expect(
        _row(SidebarKeys.machine('workstation'), section: 'pinned'),
        findsOneWidget,
      );
      await tearDownShell(tester);
    }, variant: _linux);

    testWidgets('collapses to icons and resizes within bounds', (tester) async {
      final h = await pumpShell(tester);
      await tester.drag(
        find.byKey(const ValueKey('sidebar-resize')),
        const Offset(400, 0),
      );
      await tester.pump();
      expect(h.shell.sidebarWidth, 420);
      await tester.tap(find.byKey(const ValueKey('sidebar-collapse')));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('shell-sidebar-collapsed')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('shell-sidebar')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('sidebar-expand')));
      await tester.pump();
      expect(find.byKey(const ValueKey('shell-sidebar')), findsOneWidget);
      await tearDownShell(tester);
    }, variant: _linux);
  });

  group('main area', () {
    testWidgets('a sidebar row opens in the main area; Home shows the '
        'dashboard', (tester) async {
      final h = await pumpShell(tester);
      await tester.tap(_row(SidebarKeys.tmuxSession('workstation', 'build')));
      await settleShell(tester);
      final session = h.workspace.sessions.single;
      expect(session.host.id, 'workstation#tmux:build');
      expect(_home(tester).terminalVisible, isTrue);
      expect(find.byType(ShellTabStrip), findsOneWidget);
      expect(_tab(_view(session.host.id)), findsOneWidget);
      // The row says it is open in the app.
      expect(
        find.byKey(
          ValueKey(
            'sidebar-open-${SidebarKeys.tmuxSession('workstation', 'build')}',
          ),
        ),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('terminal-header-back')));
      await tester.pump();
      expect(_home(tester).terminalVisible, isFalse);
      expect(
        find.byKey(const ValueKey('dashboard-session-workstation#tmux:build')),
        findsOneWidget,
      );
      // The dashboard's tile brings the terminal back.
      await tester.tap(
        find.byKey(const ValueKey('dashboard-session-workstation#tmux:build')),
      );
      await tester.pump();
      expect(_home(tester).terminalVisible, isTrue);
      await tearDownShell(tester);
    }, variant: _linux);

    testWidgets('splits by keyboard, moves focus with Alt+arrows, and the '
        'layout comes back after a restart', (tester) async {
      final store = InMemoryDesktopShellStore();
      final h = await pumpShell(tester, store: store);
      final a = await h.open(
        tester,
        workstation,
        const ConnectTarget.tmux('main'),
      );
      final b = await h.open(tester, buildBox, const ConnectTarget.tmux('ci'));
      h.shell.showHome = false;
      await settleShell(tester);
      expect(h.workspace.activeSession, b);
      expect(h.shell.layout.value.panes.single.view, _view(b.host.id));

      // Ctrl+Shift+\ splits right with the other session.
      await _keys(tester, [
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.shiftLeft,
      ], LogicalKeyboardKey.backslash);
      await settleShell(tester);
      final layout = h.shell.layout.value;
      expect(layout.panes.map((pane) => pane.view), [
        _view(b.host.id),
        _view(a.host.id),
      ]);
      expect(layout.focusedView, _view(a.host.id));
      expect(h.workspace.activeSession, a);
      expect(find.byKey(const ValueKey('shell-pane-p1')), findsOneWidget);
      expect(find.byKey(const ValueKey('shell-pane-p2')), findsOneWidget);

      // Alt+Left moves to the left pane; Alt+Left again has nowhere to
      // go and stays with the shell.
      await _keys(tester, [
        LogicalKeyboardKey.altLeft,
      ], LogicalKeyboardKey.arrowLeft);
      expect(h.workspace.activeSession, b);
      expect(h.shell.layout.value.focusedPaneId, 'p1');

      // A click in a pane focuses it.
      await tester.tap(find.byKey(const ValueKey('shell-pane-p2')));
      await tester.pump();
      expect(h.workspace.activeSession, a);

      // Locking closes every session at once: the panes are kept for
      // the sessions that come back.
      unawaited(h.workspace.closeAll());
      await settleShell(tester);
      expect(h.workspace.sessions, isEmpty);
      await tester.pump(const Duration(milliseconds: 50));
      final saved = store.state!['layout'];
      expect(ShellLayout.fromJson(saved).panes.length, 2);
      await tearDownShell(tester);

      // Next run: the same sessions come back, and so do the panes.
      final again = await pumpShell(
        tester,
        store: store,
        before: (h) {
          h.workspace
            ..open(
              const ConnectTarget.tmux('main').apply(workstation),
              target: const ConnectTarget.tmux('main'),
            )
            ..open(
              const ConnectTarget.tmux('ci').apply(buildBox),
              target: const ConnectTarget.tmux('ci'),
            );
        },
      );
      await settleShell(tester);
      final restored = again.shell.layout.value;
      expect(restored.panes.map((pane) => pane.view), [
        _view(b.host.id),
        _view(a.host.id),
      ]);
      expect(again.workspace.activeSession?.host.id, a.host.id);
      expect(find.byKey(const ValueKey('shell-pane-p2')), findsOneWidget);
      await tearDownShell(tester);
    }, variant: _linux);

    testWidgets('dragging a tab onto a pane edge splits there', (tester) async {
      final h = await pumpShell(tester);
      final a = await h.open(
        tester,
        workstation,
        const ConnectTarget.tmux('main'),
      );
      final b = await h.open(tester, buildBox, const ConnectTarget.tmux('ci'));
      h.shell.showHome = false;
      await settleShell(tester);
      final pane = find.byKey(const ValueKey('shell-pane-p1'));
      final target = tester.getBottomRight(pane) - const Offset(1, 200);
      final gesture = await tester.startGesture(
        tester.getCenter(_tab(_view(a.host.id))),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(0, 40));
      await tester.pump();
      await gesture.moveTo(target);
      await tester.pump();
      expect(
        find.byKey(const ValueKey('drop-highlight-right')),
        findsOneWidget,
      );
      await gesture.up();
      await settleShell(tester);
      expect(h.shell.layout.value.panes.map((pane) => pane.view), [
        _view(b.host.id),
        _view(a.host.id),
      ]);

      // The tab menu splits down too; four panes at most.
      await tester.tap(_tab(_view(b.host.id)), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.text('Split right'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(h.workspace.sessions, [a]);
      expect(h.shell.layout.value.panes.single.view, _view(a.host.id));
      await tearDownShell(tester);
    }, variant: _linux);
  });

  group('unread', () {
    testWidgets('output in a hidden session is unread until viewed; '
        'Ctrl+Shift+U jumps to it; markers survive a restart', (tester) async {
      final h = await pumpShell(tester);
      final a = await h.open(
        tester,
        workstation,
        const ConnectTarget.tmux('main'),
      );
      final b = await h.open(tester, buildBox, const ConnectTarget.tmux('ci'));
      h.shell.showHome = false;
      await settleShell(tester);
      expect(h.workspace.activeSession, b);
      // Past the reattach redraw.
      h.now = h.now.add(const Duration(seconds: 10));

      h.terminals.session(a.host.id)!.print('build finished\r\n');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      final key = SidebarKeys.tmuxSession('workstation', 'main');
      expect(h.shell.unread.isUnread(key), isTrue);
      expect(
        find.descendant(
          of: _tab(_view(a.host.id)),
          matching: find.byKey(const ValueKey('unread-dot')),
        ),
        findsOneWidget,
      );
      // Rolled up to the machine row.
      expect(
        find.descendant(
          of: _row(SidebarKeys.machine('workstation')),
          matching: find.byKey(const ValueKey('unread-dot')),
        ),
        findsOneWidget,
      );
      // The visible session's own output is read as it arrives.
      h.terminals.session(b.host.id)!.print('more\r\n');
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        h.shell.unread.isUnread(SidebarKeys.tmuxSession('build-box', 'ci')),
        isFalse,
      );

      await _keys(tester, [
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.shiftLeft,
      ], LogicalKeyboardKey.keyU);
      await settleShell(tester);
      expect(h.workspace.activeSession, a);
      expect(h.shell.unread.isUnread(key), isFalse);

      // Mark as unread from the menu, and it is saved.
      h.shell.markUnread(key);
      await tester.pump(const Duration(milliseconds: 50));
      final saved = h.store.state!['unread']! as Map;
      expect(saved['manual'], contains(key));
      await tearDownShell(tester);
    }, variant: _linux);

    testWidgets('an agent finishing marks its row; its parents roll it up', (
      tester,
    ) async {
      final h = await pumpShell(tester);
      final runner = h.runners['workstation']!;
      // Infrastructure's "main" agent finishes.
      runner.agents = runner.agents.replaceFirst(
        '"agent_status":"working"',
        '"agent_status":"done"',
      );
      await h.boards['workstation']!.refresh();
      await settleShell(tester);
      final main = SidebarKeys.herdrTab('workstation', 'w1', 'w1:t1');
      expect(h.shell.unread.isUnread(main), isTrue);
      final infra = SidebarKeys.herdrWorkspace('workstation', 'w1');
      expect(
        find.descendant(
          of: _row(infra),
          matching: find.byKey(const ValueKey('unread-dot')),
        ),
        findsOneWidget,
      );
      // Mark as read from the menu.
      await tester.tap(_row(infra), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mark as read'));
      await tester.pumpAndSettle();
      expect(h.shell.unread.isUnread(main), isFalse);
      await tearDownShell(tester);
    }, variant: _linux);
  });

  group('keyboard', () {
    testWidgets('the new shortcuts are in the registry and the help sheet', (
      tester,
    ) async {
      await pumpShell(tester);
      await _keys(tester, [
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.shiftLeft,
      ], LogicalKeyboardKey.slash);
      await tester.pumpAndSettle();
      expect(find.text('Split right'), findsOneWidget);
      expect(find.text('Ctrl+Shift+\\'), findsOneWidget);
      expect(find.text('Split down'), findsOneWidget);
      expect(find.text('Ctrl+Shift+-'), findsOneWidget);
      expect(find.text('Move between splits'), findsOneWidget);
      expect(find.text('Next unread'), findsOneWidget);
      await tearDownShell(tester);
    }, variant: _linux);

    testWidgets('Ctrl+Tab from the dashboard shows the terminal', (
      tester,
    ) async {
      final h = await pumpShell(tester);
      await h.open(tester, workstation, const ConnectTarget.tmux('main'));
      h.shell.showHome = true;
      await tester.pump();
      expect(_home(tester).terminalVisible, isFalse);
      await _keys(tester, [
        LogicalKeyboardKey.controlLeft,
      ], LogicalKeyboardKey.tab);
      expect(_home(tester).terminalVisible, isTrue);
      await tearDownShell(tester);
    }, variant: _linux);
  });

  testWidgets('the tab badge reads the agent state', (tester) async {
    final h = await pumpShell(tester);
    final session = await h.open(
      tester,
      workstation,
      const ConnectTarget.herdr(workspaceId: 'w1', label: 'Infrastructure'),
    );
    h.shell.showHome = false;
    await settleShell(tester);
    final badge = _home(tester).embedding.badgeFor!(sessionViewId(session));
    expect(badge.dot, SidebarDot.needsYou);
    await tearDownShell(tester);
  }, variant: _linux);

  testWidgets('Chat View opens as a tab and splits next to its terminal', (
    tester,
  ) async {
    final h = await pumpShell(tester);
    final session = await h.open(
      tester,
      workstation,
      const ConnectTarget.tmux('main'),
    );
    h.shell.showHome = false;
    await settleShell(tester);
    var toTerminal = 0;
    unawaited(
      openChatView(
        context: tester.element(find.byType(DesktopHome)),
        attention: h.attention,
        host: session.host,
        agent: const AgentInfo(
          id: 's1',
          name: 'todo-api',
          state: AgentAttentionState.needsInput,
          kind: 'claude',
        ),
        onOpenTerminal: () => toTerminal += 1,
      ),
    );
    await settleShell(tester);
    final chat = 'chat:${session.host.id}:s1';
    expect(_tab(chat), findsOneWidget);
    expect(find.byType(ChatViewPage), findsOneWidget);
    // No route was pushed: the chat lives in the shell's pane.
    expect(find.byType(DesktopHome), findsOneWidget);
    expect(h.shell.layout.value.focusedView, chat);

    await tester.tap(_tab(chat), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Split right'));
    await settleShell(tester);
    expect(h.shell.layout.value.panes.map((pane) => pane.view), [
      _view(session.host.id),
      chat,
    ]);
    // The chat's Terminal button hands over to the terminal.
    await tester.tap(find.text('Terminal'));
    await tester.pump();
    expect(toTerminal, 1);

    // Closing the tab closes its pane, and pops nothing: the shell is
    // the home route, not a terminal route under Chat View.
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    await tester.tap(find.byKey(ValueKey('shell-tab-close-$chat')));
    await settleShell(tester);
    expect(_tab(chat), findsNothing);
    expect(h.shell.layout.value.panes.single.view, _view(session.host.id));
    expect(navigator.canPop(), isFalse);
    expect(find.byType(DesktopHome), findsOneWidget);
    expect(h.workspace.sessions, [session]);
    await tearDownShell(tester);
  }, variant: _linux);

  testWidgets('the right panel toggles the Agents screen and the preview', (
    tester,
  ) async {
    final h = await pumpShell(tester);
    await tester.tap(find.byKey(const ValueKey('shell-toggle-agents')));
    await tester.pump();
    expect(h.shell.rightPanel, ShellRightPanel.agents);
    final panel = find.byKey(const ValueKey('shell-agents-panel'));
    expect(panel, findsOneWidget);
    // The same Agents screen as the phone's, with its Usage tab.
    expect(
      find.descendant(of: panel, matching: find.text('Usage')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('shell-toggle-preview')));
    await tester.pump();
    expect(panel, findsNothing);
    expect(find.text('Open a session to preview its web app.'), findsOneWidget);
    await tester.tap(find.byTooltip('Close the panel'));
    await tester.pump();
    expect(h.shell.rightPanel, ShellRightPanel.none);
    // Saved with the rest of the shell.
    await tester.pump(const Duration(milliseconds: 50));
    expect(h.store.state!['rightPanel'], 'none');
    await tearDownShell(tester);
  }, variant: _linux);

  testWidgets('the terminal shortcuts keep working inside the shell', (
    tester,
  ) async {
    final h = await pumpShell(tester);
    final a = await h.open(
      tester,
      workstation,
      const ConnectTarget.tmux('main'),
    );
    final b = await h.open(tester, buildBox, const ConnectTarget.tmux('ci'));
    h.shell.showHome = false;
    await settleShell(tester);
    expect(h.workspace.activeSession, b);

    // Ctrl+Tab and Alt+1 switch sessions in the focused pane.
    await _keys(tester, [
      LogicalKeyboardKey.controlLeft,
    ], LogicalKeyboardKey.tab);
    expect(h.workspace.activeSession, a);
    await _keys(tester, [
      LogicalKeyboardKey.altLeft,
    ], LogicalKeyboardKey.digit2);
    expect(h.workspace.activeSession, b);
    expect(h.shell.layout.value.focusedView, _view(b.host.id));

    // Zoom.
    final size = h.theme.terminalFontSize;
    await _keys(tester, [
      LogicalKeyboardKey.controlLeft,
    ], LogicalKeyboardKey.equal);
    await tester.pump();
    expect(h.theme.terminalFontSize, greaterThan(size));

    // F11 hides the sidebar with the terminal's chrome.
    await _keys(tester, const [], LogicalKeyboardKey.f11);
    expect(find.byKey(const ValueKey('shell-sidebar')), findsNothing);
    await _keys(tester, const [], LogicalKeyboardKey.f11);
    expect(find.byKey(const ValueKey('shell-sidebar')), findsOneWidget);

    // The switcher keys open the command palette once (the shell's, not
    // the page's quick switcher too).
    await _keys(tester, [
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.shiftLeft,
    ], LogicalKeyboardKey.keyK);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('command-palette')), findsOneWidget);
    expect(find.byKey(const ValueKey('quick-switcher')), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    // Ctrl+Shift+W closes the focused session (tmux detaches, no ask);
    // the last one leaves the dashboard.
    await _keys(tester, [
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.shiftLeft,
    ], LogicalKeyboardKey.keyW);
    await settleShell(tester);
    expect(h.workspace.sessions, [a]);
    await _keys(tester, [
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.shiftLeft,
    ], LogicalKeyboardKey.keyW);
    await settleShell(tester);
    expect(h.workspace.sessions, isEmpty);
    expect(_home(tester).terminalVisible, isFalse);
    expect(find.byType(DesktopHome), findsOneWidget);
    await tearDownShell(tester);
  }, variant: _linux);

  testWidgets(
    'the dashboard: previews and workspaces, Needs you and usage in the sidebar',
    (tester) async {
      final h = await pumpShell(
        tester,
        usage: (context, {required compact}) =>
            Text(compact ? 'Usage 42%' : 'Usage 42% today'),
      );
      // Needs you and usage live in the sidebar only, not in the main pane.
      expect(find.text('Usage 42% today'), findsNothing);
      expect(find.byKey(const ValueKey('dashboard-usage-slot')), findsNothing);
      expect(
        find.byKey(const ValueKey('dashboard-needs-you-empty')),
        findsNothing,
      );
      // The usage feature fills the sidebar's slot.
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('sidebar-usage-slot')),
          matching: find.text('Usage 42%'),
        ),
        findsOneWidget,
      );
      // Other workspaces per machine; a tile opens its session.
      final build = find.byKey(
        ValueKey(
          'dashboard-other-${SidebarKeys.tmuxSession('workstation', 'build')}',
        ),
      );
      await tester.ensureVisible(build);
      await tester.tap(build);
      await settleShell(tester);
      expect(h.workspace.sessions.single.host.id, 'workstation#tmux:build');
      expect(_home(tester).terminalVisible, isTrue);
      // Back home, the session is a live preview and no longer "other".
      h.shell.showHome = true;
      await tester.pump();
      expect(
        find.byKey(const ValueKey('dashboard-session-workstation#tmux:build')),
        findsOneWidget,
      );
      expect(build, findsNothing);
      await tearDownShell(tester);
    },
    variant: _linux,
  );

  testWidgets('the app usage shows in the sidebar only', (tester) async {
    final usage = UsageController(
      source: FakeUsageSource(const [], const {}),
      preferences: MemoryUsagePreferencesStore(),
      observeLifecycle: false,
    );
    addTearDown(usage.dispose);
    final h = await pumpShell(tester, before: (h) => h.usageController = usage);
    UsageSummaryView inSlot(String key) => tester.widget<UsageSummaryView>(
      find.descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.byType(UsageSummaryView),
      ),
    );
    expect(find.byKey(const ValueKey('dashboard-usage-slot')), findsNothing);
    expect(inSlot('sidebar-usage-slot').layout, UsageSummaryLayout.compact);
    // Not the phone's home bar.
    expect(find.byType(UsageHomeBar), findsNothing);
    // A tap opens the explorer in the main area, with room for it.
    inSlot('sidebar-usage-slot').onTap!();
    await tester.pump();
    expect(h.shell.showUsage, isTrue);
    expect(find.byType(UsageExplorerView), findsOneWidget);
    expect(find.byKey(const ValueKey('usage-explorer-close')), findsOneWidget);
    // Going home (or to a session) leaves it.
    h.shell.showHome = true;
    await tester.pump();
    expect(h.shell.showUsage, isFalse);
    expect(find.byType(UsageExplorerView), findsNothing);
    // The right panel's breakdown opens it there too.
    h.shell.rightPanel = ShellRightPanel.usage;
    await tester.pump();
    expect(find.byType(UsageBreakdown), findsOneWidget);
    await tearDownShell(tester);
  }, variant: _linux);

  testWidgets('the dashboard shows the privacy notice until dismissed', (
    tester,
  ) async {
    final telemetry = Telemetry(
      config: TelemetryConfig.disabled,
      store: MemoryTelemetryPreferencesStore(),
    );
    await telemetry.start();
    final previous = Telemetry.instance;
    Telemetry.instance = telemetry;
    addTearDown(() {
      Telemetry.instance = previous;
      telemetry.dispose();
    });
    await pumpShell(tester);
    final notice = find.descendant(
      of: find.byKey(const ValueKey('shell-dashboard')),
      matching: find.byKey(const ValueKey('privacy-notice')),
    );
    expect(notice, findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('privacy-notice-ok')));
    await tester.pump();
    expect(notice, findsNothing);
    await tearDownShell(tester);
  }, variant: _linux);

  testWidgets("an unreachable machine reads Can't reach, like the phone", (
    tester,
  ) async {
    await pumpShell(
      tester,
      before: (h) => h.runners['build-box']!.error = const SocketException(
        'Connection timed out',
        osError: OSError('No route to host', 113),
      ),
    );
    final row = _row(SidebarKeys.machine('build-box'));
    expect(
      find.descendant(of: row, matching: find.text("Can't reach build-box")),
      findsOneWidget,
    );
    // The dashboard's notice is the phone's, with its Retry.
    final notice = find.byKey(const ValueKey('dashboard-notice-build-box'));
    await tester.ensureVisible(notice);
    expect(
      find.descendant(of: notice, matching: find.text("Can't reach build-box")),
      findsOneWidget,
    );
    expect(
      find.descendant(of: notice, matching: find.text('Retry')),
      findsOneWidget,
    );
    await tearDownShell(tester);
  }, variant: _linux);
}
