import 'dart:typed_data';

import 'package:conduit/features/agent_attention/data/conductore_host_attention_provider.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/agents_digest/presentation/agents_dashboard.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_launcher.dart';
import 'package:conduit/features/companion_setup/data/companion_bundle.dart';
import 'package:conduit/features/companion_setup/presentation/companion_setup_controller.dart';
import 'package:conduit/features/companion_setup/presentation/companion_setup_page.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
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

  testWidgets('an Agents card opens the chat for its agent, its long-press '
      'the terminal', (tester) async {
    final (controller, _) = await monitor(tester, companionHost());
    final digest = monitorOnlyDigest();
    addTearDown(digest.dispose);
    final opened = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentsDashboardView(
            controller: digest,
            attention: controller,
            tabs: true,
            onOpenTerminal: (host, agent) =>
                opened.add('terminal ${host.id}/${agent.id}'),
            onOpenChat: (host, agent) =>
                opened.add('chat ${host.id}/${agent.id}'),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(chatViewAvailable(controller, companionHost()), isTrue);
    final card = find.byKey(const ValueKey('digest-card-s-1'));
    await tester.tap(card);
    await tester.longPress(card);
    expect(opened, ['chat h/s-1', 'terminal h/s-1']);
    // No Chat button: the card itself is the way in (CON-107).
    expect(find.widgetWithText(TextButton, 'Chat'), findsNothing);
  });

  testWidgets('a host without the companion gets install instructions', (
    tester,
  ) async {
    final host = buildHost('plain');
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showChatViewUnavailable(context, host: host),
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
              onPressed: () => showChatViewUnavailable(context, host: host),
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
