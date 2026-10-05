import 'dart:typed_data';

import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/features/agent_attention/data/conductore_host_attention_provider.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_sheet.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_launcher.dart';
import 'package:conduit/features/companion_setup/data/companion_bundle.dart';
import 'package:conduit/features/companion_setup/presentation/companion_setup_controller.dart';
import 'package:conduit/features/companion_setup/presentation/companion_setup_page.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:conduit/features/terminal/presentation/widgets/terminal_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

void main() {
  AgentCommandResult ok(String stdout) =>
      AgentCommandResult(stdout: stdout, stderr: '', exitCode: 0);

  final status = ok(
    '{"version":1,"seq":2,"agents":[{"sessionId":"s-1","name":"api",'
    '"cwd":"/home/a/api","state":"working","pending":[]},'
    '{"sessionId":"s-2","name":"old","cwd":"/home/a/old","state":"ended",'
    '"pending":[]}]}',
  );

  Future<(AgentAttentionController, TerminalWorkspaceController)> monitor(
    WidgetTester tester,
    SavedHost host,
  ) async {
    final workspace = TerminalWorkspaceController(
      ImmediateTerminalRepository(TrackableTerminalSession()),
    );
    final controller = AgentAttentionController(
      workspace: workspace,
      runnerFactory: (_) => ScriptedAgentCommandRunner([status]),
      provider: const ConductoreHostAttentionProvider(),
      pollInterval: const Duration(days: 1),
    );
    controller.setLongPoll(false);
    addTearDown(controller.dispose);
    addTearDown(workspace.dispose);
    final session = workspace.open(host);
    await tester.runAsync(session.connect);
    await tester.runAsync(pumpEventQueue);
    return (controller, workspace);
  }

  SavedHost companionHost() => buildHost('h').copyWith(
    agentAttentionEnabled: true,
    agentMonitor: AgentMonitorKind.companion,
  );

  testWidgets('the Agents sheet row opens the chat for its agent', (
    tester,
  ) async {
    final (controller, _) = await monitor(tester, companionHost());
    final opened = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentAttentionSheet(
            controller: controller,
            onOpenAgent: (host, agent) {},
            onOpenChat: (host, agent) => opened.add('${host.id}/${agent.id}'),
          ),
        ),
      ),
    );
    await tester.pump();
    final apiRow = find.ancestor(
      of: find.text('api'),
      matching: find.byWidgetPredicate(
        (widget) =>
            widget.key is ValueKey<String> &&
            (widget.key! as ValueKey<String>).value.startsWith('agent-row-'),
      ),
    );
    final chat = find.descendant(
      of: apiRow,
      matching: find.widgetWithText(TextButton, 'Chat'),
    );
    expect(chat, findsOneWidget);
    await tester.tap(chat);
    expect(opened, ['h/s-1']);
  });

  testWidgets('without onOpenChat the sheet shows no Chat button', (
    tester,
  ) async {
    final (controller, _) = await monitor(tester, companionHost());
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentAttentionSheet(
            controller: controller,
            onOpenAgent: (host, agent) {},
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.widgetWithText(TextButton, 'Chat'), findsNothing);
    expect(chatViewAvailable(controller, companionHost()), isTrue);
  });

  testWidgets('the overflow menu has "Open chat view" when wired', (
    tester,
  ) async {
    final workspace = TerminalWorkspaceController(
      ImmediateTerminalRepository(TrackableTerminalSession()),
    );
    addTearDown(workspace.dispose);
    final session = workspace.open(buildHost('a'));
    var opened = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalHeader(
            workspace: workspace,
            activeSession: session,
            palette: AppPalette.everforest,
            brightness: Brightness.dark,
            onBack: () {},
            onTabsChanged: () {},
            fileTabs: const [],
            activeFileTab: null,
            onFileTabSelected: (_) {},
            onFileTabClosed: (_) {},
            onOpenChatView: () => opened += 1,
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open chat view'));
    await tester.pumpAndSettle();
    expect(opened, 1);
  });

  testWidgets('a host without the companion gets install instructions', (
    tester,
  ) async {
    final host = buildHost('plain');
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => openChatViewForHost(
              context: context,
              attention: null,
              host: host,
              onOpenTerminal: (_) {},
            ),
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text('Chat view needs the companion'), findsOneWidget);
    expect(find.textContaining('host/install.sh'), findsOneWidget);
  });

  testWidgets('the companion dialog opens Agent hooks when the app has it', (
    tester,
  ) async {
    final host = buildHost('plain');
    final companion = CompanionSetupController(
      runnerFactory: (_) => ScriptedAgentCommandRunner([
        const AgentCommandResult(stdout: '', stderr: '', exitCode: 127),
      ]),
      sftpRepository: NoNetworkSftpRepository(),
      loadBundle: () async =>
          CompanionBundle(version: '0', archive: Uint8List(0)),
    );
    addTearDown(companion.dispose);
    await tester.pumpWidget(
      CompanionSetupScope(
        controller: companion,
        child: MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => openChatViewForHost(
                context: context,
                attention: null,
                host: host,
                onOpenTerminal: (_) {},
              ),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('chat-unavailable-agent-hooks')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(CompanionSetupPage), findsOneWidget);
    expect(find.text('Not installed'), findsOneWidget);
  });

  testWidgets('picking a session skips ended ones and opens the only one', (
    tester,
  ) async {
    final host = companionHost();
    final (controller, _) = await monitor(tester, host);
    AgentInfo? picked;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => picked = await pickChatAgent(
              context,
              host: host,
              agents: controller.statusFor(host.id)!.agents,
            ),
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(picked?.id, 's-1');
  });
}
