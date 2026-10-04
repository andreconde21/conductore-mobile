import 'package:conduit/core/connection_problem.dart';
import 'package:conduit/core/theme/theme_controller.dart';
import 'package:conduit/features/agent_attention/data/herdr_attention_provider.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/app_lock/presentation/app_lock_controller.dart';
import 'package:conduit/features/backup/data/app_backup_service.dart';
import 'package:conduit/features/hosts/domain/home_preferences.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/hosts/presentation/home_board_controller.dart';
import 'package:conduit/features/hosts/presentation/hosts_controller.dart';
import 'package:conduit/features/hosts/presentation/hosts_page.dart';
import 'package:conduit/features/hosts/presentation/widgets/home_session_grid.dart';
import 'package:conduit/features/local_shell/presentation/local_shell_controller.dart';
import 'package:conduit/features/sessions/domain/connect_preferences.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/sessions/presentation/session_connect_flow.dart';
import 'package:conduit/features/terminal/domain/host_key_verifier.dart';
import 'package:conduit/features/terminal/presentation/host_key_prompt_coordinator.dart';
import 'package:conduit/features/terminal/presentation/terminal_page.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';
import 'home_board_fakes.dart';

void main() {
  late ThemeController themeController;
  late HerdrFakeRunner runner;
  late List<String> runnerHosts;
  late InMemoryHomePreferencesRepository preferences;

  setUp(() async {
    themeController = ThemeController(InMemoryThemePreferences());
    await themeController.load();
    runner = HerdrFakeRunner();
    runnerHosts = [];
    preferences = InMemoryHomePreferencesRepository();
  });

  SessionConnectFlow? flow;

  Future<(TerminalWorkspaceController, HomeBoards)> pumpHome(
    WidgetTester tester, {
    List<SavedHost> hosts = const [],
    bool withConnectFlow = false,
    HostKeyVerifier? hostKeyVerifier,
    Map<String, HerdrFakeRunner> runners = const {},
  }) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.6;
    addTearDown(tester.view.reset);

    final repository = FakeHostsRepository()..persisted = List.of(hosts);
    final hostsController = HostsController(repository);
    final workspace = TerminalWorkspaceController(
      ImmediateTerminalRepository(TrackableTerminalSession()),
    );
    addTearDown(workspace.dispose);
    final agentAttention = AgentAttentionController(
      workspace: workspace,
      runnerFactory: (_) => ScriptedAgentCommandRunner([
        StateError('no agent polling in this test'),
      ]),
      provider: const HerdrAttentionProvider(),
    );
    addTearDown(agentAttention.dispose);
    final boards = HomeBoards(
      runnerFactory: (host) {
        runnerHosts.add(host.id);
        return runners[host.id] ?? runner;
      },
      pollInterval: const Duration(days: 1),
    );
    addTearDown(boards.dispose);
    final verifier = hostKeyVerifier ?? NoopVerifier();
    flow = withConnectFlow
        ? SessionConnectFlow(
            hostsController: hostsController,
            workspace: workspace,
            runnerFactory: (host) => runners[host.id] ?? runner,
            preferences: InMemoryConnectPreferencesRepository(),
          )
        : null;

    await tester.pumpWidget(
      MaterialApp(
        home: HostsPage(
          hostsController: hostsController,
          lockController: AppLockController(AlwaysAuthenticates()),
          terminalRepository: NoNetworkTerminalRepository(),
          workspaceController: workspace,
          localShellController: LocalShellController(),
          themeController: themeController,
          hostKeyVerifier: verifier,
          promptCoordinator: HostKeyPromptCoordinator(),
          sftpRepository: NoNetworkSftpRepository(),
          sftpBookmarksRepository: InMemorySftpBookmarks(),
          agentAttention: agentAttention,
          backupService: AppBackupService(
            hostsController: hostsController,
            themeController: themeController,
            hostKeyVerifier: verifier,
          ),
          fileExport: RecordingFileExport(),
          homeBoards: boards,
          homePreferences: preferences,
          connectFlow: flow,
          previewRefreshInterval: const Duration(days: 1),
          paneRefocusDelay: const Duration(milliseconds: 50),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();
    return (workspace, boards);
  }

  SavedHost host(String id, {DateTime? lastConnectedAt}) {
    return buildHost(
      id,
    ).copyWith(lastConnectedAt: lastConnectedAt ?? DateTime.utc(2026));
  }

  Finder dormant(String id, {String host = 'a'}) =>
      find.byKey(ValueKey('other-herdr-$host-$id'));
  Finder otherTmux(String name, {String host = 'a'}) =>
      find.byKey(ValueKey('other-tmux-$host-$name'));

  testWidgets('no machines shows the add-machine flow and no board', (
    tester,
  ) async {
    await pumpHome(tester);

    expect(find.text('No saved machines yet'), findsOneWidget);
    expect(find.text('Add machine'), findsOneWidget);
    expect(find.byType(DormantWorkspaceTile), findsNothing);
    expect(find.byType(HomeBoardNoticeTile), findsNothing);
    expect(runnerHosts, isEmpty);
    // Lock sits in the bar; the gear opens the full Settings page with
    // every section (backup under Sync & Backup, trusted keys and "Lock
    // now" under Security).
    expect(find.byTooltip('Lock'), findsOneWidget);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);
    for (final title in [
      'Appearance',
      'Terminal',
      'Input',
      'Chat & Voice',
      'Agents',
      'Sync & Backup',
      'Security',
      'About',
    ]) {
      expect(find.text(title), findsOneWidget, reason: title);
    }
    await tester.tap(find.text('Security'));
    await tester.pumpAndSettle();
    expect(find.text('Trusted host keys'), findsOneWidget);
    expect(find.text('Lock now'), findsOneWidget);
  });

  testWidgets('one machine: Herdr workspaces show as dormant tiles', (
    tester,
  ) async {
    await pumpHome(tester, hosts: [host('a')]);

    expect(
      tester.widget<Text>(find.byKey(const ValueKey('machine-name'))).data,
      'All machines',
    );
    expect(runnerHosts, ['a']);
    expect(find.text('SESSIONS'), findsOneWidget);
    expect(find.text('none open'), findsOneWidget);
    expect(find.byKey(const ValueKey('home-add-tile')), findsOneWidget);
    expect(find.byType(HomeBoardNoticeTile), findsNothing);

    expect(dormant('w1'), findsOneWidget);
    expect(dormant('w2'), findsOneWidget);
    expect(
      find.descendant(of: dormant('w1'), matching: find.text('Infrastructure')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: dormant('w1'),
        matching: find.text('2 agents · 2 tabs'),
      ),
      findsOneWidget,
    );
    for (final chip in ['Needs input', 'Working']) {
      expect(
        find.descendant(of: dormant('w1'), matching: find.text(chip)),
        findsOneWidget,
        reason: chip,
      );
    }
    expect(
      find.descendant(of: dormant('w2'), matching: find.text('Done')),
      findsOneWidget,
    );
    expect(find.text('OTHER WORKSPACES'), findsOneWidget);
    expect(find.text('2 not open'), findsOneWidget);
    // The official Herdr logo marks them.
    expect(
      find.descendant(
        of: dormant('w1'),
        matching: find.byKey(const ValueKey('multiplexer-icon-herdr')),
      ),
      findsOneWidget,
    );
    // No counters and no "More" area any more.
    expect(find.text('MORE'), findsNothing);
    expect(find.text('Live sessions'), findsNothing);
    expect(find.text('Saved'), findsNothing);
  });

  testWidgets('tapping a dormant workspace opens it', (tester) async {
    final (workspace, boards) = await pumpHome(tester, hosts: [host('a')]);

    await tester.tap(dormant('w1'));
    await tester.pump();
    await tester.pump();

    final session = workspace.sessions.single;
    expect(session.host.id, 'a#herdr:w1');
    expect(session.host.name, 'Host a: Infrastructure');
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.byType(TerminalPage), findsOneWidget);
    // Covered by the terminal: polling stops and the channel is closed.
    expect(boards.visible, isFalse);
    expect(boards['a']!.visible, isFalse);
    expect(runner.closeCount, greaterThanOrEqualTo(1));

    // Back home: the board resumes, and the workspace is now a live tile.
    final polls = runner.commands.where((c) => c.contains('workspace list'));
    final before = polls.length;
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(boards['a']!.visible, isTrue);
    expect(
      runner.commands.where((c) => c.contains('workspace list')).length,
      greaterThan(before),
    );
    expect(find.byType(HomeSessionTile), findsOneWidget);
    expect(dormant('w1'), findsNothing);
    expect(dormant('w2'), findsOneWidget);
  });

  testWidgets('long-pressing a dormant workspace opens one of its panes', (
    tester,
  ) async {
    final (workspace, _) = await pumpHome(tester, hosts: [host('a')]);

    await tester.longPress(dormant('w1'));
    await tester.pumpAndSettle();
    expect(find.text('main › claude'), findsOneWidget);
    expect(find.text('review › claude'), findsOneWidget);
    await tester.tap(find.text('Proofing PR 398'));
    await tester.pump();
    await tester.pump();

    expect(
      runner.commands.where((c) => c.contains('agent focus w1:p2')),
      hasLength(1),
    );
    expect(workspace.sessions.single.host.id, 'a#herdr:w1');
    await tester.pump(const Duration(seconds: 1));
    // The pane is focused again once the new client has attached.
    await tester.pump(const Duration(milliseconds: 60));
    expect(
      runner.commands.where((c) => c.contains('agent focus w1:p2')),
      hasLength(2),
    );
  });

  testWidgets('with the connect flow a pane opens at its exact place', (
    tester,
  ) async {
    final (workspace, _) = await pumpHome(
      tester,
      hosts: [host('a')],
      withConnectFlow: true,
    );

    await tester.longPress(dormant('w1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Proofing PR 398'));
    await tester.pump();
    await tester.pump();

    final session = workspace.sessions.single;
    expect(session.host.id, 'a#herdr:w1');
    // The attach command focuses the agent's pane before attaching, so the
    // new client lands on it (Herdr's focus is per server).
    expect(session.startupCommand, contains('herdr agent focus w1:p2'));
    expect(session.startupCommand, endsWith('; herdr'));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(TerminalPage), findsOneWidget);
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pump(const Duration(seconds: 1));
    await flow!.herdr.dispose();
  });

  testWidgets('a session opened by Herdr workspace id takes the live label '
      'in every title (CON-071)', (tester) async {
    final (workspace, _) = await pumpHome(tester, hosts: [host('a')]);
    final herdr = workspace.open(
      const ConnectTarget.herdr(workspaceId: 'w1').apply(host('a')),
    );
    // Named after the raw id when opened...
    expect(herdr.host.name, endsWith(': w1'));
    await tester.pump();
    await tester.pump();
    // The home board knows w1 as "Infrastructure": the tile, the tabs and
    // the switcher (all of which read the session's title) say so.
    expect(herdr.title, endsWith(': Infrastructure'));
    final tile = find.byKey(const ValueKey('home-session-a#herdr:w1'));
    expect(find.descendant(of: tile, matching: find.text('w1')), findsNothing);
    expect(
      find.descendant(of: tile, matching: find.text('Infrastructure')),
      findsWidgets,
    );
  });

  testWidgets('open sessions show as live tiles with transport and '
      'workspace', (tester) async {
    final (workspace, _) = await pumpHome(
      tester,
      hosts: [host('a'), host('m').copyWith(useMosh: true)],
    );
    workspace.open(host('m').copyWith(useMosh: true));
    // Opened last, so the page shows its machine.
    final herdr = workspace.open(
      const ConnectTarget.herdr(
        workspaceId: 'w1',
        label: 'Infrastructure',
      ).apply(host('a')),
    );
    herdr.terminal.write('\x1b[32mclaude\x1b[0m is working on it');
    await tester.pump();

    expect(find.byType(HomeSessionTile), findsNWidgets(2));
    expect(find.text('2 open'), findsOneWidget);
    final herdrTile = find.byKey(const ValueKey('home-session-a#herdr:w1'));
    expect(
      find.descendant(of: herdrTile, matching: find.text('SSH')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: herdrTile, matching: find.text('Infrastructure')),
      findsNWidgets(2),
    );
    expect(
      find.descendant(
        of: herdrTile,
        matching: find.byKey(const ValueKey('multiplexer-icon-herdr')),
      ),
      findsOneWidget,
    );
    // Its workspace has an agent waiting: the tile says so prominently.
    expect(
      find.descendant(
        of: herdrTile,
        matching: find.byKey(const ValueKey('agent-state-banner')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: herdrTile, matching: find.text('Needs input')),
      findsOneWidget,
    );
    // The live preview renders the screen, colours included.
    final preview = tester.widget<RichText>(
      find.descendant(
        of: herdrTile,
        matching: find.byKey(const ValueKey('live-preview-text')),
      ),
    );
    expect(preview.text.toPlainText(), contains('claude is working on it'));
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('home-session-m')),
        matching: find.text('Mosh'),
      ),
      findsOneWidget,
    );
    // The attached workspace is no longer dormant.
    expect(dormant('w1'), findsNothing);
    expect(dormant('w2'), findsOneWidget);

    final mosh = workspace.sessions.first;
    await tester.tap(find.byKey(const ValueKey('home-session-m')));
    await tester.pump();
    expect(workspace.activeSession, mosh);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(TerminalPage), findsOneWidget);
  });

  testWidgets('long-press on a tile renames, reconnects or closes', (
    tester,
  ) async {
    final (workspace, _) = await pumpHome(tester, hosts: [host('a')]);
    final session = workspace.open(host('a'));
    await tester.pump();
    final tile = find.byKey(const ValueKey('home-session-a'));

    await tester.longPress(tile);
    await tester.pumpAndSettle();
    expect(find.text('Reconnect'), findsOneWidget);
    expect(find.text('Close session'), findsOneWidget);
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Deploys');
    await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
    await tester.pumpAndSettle();
    expect(session.title, 'Deploys');
    expect(
      find.descendant(of: tile, matching: find.text('Deploys')),
      findsWidgets,
    );

    await tester.longPress(tile);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close session'));
    await tester.pumpAndSettle();
    expect(workspace.sessions, isEmpty);
    expect(find.byType(HomeSessionTile), findsNothing);
  });

  testWidgets('the machine filter shows all machines by default, narrows '
      'sessions and workspaces, and is remembered', (tester) async {
    final hosts = [
      host('a', lastConnectedAt: DateTime.utc(2026, 9, 2)),
      host('b', lastConnectedAt: DateTime.utc(2026, 9, 20)),
      host('c'),
    ];
    final (workspace, boards) = await pumpHome(tester, hosts: hosts);
    workspace
      ..open(host('a'))
      ..open(host('b'));
    await tester.pump();
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('machine-name'))).data,
      'All machines',
    );
    // Every machine is listed, grouped by machine.
    expect(boards.hostIds.toSet(), {'a', 'b', 'c'});
    expect(runnerHosts.toSet(), {'a', 'b', 'c'});
    expect(find.byKey(const ValueKey('other-group-b')), findsOneWidget);
    expect(find.byType(HomeSessionTile), findsNWidgets(2));
    // No machine menu in the bar any more: it lives in the sheet.
    expect(find.byTooltip('Machine actions'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('machine-chip')));
    await tester.pumpAndSettle();
    expect(find.text('Machines'), findsOneWidget);
    expect(find.text('Add machine'), findsOneWidget);
    final all = tester.widget<Checkbox>(
      find.descendant(
        of: find.byKey(const ValueKey('machine-filter-all')),
        matching: find.byType(Checkbox),
      ),
    );
    expect(all.value, isTrue);

    // Pick b and c: the page follows as the boxes change.
    await tester.tap(find.byKey(const ValueKey('machine-row-b')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('machine-row-c')));
    await tester.pump();
    expect(preferences.stored.machineFilter, {'b', 'c'});
    expect(boards.hostIds.toSet(), {'b', 'c'});
    Navigator.of(tester.element(find.text('Machines'))).pop();
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('machine-name'))).data,
      'Host b, Host c',
    );
    expect(find.byType(HomeSessionTile), findsOneWidget);
    expect(find.byKey(const ValueKey('home-session-b')), findsOneWidget);
    expect(find.byKey(const ValueKey('home-session-a')), findsNothing);
    expect(dormant('w1'), findsNothing);
    expect(dormant('w1', host: 'b'), findsOneWidget);

    // Long-press a row to show only that machine.
    await tester.tap(find.byKey(const ValueKey('machine-chip')));
    await tester.pumpAndSettle();
    await tester.longPress(find.byKey(const ValueKey('machine-row-a')));
    await tester.pump();
    expect(preferences.stored.machineFilter, {'a'});
    // "All machines" clears the filter.
    await tester.tap(find.byKey(const ValueKey('machine-filter-all')));
    await tester.pump();
    expect(preferences.stored.machineFilter, isEmpty);
    await tester.longPress(find.byKey(const ValueKey('machine-row-c')));
    await tester.pumpAndSettle();
  });

  testWidgets('a remembered filter applies on start', (tester) async {
    preferences.stored = const HomePreferences(machineFilter: {'b', 'gone'});
    final (_, boards) = await pumpHome(tester, hosts: [host('a'), host('b')]);
    await tester.pump();
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('machine-name'))).data,
      'Host b',
    );
    expect(boards.hostIds, ['b']);
    expect(dormant('w1', host: 'b'), findsOneWidget);
    expect(dormant('w1'), findsNothing);
  });

  testWidgets('hardware-key machines list workspaces only on request', (
    tester,
  ) async {
    await pumpHome(
      tester,
      hosts: [host('k').copyWith(authMethod: SshAuthMethod.hardwareKey)],
    );
    expect(find.text('Hardware-key login'), findsOneWidget);
    expect(runnerHosts, isEmpty);

    await tester.tap(find.text('List workspaces'));
    await tester.pump();
    await tester.pump();
    expect(runnerHosts, ['k']);
    expect(dormant('w1', host: 'k'), findsOneWidget);
    expect(find.byType(HomeBoardNoticeTile), findsNothing);
  });

  testWidgets('Herdr not running shows a notice that starts it', (
    tester,
  ) async {
    runner
      ..workspaces = HerdrFixtures.notRunning
      ..workspaceExitCode = 1;
    final (workspace, _) = await pumpHome(tester, hosts: [host('a')]);
    expect(find.byType(HomeBoardNoticeTile), findsOneWidget);
    expect(find.text('Herdr is not running'), findsOneWidget);

    await tester.tap(find.text('Start Herdr'));
    await tester.pump();
    expect(workspace.sessions.single.host.id, 'a#herdr');
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('a listing failure shows its reason and retries', (tester) async {
    runner.error = StateError('connection refused');
    await pumpHome(tester, hosts: [host('a')]);
    expect(find.text('Could not list workspaces'), findsOneWidget);
    expect(find.textContaining('connection refused'), findsOneWidget);

    runner.error = null;
    await tester.tap(find.text('Retry'));
    await tester.pump();
    await tester.pump();
    expect(find.byType(HomeBoardNoticeTile), findsNothing);
    expect(dormant('w1'), findsOneWidget);
  });

  testWidgets('an unreachable Tailscale machine says to check Tailscale', (
    tester,
  ) async {
    runner.error = const ConnectionFailure(
      'Could not reach Host a.',
      'SocketException: Connection timed out (OS Error: Connection timed '
          'out, errno = 110), address = 100.106.7.32, port = 22',
      kind: ConnectionProblemKind.unreachable,
    );
    await pumpHome(tester, hosts: [host('a').copyWith(host: '100.106.7.32')]);
    expect(find.text("Can't reach Host a"), findsOneWidget);
    expect(
      find.text(
        'This machine is on your Tailscale network. Check that Tailscale '
        'is on, then tap Retry.',
      ),
      findsOneWidget,
    );
    expect(find.text('Could not list workspaces'), findsNothing);
    // The technical reason waits behind Details.
    expect(find.textContaining('errno = 110'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('home-board-notice-details')));
    await tester.pump();
    expect(find.textContaining('errno = 110'), findsOneWidget);

    runner.error = null;
    await tester.tap(find.text('Retry'));
    await tester.pump();
    await tester.pump();
    expect(find.byType(HomeBoardNoticeTile), findsNothing);
    expect(dormant('w1'), findsOneWidget);
  });

  testWidgets('each machine row in the sheet has the machine menu', (
    tester,
  ) async {
    await pumpHome(tester, hosts: [host('a')]);

    await tester.tap(find.byKey(const ValueKey('machine-chip')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('machine-menu-a')));
    await tester.pumpAndSettle();
    for (final label in [
      'Connect to…',
      'Files',
      'Edit',
      'Agent hooks',
      'Duplicate',
      'Copy address',
      'Delete',
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
  });

  testWidgets('the local shell lives in the machine sheet', (tester) async {
    await pumpHome(tester, hosts: [host('a')]);
    await tester.tap(find.byKey(const ValueKey('machine-chip')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('machine-filter-local')), findsOneWidget);
    expect(find.text('This device'), findsOneWidget);
  });

  testWidgets('a never-connected machine lists workspaces only on request', (
    tester,
  ) async {
    await pumpHome(tester, hosts: [buildHost('n')]);
    expect(find.text('Not connected yet'), findsOneWidget);
    expect(runnerHosts, isEmpty);

    await tester.tap(find.text('List workspaces'));
    await tester.pump();
    await tester.pump();
    expect(runnerHosts, ['n']);
    expect(dormant('w1', host: 'n'), findsOneWidget);
  });

  testWidgets('a machine with a trusted host key lists on its own', (
    tester,
  ) async {
    await pumpHome(
      tester,
      hosts: [buildHost('n')],
      hostKeyVerifier: _TrustedVerifier('192.168.1.1', 22),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Not connected yet'), findsNothing);
    expect(runnerHosts, ['n']);
    expect(dormant('w1', host: 'n'), findsOneWidget);
  });

  testWidgets('the bottom of the page clears the 3-button navigation bar', (
    tester,
  ) async {
    // Galaxy M53 with 3-button navigation: a 48 dp bar at 2.6 px/dp.
    tester.view.padding = const FakeViewPadding(bottom: 125);
    tester.view.viewPadding = const FakeViewPadding(bottom: 125);
    runner.tmuxSessions = TmuxFixtures.sessions;
    await pumpHome(tester, hosts: [host('a')]);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);

    await tester.drag(
      find.byKey(const ValueKey('home-scroll')),
      const Offset(0, -3000),
    );
    await tester.pumpAndSettle();
    final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    final navBar = 125 / tester.view.devicePixelRatio;
    // Nothing scrolls under the buttons: the list ends above the bar.
    final list = tester.getRect(find.byKey(const ValueKey('home-scroll')));
    expect(list.bottom, lessThanOrEqualTo(screen.height - navBar + 0.01));
    // The last workspace tile is fully above it.
    final last = tester.getRect(otherTmux('build'));
    expect(last.bottom, lessThan(screen.height - navBar));
  });

  group('tmux-only machine', () {
    late HerdrFakeRunner tmuxOnly;

    setUp(() => tmuxOnly = HerdrFakeRunner.tmuxOnly());

    testWidgets('lists its other tmux sessions and labels open ones', (
      tester,
    ) async {
      final (workspace, _) = await pumpHome(
        tester,
        hosts: [host('t')],
        runners: {'t': tmuxOnly},
      );
      workspace.open(const ConnectTarget.tmux('main').apply(host('t')));
      await tester.pump();

      // The open session is labelled with its tmux session and logo.
      final tile = find.byKey(const ValueKey('home-session-t#tmux:main'));
      expect(
        find.descendant(of: tile, matching: find.text('main')),
        findsNWidgets(2),
      );
      expect(
        find.descendant(
          of: tile,
          matching: find.byKey(const ValueKey('multiplexer-icon-tmux')),
        ),
        findsOneWidget,
      );
      // Only the session that is not open is offered; no Herdr notice.
      expect(otherTmux('build', host: 't'), findsOneWidget);
      expect(otherTmux('main', host: 't'), findsNothing);
      expect(find.text('1 not open'), findsOneWidget);
      expect(find.byType(HomeBoardNoticeTile), findsNothing);
      expect(find.byType(DormantWorkspaceTile), findsNothing);
      expect(find.textContaining('Herdr'), findsNothing);

      await tester.tap(otherTmux('build', host: 't'));
      await tester.pump();
      expect(
        workspace.sessions.map((s) => s.host.id),
        contains('t#tmux:build'),
      );
      final opened = workspace.sessions.last;
      expect(opened.host.startTmuxOnConnect, isTrue);
      expect(opened.host.tmuxSessionName, 'build');
      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('long-press opens a tmux session at a window', (tester) async {
      final (workspace, _) = await pumpHome(
        tester,
        hosts: [host('t')],
        runners: {'t': tmuxOnly},
      );
      await tester.longPress(otherTmux('main', host: 't'));
      await tester.pumpAndSettle();
      expect(find.text('Open the session at a window'), findsOneWidget);
      expect(find.text('claude'), findsOneWidget);
      expect(find.text('current'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('tmux-window-2')));
      await tester.pump();
      await tester.pump();
      expect(
        tmuxOnly.commands,
        contains('tmux select-window -t =main:2'),
        reason: tmuxOnly.commands.join('\n'),
      );
      expect(workspace.sessions.single.host.id, 't#tmux:main');
      await tester.pump(const Duration(milliseconds: 400));
    });

    testWidgets('a machine that starts tmux on connect counts its session '
        'as open', (tester) async {
      final machine = host(
        't',
      ).copyWith(startTmuxOnConnect: true, tmuxSessionName: 'main');
      final (workspace, _) = await pumpHome(
        tester,
        hosts: [machine],
        runners: {'t': tmuxOnly},
      );
      workspace.open(machine);
      await tester.pump();
      final tile = find.byKey(const ValueKey('home-session-t'));
      expect(
        find.descendant(of: tile, matching: find.text('main')),
        findsOneWidget,
      );
      expect(otherTmux('main', host: 't'), findsNothing);
      expect(otherTmux('build', host: 't'), findsOneWidget);
    });

    testWidgets('no tmux and no Herdr says so', (tester) async {
      tmuxOnly
        ..tmuxExitCode = 127
        ..tmuxStderr = 'sh: 1: tmux: not found';
      await pumpHome(tester, hosts: [host('t')], runners: {'t': tmuxOnly});
      expect(find.text('No tmux or Herdr here'), findsOneWidget);
    });
  });

  testWidgets('Herdr and tmux side by side on one machine', (tester) async {
    runner.tmuxSessions = TmuxFixtures.sessions;
    await pumpHome(tester, hosts: [host('a')]);
    expect(dormant('w1'), findsOneWidget);
    expect(otherTmux('main'), findsOneWidget);
    expect(otherTmux('build'), findsOneWidget);
    expect(find.text('4 not open'), findsOneWidget);
  });

  testWidgets('sessions and workspaces switch between grid and list, and the '
      'choice is remembered', (tester) async {
    runner.tmuxSessions = TmuxFixtures.sessions;
    final (workspace, _) = await pumpHome(tester, hosts: [host('a')]);
    workspace.open(
      const ConnectTarget.herdr(
        workspaceId: 'w1',
        label: 'Infrastructure',
      ).apply(host('a')),
    );
    await tester.pump();
    expect(find.byType(HomeSessionTile), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('sessions-view-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('List').last);
    await tester.pumpAndSettle();
    expect(preferences.stored.sessionsView, HomeSessionsView.list);
    expect(find.byType(HomeSessionTile), findsNothing);
    final row = find.byKey(const ValueKey('home-session-a#herdr:w1'));
    expect(tester.widget(row), isA<HomeSessionRow>());
    // Agent status is on the row too.
    expect(
      find.descendant(of: row, matching: find.text('Needs input')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: row, matching: find.text('Host a')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('workspaces-view-toggle')));
    await tester.pump();
    expect(preferences.stored.workspacesView, HomeWorkspacesView.list);
    expect(find.byType(OtherWorkspaceRow), findsNWidgets(3));
    expect(find.byType(DormantTmuxTile), findsNothing);
  });

  testWidgets('remembered list views apply on start', (tester) async {
    preferences.stored = const HomePreferences(
      sessionsView: HomeSessionsView.list,
      workspacesView: HomeWorkspacesView.list,
    );
    runner.tmuxSessions = TmuxFixtures.sessions;
    final (workspace, _) = await pumpHome(tester, hosts: [host('a')]);
    workspace.open(host('a'));
    await tester.pump();
    expect(find.byType(HomeSessionRow), findsOneWidget);
    expect(find.byType(OtherWorkspaceRow), findsNWidgets(4));
  });

  testWidgets('"+" asks which machine when several are shown', (tester) async {
    await pumpHome(tester, hosts: [host('a'), host('b')]);
    await tester.tap(find.byTooltip('New session'));
    await tester.pumpAndSettle();
    expect(find.text('New session on'), findsOneWidget);
    expect(find.byKey(const ValueKey('new-session-a')), findsOneWidget);
    expect(find.byKey(const ValueKey('new-session-b')), findsOneWidget);
  });

  testWidgets('the machine sheet ends above the 3-button navigation bar', (
    tester,
  ) async {
    tester.view.padding = const FakeViewPadding(bottom: 125);
    tester.view.viewPadding = const FakeViewPadding(bottom: 125);
    await pumpHome(
      tester,
      hosts: [
        for (final id in ['a', 'b', 'c', 'd', 'e', 'f']) host(id),
      ],
    );
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    await tester.tap(find.byKey(const ValueKey('machine-chip')));
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const ValueKey('machine-sheet')),
      const Offset(0, -2000),
    );
    await tester.pumpAndSettle();
    final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    final navBar = 125 / tester.view.devicePixelRatio;
    final last = tester.getRect(
      find.byKey(const ValueKey('machine-filter-local')),
    );
    expect(last.bottom, lessThan(screen.height - navBar));
  });

  testWidgets('with every machine shown, never-connected ones stay quiet '
      'until picked', (tester) async {
    await pumpHome(tester, hosts: [host('a'), buildHost('n')]);
    expect(find.text('Not connected yet'), findsNothing);
    expect(runnerHosts, ['a']);

    await tester.tap(find.byKey(const ValueKey('machine-chip')));
    await tester.pumpAndSettle();
    await tester.longPress(find.byKey(const ValueKey('machine-row-n')));
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.text('Machines'))).pop();
    await tester.pumpAndSettle();
    expect(find.text('Not connected yet'), findsOneWidget);
    expect(runnerHosts, ['a']);
  });
}

class _TrustedVerifier extends NoopVerifier {
  _TrustedVerifier(this.host, this.port);

  final String host;
  final int port;

  @override
  Future<List<HostKeyRecord>> loadTrustedKeys() async => [
    HostKeyRecord(
      host: host,
      port: port,
      type: 'ssh-ed25519',
      fingerprint: 'SHA256:test',
      trustedAt: DateTime.utc(2026),
    ),
  ];
}
