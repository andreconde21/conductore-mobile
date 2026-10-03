import 'package:conduit/features/desktop_shell/domain/project_layout.dart';
import 'package:conduit/features/desktop_shell/domain/sidebar_tree.dart';
import 'package:conduit/features/desktop_shell/presentation/project_layout_controller.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'shell_harness.dart';

final _linux = TargetPlatformVariant.only(TargetPlatform.linux);

void main() {
  late ProjectLayoutController layout;

  Future<ShellHarness> pump(WidgetTester tester) async {
    final h = await pumpShell(
      tester,
      before: (h) => layout = ProjectLayoutController.instance =
          ProjectLayoutController(theme: h.theme, clock: () => h.now),
    );
    addTearDown(() {
      ProjectLayoutController.instance = null;
      layout.dispose();
    });
    await tester.tap(find.byKey(const ValueKey('sidebar-tab-projects')));
    await tester.pump();
    return h;
  }

  testWidgets("the Projects tab is sheprd's: header, move to a project, "
      'collapsed count, compact view, active filter', (tester) async {
    final h = await pump(tester);
    expect(find.byKey(const ValueKey('project-filter-toggle')), findsOneWidget);
    expect(find.text('all agents'), findsOneWidget);
    expect(find.text('detailed'), findsOneWidget);
    // Infrastructure needs you: the counter says so.
    expect(find.byKey(const ValueKey('project-needs-you')), findsOneWidget);

    // tmux "main" is its own project (nothing named any yet), open.
    final mainRow = find.byKey(
      ValueKey(
        'project-member-main-${SidebarKeys.tmuxSession('workstation', 'main')}',
      ),
    );
    expect(mainRow, findsOneWidget);

    // Right-click → Move to project… → a new project.
    await tester.tap(mainRow, buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move to project…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('move-to-new')), 'Ops');
    await tester.tap(find.byKey(const ValueKey('move-to-create')));
    await tester.pumpAndSettle();
    expect(h.theme.projectPrefs.layout!.byName('Ops')!.members, [
      'workstation/main',
    ]);
    final ops = find.byKey(const ValueKey('project-header-ops'));
    expect(ops, findsOneWidget);
    expect(
      find.byKey(
        ValueKey(
          'project-member-ops-${SidebarKeys.tmuxSession('workstation', 'main')}',
        ),
      ),
      findsOneWidget,
    );

    // Collapsed: the worst state and how many rows.
    await tester.tap(ops);
    await tester.pumpAndSettle();
    expect(h.theme.projectPrefs.collapsed['ops'], isTrue);
    final count = find.byKey(const ValueKey('project-count-ops'));
    expect(tester.widget<Text>(count).data, '1');

    // Move to Other from the menu.
    await tester.tap(ops);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(
        ValueKey(
          'project-member-ops-${SidebarKeys.tmuxSession('workstation', 'main')}',
        ),
      ),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move to Other'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('project-header-\u0000other')), findsOne);
    expect(h.theme.projectPrefs.layout!.ungrouped, ['workstation/main']);

    // Compact and active toggles are remembered in the synced prefs.
    await tester.tap(find.byKey(const ValueKey('project-view-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('compact'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('project-filter-toggle')));
    await tester.pumpAndSettle();
    expect(h.theme.projectPrefs.compact, isTrue);
    expect(h.theme.projectPrefs.activeOnly, isTrue);
    // Nothing in Other is active: it goes away; Infrastructure stays.
    expect(
      find.byKey(const ValueKey('project-header-\u0000other')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('project-header-infrastructure')),
      findsOneWidget,
    );
    await tearDownShell(tester);
  }, variant: _linux);

  testWidgets("a machine's sidebar.toml groups the tab until edited", (
    tester,
  ) async {
    final h = await pump(tester);
    layout.applyReply(
      workstation,
      '{"ok":true,"found":true,"layout":{"group":[{"name":"Work","pinned":true,'
      '"match":["infra","calendar"],"members":["local/build"]}]}}',
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('project-header-work')), findsOneWidget);
    // Pinned: the star.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('project-header-work')),
        matching: find.byIcon(Icons.star_rounded),
      ),
      findsOneWidget,
    );
    // Everything else is in Other.
    expect(find.byKey(const ValueKey('project-header-main')), findsNothing);
    expect(
      find.byKey(const ValueKey('project-header-\u0000other')),
      findsOneWidget,
    );
    expect(h.theme.projectPrefs.layout, isNull);
    expect(layout.layout.groups.single, isA<ProjectDef>());
    await tearDownShell(tester);
  }, variant: _linux);
}
