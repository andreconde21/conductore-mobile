// Agents dashboard with 30 agents on one machine, on screen for two
// minutes while the monitor polls every 15 s and nothing changes. Reports
// listener notifications, widget rebuilds and paints.
import 'dart:convert';

import 'package:conduit/features/agent_attention/data/conductore_host_attention_provider.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/agents_digest/presentation/agents_dashboard.dart';
import 'package:conduit/features/agents_digest/presentation/digest_controller.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../features/agents_digest/digest_fakes.dart';
import '../support/test_doubles.dart';
import 'perf_probe.dart';

const _agents = 30;

String _state(int i) => switch (i % 5) {
  0 => 'needs_permission',
  1 => 'waiting_input',
  _ => 'working',
};

class _Companion implements AgentCommandRunner {
  int runs = 0;

  @override
  Future<AgentCommandResult> run(
    String command, {
    required Duration timeout,
  }) async {
    runs += 1;
    String out = '{"error":"unknown command"}';
    if (command.contains('conductore-hostd status')) {
      out = jsonEncode({
        'version': 1,
        'seq': 5,
        'capabilities': ['smart-approvals', 'digest'],
        'agents': [
          for (var i = 0; i < _agents; i++)
            {
              'sessionId': 'agent-$i',
              'name': 'agent-$i',
              'cwd': '/home/a/project-$i',
              'state': _state(i),
              'updatedAt': 1790000000000 + i,
              'pending': [
                if (i % 5 == 0)
                  {
                    'id': 'req-$i',
                    'toolName': 'Bash',
                    'summary': 'npm test $i',
                    'createdAt': 1790000000000,
                  },
              ],
            },
        ],
      });
    } else if (command.contains('conductore-hostd digest')) {
      out = jsonEncode(
        digestReplyJson([
          for (var i = 0; i < _agents; i++)
            digestAgentJson(
              'agent-$i',
              state: _state(i),
              headline: 'Working on task $i',
              summary: 'Did thing $i and more.',
            ),
        ]),
      );
    }
    return AgentCommandResult(stdout: out, stderr: '', exitCode: 0);
  }

  @override
  Future<void> close() async {}
}

void main() {
  testWidgets('dashboard: 30 agents, two quiet minutes', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final runner = _Companion();
    final workspace = TerminalWorkspaceController(
      ImmediateTerminalRepository(TrackableTerminalSession()),
    );
    final attention = AgentAttentionController(
      workspace: workspace,
      runnerFactory: (_) => runner,
      provider: const ConductoreHostAttentionProvider(),
      companionProvider: const ConductoreHostAttentionProvider(),
    );
    attention.setAppForeground(false);
    final digest = DigestController(
      source: AttentionDigestHostSource(attention: attention),
      clock: () => digestNow,
      observeLifecycle: false,
    );
    final session = workspace.open(
      buildHost('h').copyWith(
        agentAttentionEnabled: true,
        agentMonitor: AgentMonitorKind.companion,
      ),
    );
    // Connected inside the test's fake clock, so the monitor's timers run
    // on it.
    await session.connect();
    await tester.pump();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentsDashboardView(
            controller: digest,
            attention: attention,
            now: () => digestNow,
            onOpenChat: (_, _) {},
            onOpenTerminal: (_, _) {},
          ),
        ),
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    var attentionNotifies = 0;
    var digestNotifies = 0;
    attention.addListener(() => attentionNotifies += 1);
    digest.addListener(() => digestNotifies += 1);
    final runsBefore = runner.runs;
    final probe = FrameProbe()..install();
    try {
      for (var s = 0; s < 120; s++) {
        await tester.pump(const Duration(seconds: 1));
      }
    } finally {
      probe.uninstall();
    }
    perfReport('dashboard.two_minutes', {
      'agents': _agents,
      'commands': runner.runs - runsBefore,
      'attention_notifies': attentionNotifies,
      'digest_notifies': digestNotifies,
      'builds': probe.builds,
      'paints': probe.paints,
      'top': probe.top().replaceAll(' ', ','),
    });
    expect(attention.statusFor('h')?.agents, hasLength(_agents));
    await tester.pumpWidget(const SizedBox());
    digest.dispose();
    attention.dispose();
    workspace.dispose();
    await tester.pump(const Duration(minutes: 1));
  });
}
