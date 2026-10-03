import 'dart:convert';

import 'package:conduit/core/theme/theme_controller.dart';
import 'package:conduit/features/agent_attention/data/conductore_host_attention_provider.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/agents_digest/data/digest_preferences.dart';
import 'package:conduit/features/agents_digest/presentation/agents_dashboard.dart';
import 'package:conduit/features/agents_digest/presentation/digest_controller.dart';
import 'package:conduit/features/agents_digest/presentation/digest_settings.dart';
import 'package:conduit/features/desktop_shell/domain/project_tree.dart';
import 'package:conduit/features/desktop_shell/presentation/project_layout_controller.dart';
import 'package:conduit/features/desktop_shell/presentation/widgets/shell_dashboard.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/hosts/presentation/widgets/home_chrome.dart';
import 'package:conduit/features/session_navigation/domain/session_view_preferences.dart';
import 'package:conduit/features/session_navigation/presentation/session_view_controller.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';
import 'digest_fakes.dart';

/// The companion on one machine: `status` for the agent monitor, `digest`
/// (facts, or `--summaries`), `decide`.
class CompanionRunner implements AgentCommandRunner {
  CompanionRunner({required this.status, this.digest, this.summaries});

  String status;
  Map<String, Object?>? digest;
  Map<String, Object?>? summaries;
  final List<String> commands = [];

  List<String> sent(String sub) =>
      commands.where((c) => c.contains('conductore-hostd $sub')).toList();

  @override
  Future<AgentCommandResult> run(
    String command, {
    required Duration timeout,
  }) async {
    commands.add(command);
    AgentCommandResult ok(String out) =>
        AgentCommandResult(stdout: out, stderr: '', exitCode: 0);
    if (command.contains('conductore-hostd status')) return ok(status);
    if (command.contains('conductore-hostd decide')) {
      return ok('{"ok":true,"requestId":"req-1","decision":"allow"}');
    }
    if (command.contains('conductore-hostd digest')) {
      final json = command.contains('--summaries')
          ? summaries ?? digest
          : digest;
      if (json == null) {
        return const AgentCommandResult(
          stdout: '{"error":"unknown command digest"}',
          stderr: '',
          exitCode: 1,
        );
      }
      return ok(jsonEncode(json));
    }
    return const AgentCommandResult(
      stdout: '{"error":"unknown command"}',
      stderr: '',
      exitCode: 1,
    );
  }

  @override
  Future<void> close() async {}
}

const _request =
    '{"id":"req-1","toolName":"Bash","summary":"git push",'
    '"toolInput":{"command":"git push"},"createdAt":1790000000000,'
    '"risk":{"level":"medium","reason":"Pushes a branch"}}';

String _status() =>
    '{"version":1,"seq":5,"capabilities":["smart-approvals","digest"],'
    '"agents":['
    '{"sessionId":"api","name":"api","cwd":"/home/a/api",'
    '"state":"needs_permission","updatedAt":1790000003000,'
    '"pending":[$_request]},'
    '{"sessionId":"web","name":"web","cwd":"/home/a/web",'
    '"state":"waiting_input","lastMessage":"Should I deploy?",'
    '"updatedAt":1790000002000,"pending":[]},'
    '{"sessionId":"etl","name":"etl","cwd":"/home/a/etl",'
    '"state":"working","updatedAt":1790000001000,"pending":[]},'
    '{"sessionId":"docs","name":"docs","cwd":"/home/a/docs",'
    '"state":"waiting_input","updatedAt":1790000000000,"pending":[]}]}';

Map<String, Object?> _digest({bool summaries = false}) => digestReplyJson([
  digestAgentJson(
    'api',
    state: 'needs_permission',
    attention: 'permission',
    pending: [
      {'id': 'req-1', 'toolName': 'Bash', 'summary': 'git push'},
    ],
    summary: summaries ? 'Fixed the date bug. Wants to push.' : null,
    summaryPending: !summaries,
    headline: 'Pushing next.',
  ),
  digestAgentJson(
    'web',
    attention: 'question',
    headline: 'Should I deploy?',
    facts: {'turns': 1},
  ),
  digestAgentJson(
    'etl',
    state: 'working',
    stuck: [
      {'rule': 'same-failure', 'reason': '`node import.js` failed 3 times'},
    ],
  ),
  digestAgentJson('docs', summary: 'Updated the install docs.'),
], tokensToday: summaries ? 6313 : 0);

