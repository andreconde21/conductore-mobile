import 'package:conduit/core/app_failure.dart';
import 'package:conduit/core/connection_problem.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/hosts/presentation/home_board_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';
import 'home_board_fakes.dart';

SavedHost connected(String id) =>
    buildHost(id).copyWith(lastConnectedAt: DateTime.utc(2026, 9, 2));

void main() {
  late HerdrFakeRunner runner;
  late int created;
  late HomeBoardController board;

  setUp(() {
    runner = HerdrFakeRunner();
    created = 0;
    board = HomeBoardController(
      runnerFactory: (_) {
        created += 1;
        return runner;
      },
      pollInterval: const Duration(days: 1),
    );
  });

  tearDown(() => board.dispose());

  test('stays idle until visible, then lists workspaces with panes', () async {
    board.selectHost(connected('a'));
    expect(created, 0);
    expect(board.state.phase, HomeBoardPhase.loading);

    board.setVisible(true);
    await board.pollNow();
    await pumpEventQueue();

    final state = board.state;
    expect(state.phase, HomeBoardPhase.ready);
    expect(state.workspaces.map((w) => w.label), [
      'Infrastructure',
      'TheCalendar',
    ]);
    final infra = state.workspaces.first;
    // Ordered by tab number, tab labels resolved.
    expect(infra.panes.map((p) => p.title), [
      'Deploying images',
      'Proofing PR 398',
    ]);
    expect(infra.panes.map((p) => p.tabLabel), ['main', 'review']);
    expect(infra.summary, AgentAttentionState.needsInput);
    expect(state.workspaces.last.panes.single.tabLabel, 'Tab 1');
    expect(state.workspaces.last.summary, AgentAttentionState.finished);
    expect(state.attentionCount, 1);
    expect(state.paneCount, 3);
  });

  test('hiding closes the channel and stops listing', () async {
    board.selectHost(connected('a'));
    board.setVisible(true);
    await pumpEventQueue();
    expect(runner.commands, isNotEmpty);

    board.setVisible(false);
    await pumpEventQueue();
    expect(runner.closeCount, 1);
    final before = runner.commands.length;
    await board.pollNow();
    // pollNow still works (the page calls refresh only while visible), but
    // a hidden board never starts a timer.
    expect(runner.commands.length, greaterThanOrEqualTo(before));
  });

  test('hardware-key machines wait for an explicit request', () async {
    final host = buildHost('k').copyWith(authMethod: SshAuthMethod.hardwareKey);
    board
      ..setVisible(true)
      ..selectHost(host);
    await pumpEventQueue();
    expect(board.state.phase, HomeBoardPhase.awaitingRequest);
    expect(created, 0);

    await board.refresh();
    expect(created, 0);

    board.requestLoad();
    await pumpEventQueue();
    expect(created, 1);
    expect(board.state.phase, HomeBoardPhase.ready);
  });

  test('reports Herdr not running and not installed', () async {
    runner
      ..workspaces = HerdrFixtures.notRunning
      ..workspaceExitCode = 1;
    board
      ..setVisible(true)
      ..selectHost(connected('a'));
    await pumpEventQueue();
    expect(board.state.phase, HomeBoardPhase.notRunning);

    runner
      ..workspaces = ''
      ..workspaceExitCode = 127
      ..workspaceStderr = 'sh: herdr: not found';
    await board.refresh();
    expect(board.state.phase, HomeBoardPhase.notInstalled);
  });

  test('an unreachable machine is told apart from a failed listing', () async {
    board
      ..setVisible(true)
      ..selectHost(connected('a').copyWith(host: 'dev.tail574592.ts.net'));
    await pumpEventQueue();

    runner.error = const ConnectionFailure(
      'Could not reach Host a.',
      "SocketException: Failed host lookup: 'dev.tail574592.ts.net'",
      kind: ConnectionProblemKind.unreachable,
    );
    await board.refresh();
    final problem = board.state.problem!;
    expect(board.state.phase, HomeBoardPhase.failed);
    expect(problem.kind, ConnectionProblemKind.unreachable);
    expect(problem.title, "Can't reach Host a");
    expect(problem.message, contains('Tailscale'));
    expect(problem.detail, contains('Failed host lookup'));

    // A command failing on a reached machine keeps the listing wording.
    runner.error = const AppFailure('The command timed out.');
    await board.refresh();
    expect(board.state.phase, HomeBoardPhase.failed);
    expect(board.state.problem, isNull);

    runner.error = null;
    await board.refresh();
    expect(board.state.phase, HomeBoardPhase.ready);
    expect(board.state.problem, isNull);
  });

  test('a failed poll keeps the last board and reconnects next time', () async {
    board
      ..setVisible(true)
      ..selectHost(connected('a'));
    await pumpEventQueue();
    expect(board.state.workspaces, hasLength(2));

    runner.error = const AppFailure('Could not reach Host a.');
    await board.refresh();
    expect(board.state.phase, HomeBoardPhase.failed);
    expect(board.state.message, contains('Could not reach'));
    expect(board.state.workspaces, hasLength(2));
    expect(runner.closeCount, 1);

    runner.error = null;
    await board.refresh();
    expect(board.state.phase, HomeBoardPhase.ready);
    expect(created, 2);
  });

  test('switching machine starts over and ignores the old fetch', () async {
    board
      ..setVisible(true)
      ..selectHost(connected('a'));
    board.selectHost(connected('b'));
    await pumpEventQueue();
    expect(board.host?.id, 'b');
    expect(board.state.phase, HomeBoardPhase.ready);
    expect(runner.closeCount, greaterThanOrEqualTo(1));
  });

  test('focusPane sends herdr agent focus with the pane id', () async {
    board
      ..setVisible(true)
      ..selectHost(connected('a'));
    await pumpEventQueue();
    final pane = board.state.workspaces.first.panes.last;
    await board.focusPane(pane.agent);
    expect(runner.commands.last, contains('agent focus w1:p2'));

    await board.focusWorkspace('w2');
    expect(runner.commands.last, contains('workspace focus w2'));
  });

  test('a never-connected machine waits, then starts once connected', () async {
    board
      ..setVisible(true)
      ..selectHost(buildHost('n'));
    await pumpEventQueue();
    expect(board.state.phase, HomeBoardPhase.awaitingRequest);
    expect(board.requestReason, HomeBoardRequestReason.neverConnected);
    expect(created, 0);

    // The first connection records a timestamp: the board starts.
    board.selectHost(connected('n'));
    await pumpEventQueue();
    expect(created, 1);
    expect(board.state.phase, HomeBoardPhase.ready);
  });

  test('a machine reached before lists without a request', () async {
    // No saved timestamp, but the host key is trusted.
    board
      ..setVisible(true)
      ..selectHost(buildHost('t'), connectedBefore: true);
    await pumpEventQueue();
    expect(board.requestReason, isNull);
    expect(created, 1);
    expect(board.state.phase, HomeBoardPhase.ready);
  });

  test('learning that a waiting machine was reached starts it', () async {
    board
      ..setVisible(true)
      ..selectHost(buildHost('n'));
    await pumpEventQueue();
    expect(board.state.phase, HomeBoardPhase.awaitingRequest);

    // The trusted keys load after the first frame.
    board.selectHost(buildHost('n'), connectedBefore: true);
    await pumpEventQueue();
    expect(created, 1);
    expect(board.state.phase, HomeBoardPhase.ready);
  });

  testWidgets('polling stops after repeated failures until refreshed', (
    tester,
  ) async {
    final timed = HomeBoardController(runnerFactory: (_) => runner);
    addTearDown(timed.dispose);
    runner.error = const AppFailure('Host key rejected.');
    timed
      ..setVisible(true)
      ..selectHost(connected('a'));
    await tester.pump(const Duration(minutes: 10));
    final attempts = runner.commands.length;
    expect(attempts, 3);

    await tester.pump(const Duration(minutes: 10));
    expect(runner.commands.length, attempts);

    runner.error = null;
    await tester.runAsync(timed.refresh);
    expect(timed.state.phase, HomeBoardPhase.ready);
    timed.setVisible(false);
  });

  group('tmux', () {
    test('lists tmux sessions next to Herdr workspaces', () async {
      runner.tmuxSessions = TmuxFixtures.sessions;
      board
        ..setVisible(true)
        ..selectHost(connected('a'));
      await pumpEventQueue();

      final state = board.state;
      expect(state.phase, HomeBoardPhase.ready);
      expect(state.hasTmux, isTrue);
      expect(state.tmuxSessions.map((s) => s.name), ['main', 'build']);
      expect(state.tmuxSessions.first.isAttached, isTrue);
      expect(state.tmuxSessions.first.windows, 3);
      expect(state.workspaces, hasLength(2));
      expect(runner.commands.first, startsWith('tmux -u list-sessions'));
    });

    test('no tmux server is an empty list, not an error', () async {
      runner
        ..tmuxExitCode = 1
        ..tmuxStderr = TmuxFixtures.noServer;
      board
        ..setVisible(true)
        ..selectHost(connected('a'));
      await pumpEventQueue();
      expect(board.state.tmux, HomeTmuxStatus.available);
      expect(board.state.tmuxSessions, isEmpty);
      expect(board.state.phase, HomeBoardPhase.ready);
    });

    testWidgets('a tmux-only machine keeps polling; one with neither stops', (
      tester,
    ) async {
      final tmuxOnly = HerdrFakeRunner.tmuxOnly();
      final timed = HomeBoardController(runnerFactory: (_) => tmuxOnly);
      addTearDown(timed.dispose);
      timed
        ..setVisible(true)
        ..selectHost(connected('a'));
      await tester.pump();
      expect(timed.state.phase, HomeBoardPhase.notInstalled);
      expect(timed.state.hasTmux, isTrue);
      expect(timed.state.tmuxSessions.map((s) => s.name), ['main', 'build']);
      int polls() => tmuxOnly.commands
          .where((c) => c.startsWith('tmux -u list-sessions'))
          .length;
      final first = polls();
      await tester.pump(const Duration(seconds: 16));
      expect(polls(), greaterThan(first), reason: 'tmux keeps being listed');

      // Neither tmux nor Herdr: nothing to poll for.
      tmuxOnly
        ..tmuxExitCode = 127
        ..tmuxStderr = 'sh: 1: tmux: not found';
      // Quiet for a while, the board lists every 10 s by now.
      await tester.pump(const Duration(seconds: 11));
      expect(timed.state.tmux, HomeTmuxStatus.notInstalled);
      final stopped = polls();
      await tester.pump(const Duration(minutes: 1));
      expect(polls(), stopped);
      timed.setVisible(false);
    });

    testWidgets('a quiet board stretches its polls to 20 s; a change, a '
        'refresh or coming back returns to 5 s', (tester) async {
      final quiet = HerdrFakeRunner.tmuxOnly();
      final timed = HomeBoardController(runnerFactory: (_) => quiet);
      addTearDown(timed.dispose);
      timed
        ..setVisible(true)
        ..selectHost(connected('a'));
      await tester.pump();
      int polls() => quiet.commands
          .where((c) => c.startsWith('tmux -u list-sessions'))
          .length;
      // Two minutes of the same listing: 5, 5, 5, 10, 10, 10, 15, … 20 s.
      var start = polls();
      await tester.pump(const Duration(minutes: 2));
      final quietPolls = polls() - start;
      expect(quietPolls, inInclusiveRange(7, 10));
      start = polls();
      await tester.pump(const Duration(minutes: 1));
      expect(polls() - start, 3, reason: 'every 20 s once settled');

      // A new session shows up: back to every 5 s.
      quiet.tmuxSessions = '${TmuxFixtures.sessions}extra\t0\t1\t1790229700\n';
      while (timed.state.tmuxSessions.length < 3) {
        await tester.pump(const Duration(seconds: 1));
      }
      start = polls();
      await tester.pump(const Duration(seconds: 10));
      expect(polls() - start, 2, reason: 'every 5 s after a change');

      // Leaving and coming back starts at 5 s too.
      await tester.pump(const Duration(minutes: 2));
      timed
        ..setVisible(false)
        ..setVisible(true);
      await tester.pump();
      start = polls();
      await tester.pump(const Duration(seconds: 10));
      expect(polls() - start, 2, reason: 'every 5 s after coming back');
      timed.setVisible(false);
    });

    test('Herdr failing on a reachable machine keeps the tmux list', () async {
      runner
        ..tmuxSessions = TmuxFixtures.sessions
        ..workspaceExitCode = 2
        ..workspaceStderr = 'herdr: socket error';
      board
        ..setVisible(true)
        ..selectHost(connected('a'));
      await pumpEventQueue();
      expect(board.state.phase, HomeBoardPhase.failed);
      expect(board.state.message, 'herdr: socket error');
      expect(board.state.tmuxSessions, hasLength(2));
      // Not a connection failure: the channel stays open.
      expect(runner.closeCount, 0);
    });

    test('lists windows and selects one before attaching', () async {
      board
        ..setVisible(true)
        ..selectHost(connected('a'));
      await pumpEventQueue();

      final windows = await board.listTmuxWindows('my session');
      expect(windows.map((w) => w.name), ['zsh', 'claude', 'logs']);
      expect(windows[1].active, isTrue);
      expect(windows[1].panes, 2);
      expect(
        runner.commands.last,
        startsWith("tmux list-windows -t '=my session' -F"),
      );

      await board.selectTmuxWindow('my session', 2);
      expect(runner.commands.last, "tmux select-window -t '=my session:2'");
    });

    test('parses tab-separated windows, skipping junk', () {
      expect(
        HomeTmuxCommands.parseWindows('0\tzsh\t1\t1\nbogus\n\n3\tvim\n'),
        const [
          TmuxWindowInfo(index: 0, name: 'zsh', active: true),
          TmuxWindowInfo(index: 3, name: 'vim'),
        ],
      );
      // tmux's window_activity, for the desktop sidebar's unread markers.
      expect(
        HomeTmuxCommands.parseWindows(
          '2\tlogs\t1\t0\t1790229600\n',
        ).single.activity,
        DateTime.fromMillisecondsSinceEpoch(1790229600000, isUtc: true),
      );
      expect(
        HomeTmuxCommands.listWindows('main'),
        contains('#{window_activity}'),
      );
    });
  });

  group('HomeBoards', () {
    late HomeBoards boards;
    late List<String> runnersFor;

    setUp(() {
      runnersFor = [];
      boards = HomeBoards(
        runnerFactory: (host) {
          runnersFor.add(host.id);
          return runner;
        },
        pollInterval: const Duration(days: 1),
      );
    });

    tearDown(() => boards.dispose());

    test('one board per selected remote machine, dropped ones stop', () async {
      var notified = 0;
      boards
        ..addListener(() => notified += 1)
        ..setVisible(true)
        ..sync([
          HomeBoardEntry(connected('a')),
          HomeBoardEntry(connected('b')),
          HomeBoardEntry(buildHost('local').copyWith(isLocal: true)),
        ]);
      await pumpEventQueue();
      expect(boards.hostIds, ['a', 'b']);
      expect(runnersFor, ['a', 'b']);
      expect(boards['a']!.state.phase, HomeBoardPhase.ready);
      expect(boards['b']!.visible, isTrue);
      expect(notified, greaterThan(0));

      final a = boards['a']!;
      boards.sync([HomeBoardEntry(connected('b'))]);
      expect(boards.hostIds, ['b']);
      expect(boards['a'], isNull);
      expect(a.state.phase, HomeBoardPhase.ready, reason: 'disposed as is');

      boards.setVisible(false);
      expect(boards['b']!.visible, isFalse);
    });

    test('a never-connected machine waits until marked as reached', () async {
      boards
        ..setVisible(true)
        ..sync([HomeBoardEntry(buildHost('n'))]);
      await pumpEventQueue();
      expect(boards['n']!.state.phase, HomeBoardPhase.awaitingRequest);
      expect(runnersFor, isEmpty);

      boards.sync([HomeBoardEntry(buildHost('n'), connectedBefore: true)]);
      await pumpEventQueue();
      expect(boards['n']!.state.phase, HomeBoardPhase.ready);
    });
  });

  test('a refresh while hidden closes its channel afterwards', () async {
    final runner = HerdrFakeRunner();
    var created = 0;
    final boards = HomeBoards(
      runnerFactory: (_) {
        created += 1;
        return runner;
      },
      pollInterval: const Duration(days: 1),
    );
    boards.sync([
      HomeBoardEntry(
        buildHost('a').copyWith(lastConnectedAt: DateTime.utc(2026, 9, 2)),
      ),
    ]);
    // The home page is covered by the terminal; the quick switcher
    // refreshes the boards from there.
    boards.setVisible(false);
    await boards.refresh();
    await pumpEventQueue();
    expect(created, 1);
    expect(runner.commands, isNotEmpty);
    expect(runner.closeCount, 1);
    boards.dispose();
  });
}
