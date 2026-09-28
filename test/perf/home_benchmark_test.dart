// Home page with 5 machines (4 Herdr workspaces each, 20 in all) and 8
// open sessions whose previews are live: one session prints a line every
// half second, the others sit still. Reports a minute of it: widget
// rebuilds, paints, board commands per machine, and the frame time.
import 'dart:convert';

import 'package:conduit/core/theme/theme_controller.dart';
import 'package:conduit/features/agent_attention/data/herdr_attention_provider.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/app_lock/presentation/app_lock_controller.dart';
import 'package:conduit/features/backup/data/app_backup_service.dart';
import 'package:conduit/features/hosts/domain/home_preferences.dart';
import 'package:conduit/features/hosts/presentation/home_board_controller.dart';
import 'package:conduit/features/hosts/presentation/hosts_controller.dart';
import 'package:conduit/features/hosts/presentation/hosts_page.dart';
import 'package:conduit/features/local_shell/presentation/local_shell_controller.dart';
import 'package:conduit/features/terminal/presentation/host_key_prompt_coordinator.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../features/hosts/home_board_fakes.dart';
import '../support/test_doubles.dart';
import 'perf_probe.dart';

String workspacesJson(String host) => jsonEncode({
  'id': '1',
  'result': {
    'workspaces': [
      for (var w = 0; w < 4; w++)
        {
          'workspace_id': '$host-w$w',
          'label': 'Project $host-$w',
          'number': w + 1,
          'agent_status': w.isEven ? 'working' : 'idle',
          'tab_count': 2,
        },
    ],
  },
});

String agentsJson(String host) => jsonEncode({
  'id': '3',
  'result': {
    'agents': [
      for (var w = 0; w < 4; w++)
        {
          'agent': 'claude',
          'pane_id': '$host-w$w:p1',
          'tab_id': '$host-w$w:t1',
          'workspace_id': '$host-w$w',
          'agent_status': w == 0 ? 'blocked' : 'working',
          'terminal_title_stripped': 'Task $w on $host',
        },
    ],
  },
});

void main() {
  testWidgets('home: 5 machines, 20 workspaces, 8 live previews', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.6;
    addTearDown(tester.view.reset);

    final theme = ThemeController(InMemoryThemePreferences());
    await theme.load();
    final hosts = [
      for (var i = 0; i < 5; i++)
        buildHost(
          'm$i',
        ).copyWith(lastConnectedAt: DateTime.utc(2026, 9, i + 1)),
    ];
    final runners = {
      for (final host in hosts)
        host.id: HerdrFakeRunner(
          workspaces: workspacesJson(host.id),
          agents: agentsJson(host.id),
          tabs: '{"id":"2","result":{"tabs":[]}}',
        ),
    };
    var connections = 0;
    final hostsController = HostsController(
      FakeHostsRepository()..persisted = List.of(hosts),
    );
    final workspace = TerminalWorkspaceController(
      ImmediateTerminalRepository(TrackableTerminalSession()),
    );
    addTearDown(workspace.dispose);
    final attention = AgentAttentionController(
      workspace: workspace,
      runnerFactory: (_) => ScriptedAgentCommandRunner([
        StateError('no agent polling in this test'),
      ]),
      provider: const HerdrAttentionProvider(),
    );
    addTearDown(attention.dispose);
    final boards = HomeBoards(
      runnerFactory: (host) {
        connections += 1;
        return runners[host.id]!;
      },
    );
    addTearDown(boards.dispose);
    final verifier = NoopVerifier();
    await tester.pumpWidget(
      MaterialApp(
        home: HostsPage(
          hostsController: hostsController,
          lockController: AppLockController(AlwaysAuthenticates()),
          terminalRepository: NoNetworkTerminalRepository(),
          workspaceController: workspace,
          localShellController: LocalShellController(),
          themeController: theme,
          hostKeyVerifier: verifier,
          promptCoordinator: HostKeyPromptCoordinator(),
          sftpRepository: NoNetworkSftpRepository(),
          sftpBookmarksRepository: InMemorySftpBookmarks(),
          agentAttention: attention,
          backupService: AppBackupService(
            hostsController: hostsController,
            themeController: theme,
            hostKeyVerifier: verifier,
          ),
          fileExport: RecordingFileExport(),
          homeBoards: boards,
          homePreferences: InMemoryHomePreferencesRepository(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    final sessions = [
      for (var i = 0; i < 8; i++)
        workspace.open(buildHost('s$i').copyWith(name: 'Session $i')),
    ];
    for (final session in sessions) {
      await session.connect();
      for (var line = 0; line < 20; line++) {
        session.terminal.write('session ${session.host.id} line $line\r\n');
      }
    }
    await tester.pump(const Duration(seconds: 1));
    for (final runner in runners.values) {
      runner.commands.clear();
    }

    final probe = FrameProbe()..install();
    var frameUs = 0;
    var frames = 0;
    try {
      for (var tick = 0; tick < 120; tick++) {
        sessions.first.terminal.write('build step $tick\r\n');
        final watch = Stopwatch()..start();
        await tester.pump(const Duration(milliseconds: 500));
        frameUs += watch.elapsedMicroseconds;
        frames += 1;
      }
    } finally {
      probe.uninstall();
    }
    final commands = runners.values.map((r) => r.commands.length);
    perfReport('home.minute', {
      'builds': probe.builds,
      'paints': probe.paints,
      'board_commands_per_machine': commands.first,
      'board_connections': connections,
      'avg_pump_ms': (frameUs / frames / 1000).toStringAsFixed(2),
      'top': probe.top().replaceAll(' ', ','),
    });
    expect(boards['m0']!.state.workspaces, hasLength(4));
    // Only the busy session's preview redraws, once per refresh tick.
    // Before: the page rebuilt every 2 s and on every board poll (26k
    // widget builds and 7k paints a minute).
    expect(probe.builds, lessThan(500));
    expect(probe.paints, lessThan(1000));

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 10));
  });
}
