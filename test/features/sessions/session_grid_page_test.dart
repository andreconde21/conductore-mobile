import 'package:conduit/core/theme/theme_controller.dart';
import 'package:conduit/features/agent_attention/data/herdr_attention_provider.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/sessions/presentation/session_grid_page.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

void main() {
  late ThemeController themeController;

  setUp(() async {
    themeController = ThemeController(InMemoryThemePreferences());
    await themeController.load();
  });

  Future<TerminalWorkspaceController> pumpGrid(
    WidgetTester tester, {
    AgentAttentionController Function(TerminalWorkspaceController)?
    agentAttention,
  }) async {
    final workspace = TerminalWorkspaceController(
      ImmediateTerminalRepository(TrackableTerminalSession()),
    );
    addTearDown(workspace.dispose);
    final attention = agentAttention?.call(workspace);
    await tester.pumpWidget(
      MaterialApp(
        home: SessionGridPage(
          workspace: workspace,
          themeController: themeController,
          agentAttention: attention,
          refreshInterval: const Duration(days: 1),
        ),
      ),
    );
    return workspace;
  }

  testWidgets('renders one tile per session with preview and labels', (
    tester,
  ) async {
    final workspace = await pumpGrid(tester);
    final plain = workspace.open(buildHost('a'));
    final herdr = workspace.open(
      const ConnectTarget.herdr(
        workspaceId: 'wX',
        label: 'Conductore-Mobile',
      ).apply(buildHost('b')),
    );
    plain.terminal.write('\$ ls\r\nREADME.md\r\n');
    herdr.terminal.write('Proofing… 16m 21s\r\n');
    await tester.pump();

    expect(find.byType(SessionTile), findsNWidgets(2));
    expect(find.text('Host a'), findsOneWidget);
    expect(find.text('Host b'), findsOneWidget);
    expect(find.text('Conductore-Mobile'), findsOneWidget);
    expect(find.textContaining('README.md'), findsOneWidget);
    expect(find.textContaining('Proofing'), findsOneWidget);
    expect(find.text('2 open'), findsOneWidget);
    // Without a connect flow there is no "+" tile.
    expect(find.text('New session'), findsNothing);
  });

  testWidgets('tapping a tile activates its session and closes the grid', (
    tester,
  ) async {
    final workspace = await pumpGrid(tester);
    final first = workspace.open(buildHost('a'));
    workspace.open(buildHost('b'));
    await tester.pump();
    expect(workspace.activeSession, isNot(first));

    await tester.tap(find.text('Host a'));
    await tester.pumpAndSettle();

    expect(workspace.activeSession, first);
    expect(find.byType(SessionGridPage), findsNothing);
  });

  testWidgets('long-press offers to close the session', (tester) async {
    final workspace = await pumpGrid(tester);
    workspace.open(buildHost('a'));
    workspace.open(buildHost('b'));
    await tester.pump();

    await tester.longPress(find.text('Host b'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close session'));
    await tester.pumpAndSettle();

    expect(workspace.sessions.map((session) => session.host.id), ['a']);
    expect(find.byType(SessionTile), findsOneWidget);
  });

  testWidgets('shows the agent badge for the session workspace', (
    tester,
  ) async {
    const agents = AgentCommandResult(
      stdout:
          '[{"name": "builder", "state": "working", "workspace_id": "wX"},'
          ' {"name": "reviewer", "state": "blocked", "workspace_id": "w4"}]',
      stderr: '',
      exitCode: 0,
    );
    late AgentAttentionController attention;
    final workspace = await pumpGrid(
      tester,
      agentAttention: (workspace) {
        attention = AgentAttentionController(
          workspace: workspace,
          runnerFactory: (_) => ScriptedAgentCommandRunner([agents]),
          provider: const HerdrAttentionProvider(),
          pollInterval: const Duration(days: 1),
        );
        addTearDown(attention.dispose);
        return attention;
      },
    );
    final host = buildHost('h').copyWith(agentAttentionEnabled: true);
    final session = workspace.open(
      const ConnectTarget.herdr(workspaceId: 'wX', label: 'Mobile').apply(host),
    );
    await tester.runAsync(session.connect);
    await tester.runAsync(pumpEventQueue);
    await tester.pump();

    // Only the wX agent counts for this tile: "Working", not "Needs input".
    expect(find.text('Working'), findsOneWidget);
    expect(find.text('Needs input'), findsNothing);
    expect(
      summarizeAgentState(attention.statusFor(session.host.id), 'h#tmux:x'),
      AgentAttentionState.needsInput,
    );
  });

  testWidgets(
    'desktop right-click on a tile opens its actions',
    (tester) async {
      final workspace = await pumpGrid(tester);
      workspace.open(buildHost('a'));
      await tester.pump();
      await tester.tap(find.text('Host a'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.text('Reconnect'), findsOneWidget);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.linux,
      TargetPlatform.windows,
      TargetPlatform.macOS,
    }),
  );

  testWidgets('phones ignore right-click on a tile', (tester) async {
    final workspace = await pumpGrid(tester);
    workspace.open(buildHost('a'));
    await tester.pump();
    await tester.tap(find.text('Host a'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('Reconnect'), findsNothing);
  });
}
