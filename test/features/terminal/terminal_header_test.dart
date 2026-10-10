import 'package:conduit/core/theme/theme_controller.dart';
import 'package:conduit/features/quick_actions/domain/quick_action.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/sessions/presentation/session_grid_page.dart';
import 'package:conduit/features/terminal/presentation/terminal_file_tabs_controller.dart';
import 'package:conduit/features/terminal/presentation/terminal_keyboard_bar.dart';
import 'package:conduit/features/terminal/presentation/terminal_page.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:conduit/features/terminal/presentation/widgets/session_tabs.dart';
import 'package:conduit/features/terminal/presentation/widgets/terminal_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

void main() {
  late ThemeController themeController;

  setUp(() async {
    themeController = ThemeController(InMemoryThemePreferences());
    await themeController.load();
  });

  Future<TerminalWorkspaceController> pumpTerminal(
    WidgetTester tester, {
    bool withVerifier = false,
  }) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.6;
    addTearDown(tester.view.reset);
    final workspace = TerminalWorkspaceController(
      ImmediateTerminalRepository(TrackableTerminalSession()),
    );
    addTearDown(workspace.dispose);
    workspace
      ..open(
        const ConnectTarget.herdr(
          workspaceId: 'w1',
          label: 'Infrastructure',
        ).apply(buildHost('a')),
      )
      ..open(
        const ConnectTarget.herdr(
          workspaceId: 'w2',
          label: 'TheCalendar',
        ).apply(buildHost('a')),
      );
    await tester.pumpWidget(
      MaterialApp(
        home: TerminalPage(
          workspace: workspace,
          themeController: themeController,
          sftpRepository: NoNetworkSftpRepository(),
          hostKeyVerifier: withVerifier ? NoopVerifier() : null,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    return workspace;
  }

  testWidgets('one 40 dp row holds back, tabs and actions', (tester) async {
    await pumpTerminal(tester);

    expect(find.byType(TerminalHeader), findsOneWidget);
    expect(tester.getSize(find.byType(TerminalHeader)).height, 40);
    expect(find.byTooltip('Machines'), findsOneWidget);
    expect(find.byTooltip('Sessions'), findsOneWidget);
    expect(find.byTooltip('More'), findsOneWidget);
    // Sessions on one machine show their target, not the machine name.
    expect(find.text('Infrastructure'), findsOneWidget);
    expect(find.text('TheCalendar'), findsOneWidget);
    // Only the active tab carries a close button.
    expect(find.byTooltip('Close'), findsOneWidget);
  });

  testWidgets('tapping a tab activates its session', (tester) async {
    final workspace = await pumpTerminal(tester);
    expect(workspace.activeSession!.host.id, 'a#herdr:w2');

    await tester.tap(find.text('Infrastructure'));
    await tester.pump();
    expect(workspace.activeSession!.host.id, 'a#herdr:w1');
  });

  testWidgets('overflow keeps reconnect and close; the Full key behind ⋯ '
      'hides the row', (tester) async {
    final workspace = await pumpTerminal(tester);

    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    expect(find.text('Host a: TheCalendar'), findsOneWidget);
    expect(find.text('Reconnect'), findsOneWidget);
    expect(find.text('Fullscreen'), findsNothing);
    expect(find.text('Close session'), findsOneWidget);
    // No connect flow here, so no "New session".
    expect(find.text('New session'), findsNothing);

    await tester.tap(find.text('Close session'));
    await tester.pumpAndSettle();
    expect(workspace.sessions, hasLength(1));

    await tester.tap(find.byKey(const ValueKey('toolbar-more')));
    await tester.pumpAndSettle();
    await tester.dragUntilVisible(
      find.byIcon(Icons.fullscreen_rounded),
      find
          .descendant(
            of: find.byType(TerminalKeyboardBar),
            matching: find.byType(ListView),
          )
          .first,
      const Offset(-200, 0),
    );
    await tester.tap(find.byIcon(Icons.fullscreen_rounded));
    await tester.pumpAndSettle();
    expect(find.byType(TerminalHeader), findsNothing);
  });

  testWidgets('the overflow menu opens Settings', (tester) async {
    await pumpTerminal(tester);

    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('terminal-menu-settings')));
    await tester.pumpAndSettle();

    expect(find.text('Settings'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('settings-section-terminal')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('settings-section-terminal')));
    await tester.pumpAndSettle();
    expect(find.text('Send mouse taps'), findsOneWidget);
  });

  testWidgets('swiping down on the row opens the switcher, which leads to '
      'the session grid', (tester) async {
    await pumpTerminal(tester);
    final row = tester.getRect(find.byType(TerminalHeader));

    final gesture = await tester.startGesture(
      Offset(row.left + 60, row.center.dy),
    );
    for (var i = 0; i < 6; i += 1) {
      await gesture.moveBy(const Offset(0, 25));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('quick-switcher')), findsOneWidget);
    await tester.tap(find.byTooltip('Session grid'));
    await tester.pumpAndSettle();
    expect(find.byType(SessionGridPage), findsOneWidget);
  });

  testWidgets('file tabs sit in the same strip and close through the page', (
    tester,
  ) async {
    final workspace = TerminalWorkspaceController(
      ImmediateTerminalRepository(TrackableTerminalSession()),
    );
    addTearDown(workspace.dispose);
    final session = workspace.open(buildHost('a'));
    final files = TerminalFileTabsController(NoNetworkSftpRepository());
    addTearDown(files.dispose);
    final tab = files.open(buildHost('a'), '/srv/app/README.md');
    final closed = <TerminalFileTab>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListenableBuilder(
            listenable: files,
            builder: (context, _) => TerminalHeader(
              workspace: workspace,
              activeSession: session,
              palette: themeController.palette,
              brightness: Brightness.dark,
              onBack: () {},
              onTabsChanged: () {},
              fileTabs: files.tabs,
              activeFileTab: files.active,
              onFileTabSelected: files.activate,
              onFileTabClosed: closed.add,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(SessionTabs), findsOneWidget);
    expect(find.text('README.md'), findsOneWidget);
    expect(find.text('Host a'), findsOneWidget);

    // The file tab is active: its close button asks the page.
    await tester.tap(find.byTooltip('Close'));
    await tester.pump();
    expect(closed, [tab]);

    // Selecting the session tab moves the close button there.
    files.activate(null);
    await tester.pump();
    expect(
      find.descendant(
        of: find.ancestor(
          of: find.text('Host a'),
          matching: find.byType(InkWell),
        ),
        matching: find.byTooltip('Close'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('the row has one overflow menu that holds the session tools', (
    tester,
  ) async {
    await pumpTerminal(tester, withVerifier: true);

    // One three-dot button, not a second one for the tools.
    expect(find.byIcon(Icons.more_vert_rounded), findsOneWidget);
    expect(find.byTooltip('Session tools'), findsNothing);

    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    expect(find.text('Git diff'), findsOneWidget);
    expect(find.text('Live preview'), findsOneWidget);
    expect(find.text('Reconnect'), findsOneWidget);
    expect(find.text('Close session'), findsOneWidget);
    // Title, tools, session control, close: three dividers between them.
    expect(find.byType(PopupMenuDivider), findsNWidgets(3));
  });

  testWidgets('phones: the ⋮ menu keeps only what has no button elsewhere '
      '(CON-106)', (tester) async {
    await pumpTerminal(tester, withVerifier: true);
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();

    final entries = tester
        .widgetList<PopupMenuItem<TerminalHeaderAction>>(
          find.byType(PopupMenuItem<TerminalHeaderAction>),
        )
        .where((item) => item.value != null)
        .map((item) => item.value)
        .toList();
    expect(entries, [
      TerminalHeaderAction.gitDiff,
      TerminalHeaderAction.livePreview,
      TerminalHeaderAction.reconnect,
      // New session needs a connect flow, which this page has none of.
      TerminalHeaderAction.settings,
      TerminalHeaderAction.closeSession,
    ]);
    // Chat View is the Chat key, fullscreen the Full key, the composer is
    // in the chat line, and shortcuts are for desktops.
    for (final gone in [
      'Open chat view',
      'Fullscreen',
      'Compose a prompt…',
      'Keyboard shortcuts',
    ]) {
      expect(find.text(gone), findsNothing, reason: gone);
    }
  });

  testWidgets('overflow entries call back with the chosen tool', (
    tester,
  ) async {
    final workspace = TerminalWorkspaceController(
      ImmediateTerminalRepository(TrackableTerminalSession()),
    );
    addTearDown(workspace.dispose);
    final session = workspace.open(buildHost('a'));
    final tools = <SessionTool>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalHeader(
            workspace: workspace,
            activeSession: session,
            palette: themeController.palette,
            brightness: Brightness.dark,
            onBack: () {},
            onTabsChanged: () {},
            fileTabs: const [],
            activeFileTab: null,
            onFileTabSelected: (_) {},
            onFileTabClosed: (_) {},
            onOpenSessionTool: tools.add,
          ),
        ),
      ),
    );

    Future<void> choose(String label) async {
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }

    await choose('Git diff');
    await choose('Live preview');

    expect(tools, [SessionTool.gitDiff, SessionTool.livePreview]);
    expect(find.byIcon(Icons.more_vert_rounded), findsOneWidget);
  });

  testWidgets('phones: the menu is unchanged without quick actions, and '
      'offers them once there are some', (tester) async {
    await pumpTerminal(tester);
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('terminal-menu-quick-actions')),
      findsNothing,
    );
    // The desktop-only entry stays off phones.
    expect(
      find.byKey(const ValueKey('terminal-menu-recent-dirs')),
      findsNothing,
    );
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    await themeController.setQuickActions(const [
      QuickAction(id: 'deploy', label: 'Deploy', command: 'make deploy'),
    ]);
    await tester.pump();
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('terminal-menu-quick-actions')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('session-quick-actions')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('session-quick-action-deploy')),
      findsOneWidget,
    );
  });
}
