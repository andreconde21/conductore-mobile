import 'package:conduit/core/connection_problem.dart';
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
    // The header's ⋯ button sits at its right edge and is enabled.
    final menu = find.byKey(const ValueKey('home-project-menu-ops'));
    expect(menu, findsOneWidget);
    expect(
      tester.getRect(ops).right - tester.getRect(menu).right,
      lessThanOrEqualTo(4),
    );
    expect(tester.widget<IconButton>(menu).onPressed, isNotNull);
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

  testWidgets('in project mode an unreachable machine keeps its notice as '
      'one line, with Retry and the details', (tester) async {
    late ProjectLayoutController layout;
    final h = await pumpShell(
      tester,
      size: const Size(390, 844),
      shellMode: false,
      before: (h) {
        h.runners['build-box']!.error = const ConnectionFailure(
          'Could not reach build-box.',
          'SocketException: Connection timed out, errno = 110',
          kind: ConnectionProblemKind.unreachable,
        );
        layout = ProjectLayoutController.instance = ProjectLayoutController(
          theme: h.theme,
          clock: () => h.now,
        );
      },
    );
    addTearDown(() {
      ProjectLayoutController.instance = null;
      layout.dispose();
    });
    await layout.setGroupByProject(true);
    await h.boards['build-box']?.refresh();
    await tester.pumpWidget(h.page(shellMode: false));
    await settleShell(tester);
    final line = find.byKey(const ValueKey('home-notice-line-build-box'));
    await tester.scrollUntilVisible(line, 200);
    expect(line, findsOneWidget);
    expect(
      find.descendant(of: line, matching: find.textContaining("Can't reach")),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('home-notice-line-workstation')),
      findsNothing,
    );
    // Tap: the whole notice with its details.
    await tester.tap(
      find.descendant(of: line, matching: find.byType(Text)).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('home-board-notice-details')));
    await tester.pump();
    expect(find.textContaining('errno = 110'), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    // Retry lists again: once reachable, the line goes away.
    h.runners['build-box']!.error = null;
    await tester.tap(
      find.descendant(
        of: line,
        matching: find.widgetWithText(TextButton, 'Retry'),
      ),
    );
    await settleShell(tester);
    expect(line, findsNothing);
    await tearDownShell(tester);
  });
}
