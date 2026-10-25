import 'dart:async';
import 'dart:convert';

import 'package:conduit/core/connection_problem.dart';
import 'package:conduit/features/desktop_shell/domain/project_layout.dart';
import 'package:conduit/features/desktop_shell/domain/sidebar_tree.dart';
import 'package:conduit/features/desktop_shell/presentation/project_layout_controller.dart';
import 'package:conduit/features/hosts/domain/home_preferences.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../desktop_shell/shell_harness.dart';

/// The home list's scrollable (the search field has one of its own).
final homeScrollable = find
    .descendant(
      of: find.byKey(const ValueKey('home-scroll')),
      matching: find.byType(Scrollable),
    )
    .first;

void main() {
  testWidgets('the top-bar switch goes to Projects and back, remembered; '
      'long-press to move, collapse with a count', (tester) async {
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
    // No project layout: Open / Closed, and the old toggle is gone.
    expect(find.text('SESSIONS'), findsOneWidget);
    expect(find.byKey(const ValueKey('home-projects')), findsNothing);
    expect(find.byKey(const ValueKey('home-group-by-toggle')), findsNothing);
    final toggle = find.byKey(const ValueKey('home-mode-projects'));
    await tester.tap(toggle);
    await settleShell(tester);
    expect(h.homePreferences.stored.mode, HomeMode.projects);
    expect(find.byKey(const ValueKey('home-projects')), findsOneWidget);
    expect(find.text('PROJECTS'), findsOneWidget);
    // No separate sessions section, and one layout only.
    expect(find.text('SESSIONS'), findsNothing);
    expect(find.text('OTHER WORKSPACES'), findsNothing);
    expect(find.byKey(const ValueKey('workspaces-view-toggle')), findsNothing);

    // tmux "main" on workstation: its own project for now.
    final main = find.byKey(
      ValueKey(
        'home-project-row-${SidebarKeys.tmuxSession('workstation', 'main')}',
      ),
    );
    await tester.scrollUntilVisible(main, 200, scrollable: homeScrollable);
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
    await tester.scrollUntilVisible(ops, 200, scrollable: homeScrollable);
    await tester.ensureVisible(ops);
    await tester.pumpAndSettle();
    // The project is a box with its header inside.
    expect(
      find.ancestor(
        of: ops,
        matching: find.byKey(const ValueKey('home-project-box-ops')),
      ),
      findsOneWidget,
    );
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

    // A new page (app restart) comes back in Projects mode.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(h.page(shellMode: false));
    await settleShell(tester);
    expect(find.byKey(const ValueKey('home-projects')), findsOneWidget);

    // Back to Open / Closed.
    final back = find.byKey(const ValueKey('home-mode-open'));
    await tester.scrollUntilVisible(back, -200, scrollable: homeScrollable);
    await tester.tap(back);
    await settleShell(tester);
    expect(h.homePreferences.stored.mode, HomeMode.openClosed);
    expect(find.byKey(const ValueKey('home-projects')), findsNothing);
    expect(find.text('SESSIONS'), findsOneWidget);
    await tearDownShell(tester);
  });

  // André's phone is 1080 px at 2.625 (411 dp); also a small and a large
  // phone, his font scale and the default, with and without the needs-you
  // counter (CON-120). Not 360 dp at ×1.3: the test font's square glyphs
  // make "Projects | Open" wider than the row there (real fonts fit).
  for (final width in [360.0, 411.43, 480.0]) {
    for (final scale in [1.0, 1.3]) {
      if (width == 360 && scale != 1) continue;
      for (final needsYou in [true, false]) {
        testWidgets('at $width dp, text ×$scale, needs-you '
            '${needsYou ? 'shown' : 'hidden'}: the view bar\'s ⋮ sits at the '
            'right edge under the header\'s +, and the search field and '
            'the switch are one height on one line', (tester) async {
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          late ProjectLayoutController layout;
          await pumpShell(
            tester,
            size: Size(width, 914),
            pixelRatio: 2.625,
            shellMode: false,
            before: (h) {
              layout = ProjectLayoutController.instance =
                  ProjectLayoutController(theme: h.theme, clock: () => h.now);
              h.homePreferences.stored = const HomePreferences(
                mode: HomeMode.projects,
              );
              if (!needsYou) {
                final runner = h.runners['workstation']!;
                runner
                  ..agents = runner.agents.replaceAll('blocked', 'working')
                  ..workspaces = runner.workspaces.replaceAll(
                    'blocked',
                    'working',
                  )
                  ..tabs = runner.tabs.replaceAll('blocked', 'working');
              }
            },
          );
          addTearDown(() {
            ProjectLayoutController.instance = null;
            layout.dispose();
          });
          expect(
            find.byKey(const ValueKey('project-needs-you')),
            needsYou ? findsOneWidget : findsNothing,
          );
          final viewMenu = find.byIcon(Icons.more_vert_rounded);
          final add = find.byIcon(Icons.add_rounded);
          expect(add, findsOneWidget);
          expect(
            tester.getCenter(viewMenu).dx,
            moreOrLessEquals(tester.getCenter(add).dx, epsilon: 1),
          );
          final box = find.byWidgetPredicate(
            (widget) =>
                widget.key is ValueKey<String> &&
                (widget.key! as ValueKey<String>).value.startsWith(
                  'home-project-box-',
                ),
          );
          expect(
            tester.getRect(box.first).right - tester.getRect(viewMenu).right,
            inInclusiveRange(0, 12),
          );

          final field = tester.getRect(
            find.byKey(const ValueKey('home-workspace-search')),
          );
          final modes = tester.getRect(
            find.byKey(const ValueKey('home-mode-switch')),
          );
          expect(modes.height, moreOrLessEquals(field.height, epsilon: 0.5));
          expect(modes.top, moreOrLessEquals(field.top, epsilon: 0.5));
          // The field's border is drawn to its full height.
          expect(
            tester
                .getRect(
                  find.descendant(
                    of: find.byKey(const ValueKey('home-workspace-search')),
                    matching: find.byType(InputDecorator),
                  ),
                )
                .height,
            moreOrLessEquals(field.height, epsilon: 0.5),
          );
          await tearDownShell(tester);
        });
      }
    }
  }

  testWidgets('who had "group by project" on lands in Projects mode, and it '
      'is saved', (tester) async {
    late ProjectLayoutController layout;
    final h = await pumpShell(
      tester,
      size: const Size(390, 844),
      shellMode: false,
      before: (h) {
        layout = ProjectLayoutController.instance = ProjectLayoutController(
          theme: h.theme,
          clock: () => h.now,
        );
        unawaited(
          h.theme.setProjectPrefs(
            h.theme.projectPrefs.copyWith(groupByProject: true),
          ),
        );
      },
    );
    addTearDown(() {
      ProjectLayoutController.instance = null;
      layout.dispose();
    });
    expect(find.byKey(const ValueKey('home-projects')), findsOneWidget);
    expect(h.homePreferences.stored.mode, HomeMode.projects);
    await tearDownShell(tester);
  });

  testWidgets('with a project layout and nothing picked, home opens in '
      'Projects mode without saving a choice', (tester) async {
    late ProjectLayoutController layout;
    final h = await pumpShell(
      tester,
      size: const Size(390, 844),
      shellMode: false,
      before: (h) {
        layout = ProjectLayoutController.instance = ProjectLayoutController(
          theme: h.theme,
          clock: () => h.now,
        );
        unawaited(
          h.theme.setProjectPrefs(
            h.theme.projectPrefs.copyWith(
              layout: const ProjectLayout().add(
                'Infra',
                rules: ['Infrastructure'],
              ),
            ),
          ),
        );
      },
    );
    addTearDown(() {
      ProjectLayoutController.instance = null;
      layout.dispose();
    });
    expect(find.byKey(const ValueKey('home-projects')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('home-project-box-infra')),
      findsOneWidget,
    );
    expect(h.homePreferences.stored.mode, isNull);
    await tearDownShell(tester);
  });

  testWidgets('Projects mode: an open workspace is its one row, marked open, '
      'and a tap goes to its session', (tester) async {
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
    final session = await h.open(
      tester,
      workstation,
      const ConnectTarget.herdr(workspaceId: 'w2', label: 'TheCalendar'),
    );
    await settleShell(tester);
    // Open / Closed lists it as a session tile.
    expect(
      find.byKey(ValueKey('home-session-${session.host.id}')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('home-mode-projects')));
    await settleShell(tester);
    expect(
      find.byKey(ValueKey('home-session-${session.host.id}')),
      findsNothing,
    );
    final agent = find.byKey(
      ValueKey(
        'home-project-agent-'
        '${SidebarKeys.herdrTab('workstation', 'w2', 'w2:t1')}',
      ),
    );
    await tester.scrollUntilVisible(agent, 200, scrollable: homeScrollable);
    expect(agent, findsOneWidget);
    expect(
      find.descendant(of: agent, matching: find.text('open')),
      findsOneWidget,
    );
    // Nothing listed twice: the workspace has no second row, and no row
    // stands for the open session itself.
    final keys = [
      for (final element
          in find
              .byWidgetPredicate(
                (widget) =>
                    widget.key is ValueKey<String> &&
                    (widget.key! as ValueKey<String>).value.startsWith(
                      'home-project-',
                    ) &&
                    !(widget.key! as ValueKey<String>).value.startsWith(
                      'home-project-box-',
                    ) &&
                    !(widget.key! as ValueKey<String>).value.startsWith(
                      'home-project-menu-',
                    ) &&
                    !(widget.key! as ValueKey<String>).value.startsWith(
                      'home-project-open-',
                    ),
                skipOffstage: false,
              )
              .evaluate())
        (element.widget.key! as ValueKey<String>).value,
    ];
    expect(keys.toSet().length, keys.length);
    expect(
      keys.where((key) => key.contains('w2')),
      hasLength(1),
      reason: '$keys',
    );
    expect(
      keys.where(
        (key) => key.contains(
          SidebarKeys.openSession('workstation', session.host.id),
        ),
      ),
      isEmpty,
    );
    expect(h.workspace.sessions, hasLength(1));
    await tester.tap(agent);
    await settleShell(tester);
    expect(h.workspace.sessions, hasLength(1));
    expect(h.workspace.activeSession, session);
    await tearDownShell(tester);
  });

  testWidgets('Projects mode keeps the "needs you" jump to the first '
      'waiting agent', (tester) async {
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
    await tester.tap(find.byKey(const ValueKey('home-mode-projects')));
    await settleShell(tester);
    final needsYou = find.byKey(const ValueKey('project-needs-you'));
    expect(needsYou, findsOneWidget);
    expect(h.workspace.sessions, isEmpty);
    await tester.tap(needsYou);
    await settleShell(tester);
    // Infrastructure's blocked agent ("Proofing PR 398") opens.
    final opened = h.workspace.sessions.single;
    expect(ConnectTarget.fromSessionHostId(opened.host.id)?.name, 'w1');
    await tearDownShell(tester);
  });

  Future<ShellHarness> pumpSearchHome(
    WidgetTester tester, {
    required HomeMode mode,
  }) async {
    late ProjectLayoutController layout;
    final h = await pumpShell(
      tester,
      size: const Size(390, 844),
      shellMode: false,
      before: (h) {
        layout = ProjectLayoutController.instance = ProjectLayoutController(
          theme: h.theme,
          clock: () => h.now,
        );
        h.homePreferences.stored = HomePreferences(mode: mode);
        unawaited(
          h.theme.setProjectPrefs(
            h.theme.projectPrefs.copyWith(
              layout: const ProjectLayout().add('Ops', rules: ['TheCalendar']),
            ),
          ),
        );
      },
    );
    addTearDown(() {
      ProjectLayoutController.instance = null;
      layout.dispose();
    });
    return h;
  }

  final searchField = find.byKey(const ValueKey('home-workspace-search'));
  final boxes = find.byWidgetPredicate(
    (widget) =>
        widget.key is ValueKey<String> &&
        (widget.key! as ValueKey<String>).value.startsWith('home-project-box-'),
  );

  Future<void> search(WidgetTester tester, String query) async {
    await tester.enterText(
      find.descendant(of: searchField, matching: find.byType(TextField)),
      query,
    );
    await settleShell(tester);
  }

  testWidgets('Projects mode search: pane title, workspace, tab, project and '
      'machine; a project with no match hides; clearing restores', (
    tester,
  ) async {
    await pumpSearchHome(tester, mode: HomeMode.projects);
    expect(searchField, findsOneWidget);
    final all = boxes.evaluate().length;
    expect(all, greaterThan(1));
    expect(find.textContaining('Deploying images'), findsOneWidget);

    // Pane title, case-insensitive: that agent only, in its one box.
    await search(tester, 'pROOFING');
    expect(find.textContaining('Proofing PR 398'), findsOneWidget);
    expect(find.textContaining('Deploying images'), findsNothing);
    expect(find.textContaining('Nightly E2E'), findsNothing);
    expect(boxes, findsOneWidget);

    // Tab name: Infrastructure's "review" tab.
    await search(tester, 'review');
    expect(find.textContaining('Proofing PR 398'), findsOneWidget);
    expect(find.textContaining('Deploying images'), findsNothing);

    // Workspace label: both of Infrastructure's agents.
    await search(tester, 'infrastruct');
    expect(find.textContaining('Proofing PR 398'), findsOneWidget);
    expect(find.textContaining('Deploying images'), findsOneWidget);
    expect(find.textContaining('Nightly E2E'), findsNothing);

    // Project name: everything in Ops (TheCalendar), and only that box.
    await search(tester, 'ops');
    expect(find.byKey(const ValueKey('home-project-box-ops')), findsOneWidget);
    expect(find.textContaining('Nightly E2E'), findsOneWidget);
    expect(boxes, findsOneWidget);

    // Machine name: build-box's tmux session only.
    await search(tester, 'build-box');
    expect(
      find.byKey(
        ValueKey(
          'home-project-row-${SidebarKeys.tmuxSession('build-box', 'ci')}',
        ),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Proofing PR 398'), findsNothing);

    // Nothing matches: says so.
    await search(tester, 'zzz-nothing');
    expect(boxes, findsNothing);
    expect(find.byKey(const ValueKey('home-projects-empty')), findsOneWidget);

    // Clearing restores the view.
    await tester.tap(
      find.descendant(of: searchField, matching: find.byTooltip('Clear')),
    );
    await settleShell(tester);
    expect(boxes.evaluate().length, all);
    expect(find.textContaining('Deploying images'), findsOneWidget);
    await tearDownShell(tester);
  });

  testWidgets('Projects mode with Sync with sheprd names each agent row the '
      "way sheprd's sidebar does", (tester) async {
    final h = await pumpSearchHome(tester, mode: HomeMode.projects);
    final layout = ProjectLayoutController.instance!;
    await layout.setSheprdSync(true);
    layout.applyViewReply(
      workstation,
      'noise\n${jsonEncode({
        'ok': true,
        'found': true,
        'stale': false,
        'view': {
          'version': 1,
          'updated': 1000,
          'rows': 3,
          'hub': 'workstation',
          'self': 'local',
          'layout': {'group': <Object>[]},
          'agents': {
            'local/w1:p2': {'presence': 'idle', 'state_seq': 1, 'title': 'Release checklist', 'active': true},
            'local/w1:p1': {'presence': 'idle', 'state_seq': 1, 'title': 'Image pipeline', 'active': true},
          },
          'order': <String>[],
        },
      })}',
    );
    await settleShell(tester);
    expect(layout.mirroring, isTrue);
    // Both of Infrastructure's agents: sheprd's titles, not the pane's.
    expect(find.textContaining('Release checklist'), findsOneWidget);
    expect(find.textContaining('Image pipeline'), findsOneWidget);
    expect(find.textContaining('Proofing PR 398'), findsNothing);
    expect(h.workspace.sessions, isEmpty);
    await tearDownShell(tester);
  });

  testWidgets('Open / Closed search filters sessions and other workspaces, '
      'machine groups without a match hide', (tester) async {
    final h = await pumpSearchHome(tester, mode: HomeMode.openClosed);
    final session = await h.open(
      tester,
      workstation,
      const ConnectTarget.herdr(workspaceId: 'w1', label: 'Infrastructure'),
    );
    await settleShell(tester);
    final tile = find.byKey(ValueKey('home-session-${session.host.id}'));
    const calendar = ValueKey('other-herdr-workstation-w2');
    const main = ValueKey('other-tmux-workstation-main');
    const ci = ValueKey('other-tmux-build-box-ci');
    expect(tile, findsOneWidget);
    expect(find.byKey(calendar), findsOneWidget);

    // A pane title inside the open workspace keeps its session.
    await search(tester, 'proofing');
    expect(tile, findsOneWidget);
    expect(find.byKey(calendar), findsNothing);
    expect(find.byKey(main), findsNothing);

    // The project name (Ops holds TheCalendar).
    await search(tester, 'OPS');
    expect(tile, findsNothing);
    expect(find.byKey(calendar), findsOneWidget);
    expect(find.byKey(main), findsNothing);
    expect(find.byKey(ci), findsNothing);

    // A machine name keeps that machine's group.
    await search(tester, 'build-box');
    await tester.scrollUntilVisible(
      find.byKey(ci),
      200,
      scrollable: homeScrollable,
    );
    expect(find.byKey(ci), findsOneWidget);
    expect(find.byKey(calendar), findsNothing);
    expect(find.byKey(const ValueKey('other-group-workstation')), findsNothing);

    await search(tester, '');
    await tester.scrollUntilVisible(tile, -200, scrollable: homeScrollable);
    expect(tile, findsOneWidget);
    expect(find.byKey(calendar), findsOneWidget);
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
    await h.homePreferences.save(
      const HomePreferences(mode: HomeMode.projects),
    );
    await h.boards['build-box']?.refresh();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(h.page(shellMode: false));
    await settleShell(tester);
    final line = find.byKey(const ValueKey('home-notice-line-build-box'));
    await tester.scrollUntilVisible(line, 200, scrollable: homeScrollable);
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
