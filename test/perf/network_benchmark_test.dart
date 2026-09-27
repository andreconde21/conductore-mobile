// Steady-state network cost per machine: how many SSH connections the side
// channels open and how many commands they run in a minute, with the real
// controllers (agent monitor and its long-poll, home boards, usage, chat)
// over fake connections. Three states: the home page on screen, the app
// in the background (Android keeps monitoring), and a Chat view open.
import 'dart:async';

import 'package:conduit/features/agent_attention/data/conductore_host_attention_provider.dart';
import 'package:conduit/features/agent_attention/data/herdr_attention_provider.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_controller.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/hosts/presentation/home_board_controller.dart';
import 'package:conduit/features/live_preview/presentation/preview_ready_controller.dart';
import 'package:conduit/features/terminal/domain/multiplexer_tabs.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:conduit/features/this_computer/data/host_channels.dart';
import 'package:conduit/features/usage/presentation/usage_controller.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import '../features/chat_view/chat_fixtures.dart';
import '../features/hosts/home_board_fakes.dart';
import '../support/test_doubles.dart';
import 'perf_probe.dart';

/// What every fake connection to every machine records.
class NetworkLog {
  final Map<String, int> opened = {};
  final Map<String, int> live = {};
  final Map<String, int> peakLive = {};
  final Map<String, Map<String, int>> commands = {};

  void open(String host) {
    opened[host] = (opened[host] ?? 0) + 1;
    live[host] = (live[host] ?? 0) + 1;
    if (live[host]! > (peakLive[host] ?? 0)) peakLive[host] = live[host]!;
  }

  void close(String host) => live[host] = (live[host] ?? 1) - 1;

  void command(String host, String command) {
    final kind = _kind(command);
    final byKind = commands.putIfAbsent(host, () => {});
    byKind[kind] = (byKind[kind] ?? 0) + 1;
  }

  void reset() {
    opened.clear();
    commands.clear();
    peakLive
      ..clear()
      ..addAll(live);
  }

  int total(String host) =>
      (commands[host] ?? const {}).values.fold(0, (a, b) => a + b);

  static String _kind(String command) {
    for (final (pattern, kind) in [
      ('conductore-hostd version', 'version'),
      ('conductore-hostd status', 'status'),
      ('conductore-hostd events', 'events'),
      ('conductore-hostd transcript', 'transcript'),
      ('conductore-hostd usage', 'usage'),
      ('tmux list-sessions', 'tmux'),
      ('workspace list', 'herdr-workspaces'),
      ('tab list', 'herdr-tabs'),
      ('agent list', 'herdr-agents'),
    ]) {
      if (command.contains(pattern)) return kind;
    }
    return 'other';
  }
}

/// One fake SSH connection: answers the companion, Herdr and tmux.
class FakeConnection implements StdinAgentCommandRunner {
  FakeConnection(this.host, this.log) {
    log.open(host);
  }

  final String host;
  final NetworkLog log;
  bool _closed = false;

  @override
  Future<AgentCommandResult> run(
    String command, {
    required Duration timeout,
  }) async {
    log.command(host, command);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    String out = '';
    if (command.contains('conductore-hostd version')) {
      out = '{"version":"1.0.0"}';
    } else if (command.contains('conductore-hostd status')) {
      out =
          '{"version":1,"seq":1,"agents":[{"sessionId":"s-1","name":"api",'
          '"cwd":"/a","state":"working","pending":[]}]}';
    } else if (command.contains('conductore-hostd events')) {
      // Nothing happens: the long-poll runs to its host-side timeout.
      await Future<void>.delayed(ConductoreHostAttentionProvider.watchTimeout);
      out = '{"type":"timeout","seq":1}';
    } else if (command.contains('conductore-hostd transcript')) {
      out = page([userLine('u1', 'hi')], offset: 50, state: 'working');
    } else if (command.contains('conductore-hostd usage')) {
      out = '{"version":1,"days":[]}';
    } else if (command.contains('tmux list-sessions')) {
      out = 'main\t1\t3\t1790229500\n';
    } else if (command.contains('workspace list')) {
      out = HerdrFixtures.workspaces;
    } else if (command.contains('tab list')) {
      out = HerdrFixtures.tabs;
    } else if (command.contains('agent list')) {
      out = HerdrFixtures.agents;
    }
    return AgentCommandResult(stdout: out, stderr: '', exitCode: 0);
  }

  @override
  Future<AgentCommandResult> runWithStdin(
    String command, {
    required String stdin,
    required Duration timeout,
    Future<void>? cancel,
  }) => run(command, timeout: timeout);

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    log.close(host);
  }
}

