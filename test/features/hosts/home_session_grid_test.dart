import 'package:conduit/core/connection_problem.dart';
import 'package:conduit/core/presentation/multiplexer_icon.dart';
import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/hosts/presentation/home_board_controller.dart';
import 'package:conduit/features/hosts/presentation/widgets/home_session_grid.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/sessions/domain/remote_session_listing.dart';
import 'package:conduit/features/sessions/presentation/terminal_preview.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

HomeBoardWorkspace workspace(
  String id,
  String label, {
  List<AgentAttentionState> states = const [],
  String status = '',
  int tabs = 0,
}) {
  return HomeBoardWorkspace(
    workspace: HerdrWorkspaceInfo(
      id: id,
      label: label,
      agentStatus: status,
      tabCount: tabs,
    ),
    panes: [
      for (var index = 0; index < states.length; index++)
        HomeBoardPane(
          agent: AgentInfo(
            id: '$id:p$index',
            name: 'agent $index',
            state: states[index],
            workspace: id,
            pane: '$id:p$index',
          ),
        ),
    ],
  );
}

void main() {
  final palette = AppPalette.values.first;

  Widget host(Widget child, {double width = 190, double height = 290}) =>
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(width: width, height: height, child: child),
          ),
        ),
      );

  TerminalSessionController session(SavedHostBuilder build) {
    final controller = TerminalSessionController(
      host: build(),
      repository: ImmediateTerminalRepository(TrackableTerminalSession()),
    );
    addTearDown(controller.dispose);
    return controller;
  }

  group('HomeGridMetrics', () {
    test('two large 4:5 columns on a Galaxy M53', () {
      // 1080 px at 2.625 px/dp.
      final metrics = HomeGridMetrics.of(1080 / 2.625);
      expect(metrics.columns, 2);
      expect(metrics.tileWidth, closeTo(183.7, 0.5));
      expect(
        metrics.sessionExtent,
        closeTo(metrics.tileWidth * 1.25 + HomeGridMetrics.labelHeight, 0.01),
      );
      expect(HomeGridMetrics.of(1080 / 2.625, large: true).columns, 1);
      expect(HomeGridMetrics.of(700).columns, 3);
    });
  });

  group('HomeSessionInfo', () {
    test('uses the live Herdr workspace name and state', () {
      final herdr = session(
        () => const ConnectTarget.herdr(
          workspaceId: 'w1',
          label: 'Old name',
        ).apply(buildHost('a')),
      );
      final info = HomeSessionInfo.of(
        herdr,
        workspaces: [
          workspace(
            'w1',
            'Infrastructure',
            states: [
              AgentAttentionState.working,
              AgentAttentionState.needsInput,
            ],
          ),
        ],
      );
      expect(info.isHerdr, isTrue);
      expect(info.targetLabel, 'Infrastructure');
      expect(info.agentState, AgentAttentionState.needsInput);

      // Without the board the name baked into the title is used.
      expect(HomeSessionInfo.of(herdr).targetLabel, 'Old name');
      expect(HomeSessionInfo.of(session(() => buildHost('p'))).targetLabel, '');
    });

    test('labels tmux sessions, including tmux-on-connect machines', () {
      final target = session(
        () => const ConnectTarget.tmux('build').apply(buildHost('t')),
      );
      final targetInfo = HomeSessionInfo.of(target, machineName: 'Box');
      expect(targetInfo.multiplexer, MultiplexerKind.tmux);
      expect(targetInfo.targetLabel, 'build');
      expect(targetInfo.machineName, 'Box');
      expect(HomeSessionInfo.tmuxSessionOf(target), 'build');

      final onConnect = session(
        () => buildHost(
          't',
        ).copyWith(startTmuxOnConnect: true, tmuxSessionName: 'main'),
      );
      final info = HomeSessionInfo.of(onConnect);
      expect(info.multiplexer, MultiplexerKind.tmux);
      expect(info.targetLabel, 'main');
      expect(HomeSessionInfo.tmuxSessionOf(onConnect), 'main');

      final plain = session(() => buildHost('p'));
      expect(HomeSessionInfo.of(plain).multiplexer, isNull);
      expect(HomeSessionInfo.tmuxSessionOf(plain), isNull);
    });
  });

  group('HomeSessionRow', () {
    testWidgets('shows status, transport, target, machine, agent and tail', (
      tester,
    ) async {
      final tmux = session(
        () => const ConnectTarget.tmux('build').apply(buildHost('t')),
      );
      tmux.terminal.write('first line\r\n\$ make deploy\r\n');
      await tester.pumpWidget(
        host(
          HomeSessionRow(
            session: tmux,
            info: HomeSessionInfo.of(
              tmux,
              agentState: AgentAttentionState.working,
              machineName: 'Build box',
            ),
            palette: palette,
            brightness: Brightness.dark,
            fontFamily: 'monospace',
            onTap: () {},
            onLongPress: () {},
          ),
          width: 360,
          height: 90,
        ),
      );
      expect(find.text('SSH'), findsOneWidget);
      expect(find.text('build'), findsOneWidget);
      expect(find.text('Build box'), findsOneWidget);
      expect(find.text('Working'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('multiplexer-icon-tmux')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('home-row-dot')), findsOneWidget);
      // Not connected yet: the tail says so instead of an empty line.
      expect(find.text('Not connected'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    test('the tail is the last non-blank line on screen', () {
      final plain = session(() => buildHost('p'));
      plain.terminal.write('one\r\ntwo\r\n\r\n');
      expect(HomeSessionRow.tailOf(plain), 'two');
    });
  });

  group('DormantTmuxTile', () {
    testWidgets('names the session, counts windows, marks attached', (
      tester,
    ) async {
      var opened = 0;
      await tester.pumpWidget(
        host(
          DormantTmuxTile(
            session: const TmuxSessionInfo(
              name: 'main',
              attachedClients: 1,
              windows: 3,
            ),
            palette: palette,
            brightness: Brightness.dark,
            onTap: () => opened += 1,
          ),
          height: 118,
        ),
      );
      expect(find.text('main'), findsOneWidget);
      expect(find.text('3 windows'), findsOneWidget);
      expect(find.text('Attached elsewhere'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('multiplexer-icon-tmux')),
        findsOneWidget,
      );
      await tester.tap(find.text('main'));
      expect(opened, 1);
      expect(tester.takeException(), isNull);
    });

    test('details read windows and last activity', () {
      final now = DateTime.utc(2026, 9, 25, 12);
      expect(
        tmuxDetails(
          TmuxSessionInfo(
            name: 'x',
            lastActivity: now.subtract(const Duration(minutes: 5)),
          ),
          now: now,
        ),
        '1 window · active 5m ago',
      );
    });
  });

  group('HomeSessionTile', () {
    testWidgets('shows badge, title, workspace and agent state', (
      tester,
    ) async {
      final herdr = session(
        () => const ConnectTarget.herdr(
          workspaceId: 'w1',
          label: 'DTech',
        ).apply(buildHost('a').copyWith(useMosh: true)),
      );
      herdr.terminal.write('hello from herdr');
      var taps = 0;
      var longPresses = 0;
      await tester.pumpWidget(
        host(
          HomeSessionTile(
            session: herdr,
            info: HomeSessionInfo.of(
              herdr,
              agentState: AgentAttentionState.needsInput,
            ),
            palette: palette,
            brightness: Brightness.dark,
            fontFamily: 'monospace',
            onTap: () => taps += 1,
            onLongPress: () => longPresses += 1,
          ),
        ),
      );

      expect(find.text('Mosh'), findsOneWidget);
      // Titled by the workspace (over the preview and below it), the
      // machine only as a small caption (CON-071).
      expect(find.text('DTech'), findsNWidgets(2));
      expect(find.text('Host a: DTech'), findsNothing);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('home-machine-caption')))
            .data,
        'Host a',
      );
      expect(
        find.byKey(const ValueKey('multiplexer-icon-herdr')),
        findsOneWidget,
      );
      // The agent state is a banner over the preview, not a small chip.
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('agent-state-banner')),
          matching: find.text('Needs input'),
        ),
        findsOneWidget,
      );
      final dot = tester.widget<Container>(
        find.byKey(const ValueKey('home-tile-dot')),
      );
      expect(
        (dot.decoration! as BoxDecoration).color,
        AppPalette.defaultPalette.attention,
      );
      final text = tester.widget<RichText>(
        find.byKey(const ValueKey('live-preview-text')),
      );
      expect(text.text.toPlainText(), contains('hello from herdr'));

      await tester.tap(find.byType(InkWell));
      await tester.longPress(find.byType(InkWell));
      expect((taps, longPresses), (1, 1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('an idle session says so and shows SSH', (tester) async {
      final plain = session(() => buildHost('p'));
      await tester.pumpWidget(
        host(
          HomeSessionTile(
            session: plain,
            info: HomeSessionInfo.of(plain),
            palette: palette,
            brightness: Brightness.dark,
            fontFamily: 'monospace',
            onTap: () {},
            onLongPress: () {},
          ),
        ),
      );
      expect(find.text('SSH'), findsOneWidget);
      expect(find.text('Not connected'), findsOneWidget);
      expect(find.text(plain.host.endpoint), findsOneWidget);
    });
  });

  group('DormantWorkspaceTile', () {
    testWidgets('names the workspace and counts its agents by state', (
      tester,
    ) async {
      var opened = 0;
      await tester.pumpWidget(
        host(
          DormantWorkspaceTile(
            workspace: workspace(
              'w3',
              'TheCalendar',
              tabs: 3,
              states: [
                AgentAttentionState.working,
                AgentAttentionState.working,
                AgentAttentionState.needsInput,
              ],
            ),
            palette: palette,
            brightness: Brightness.dark,
            onTap: () => opened += 1,
          ),
          height: 118,
        ),
      );
      expect(find.text('TheCalendar'), findsOneWidget);
      expect(find.text('3 agents · 3 tabs'), findsOneWidget);
      expect(find.text('Needs input'), findsOneWidget);
      expect(find.text('Working ×2'), findsOneWidget);
      await tester.tap(find.text('TheCalendar'));
      expect(opened, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('falls back to Herdr\'s workspace status', (tester) async {
      await tester.pumpWidget(
        host(
          DormantWorkspaceTile(
            workspace: workspace('w4', 'Quiet', status: 'done'),
            palette: palette,
            brightness: Brightness.dark,
            onTap: () {},
          ),
          height: 118,
        ),
      );
      expect(find.text('Not open in the app'), findsOneWidget);
      expect(find.text('Done'), findsOneWidget);
    });
  });

  group('HomeBoardNotice', () {
    test('explains every state the board cannot list in', () {
      HomeBoardNotice? of(
        HomeBoardPhase phase, {
        HomeBoardRequestReason? reason,
        String? message,
        List<HomeBoardWorkspace> workspaces = const [],
        bool herdrOpen = false,
      }) => HomeBoardNotice.of(
        HomeBoardState(phase: phase, message: message, workspaces: workspaces),
        requestReason: reason,
        hasOpenHerdrSession: herdrOpen,
      );

      expect(of(HomeBoardPhase.idle), isNull);
      expect(
        of(
          HomeBoardPhase.awaitingRequest,
          reason: HomeBoardRequestReason.hardwareKey,
        )!.title,
        'Hardware-key login',
      );
      final never = of(
        HomeBoardPhase.awaitingRequest,
        reason: HomeBoardRequestReason.neverConnected,
      )!;
      expect(never.title, 'Not connected yet');
      expect(never.action, HomeBoardNoticeAction.request);
      expect(of(HomeBoardPhase.loading)!.busy, isTrue);
      expect(
        of(HomeBoardPhase.notInstalled)!.action,
        HomeBoardNoticeAction.openShell,
      );
      expect(
        of(HomeBoardPhase.notRunning)!.action,
        HomeBoardNoticeAction.startHerdr,
      );
      final failed = of(HomeBoardPhase.failed, message: 'timed out')!;
      expect(failed.title, 'Could not list workspaces');
      expect(failed.message, 'timed out');
      expect(failed.action, HomeBoardNoticeAction.retry);
      expect(
        of(HomeBoardPhase.failed, workspaces: [workspace('w1', 'A')])!.title,
        'Showing the last list',
      );
      expect(of(HomeBoardPhase.ready)!.title, 'No Herdr workspaces');
      expect(of(HomeBoardPhase.ready, herdrOpen: true), isNull);
      expect(
        of(HomeBoardPhase.ready, workspaces: [workspace('w1', 'A')]),
        isNull,
      );
    });

    test('a connection problem replaces the listing wording', () {
      const problem = ConnectionProblem(
        kind: ConnectionProblemKind.unreachable,
        title: "Can't reach dev",
        message: 'This machine is on your Tailscale network.',
        detail: 'SocketException: Network is unreachable',
      );
      final fresh = HomeBoardNotice.of(
        const HomeBoardState(
          phase: HomeBoardPhase.failed,
          message: 'Could not reach dev.',
          problem: problem,
        ),
      )!;
      expect(fresh.title, "Can't reach dev");
      expect(fresh.message, 'This machine is on your Tailscale network.');
      expect(fresh.detail, 'SocketException: Network is unreachable');
      expect(fresh.icon, Icons.cloud_off_rounded);
      expect(fresh.action, HomeBoardNoticeAction.retry);

      // Stale data (even tmux sessions, which used to read as "Herdr
      // broke") keeps the headline and says the list is old.
      final stale = HomeBoardNotice.of(
        HomeBoardState(
          phase: HomeBoardPhase.failed,
          tmux: HomeTmuxStatus.available,
          tmuxSessions: const [TmuxSessionInfo(name: 'main')],
          workspaces: [workspace('w1', 'A')],
          problem: problem,
        ),
      )!;
      expect(stale.title, "Can't reach dev");
      expect(
        stale.message,
        'Showing the last list. This machine is on your Tailscale network.',
      );
      expect(stale.action, HomeBoardNoticeAction.retry);

      final signIn = HomeBoardNotice.of(
        const HomeBoardState(
          phase: HomeBoardPhase.failed,
          problem: ConnectionProblem(
            kind: ConnectionProblemKind.authentication,
            title: 'Sign-in to dev failed',
            message: 'Check the key.',
          ),
        ),
      )!;
      expect(signIn.title, 'Sign-in to dev failed');
      expect(signIn.icon, Icons.lock_outline_rounded);
      expect(signIn.detail, isNull);
    });

    test('a tmux-only machine needs no Herdr notice', () {
      const sessions = [TmuxSessionInfo(name: 'main')];
      HomeBoardNotice? of(
        HomeBoardPhase phase, {
        HomeTmuxStatus tmux = HomeTmuxStatus.available,
        List<TmuxSessionInfo> tmuxSessions = const [],
      }) => HomeBoardNotice.of(
        HomeBoardState(
          phase: phase,
          tmux: tmux,
          tmuxSessions: tmuxSessions,
          message: 'herdr broke',
        ),
      );

      // Herdr missing but tmux there: nothing to explain.
      expect(of(HomeBoardPhase.notInstalled), isNull);
      expect(
        of(
          HomeBoardPhase.notInstalled,
          tmux: HomeTmuxStatus.notInstalled,
        )!.title,
        'No tmux or Herdr here',
      );
      expect(of(HomeBoardPhase.notRunning, tmuxSessions: sessions), isNull);
      expect(of(HomeBoardPhase.ready, tmuxSessions: sessions), isNull);
      expect(
        of(HomeBoardPhase.failed, tmuxSessions: sessions)!.title,
        'Could not list Herdr workspaces',
      );
      expect(
        of(HomeBoardPhase.failed)!.title,
        'Could not list Herdr workspaces',
      );
    });

    testWidgets('the tile shows the reason and runs the action', (
      tester,
    ) async {
      var acted = 0;
      await tester.pumpWidget(
        host(
          HomeBoardNoticeTile(
            notice: HomeBoardNotice.of(
              const HomeBoardState(
                phase: HomeBoardPhase.failed,
                message: 'Connection refused',
              ),
            )!,
            palette: palette,
            brightness: Brightness.dark,
            onAction: () => acted += 1,
          ),
          width: 380,
          height: 100,
        ),
      );
      expect(find.text('Connection refused'), findsOneWidget);
      await tester.tap(find.text('Retry'));
      expect(acted, 1);
    });
  });
  group('session titles and previews (CON-071)', () {
    TerminalSessionController w8() => session(
      () => const ConnectTarget.herdr(
        workspaceId: 'w8',
      ).apply(buildHost('a').copyWith(name: 'development-central')),
    );

    testWidgets('a row at 360 dp: the workspace label is the title, the '
        'machine a caption, Claude Code\'s footer is skipped', (tester) async {
      final herdr = w8();
      await herdr.connect();
      herdr.terminal.write(
        'Reading rejectIfAutoManaged\r\n'
        '──────────────────────\r\n'
        '❯ \r\n'
        '──────────────────────\r\n'
        '⏵⏵ auto mode on (alt+m to cycle) · ← for agents\r\n',
      );
      await tester.pumpWidget(
        host(
          HomeSessionRow(
            session: herdr,
            info: HomeSessionInfo.of(
              herdr,
              workspaces: [workspace('w8', 'lf-seguros-web')],
              agentState: AgentAttentionState.working,
              machineName: 'development-central',
            ),
            palette: palette,
            brightness: Brightness.dark,
            fontFamily: 'monospace',
            onTap: () {},
            onLongPress: () {},
          ),
          width: 360,
          height: 90,
        ),
      );
      final title = tester.widget<Text>(
        find.byKey(const ValueKey('home-row-title')),
      );
      expect(title.data, 'lf-seguros-web');
      expect(find.textContaining('development-central:'), findsNothing);
      expect(find.textContaining('w8'), findsNothing);
      // The machine once, as the small caption at the bottom right.
      expect(find.text('development-central'), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('home-machine-caption')))
            .data,
        'development-central',
      );
      final tail = tester.widget<Text>(
        find.byKey(const ValueKey('home-row-tail')),
      );
      expect(tail.data, 'Reading rejectIfAutoManaged');
      expect(tail.style?.fontFamilyFallback, previewFontFallback);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the agent\'s own line wins over the screen', (tester) async {
      final herdr = w8();
      herdr.terminal.write('some output\r\n');
      await herdr.connect();
      await tester.pumpWidget(
        host(
          HomeSessionRow(
            session: herdr,
            info: HomeSessionInfo.of(
              herdr,
              agentLine: 'Fixing the CI cache\nsecond line',
            ),
            palette: palette,
            brightness: Brightness.dark,
            fontFamily: 'monospace',
            onTap: () {},
            onLongPress: () {},
          ),
          width: 360,
          height: 90,
        ),
      );
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('home-row-tail'))).data,
        'Fixing the CI cache',
      );
    });

    testWidgets('a grid tile at 360 dp names the workspace, not its id', (
      tester,
    ) async {
      final herdr = w8();
      await tester.pumpWidget(
        host(
          HomeSessionTile(
            session: herdr,
            info: HomeSessionInfo.of(
              herdr,
              workspaces: [workspace('w8', 'lf-seguros-web')],
              machineName: 'development-central',
            ),
            palette: palette,
            brightness: Brightness.dark,
            fontFamily: 'monospace',
            onTap: () {},
            onLongPress: () {},
          ),
          width: HomeGridMetrics.of(360).tileWidth,
          height: HomeGridMetrics.of(360).sessionExtent,
        ),
      );
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('home-tile-title'))).data,
        'lf-seguros-web',
      );
      expect(find.textContaining('w8'), findsNothing);
      expect(find.text('development-central'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    test('the live label replaces a raw workspace id in every title', () {
      final herdr = w8();
      expect(herdr.title, 'development-central: w8');
      herdr.noteTargetLabel('lf-seguros-web');
      expect(herdr.title, 'development-central: lf-seguros-web');
      herdr.noteTargetLabel('');
      expect(herdr.title, 'development-central: w8');
      herdr
        ..noteTargetLabel('lf-seguros-web')
        ..rename('Mine');
      expect(herdr.title, 'Mine');
    });

    test('agent chrome is not a preview line', () {
      for (final chrome in [
        '⏵⏵ auto mode on (alt+m to cycle) · ← for agents',
        '⏸ plan mode on (shift+tab to cycle)',
        'accept edits on',
        '? for shortcuts',
        '─────────────',
        '│ > │',
        '❯',
        '  100% context left',
      ]) {
        expect(isAgentChromeLine(chrome), isTrue, reason: chrome);
      }
      expect(isAgentChromeLine('npm test passed'), isFalse);
      expect(meaningfulTail(['done', '? for shortcuts', '']), 'done');
      expect(meaningfulTail(['? for shortcuts']), '');
      expect(withPreviewGlyphs('⏵⏵ on ⏸'), '▸▸ on ‖');
    });
  });
}

typedef SavedHostBuilder = SavedHost Function();
