import 'package:conduit/features/agent_attention/data/herdr_attention_provider.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/home_widget/domain/agent_status_widget_channel.dart';
import 'package:conduit/features/home_widget/presentation/agent_status_launch_listener.dart';
import 'package:conduit/features/home_widget/presentation/home_launch_requests.dart';
import 'package:conduit/features/home_widget/presentation/quick_settings_tile_controls.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';
import 'fake_agent_status_widget_channel.dart';

void main() {
  late TerminalWorkspaceController workspace;
  late AgentAttentionController controller;

  setUp(() {
    workspace = TerminalWorkspaceController(
      ImmediateTerminalRepository(TrackableTerminalSession()),
    );
    controller = AgentAttentionController(
      workspace: workspace,
      runnerFactory: (_) => ScriptedAgentCommandRunner(const []),
      provider: const HerdrAttentionProvider(),
      pollInterval: const Duration(days: 1),
    );
  });

  tearDown(() {
    controller.dispose();
    workspace.dispose();
  });

  Widget app(FakeAgentStatusWidgetChannel channel) => MaterialApp(
    home: AgentStatusLaunchListener(
      channel: channel,
      agentAttention: controller,
      workspace: workspace,
      child: const Scaffold(body: Text('home')),
    ),
  );

  testWidgets('opens the agent sheet for a pending launch target', (
    tester,
  ) async {
    final channel = FakeAgentStatusWidgetChannel()
      ..pendingTarget = AgentStatusLaunchTarget.agents;
    await tester.pumpWidget(app(channel));
    await tester.pumpAndSettle();

    expect(channel.consumeCalls, 1);
    expect(find.text('Agents'), findsOneWidget);
    expect(find.byType(BottomSheet), findsOneWidget);
  });

  testWidgets('does nothing without a target', (tester) async {
    final channel = FakeAgentStatusWidgetChannel();
    await tester.pumpWidget(app(channel));
    await tester.pumpAndSettle();

    expect(channel.consumeCalls, 1);
    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets('opens the sheet when a target arrives while running', (
    tester,
  ) async {
    final channel = FakeAgentStatusWidgetChannel();
    await tester.pumpWidget(app(channel));
    await tester.pumpAndSettle();
    expect(channel.listener, isNotNull);

    channel.deliver(AgentStatusLaunchTarget.agents);
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);

    // A second delivery while the sheet is open does not stack sheets.
    channel.deliver(AgentStatusLaunchTarget.agents);
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
  });

  testWidgets('the widget\'s dashboard and ring taps go to their screens', (
    tester,
  ) async {
    final opened = <String>[];
    final channel = FakeAgentStatusWidgetChannel();
    await tester.pumpWidget(
      MaterialApp(
        home: AgentStatusLaunchListener(
          channel: channel,
          agentAttention: controller,
          workspace: workspace,
          onDashboard: () => opened.add('dashboard'),
          onUsage: () => opened.add('usage'),
          child: const Scaffold(body: Text('home')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    channel.deliver(AgentStatusLaunchTarget.dashboard);
    await tester.pumpAndSettle();
    channel.deliver(AgentStatusLaunchTarget.usage);
    await tester.pumpAndSettle();
    expect(opened, ['dashboard', 'usage']);
    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets('without a dashboard, its tap shows the agent sheet', (
    tester,
  ) async {
    final channel = FakeAgentStatusWidgetChannel()
      ..pendingTarget = AgentStatusLaunchTarget.dashboard;
    await tester.pumpWidget(app(channel));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
  });

  testWidgets('home launch requests wait until the home page takes them', (
    tester,
  ) async {
    final requests = HomeLaunchRequests();
    addTearDown(requests.dispose);
    var notified = 0;
    requests
      ..request(HomeLaunchRequest.usage)
      ..addListener(() => notified++)
      ..request(HomeLaunchRequest.dashboard);
    expect(notified, 1);
    expect(requests.take(), HomeLaunchRequest.dashboard);
    expect(requests.take(), isNull);
  });

  testWidgets('unregisters its listener on dispose', (tester) async {
    final channel = FakeAgentStatusWidgetChannel();
    await tester.pumpWidget(app(channel));
    await tester.pumpWidget(const MaterialApp(home: Text('gone')));
    expect(channel.listener, isNull);
  });

  testWidgets('quick-settings entry reports the add-tile outcome', (
    tester,
  ) async {
    final channel = FakeAgentStatusWidgetChannel()
      ..addTileResult = AddTileResult.unsupported;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: QuickSettingsTileControls(channel: channel)),
      ),
    );

    await tester.tap(find.text('Add quick-settings tile'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        QuickSettingsTileControls.messageFor(AddTileResult.unsupported),
      ),
      findsOneWidget,
    );
  });
}
