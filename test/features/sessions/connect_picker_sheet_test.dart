import 'package:conduit/core/app_failure.dart';
import 'package:conduit/core/connection_problem.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/sessions/data/workspace_creator.dart';
import 'package:conduit/features/sessions/domain/connect_preferences.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/sessions/presentation/connect_picker_sheet.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

void main() {
  setUp(WorkspaceCreator.clearDetectedAgents);

  const tmuxOutput = AgentCommandResult(
    stdout: 'root\t1\t2\t1790229500\nbuild\t0\t1\t1790229600\n',
    stderr: '',
    exitCode: 0,
  );
  const herdrOutput = AgentCommandResult(
    stdout:
        '{"id":"cli:workspace:list","result":{"type":"workspace_list",'
        '"workspaces":[{"active_tab_id":"w4:t4","agent_status":"idle",'
        '"focused":false,"label":"Infrastructure","number":1,"pane_count":1,'
        '"tab_count":1,"workspace_id":"w4"},{"active_tab_id":"wX:t1",'
        '"agent_status":"blocked","focused":true,"label":"Conductore-Mobile",'
        '"number":11,"pane_count":1,"tab_count":1,"workspace_id":"wX"}]}}',
    stderr: '',
    exitCode: 0,
  );
  const notInstalled = AgentCommandResult(
    stdout: '',
    stderr: 'sh: 1: herdr: not found',
    exitCode: 127,
  );

  Future<(ScriptedAgentCommandRunner, List<ConnectPickerResult>)> pumpPicker(
    WidgetTester tester,
    List<Object> script, {
    SavedHost? host,
    ConnectPreferences preferences = const ConnectPreferences(),
    Set<String> activeTargetKeys = const {},
    ConnectPickerTab initialTab = ConnectPickerTab.tmux,
  }) async {
    final runner = ScriptedAgentCommandRunner(script);
    final picked = <ConnectPickerResult>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConnectPickerSheet(
            host: host ?? buildHost('h'),
            runner: runner,
            preferences: preferences,
            activeTargetKeys: activeTargetKeys,
            initialTab: initialTab,
            onPicked: picked.add,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (runner, picked);
  }

  testWidgets('an unreachable machine says so on both tabs, with Retry', (
    tester,
  ) async {
    const unreachable = ConnectionFailure(
      'Could not reach Host h.',
      'SocketException: Network is unreachable (OS Error: Network is '
          'unreachable, errno = 101)',
      kind: ConnectionProblemKind.unreachable,
    );
    final (runner, _) = await pumpPicker(tester, [
      unreachable,
    ], host: buildHost('h').copyWith(host: '100.106.7.32'));
    expect(find.text("Can't reach Host h"), findsOneWidget);
    expect(
      find.textContaining('Tailscale is on, then tap Retry'),
      findsOneWidget,
    );
    expect(find.textContaining('Could not list tmux'), findsNothing);
    expect(find.textContaining('errno = 101'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('connection-details-toggle')));
    await tester.pumpAndSettle();
    expect(find.textContaining('errno = 101'), findsOneWidget);

    await tester.tap(find.text('Herdr'));
    await tester.pumpAndSettle();
    expect(find.text("Can't reach Host h"), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(runner.commands, isNotEmpty);
  });

  testWidgets('a failed command keeps the listing wording', (tester) async {
    await pumpPicker(tester, [const AppFailure('The command timed out.')]);
    expect(
      find.text('Could not list tmux sessions. The command timed out.'),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('connection-details-toggle')),
      findsNothing,
    );
  });

  for (final scale in [1.0, 1.3]) {
    testWidgets('tab labels stay on one line at 360 dp, text scale $scale', (
      tester,
    ) async {
      // A 360 dp wide phone (Galaxy M53 in its narrowest display setting).
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final runner = ScriptedAgentCommandRunner([tmuxOutput, herdrOutput]);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery.withClampedTextScaling(
            minScaleFactor: scale,
            maxScaleFactor: scale,
            child: Scaffold(
              body: ConnectPickerSheet(
                host: buildHost('h'),
                runner: runner,
                onPicked: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      final tabs = tester.getRect(
        find.byKey(const ValueKey('connect-picker-tabs')),
      );
      for (final label in ['Tmux', 'Herdr', 'Recent', 'Skip']) {
        final text = find.text(label);
        expect(text, findsOneWidget, reason: label);
        final paragraph = tester.renderObject<RenderParagraph>(text);
        final lineHeight = paragraph.text.style!.fontSize! * scale * 1.6;
        expect(
          paragraph.size.height,
          lessThan(lineHeight),
          reason: '$label wraps onto a second line',
        );
        final rect = tester.getRect(text);
        expect(rect.right, lessThanOrEqualTo(360), reason: label);
        if (label != 'Skip') {
          expect(rect.left, greaterThanOrEqualTo(tabs.left), reason: label);
          expect(rect.right, lessThanOrEqualTo(tabs.right), reason: label);
        }
      }
      // The official logos sit on the tabs.
      expect(
        find.byKey(const ValueKey('multiplexer-icon-tmux')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('multiplexer-icon-herdr')),
        findsOneWidget,
      );
    });
  }

  testWidgets('lists tmux sessions with attached and active badges', (
    tester,
  ) async {
    final (runner, picked) = await pumpPicker(
      tester,
      [tmuxOutput, herdrOutput],
      activeTargetKeys: {'tmux:build'},
    );

    expect(runner.commands.first, startsWith('tmux -u list-sessions'));
    expect(find.text('root'), findsOneWidget);
    expect(find.text('build'), findsOneWidget);
    expect(find.text('Attached'), findsOneWidget);
    expect(find.text('Active'), findsOneWidget);
    expect(find.text('New session'), findsOneWidget);

    await tester.tap(find.text('root'));
    expect(picked.single.target, const ConnectTarget.tmux('root'));
    expect(picked.single.remember, isFalse);
  });

  testWidgets('lists Herdr workspaces and picks one with its label', (
    tester,
  ) async {
    final (runner, picked) = await pumpPicker(
      tester,
      [tmuxOutput, herdrOutput],
      initialTab: ConnectPickerTab.herdr,
      activeTargetKeys: {'herdr:w4'},
    );

    expect(runner.commands, hasLength(3));
    expect(runner.commands[1], contains('herdr session list --json'));
    expect(runner.commands[2], contains('herdr workspace list'));
    expect(find.text('Infrastructure'), findsOneWidget);
    expect(find.text('Conductore-Mobile'), findsOneWidget);
    expect(find.text('Active'), findsOneWidget);
    expect(find.text('Needs input'), findsOneWidget);
    // One Herdr session: workspaces are listed directly, and the one Herdr
    // has focused carries the dot.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('herdr-workspace-:wX')),
        matching: find.byKey(const ValueKey('herdr-focused-dot')),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('herdr-focused-dot')), findsOneWidget);
    expect(find.textContaining('default'), findsNothing);

    await tester.tap(find.byType(Switch));
    await tester.pump();
    await tester.tap(find.text('Conductore-Mobile'));
    expect(
      picked.single.target,
      const ConnectTarget.herdr(workspaceId: 'wX', label: 'Conductore-Mobile'),
    );
    expect(picked.single.remember, isTrue);
  });

  testWidgets('Herdr tabs read as what they show, never as ids', (
    tester,
  ) async {
    // Shaped like Herdr 0.9.1's `workspace list`, `tab list`, `pane list`.
    const workspaces = AgentCommandResult(
      stdout:
          '{"id":"cli:workspace:list","result":{"type":"workspace_list",'
          '"workspaces":[{"active_tab_id":"w1:t1","agent_status":"idle",'
          '"focused":true,"label":"TheCalendar","number":1,"pane_count":3,'
          '"tab_count":3,"workspace_id":"w1"}]}}',
      stderr: '',
      exitCode: 0,
    );
    const tabs = AgentCommandResult(
      stdout:
          '{"id":"cli:tab:list","result":{"tabs":['
          '{"agent_status":"idle","focused":true,"label":"","number":1,'
          '"pane_count":1,"tab_id":"w1:t1","workspace_id":"w1"},'
          '{"agent_status":"working","focused":false,"label":"api",'
          '"number":2,"pane_count":2,"tab_id":"w1:t2","workspace_id":"w1"},'
          '{"agent_status":"idle","focused":false,"label":"","number":3,'
          '"pane_count":1,"tab_id":"w1:t3","workspace_id":"w1"}]}}',
      stderr: '',
      exitCode: 0,
    );
    const panes = AgentCommandResult(
      stdout:
          '{"id":"cli:pane:list","result":{"panes":['
          '{"agent":"claude","agent_status":"idle",'
          '"cwd":"/root/Projects/TheCalendar","focused":true,'
          '"pane_id":"w1:p1","tab_id":"w1:t1",'
          '"terminal_title":"✳ Tasks PR review",'
          '"terminal_title_stripped":"Tasks PR review","workspace_id":"w1"},'
          '{"agent_status":"idle","cwd":"/srv/api","focused":false,'
          '"pane_id":"w1:p2","tab_id":"w1:t2","terminal_title":"",'
          '"workspace_id":"w1"},'
          '{"agent":"codex","agent_status":"working","cwd":"/srv/api",'
          '"focused":false,"pane_id":"w1:p3","tab_id":"w1:t2",'
          '"terminal_title_stripped":"Fix login","workspace_id":"w1"}]}}',
      stderr: '',
      exitCode: 0,
    );
    final (runner, _) = await pumpPicker(tester, [
      tmuxOutput,
      notInstalled,
      workspaces,
      tabs,
      panes,
    ], initialTab: ConnectPickerTab.herdr);
    expect(runner.commands.last, contains('exec herdr pane list'));
    expect(find.text('Tab 1'), findsOneWidget);
    expect(find.text('claude: Tasks PR review'), findsOneWidget);
    expect(find.text('api'), findsOneWidget);
    // No focused pane in the tab: its first pane, named by its folder.
    expect(find.text('api · 2 panes'), findsOneWidget);
    expect(find.text('Tab 3'), findsOneWidget);
    for (final id in ['w1:t1', 'w1:t2', 'w1:t3', 'w1:p1']) {
      expect(find.textContaining(id), findsNothing, reason: id);
    }
  });

  testWidgets('lists several Herdr sessions as session ‧ workspace', (
    tester,
  ) async {
    const sessions = AgentCommandResult(
      stdout:
          '{"sessions":[{"default":true,"name":"default","running":true},'
          '{"default":false,"name":"work","running":true},'
          '{"default":false,"name":"old","running":false}]}',
      stderr: '',
      exitCode: 0,
    );
    const workOutput = AgentCommandResult(
      stdout:
          '{"result":{"workspaces":[{"workspace_id":"w1","label":"api",'
          '"focused":true,"tab_count":1,"active_tab_id":"w1:t1"}]}}',
      stderr: '',
      exitCode: 0,
    );
    final (runner, picked) = await pumpPicker(
      tester,
      [tmuxOutput, sessions, herdrOutput, workOutput],
      initialTab: ConnectPickerTab.herdr,
      activeTargetKeys: {'herdr@work:w1'},
    );

    expect(runner.commands, hasLength(4));
    expect(runner.commands[2], contains('exec herdr workspace list'));
    expect(
      runner.commands[3],
      contains('exec herdr --session work workspace list'),
    );
    expect(find.text('default ‧ Infrastructure'), findsOneWidget);
    expect(find.text('default ‧ Conductore-Mobile'), findsOneWidget);
    expect(find.text('work ‧ api'), findsOneWidget);
    // Each session has its own focused workspace.
    expect(find.byKey(const ValueKey('herdr-focused-dot')), findsNWidgets(2));
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('herdr-workspace-work:w1')),
        matching: find.text('Active'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('work ‧ api'));
    expect(
      picked.single.target,
      const ConnectTarget.herdr(
        workspaceId: 'w1',
        label: 'work ‧ api',
        session: 'work',
      ),
    );
    expect(
      picked.single.target.startupCommand,
      'herdr --session work workspace focus w1 >/dev/null 2>&1; '
      'herdr --session work',
    );
  });

  testWidgets('explains when Herdr is not installed', (tester) async {
    await pumpPicker(tester, [
      tmuxOutput,
      notInstalled,
    ], initialTab: ConnectPickerTab.herdr);
    expect(
      find.text('Herdr is not installed on this machine.'),
      findsOneWidget,
    );
  });

  testWidgets('skip returns a plain shell', (tester) async {
    final (_, picked) = await pumpPicker(tester, [tmuxOutput, herdrOutput]);
    await tester.tap(find.text('Skip'));
    expect(picked.single.target, const ConnectTarget.shell());
  });

  testWidgets('recent tab shows earlier choices', (tester) async {
    final (_, picked) = await pumpPicker(
      tester,
      [tmuxOutput, herdrOutput],
      initialTab: ConnectPickerTab.recent,
      preferences: const ConnectPreferences(
        recents: [
          ConnectTarget.herdr(workspaceId: 'w7', label: 'TheCalendar'),
          ConnectTarget.tmux('ops'),
        ],
      ),
    );
    expect(find.text('TheCalendar'), findsOneWidget);
    expect(find.text('ops'), findsOneWidget);

    await tester.tap(find.text('ops'));
    expect(picked.single.target, const ConnectTarget.tmux('ops'));
  });

  testWidgets('new tmux session asks for a name', (tester) async {
    final (runner, picked) = await pumpPicker(tester, [
      tmuxOutput,
      herdrOutput,
    ]);
    await tester.tap(find.text('New session'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('new-workspace-name')),
      'agents',
    );
    await tester.tap(find.byKey(const ValueKey('new-workspace-create')));
    await tester.pumpAndSettle();
    // Only a name: attach-or-create, as before, with no extra command
    // (the last one asked which agents the machine has).
    expect(picked.single.target, const ConnectTarget.tmux('agents'));
    expect(runner.commands, hasLength(4));
    expect(runner.commands.last, contains('command -v'));
  });

  testWidgets('new tmux session in a suggested folder with an installed '
      'agent', (tester) async {
    final runner = ScriptedAgentCommandRunner([
      tmuxOutput,
      herdrOutput,
      herdrOutput,
      // Which agents the machine has (CON-071).
      const AgentCommandResult(
        stdout: 'claude\ncodex\ncursor-agent\n',
        stderr: '',
        exitCode: 0,
      ),
      const AgentCommandResult(stdout: '', stderr: '', exitCode: 0),
    ]);
    final picked = <ConnectPickerResult>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConnectPickerSheet(
            host: buildHost('h'),
            runner: runner,
            recentDirectories: const ['/home/a/Projects/TheCalendar', '/srv'],
            onPicked: picked.add,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('New session'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(
        const ValueKey('new-workspace-folder-/home/a/Projects/TheCalendar'),
      ),
    );
    // No favourite: None and only what this machine has, None first.
    expect(find.text('Start Claude in it'), findsNothing);
    expect(
      tester
          .widget<ChoiceChip>(
            find.byKey(const ValueKey('new-workspace-agent-none')),
          )
          .selected,
      isTrue,
    );
    expect(find.text('Claude Code'), findsOneWidget);
    expect(find.text('Codex'), findsOneWidget);
    expect(find.text('Cursor'), findsOneWidget);
    expect(find.text('OpenCode'), findsNothing);
    expect(find.text('Gemini CLI'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('new-workspace-agent-codex')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('new-workspace-create')));
    await tester.pumpAndSettle();

    // Named after the folder, created there, Codex typed in; then opened,
    // remembering Codex for this machine.
    expect(picked.single.target, const ConnectTarget.tmux('TheCalendar'));
    expect(picked.single.agent, 'codex');
    expect(runner.commands, hasLength(5));
    expect(runner.commands[3], contains('command -v'));
    final create = runner.commands.last;
    expect(create, startsWith("sh -c 'eval"));
    expect(create, contains('new-session'));
    expect(create, contains('send-keys'));
  });

  testWidgets('the last agent chosen on the machine is preselected, and '
      'kept out when no longer installed', (tester) async {
    for (final (installed, selected) in [
      ('opencode\ngemini\n', 'gemini'),
      ('opencode\n', 'none'),
    ]) {
      WorkspaceCreator.clearDetectedAgents();
      final (_, picked) = await pumpPicker(tester, [
        tmuxOutput,
        herdrOutput,
        herdrOutput,
        AgentCommandResult(stdout: installed, stderr: '', exitCode: 0),
      ], preferences: const ConnectPreferences(lastAgent: 'gemini'));
      await tester.tap(find.text('New session'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ChoiceChip>(
              find.byKey(ValueKey('new-workspace-agent-$selected')),
            )
            .selected,
        isTrue,
      );
      expect(picked, isEmpty);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    }
  });

  testWidgets('new Herdr workspace: created, then picked by id; a failure '
      'stays in the dialog', (tester) async {
    const created = AgentCommandResult(
      stdout:
          '{"id":"cli:workspace:create","result":{"root_pane":{"pane_id":'
          '"w9:p1","workspace_id":"w9"},"type":"workspace_created",'
          '"workspace":{"label":"api","workspace_id":"w9"}}}',
      stderr: '',
      exitCode: 0,
    );
    final (runner, picked) = await pumpPicker(tester, [
      tmuxOutput,
      herdrOutput,
      herdrOutput,
      // No agents on this machine.
      const AgentCommandResult(stdout: '', stderr: '', exitCode: 0),
      const AgentCommandResult(
        stdout: '',
        stderr: 'No such folder: /nope',
        exitCode: 3,
      ),
      created,
    ], initialTab: ConnectPickerTab.herdr);
    await tester.tap(find.byKey(const ValueKey('herdr-new-workspace')));
    await tester.pumpAndSettle();
    expect(find.text('New Herdr workspace'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('new-workspace-name')),
      'api',
    );
    await tester.enterText(
      find.byKey(const ValueKey('new-workspace-folder')),
      '/nope',
    );
    await tester.tap(find.byKey(const ValueKey('new-workspace-create')));
    await tester.pumpAndSettle();
    expect(find.text('No such folder: /nope'), findsOneWidget);
    expect(picked, isEmpty);

    await tester.enterText(
      find.byKey(const ValueKey('new-workspace-folder')),
      '~/api',
    );
    await tester.tap(find.byKey(const ValueKey('new-workspace-create')));
    await tester.pumpAndSettle();
    expect(find.text('New Herdr workspace'), findsNothing);
    expect(
      picked.single.target,
      const ConnectTarget.herdr(workspaceId: 'w9', label: 'api'),
    );
    // No agent asked for: no pane command after the create.
    expect(find.text('No coding agents found on this machine.'), findsNothing);
    expect(runner.commands, hasLength(6));
    // "Phone may move Herdr focus" is off: created without moving it.
    expect(runner.commands.last, contains('--no-focus'));
  });

  testWidgets('does not list automatically for hardware-key logins', (
    tester,
  ) async {
    final (runner, _) = await pumpPicker(
      tester,
      [tmuxOutput, herdrOutput],
      host: buildHost(
        'h',
      ).copyWith(authMethod: SshAuthMethod.hardwareKey, privateKey: 'stub'),
    );
    expect(runner.commands, isEmpty);
    expect(find.text('Load sessions'), findsOneWidget);

    await tester.tap(find.text('Load sessions'));
    await tester.pumpAndSettle();
    expect(runner.commands, hasLength(3));
    expect(find.text('root'), findsOneWidget);
  });

  testWidgets(
    'desktop filters the rows and switches tabs with Ctrl+1/2/3',
    (tester) async {
      await pumpPicker(tester, [tmuxOutput, herdrOutput]);
      expect(find.text('root'), findsOneWidget);
      expect(find.text('build'), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('connect-picker-filter')),
        'bui',
      );
      await tester.pumpAndSettle();
      expect(find.text('root'), findsNothing);
      expect(find.text('build'), findsOneWidget);

      final mac = defaultTargetPlatform == TargetPlatform.macOS;
      final modifier = mac
          ? LogicalKeyboardKey.metaLeft
          : LogicalKeyboardKey.controlLeft;
      await tester.sendKeyDownEvent(modifier);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
      await tester.sendKeyUpEvent(modifier);
      await tester.pumpAndSettle();
      final tabs = tester.widget<SegmentedButton<ConnectPickerTab>>(
        find.byKey(const ValueKey('connect-picker-tabs')),
      );
      expect(tabs.selected, {ConnectPickerTab.recent});
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.linux,
      TargetPlatform.windows,
      TargetPlatform.macOS,
    }),
  );

  testWidgets('phones have no filter field', (tester) async {
    await pumpPicker(tester, [tmuxOutput, herdrOutput]);
    expect(find.byKey(const ValueKey('connect-picker-filter')), findsNothing);
    expect(find.text('root'), findsOneWidget);
  });
}