enum Scene { home, background, chat, terminal }

void main() {
  void measure(Scene scene) {
    fakeAsync((async) {
      final log = NetworkLog();
      // The app's side channels, over fake SSH connections.
      final channels = HostChannels(
        hostKeyVerifier: NoopVerifier(),
        localRunner: () => throw StateError('no local machine here'),
        sshFiles: NoNetworkSftpRepository(),
        localFiles: NoNetworkSftpRepository(),
        sshRunner: (host) => FakeConnection(host.id, log),
      );
      final open = channels.runner;

      final machines = [
        for (var i = 0; i < 5; i++)
          buildHost('m$i').copyWith(
            lastConnectedAt: DateTime.utc(2026),
            agentAttentionEnabled: true,
          ),
      ];
      final workspace = TerminalWorkspaceController(FreshTerminalRepository());
      final attention = AgentAttentionController(
        workspace: workspace,
        runnerFactory: open,
        provider: const HerdrAttentionProvider(),
        companionProvider: const ConductoreHostAttentionProvider(),
      );
      final boards = HomeBoards(runnerFactory: open);
      final usage = UsageController(
        source: AttentionUsageHostSource(attention: attention),
        observeLifecycle: false,
      );
      // One terminal open on m0, monitored.
      unawaited(workspace.open(machines.first).connect());
      boards.sync([for (final m in machines) HomeBoardEntry(m)]);
      async.elapse(const Duration(seconds: 1));
      ChatViewController? chat;
      VoidCallback? detachUsage;
      switch (scene) {
        case Scene.home:
          boards.setVisible(true);
          detachUsage = usage.attachView();
          attention.setAppForeground(true);
        case Scene.background:
          // Android: monitoring goes on, the long-poll and the pages stop.
          attention
            ..setAppActive(true)
            ..setAppForeground(false);
          usage.setAppActive(false);
        case Scene.terminal:
          break;
        case Scene.chat:
          attention.setAppForeground(true);
          final (runner, owned: _) = attention.runnerFor(machines.first);
          chat = ChatViewController(runner: runner, sessionId: 's-1')
            ..setVisible(true);
      }
      PreviewReadyController? preview;
      SerialCommandChannel? tabs;
      Timer? tabsTimer;
      if (scene == Scene.terminal) {
        // The terminal page in front: the monitor's long-poll, the tab
        // strip's 2 s tmux poll and the preview watcher's port poll.
        attention.setAppForeground(true);
        tabs = SerialCommandChannel(runnerFactory: () => open(machines.first));
        tabsTimer = Timer.periodic(
          const Duration(seconds: 2),
          (_) => unawaited(tabs!.query('tmux list-windows -t =main')),
        );
        preview = PreviewReadyController(
          runnerFactory: () => open(machines.first),
        )..setForeground(true);
      }
      // Settle, then count one steady minute.
      async.elapse(const Duration(minutes: 2));
      final openedToSettle = log.opened.values.fold(0, (a, b) => a + b);
      log.reset();
      async.elapse(const Duration(minutes: 1));

      final monitored = machines.first.id;
      final other = machines[1].id;
      perfReport('network.${scene.name}', {
        'connections_opened_to_settle': openedToSettle,
        'monitored_connections': log.peakLive[monitored] ?? 0,
        'monitored_opened_per_min': log.opened[monitored] ?? 0,
        'monitored_commands_per_min': log.total(monitored),
        'other_machine_connections': log.peakLive[other] ?? 0,
        'other_machine_commands_per_min': log.total(other),
        'monitored_by_kind': (log.commands[monitored] ?? const {}).entries
            .map((e) => '${e.key}:${e.value}')
            .join(','),
      });

      // One connection per machine for every side channel (before: the
      // monitor, board, tab strip and preview watcher each had one).
      expect(log.peakLive[monitored] ?? 0, lessThanOrEqualTo(1));
      chat?.dispose();
      tabsTimer?.cancel();
      unawaited(tabs?.close());
      preview?.dispose();
      detachUsage?.call();
      usage.dispose();
      boards.dispose();
      attention.dispose();
      unawaited(workspace.closeAll());
      async.elapse(const Duration(minutes: 2));
    });
  }

  test('home on screen', () => measure(Scene.home));
  test('app in the background', () => measure(Scene.background));
  test('chat view open', () => measure(Scene.chat));
  test('terminal page in front', () => measure(Scene.terminal));
}
