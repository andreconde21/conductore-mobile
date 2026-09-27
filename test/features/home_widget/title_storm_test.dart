import 'package:conduit/features/agent_attention/data/herdr_attention_provider.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/home_widget/presentation/agent_status_widget_pusher.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';
import 'fake_agent_status_widget_channel.dart';

void main() {
  test('terminal title changes (OSC 2) neither re-notify the workspace or '
      'agent attention nor push widget snapshots', () async {
    final workspace = TerminalWorkspaceController(
      ImmediateTerminalRepository(TrackableTerminalSession()),
    );
    final runner = ScriptedAgentCommandRunner([
      const AgentCommandResult(
        stdout: '[{"name": "b", "state": "working"}]',
        stderr: '',
        exitCode: 0,
      ),
    ]);
    final attention = AgentAttentionController(
      workspace: workspace,
      runnerFactory: (_) => runner,
      provider: const HerdrAttentionProvider(),
      pollInterval: const Duration(days: 1),
    );
    final session = workspace.open(
      buildHost('h').copyWith(agentAttentionEnabled: true),
    );
    await session.connect();
    await pumpEventQueue();
    var workspaceNotifies = 0;
    var notifies = 0;
    workspace.addListener(() => workspaceNotifies++);
    attention.addListener(() => notifies++);
    final channel = FakeAgentStatusWidgetChannel();
    final pusher = AgentStatusWidgetPusher.forController(
      attention,
      channel: channel,
      debounce: const Duration(milliseconds: 20),
    )..start();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final basePushes = channel.pushed.length;

    // A spinner in the title.
    const frames = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];
    for (final f in frames) {
      session.terminal.write('\x1b]2;$f Claude Code\x07');
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(session.terminalTitle, '⠏ Claude Code');
    expect(workspaceNotifies, 0);
    expect(notifies, 0);
    expect(channel.pushed.length, basePushes);
    pusher.dispose();
    attention.dispose();
    workspace.dispose();
  });

  test('a session notifying without changing the monitored hosts does not '
      're-notify agent attention', () async {
    final workspace = TerminalWorkspaceController(
      ImmediateTerminalRepository(TrackableTerminalSession()),
    );
    final attention = AgentAttentionController(
      workspace: workspace,
      runnerFactory: (_) => ScriptedAgentCommandRunner(const []),
      provider: const HerdrAttentionProvider(),
      pollInterval: const Duration(days: 1),
    );
    final session = workspace.open(
      buildHost('h').copyWith(agentAttentionEnabled: true),
    );
    await session.connect();
    await pumpEventQueue();
    var notifies = 0;
    attention.addListener(() => notifies++);

    session.rename('Build box');
    session.rename(null);
    expect(notifies, 0);

    await session.disconnect();
    expect(attention.isMonitoring(session.host.id), isFalse);
    expect(notifies, greaterThan(0));
    attention.dispose();
    workspace.dispose();
  });
}
