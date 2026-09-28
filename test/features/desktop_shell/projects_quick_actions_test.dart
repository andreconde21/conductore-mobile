import 'package:conduit/features/desktop_shell/domain/sidebar_tree.dart';
import 'package:conduit/features/desktop_shell/presentation/desktop_shell_controller.dart';
import 'package:conduit/features/quick_actions/domain/quick_action.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'shell_harness.dart';

final _linux = TargetPlatformVariant.only(TargetPlatform.linux);

void main() {
  testWidgets('the Projects tab lists projects; the Machines tab is '
      'unchanged', (tester) async {
    final h = await pumpShell(tester);
    expect(find.byKey(const ValueKey('shell-sidebar')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('sidebar-tab-projects')));
    await tester.pump();
    expect(h.shell.sidebarTab, ShellSidebarTab.projects);
    expect(find.byKey(const ValueKey('shell-project-sidebar')), findsOneWidget);
    // tmux "main" on workstation is a project of its own (no agents).
    final main = find.byKey(const ValueKey('project-row-main'));
    expect(main, findsOneWidget);
    await tester.tap(main);
    await tester.pump();
    final member = find.byKey(
      ValueKey(
        'project-member-main-${SidebarKeys.tmuxSession('workstation', 'main')}',
      ),
    );
    expect(member, findsOneWidget);
    await tester.tap(member);
    await settleShell(tester);
    expect(h.workspace.sessions.single.host.id, 'workstation#tmux:main');

    // Right-click on a project: its menu with Add action.
    await tester.tap(main, buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('Add action…'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('sidebar-tab-machines')));
    await tester.pump();
    expect(find.byKey(const ValueKey('shell-sidebar')), findsOneWidget);
    // The tab is remembered.
    await tester.pump(const Duration(milliseconds: 50));
    expect(h.store.state!['sidebarTab'], 'machines');
    await tearDownShell(tester);
  }, variant: _linux);

  testWidgets('a personal quick action shows in the toolbar, runs from its '
      'button and its keys', (tester) async {
    final h = await pumpShell(tester);
    await h.theme.setQuickActions(const [
      QuickAction(
        id: 'hello',
        label: 'Say hello',
        command: 'echo hello',
        terminalName: 'greeter',
        keybinding: 'ctrl+alt+h',
      ),
    ]);
    await h.open(tester, workstation, const ConnectTarget.tmux('main'));
    h.shell.showHome = false;
    await settleShell(tester);
    final button = find.byKey(const ValueKey('quick-action-hello'));
    expect(button, findsOneWidget);
    await tester.tap(button);
    await settleShell(tester);
    final greeter = h.workspace.sessions
        .where((session) => session.customTitle == 'greeter')
        .toList();
    expect(greeter, hasLength(1));
    expect(h.workspace.sessions, hasLength(2));

    // Ctrl+Alt+H in the focused project runs it again, in the same
    // terminal (it is named greeter now).
    h.workspace.activate(h.workspace.sessions.first);
    await settleShell(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settleShell(tester);
    expect(h.workspace.sessions, hasLength(2));
    await tearDownShell(tester);
  }, variant: _linux);

  testWidgets('phones: no project tab, no quick action buttons', (
    tester,
  ) async {
    final h = await pumpShell(tester, size: const Size(390, 844));
    await h.theme.setQuickActions(const [
      QuickAction(id: 'hello', label: 'Say hello', command: 'echo hello'),
    ]);
    await tester.pump();
    expect(find.byKey(const ValueKey('sidebar-tab-projects')), findsNothing);
    expect(find.byKey(const ValueKey('quick-action-hello')), findsNothing);
    await tearDownShell(tester);
  });
}