void main() {
  SavedHost host() => buildHost('h').copyWith(
    agentAttentionEnabled: true,
    agentMonitor: AgentMonitorKind.companion,
  );

  late CompanionRunner runner;
  late AgentAttentionController attention;
  late DigestController digest;
  late MemoryDigestPreferencesStore store;

  Future<void> start(
    WidgetTester tester, {
    Map<String, Object?>? facts,
    Map<String, Object?>? summaries,
    DigestPreferences preferences = const DigestPreferences(),
  }) async {
    runner = CompanionRunner(
      status: _status(),
      digest: facts,
      summaries: summaries,
    );
    final workspace = TerminalWorkspaceController(
      ImmediateTerminalRepository(TrackableTerminalSession()),
    );
    attention = AgentAttentionController(
      workspace: workspace,
      runnerFactory: (_) => runner,
      provider: const ConductoreHostAttentionProvider(),
      companionProvider: const ConductoreHostAttentionProvider(),
      pollInterval: const Duration(days: 1),
    );
    attention.setAppForeground(false);
    store = MemoryDigestPreferencesStore(preferences);
    digest = DigestController(
      source: AttentionDigestHostSource(attention: attention),
      preferences: store,
      clock: () => digestNow,
      observeLifecycle: false,
    );
    addTearDown(digest.dispose);
    addTearDown(attention.dispose);
    addTearDown(workspace.dispose);
    final session = workspace.open(host());
    await tester.runAsync(session.connect);
    await tester.runAsync(pumpEventQueue);
  }

  Future<List<String>> pumpView(
    WidgetTester tester, {
    SessionViewController? views,
    List<String>? sentText,
    ProjectLayoutController? projects,
  }) async {
    // Tall enough for every card (the list builds lazily).
    tester.view.physicalSize = const Size(900, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final opened = <String>[];
    Widget view = AgentsDashboardView(
      controller: digest,
      attention: attention,
      now: () => digestNow,
      onOpenChat: (host, agent) => opened.add('chat:${agent.id}'),
      onOpenTerminal: (host, agent) => opened.add('terminal:${agent.id}'),
      sendText: (host, sessionId, text) async =>
          sentText?.add('$sessionId:$text'),
      projects: projects,
    );
    if (views != null) view = SessionViewScope(controller: views, child: view);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: view)));
    await tester.runAsync(pumpEventQueue);
    await tester.pump();
    await tester.runAsync(pumpEventQueue);
    await tester.pump();
    return opened;
  }

  testWidgets('header, sections and cards: facts first, then summaries', (
    tester,
  ) async {
    await start(tester, facts: _digest(), summaries: _digest(summaries: true));
    await pumpView(tester);
    expect(runner.sent('digest'), hasLength(2));
    expect(runner.sent('digest').last, contains('--summaries'));
    final header = tester.widget<Text>(
      find.byKey(const ValueKey('digest-header')),
    );
    expect(header.data, contains('2 need you'));
    // The stuck agent works, but counts under stuck.
    expect(header.data, contains('0 working'));
    expect(header.data, contains('1 stuck'));
    expect(header.data, contains('1 done'));
    for (final section in ['needsYou', 'stuck', 'done']) {
      expect(find.byKey(ValueKey('digest-section-$section')), findsOneWidget);
    }
    expect(find.text('Fixed the date bug. Wants to push.'), findsOneWidget);
    expect(find.text('`node import.js` failed 3 times'), findsOneWidget);
    expect(find.byKey(const ValueKey('digest-fact-files-api')), findsOneWidget);
    expect(find.text('2 files +48 −9'), findsWidgets);
    expect(find.text('tests ✓2 ✗1'), findsWidgets);
    expect(find.textContaining('962k tok'), findsWidgets);
    // The question gets an Answer button, the approval its buttons.
    expect(find.widgetWithText(TextButton, 'Answer'), findsOneWidget);
    expect(find.text('Allow'), findsOneWidget);
  });

  testWidgets('a Codex agent carries its badge; Claude Code cards none', (
    tester,
  ) async {
    await start(
      tester,
      facts: digestReplyJson([
        // The companion names the kind only for agents other than Claude.
        {
          ...digestAgentJson('repo', headline: 'Added hello.txt.'),
          'kind': 'codex',
        },
        digestAgentJson('api', headline: 'Done.'),
      ]),
    );
    await pumpView(tester);
    expect(find.byKey(const ValueKey('digest-kind-repo')), findsOneWidget);
    expect(find.byKey(const ValueKey('digest-kind-api')), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('digest-kind-repo')),
        matching: find.text('CX'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('group by project: layout projects first, then Other; '
      'collapsing hides the cards', (tester) async {
    await start(tester, facts: _digest());
    final theme = ThemeController(InMemoryThemePreferences());
    await theme.load();
    final projects = ProjectLayoutController(theme: theme);
    addTearDown(projects.dispose);
    await projects.addProject('Backend', rules: ['api', 'etl']);
    await pumpView(tester, projects: projects);
    expect(find.byKey(const ValueKey('digest-section-needsYou')), findsOne);
    await tester.tap(find.byKey(const ValueKey('digest-group-by-toggle')));
    await tester.pump();
    expect(theme.projectPrefs.groupByProject, isTrue);
    expect(find.byKey(const ValueKey('digest-section-needsYou')), findsNothing);
    final backend = find.byKey(const ValueKey('digest-project-backend'));
    final other = find.byKey(
      const ValueKey('digest-project-${ProjectGroup.otherKey}'),
    );
    expect(backend, findsOneWidget);
    expect(other, findsOneWidget);
    expect(
      tester.getTopLeft(backend).dy,
      lessThan(tester.getTopLeft(other).dy),
    );
    // Backend: api and etl; Other: web and docs.
    double y(String id) =>
        tester.getTopLeft(find.byKey(ValueKey('digest-card-$id'))).dy;
    expect(y('api'), lessThan(tester.getTopLeft(other).dy));
    expect(y('etl'), lessThan(tester.getTopLeft(other).dy));
    expect(y('web'), greaterThan(tester.getTopLeft(other).dy));
    expect(y('docs'), greaterThan(tester.getTopLeft(other).dy));

    await tester.tap(backend);
    await tester.pump();
    expect(find.byKey(const ValueKey('digest-card-api')), findsNothing);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('project-count-backend')))
          .data,
      '2',
    );
  });

  testWidgets('approve from the card goes through the monitor', (tester) async {
    await start(tester, facts: _digest());
    await pumpView(tester);
    await tester.tap(find.text('Allow'));
    await tester.runAsync(pumpEventQueue);
    await tester.pump();
    expect(runner.sent('decide'), hasLength(1));
    expect(runner.sent('decide').single, contains('req-1 allow'));
  });

  testWidgets('tap follows the default view; Chat, Terminal and Answer', (
    tester,
  ) async {
    await start(tester, facts: _digest());
    final sent = <String>[];
    final views = SessionViewController(_MemoryViews());
    await views.setDefaultView(SessionView.terminal);
    final opened = await pumpView(tester, views: views, sentText: sent);

    await tester.tap(find.byKey(const ValueKey('digest-line-docs')));
    expect(opened.last, 'terminal:docs');
    await views.setDefaultView(SessionView.chat);
    await tester.tap(find.byKey(const ValueKey('digest-line-docs')));
    expect(opened.last, 'chat:docs');

    await tester.tap(find.byKey(const ValueKey('digest-terminal-web')));
    expect(opened.last, 'terminal:web');
    await tester.tap(find.byKey(const ValueKey('digest-chat-web')));
    expect(opened.last, 'chat:web');

    await tester.tap(find.byKey(const ValueKey('digest-tell-web')));
    await tester.pumpAndSettle();
    expect(find.text('Answer web'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('digest-tell-field')),
      'Yes, deploy',
    );
    await tester.tap(find.byKey(const ValueKey('digest-tell-send')));
    await tester.pumpAndSettle();
    expect(sent, ['web:Yes, deploy']);
  });

  group('desktop', () {
    const desktops = TargetPlatformVariant({
      TargetPlatform.linux,
      TargetPlatform.windows,
      TargetPlatform.macOS,
    });
    const modifier = LogicalKeyboardKey.controlLeft;
    LogicalKeyboardKey sendModifier() =>
        defaultTargetPlatform == TargetPlatform.macOS
        ? LogicalKeyboardKey.metaLeft
        : modifier;

    Future<void> ctrlEnter(WidgetTester tester, LogicalKeyboardKey key) async {
      await tester.sendKeyDownEvent(key);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(key);
      await tester.pumpAndSettle();
    }

    testWidgets('right-click a card: Chat, Terminal and Answer as a menu', (
      tester,
    ) async {
      await start(tester, facts: _digest());
      final opened = await pumpView(tester);
      await tester.tap(
        find.byKey(const ValueKey('digest-line-web')),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('digest-menu-Answer…')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('digest-menu-Terminal')));
      await tester.pumpAndSettle();
      expect(opened.last, 'terminal:web');
    }, variant: desktops);

    testWidgets('Ctrl+Enter (Cmd+Enter on macOS) sends from Tell', (
      tester,
    ) async {
      await start(tester, facts: _digest());
      final sent = <String>[];
      await pumpView(tester, sentText: sent);
      await tester.tap(find.byKey(const ValueKey('digest-tell-web')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('digest-tell-field')),
        'Ship it',
      );
      await ctrlEnter(tester, sendModifier());
      expect(sent, ['web:Ship it']);
    }, variant: desktops);

    testWidgets('phone: no right-click menu, Ctrl+Enter does not send', (
      tester,
    ) async {
      await start(tester, facts: _digest());
      final sent = <String>[];
      await pumpView(tester, sentText: sent);
      await tester.tap(
        find.byKey(const ValueKey('digest-line-web')),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('digest-menu-Chat')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('digest-tell-web')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('digest-tell-field')),
        'Ship it',
      );
      await ctrlEnter(tester, modifier);
      expect(sent, isEmpty);
      expect(find.text('Answer web'), findsOneWidget);
    });
  });

  testWidgets('summaries off: facts only, and the note says so', (
    tester,
  ) async {
    await start(
      tester,
      facts: _digest(),
      preferences: const DigestPreferences(summariesEnabled: false),
    );
    await pumpView(tester);
    expect(runner.sent('digest'), hasLength(1));
    expect(find.byKey(const ValueKey('digest-summaries-off')), findsOneWidget);
    // The facts line stands in.
    expect(
      find.text('2 files edited, tests passing. Pushing next.'),
      findsOneWidget,
    );
  });

  testWidgets('an older companion: status only, with the update hint', (
    tester,
  ) async {
    await start(tester);
    await pumpView(tester);
    expect(find.byKey(const ValueKey('digest-update-hint-h')), findsOneWidget);
    expect(find.text('Update agent hooks'), findsOneWidget);
    // From the monitor: the approval and the question are still there.
    final header = tester.widget<Text>(
      find.byKey(const ValueKey('digest-header')),
    );
    expect(header.data, contains('2 need you'));
    expect(find.text('Allow'), findsOneWidget);
  });

  testWidgets('settings: summaries switch, the locked rule, thresholds', (
    tester,
  ) async {
    await start(tester, facts: _digest());
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: DigestSettingsCards(controller: digest),
          ),
        ),
      ),
    );
    await tester.runAsync(pumpEventQueue);
    await tester.pump();
    expect(
      find.byKey(const ValueKey('settings-digest-only-changed')),
      findsOneWidget,
    );
    expect(find.text('Summaries today: none yet.'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('settings-digest-summaries-switch')),
    );
    await tester.pump();
    expect(digest.preferences.summariesEnabled, isFalse);
    expect(store.value.summariesEnabled, isFalse);

    await tester.tap(find.text('30 min (default)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('60 min').last);
    await tester.pumpAndSettle();
    expect(store.value.thresholds.workingMinutes, 60);
  });

  testWidgets('the desktop home puts the dashboard above the sessions', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ShellDashboard(
            needsYou: const [],
            sessions: const [],
            otherGroups: const [],
            onOpenNeedsYou: (_) {},
            onNewSession: () {},
            agents: const Text('agents here'),
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('dashboard-agents')), findsOneWidget);
    expect(find.text('AGENTS'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('agents here')).dy,
      lessThan(tester.getTopLeft(find.text('RECENT SESSIONS')).dy),
    );
  });

  testWidgets('the home bar button opens the dashboard, with a badge', (
    tester,
  ) async {
    var opened = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomeTopBar(
            onLock: () {},
            onSettings: () {},
            onAgents: () => opened++,
            agentsBadge: 2,
          ),
        ),
      ),
    );
    expect(find.text('2'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('home-agents-dashboard')));
    expect(opened, 1);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomeTopBar(onLock: () {}, onSettings: () {}),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('home-agents-dashboard')), findsNothing);
  });

  testWidgets('hidden under another route: detached, no polling', (
    tester,
  ) async {
    await start(tester, facts: _digest());
    await pumpView(tester);
    expect(digest.isVisible, isTrue);
    await tester.pumpWidget(
      MaterialApp(
        home: TickerMode(
          enabled: false,
          child: Scaffold(
            body: AgentsDashboardView(
              controller: digest,
              attention: attention,
              onOpenChat: (_, _) {},
              onOpenTerminal: (_, _) {},
            ),
          ),
        ),
      ),
    );
    expect(digest.isVisible, isFalse);
  });
}

class _MemoryViews implements SessionViewPreferencesRepository {
  SessionViewPreferences value = const SessionViewPreferences();

  @override
  Future<SessionViewPreferences> load() async => value;

  @override
  Future<void> save(SessionViewPreferences preferences) async =>
      value = preferences;
}
