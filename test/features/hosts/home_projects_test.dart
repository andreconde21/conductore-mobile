import 'package:conduit/features/desktop_shell/domain/sidebar_tree.dart';
import 'package:conduit/features/desktop_shell/presentation/project_layout_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../desktop_shell/shell_harness.dart';

void main() {
  testWidgets('the phone home groups by project: toggle, long-press to '
      'move, collapse with a count', (tester) async {
    late ProjectLayoutController layout;
    final h = await pumpShell(
      tester,
      size: const Size(390, 844),
      shellMode: false,
      before: (h) => layout = ProjectLayoutController.instance =
          ProjectLayoutController(theme: h.theme, clock: () => h.now),
    );
    addTearDown(() {
      ProjectLayoutController.instance = null;
      layout.dispose();
    });
    final toggle = find.byKey(const ValueKey('home-group-by-toggle'));
    await tester.scrollUntilVisible(toggle, 200);
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await settleShell(tester);
    expect(h.theme.projectPrefs.groupByProject, isTrue);
    expect(find.byKey(const ValueKey('home-projects')), findsOneWidget);
    expect(find.text('PROJECTS'), findsOneWidget);

    // tmux "main" on workstation: its own project for now.
    final main = find.byKey(
      ValueKey(
        'home-project-row-${SidebarKeys.tmuxSession('workstation', 'main')}',
      ),
    );
    await tester.scrollUntilVisible(main, 200);
    await tester.ensureVisible(main);
    await tester.pumpAndSettle();
    await tester.longPress(main);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('project-entry-move')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('move-to-new')), 'Ops');
    await tester.tap(find.byKey(const ValueKey('move-to-create')));
    await settleShell(tester);
    expect(h.theme.projectPrefs.layout!.byName('Ops')!.members, [
      'workstation/main',
    ]);

    final ops = find.byKey(const ValueKey('project-header-ops'));
    await tester.scrollUntilVisible(ops, 200);
    await tester.ensureVisible(ops);
    await tester.pumpAndSettle();
    await tester.tap(ops);
    await settleShell(tester);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('project-count-ops'))).data,
      '1',
    );
    expect(main, findsNothing);

    // Back to machines.
    final back = find.byKey(const ValueKey('home-group-by-toggle'));
    await tester.scrollUntilVisible(back, -200);
    await tester.ensureVisible(back);
    await tester.pumpAndSettle();
    await tester.tap(back);
    await settleShell(tester);
    expect(find.byKey(const ValueKey('home-projects')), findsNothing);
    await tearDownShell(tester);
  });
}
