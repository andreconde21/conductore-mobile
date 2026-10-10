import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:conduit/features/terminal/presentation/widgets/session_tabs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

void main() {
  testWidgets('session tabs carry the tmux and Herdr logos', (tester) async {
    final workspace = TerminalWorkspaceController(
      ImmediateTerminalRepository(TrackableTerminalSession()),
    );
    addTearDown(workspace.dispose);
    workspace
      ..open(buildHost('plain'))
      ..open(const ConnectTarget.tmux('main').apply(buildHost('t')))
      ..open(
        buildHost(
          'auto',
        ).copyWith(startTmuxOnConnect: true, tmuxSessionName: 'work'),
      )
      ..open(
        const ConnectTarget.herdr(
          workspaceId: 'w1',
          label: 'Infra',
        ).apply(buildHost('h')),
      );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SessionTabs(
            workspace: workspace,
            activeSession: workspace.activeSession,
            palette: AppPalette.values.first,
            brightness: Brightness.dark,
            onChanged: () {},
            fileTabs: const [],
            activeFileTab: null,
            onFileTabSelected: (_) {},
            onFileTabClosed: (_) {},
          ),
        ),
      ),
    );
    expect(
      find.byKey(const ValueKey('multiplexer-icon-tmux')),
      findsNWidgets(2),
    );
    expect(
      find.byKey(const ValueKey('multiplexer-icon-herdr')),
      findsOneWidget,
    );
    await tester.pump(const Duration(milliseconds: 400));
  });

  test('a tab is named after its project, not the machine', () {
    final workspace = TerminalWorkspaceController(
      ImmediateTerminalRepository(TrackableTerminalSession()),
    );
    addTearDown(workspace.dispose);
    workspace
      ..open(
        const ConnectTarget.herdr(
          workspaceId: 'w1',
          label: 'Infra',
        ).apply(buildHost('a')),
      )
      ..open(
        const ConnectTarget.herdr(
          workspaceId: 'w2',
          label: 'Shop',
        ).apply(buildHost('b')),
      );
    final sessions = workspace.sessions;
    // Two machines, still the project first.
    expect(SessionTabs.labelFor(sessions[0], sessions), 'Infra');
    expect(SessionTabs.labelFor(sessions[1], sessions), 'Shop');
    // The same project on two machines keeps the machine to tell them apart.
    workspace.open(
      const ConnectTarget.herdr(
        workspaceId: 'w3',
        label: 'Infra',
      ).apply(buildHost('c')),
    );
    final three = workspace.sessions;
    expect(SessionTabs.labelFor(three[0], three), three[0].title);
    expect(SessionTabs.labelFor(three[2], three), three[2].title);
    expect(SessionTabs.labelFor(three[1], three), 'Shop');
  });
}
