@Tags(['screenshots'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conduit/core/connection_problem.dart';
import 'package:conduit/core/presentation/adaptive_modal.dart';
import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/core/theme/theme_controller.dart';
import 'package:conduit/core/theme/theme_preferences_repository.dart';
import 'package:conduit/features/agent_attention/data/conductore_host_attention_provider.dart';
import 'package:conduit/features/agent_attention/data/herdr_attention_provider.dart';
import 'package:conduit/features/agent_attention/domain/agent_attention.dart';
import 'package:conduit/features/agent_attention/domain/agent_command_runner.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_sheet.dart';
import 'package:conduit/features/agent_attention/presentation/approval_rules_page.dart';
import 'package:conduit/features/agents_digest/presentation/agents_dashboard.dart';
import 'package:conduit/features/agents_digest/presentation/digest_controller.dart';
import 'package:conduit/features/app_lock/presentation/app_lock_controller.dart';
import 'package:conduit/features/backup/data/app_backup_service.dart';
import 'package:conduit/features/chat_view/presentation/chat_forward.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_controller.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_page.dart';
import 'package:conduit/features/chat_view/presentation/chat_view_presenter.dart';
import 'package:conduit/features/companion_setup/data/companion_bundle.dart';
import 'package:conduit/features/companion_setup/presentation/companion_setup_controller.dart';
import 'package:conduit/features/companion_setup/presentation/companion_setup_page.dart';
import 'package:conduit/features/desktop_shell/data/desktop_shell_store.dart';
import 'package:conduit/features/desktop_shell/domain/shell_layout.dart';
import 'package:conduit/features/desktop_shell/domain/sidebar_prefs.dart';
import 'package:conduit/features/desktop_shell/presentation/desktop_home.dart';
import 'package:conduit/features/desktop_shell/presentation/desktop_shell_controller.dart';
import 'package:conduit/features/hosts/domain/home_preferences.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/hosts/presentation/home_board_controller.dart';
import 'package:conduit/features/hosts/presentation/hosts_controller.dart';
import 'package:conduit/features/hosts/presentation/hosts_page.dart';
import 'package:conduit/features/hosts/presentation/widgets/home_session_grid.dart';
import 'package:conduit/features/live_preview/presentation/preview_ready_controller.dart';
import 'package:conduit/features/local_shell/presentation/local_shell_controller.dart';
import 'package:conduit/features/prompt_menus/presentation/prompt_menu_strip.dart';
import 'package:conduit/features/review/data/review_client.dart';
import 'package:conduit/features/review/presentation/review_controller.dart';
import 'package:conduit/features/review/presentation/review_page.dart';
import 'package:conduit/features/sessions/domain/connect_preferences.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/sessions/presentation/session_connect_flow.dart';
import 'package:conduit/features/sync/data/sync_crypto.dart';
import 'package:conduit/features/sync/data/sync_setup.dart';
import 'package:conduit/features/sync/data/sync_state_store.dart';
import 'package:conduit/features/sync/presentation/sync_controller.dart';
import 'package:conduit/features/sync/presentation/sync_page.dart';
import 'package:conduit/features/sync/presentation/widgets/qr_code_view.dart';
import 'package:conduit/features/terminal/domain/herdr_keymap.dart';
import 'package:conduit/features/terminal/domain/herdr_navigator.dart';
import 'package:conduit/features/terminal/domain/host_key_verifier.dart';
import 'package:conduit/features/terminal/presentation/host_key_prompt_coordinator.dart';
import 'package:conduit/features/terminal/presentation/terminal_page.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:conduit/features/this_computer/domain/this_computer_settings.dart';
import 'package:conduit/features/usage/data/usage_preferences.dart';
import 'package:conduit/features/usage/presentation/usage_controller.dart';
import 'package:conduit/features/usage/presentation/usage_explorer_view.dart';
import 'package:conduit/features/usage/presentation/usage_widgets.dart';
import 'package:conduit/features/voice/domain/voice_preferences.dart';
import 'package:conduit/features/voice/presentation/dictation_controller.dart';
import 'package:conduit/features/voice/presentation/read_aloud_controller.dart';
import 'package:conduit/features/voice/presentation/voice_settings_scope.dart';
import 'package:conduit/features/voice_guide/domain/guide_preferences.dart';
import 'package:conduit/features/voice_guide/domain/guide_world.dart';
import 'package:conduit/features/voice_guide/presentation/app_guide.dart';
import 'package:conduit/features/voice_guide/presentation/guide_controller.dart';
import 'package:conduit/features/voice_guide/presentation/guide_overlay.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

import '../features/chat_view/chat_fixtures.dart';
import '../features/companion_setup/companion_fakes.dart' show MatchingRunner;
import '../features/hosts/home_board_fakes.dart';
import '../features/sync/fake_sync_hub.dart';
import '../features/sync/sync_test_support.dart';
import '../features/terminal/herdr/fake_herdr_runner.dart';
import '../features/usage/usage_fakes.dart';
import '../features/voice/fake_speech_recognizer.dart';
import '../features/voice/fake_tts.dart';
import '../features/voice_guide/guide_fixtures.dart'
    show FakeApprovals, FakeMessenger, FakeNavigator;
import '../support/test_doubles.dart';
import 'demo_screens.dart';
import 'screenshot_harness.dart';

// Demo machines. Nothing here points at a real host.
final workstation = SavedHost(
  id: 'workstation',
  name: 'workstation',
  host: 'workstation.local',
  port: 22,
  username: 'demo',
  authMethod: SshAuthMethod.password,
  password: 'demo',
  agentAttentionEnabled: true,
  lastConnectedAt: DateTime.utc(2026, 9, 25, 9),
);
final buildBox = SavedHost(
  id: 'build-box',
  name: 'build-box',
  host: 'build-box.local',
  port: 22,
  username: 'demo',
  authMethod: SshAuthMethod.password,
  password: 'demo',
  lastConnectedAt: DateTime.utc(2026, 9, 25, 8),
);

/// Herdr on the workstation: api (blocked), web (working), infra (done).
const workstationWorkspaces =
    '{"id":"1","result":{"workspaces":['
    '{"workspace_id":"w1","label":"api","number":1,'
    '"agent_status":"blocked","focused":true,"tab_count":4,'
    '"active_tab_id":"w1:t1"},'
    '{"workspace_id":"w2","label":"web","number":2,'
    '"agent_status":"working","tab_count":1,"active_tab_id":"w2:t1"},'
    '{"workspace_id":"w3","label":"infra","number":3,'
    '"agent_status":"done","tab_count":3,"active_tab_id":"w3:t1"},'
    '{"workspace_id":"w4","label":"docs","number":4,'
    '"agent_status":"idle","tab_count":1,"active_tab_id":"w4:t1"}]}}';

/// `herdr tab list` (Herdr 0.9.1 shape): api has four tabs, claude focused.
const workstationTabs =
    '{"id":"2","result":{"tabs":['
    '{"tab_id":"w1:t1","workspace_id":"w1","label":"claude","number":1,'
    '"agent_status":"working","focused":true,"pane_count":1},'
    '{"tab_id":"w1:t2","workspace_id":"w1","label":"server","number":2,'
    '"agent_status":"idle","focused":false,"pane_count":1},'
    '{"tab_id":"w1:t3","workspace_id":"w1","label":"tests","number":3,'
    '"agent_status":"blocked","focused":false,"pane_count":2},'
    '{"tab_id":"w1:t4","workspace_id":"w1","label":"logs","number":4,'
    '"agent_status":"idle","focused":false,"pane_count":1},'
    '{"tab_id":"w2:t1","workspace_id":"w2","label":"claude","number":1,'
    '"agent_status":"working","focused":true,"pane_count":1},'
    '{"tab_id":"w3:t1","workspace_id":"w3","label":"plan","number":1,'
    '"agent_status":"done","focused":true,"pane_count":1},'
    '{"tab_id":"w3:t2","workspace_id":"w3","label":"apply","number":2,'
    '"agent_status":"working","focused":false,"pane_count":1},'
    '{"tab_id":"w3:t3","workspace_id":"w3","label":"logs","number":3,'
    '"agent_status":"idle","focused":false,"pane_count":1},'
    '{"tab_id":"w4:t1","workspace_id":"w4","label":"","number":1,'
    '"agent_status":"idle","focused":true,"pane_count":1}]}}';

/// Herdr on This computer: one workspace, "notes".
const thisComputerWorkspaces =
    '{"id":"1","result":{"workspaces":['
    '{"workspace_id":"w1","label":"notes","number":1,'
    '"agent_status":"idle","focused":true,"tab_count":1,'
    '"active_tab_id":"w1:t1"}]}}';

const workstationAgents =
    '{"id":"3","result":{"agents":['
    '{"agent":"claude","pane_id":"w1:p1","tab_id":"w1:t1",'
    '"workspace_id":"w1","agent_status":"blocked",'
    '"terminal_title_stripped":"Due dates for todos"},'
    '{"agent":"claude","pane_id":"w2:p1","tab_id":"w2:t1",'
    '"workspace_id":"w2","agent_status":"working",'
    '"terminal_title_stripped":"Keyboard shortcuts"},'
    '{"agent":"claude","pane_id":"w3:p1","tab_id":"w3:t1",'
    '"workspace_id":"w3","agent_status":"done",'
    '"terminal_title_stripped":"Terraform plan"},'
    '{"agent":"codex","pane_id":"w3:p2","tab_id":"w3:t2",'
    '"workspace_id":"w3","agent_status":"working",'
    '"terminal_title_stripped":"Apply staging"}]}}';

/// `tmux list-sessions` lines, active [minutesAgo] minutes ago.
String tmuxLine(
  String name, {
  int attached = 0,
  int windows = 1,
  int minutesAgo = 3,
}) {
  final activity =
      DateTime.now()
          .subtract(Duration(minutes: minutesAgo))
          .millisecondsSinceEpoch ~/
      1000;
  return '$name\t$attached\t$windows\t$activity\n';
}

String buildBoxTmux() =>
    tmuxLine('ci', attached: 1, windows: 2, minutesAgo: 1) +
    tmuxLine('deploy', minutesAgo: 42);

/// One terminal session per connect whose screen is written by the test.
class DemoTerminalRepository extends FreshTerminalRepository {}

Future<TerminalSessionController> openDemoSession(
  WidgetTester tester,
  TerminalWorkspaceController workspace,
  SavedHost host,
  String screen, {
  int columns = 46,
  int rows = 40,
}) async {
  final session = workspace.open(host);
  await tester.runAsync(session.connect);
  session.terminal.resize(columns, rows);
  session.terminal.write(screen);
  return session;
}

class _NoopWakelock extends WakelockPlusPlatformInterface {
  @override
  Future<void> toggle({required bool enable}) async {}

  @override
  Future<bool> get enabled async => false;
}

AgentCommandResult ok(String stdout) =>
    AgentCommandResult(stdout: stdout, stderr: '', exitCode: 0);

/// `herdr pane list`: the focused Claude pane of workspace api.
const workstationPanes =
    '{"id":"cli:pane:list","result":{"panes":['
    '{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1",'
    '"cwd":"/home/demo/todo-api","focused":true},'
    '{"pane_id":"w1:p2","workspace_id":"w1","tab_id":"w1:t2",'
    '"cwd":"/home/demo/todo-api"}],"type":"pane_list"}}';

/// Answers the Herdr CLI on the workstation from the demo fixtures.
AgentCommandResult workstationHerdr(String command) {
  if (command.contains('herdr/config.toml')) {
    return const AgentCommandResult(stdout: '', stderr: '', exitCode: 1);
  }
  if (command.contains('pane list')) return ok(workstationPanes);
  if (command.contains('workspace list')) return ok(workstationWorkspaces);
  if (command.contains('tab list')) return ok(workstationTabs);
  if (command.contains('agent list')) return ok(workstationAgents);
  return ok('');
}

/// The bundled companion's version, so the hooks screen reads up to date.
Future<CompanionBundle> loadCompanionBundle() async {
  final manifest =
      jsonDecode(File('assets/companion/manifest.json').readAsStringSync())
          as Map<String, Object?>;
  return CompanionBundle(
    version: manifest['version']! as String,
    archive: Uint8List(0),
  );
}

int minutesAgo(int minutes) =>
    DateTime.now().subtract(Duration(minutes: minutes)).millisecondsSinceEpoch;

/// One agent in `conductore-hostd status`.
String agentJson(
  String id,
  String name, {
  required String state,
  required int minutes,
  String? message,
  String pending = '',
  String extra = '',
}) =>
    '{"sessionId":"$id","name":"$name","cwd":"/home/demo/$name",'
    '"state":"$state","updatedAt":${minutesAgo(minutes)},'
    '"startedAt":${minutesAgo(minutes + 30)}'
    '${message == null ? '' : ',"lastMessage":"$message"'}'
    ',"pending":[$pending]$extra}';

String statusOf(List<String> agents) =>
    '{"version":1,"seq":2,"source":"daemon","agents":[${agents.join(',')}]}';

const apiPending =
    '{"id":"req-1","toolName":"Bash","summary":"npm test -- due-date",'
    '"toolInput":{"command":"npm test -- due-date",'
    '"description":"Run the due date tests"}}';

/// Companion status on the workstation: the Claude session in workspace
/// api, plus (for the inbox) two more.
String workstationStatus({bool needsApproval = false, bool all = false}) =>
    statusOf([
      agentJson(
        's-api',
        'todo-api',
        state: needsApproval ? 'needs_permission' : 'working',
        minutes: 0,
        message: needsApproval ? null : 'Writing the due date tests.',
        pending: needsApproval ? apiPending : '',
        extra: ',"herdr":{"tabId":"w1:t1","paneId":"w1:p1"}',
      ),
      if (all) ...[
        agentJson(
          's-web',
          'todo-web',
          state: 'working',
          minutes: 1,
          message: 'Refactoring TodoList for keyboard navigation.',
        ),
        agentJson(
          's-infra',
          'infra',
          state: 'ended',
          minutes: 18,
          message: 'Plan: 3 to add, 0 to change, 0 to destroy.',
        ),
      ],
    ]);

String buildBoxStatus() => statusOf([
  agentJson(
    's-docs',
    'todo-docs',
    state: 'ended',
    minutes: 9,
    message: 'README updated with the new due date API.',
  ),
]);

/// [line] stamped [ago] before now, so elapsed times read naturally.
Map<String, Object?> stamped(Map<String, Object?> line, Duration ago) =>
    line
      ..['timestamp'] = DateTime.now().toUtc().subtract(ago).toIso8601String();

/// A transcript page whose agent started [started] ago.
String livePage(
  List<Map<String, Object?>> entries, {
  required String state,
  Duration started = const Duration(minutes: 26),
  List<Map<String, Object?>> pending = const [],
}) {
  final json =
      jsonDecode(page(entries, state: state, pending: pending))
          as Map<String, Object?>;
  final agent = json['agent']! as Map<String, Object?>;
  final now = DateTime.now();
  agent['startedAt'] = now.subtract(started).millisecondsSinceEpoch;
  agent['updatedAt'] = now.millisecondsSinceEpoch;
  return jsonEncode(json);
}

const _dateTable =
    'Here is how they compare for a due date field:\n\n'
    '| Library | Time zones | Tree-shakes | Size |\n'
    '|:--------|:----------:|:-----------:|:----:|\n'
    '| date-fns | add-on | yes | 18 KB |\n'
    '| Day.js | plugin | partly | 3 KB |\n'
    '| Luxon | built in | no | 23 KB |\n\n'
    "I'll go with **date-fns**: we only need parsing and comparing, and it "
    'tree-shakes to about 2 KB for that.';

/// Demo sync keys: fast parameters, nothing real.
const _syncCrypto = SyncCrypto(
  params: KdfParams.insecureFast,
  useIsolate: false,
);

Future<SyncController> demoSyncDevice(
  FakeHubServer server, {
  List<SavedHost> hosts = const [],
}) async {
  final local = await LocalDevice.create(
    hosts: hosts,
    trustedKeys: [
      HostKeyRecord(
        host: workstation.host,
        port: 22,
        type: 'ssh-ed25519',
        fingerprint: 'SHA256:demo-workstation',
        trustedAt: DateTime.utc(2026, 9),
      ),
    ],
  );
  final sync = SyncController(
    state: InMemorySyncStateStore(),
    local: local.store,
    hubFactory: server.factory,
    hosts: local.hosts,
    hostKeys: local.verifier,
    crypto: _syncCrypto,
    setupCodec: const SyncSetupCodec(
      crypto: _syncCrypto,
      params: KdfParams.insecureFast,
    ),
    timers: FakeSyncTimers(),
    observeLifecycle: false,
  );
  await sync.start();
  return sync;
}

/// A companion 1.0 `usage` reply: [reply] with the range end it covers.
Map<String, Object?> companion1(
  Map<String, Object?> reply, {
  required String to,
}) => {...reply, 'version': '1.0.0', 'to': to};

Widget _withUsage(UsageController? usage, Widget page) =>
    usage == null ? page : UsageScope(controller: usage, child: page);

/// [page] with the voice guide's home button and, while it runs, its card.
Widget _withGuide(GuideController? guide, Widget page) => guide == null
    ? page
    : GuideScope(
        controller: guide,
        child: Stack(
          children: [
            page,
            GuideOverlay(controller: guide),
          ],
        ),
      );

/// Usage on the workstation: the 5-hour limit at 62 %, the week at 31 %,
/// today's tokens and cost. [detailed] adds the build box and a week of
/// projects and models, for the breakdown.
/// [accounts] adds two Claude accounts managed by cswap, work active.
UsageController demoUsage({bool detailed = false, bool accounts = false}) {
  final now = DateTime.now();
  String day(int back) {
    final d = now.subtract(Duration(days: back));
    return '${d.year}-${'${d.month}'.padLeft(2, '0')}-'
        '${'${d.day}'.padLeft(2, '0')}';
  }

  final limits = [
    {
      'label': '5h',
      'usedPct': 62,
      'resetsAt': now
          .add(const Duration(hours: 2, minutes: 14))
          .millisecondsSinceEpoch,
    },
    {
      'label': '7d',
      'usedPct': 31,
      'resetsAt': now.add(const Duration(days: 3)).millisecondsSinceEpoch,
    },
  ];
  final runner = FakeUsageRunner(
    () => FakeUsageRunner.ok(
      companion1(
        usageReplyJson(
          machine: 'workstation',
          today: day(0),
          from: day(6),
          limits: limits,
          accounts: accounts
              ? [
                  usageAccount(
                    1,
                    'work',
                    active: true,
                    fiveHour: 62,
                    weekly: 31,
                    fiveHourResets: now.add(
                      const Duration(hours: 2, minutes: 14),
                    ),
                    weeklyResets: now.add(const Duration(days: 3)),
                  ),
                  usageAccount(
                    2,
                    'personal',
                    fiveHour: 8,
                    weekly: 12,
                    fiveHourResets: now.add(const Duration(hours: 4)),
                    weeklyResets: now.add(const Duration(days: 5)),
                  ),
                ]
              : null,
          rows: [
            usageRow(day(0), output: 1840000, costUsd: 6.4),
            usageRow(day(1), project: 'todo-web', output: 920000, costUsd: 3.1),
            if (detailed) ...[
              usageRow(
                day(0),
                project: 'todo-web',
                model: 'claude-sonnet-5',
                output: 610000,
                costUsd: 1.2,
              ),
              usageRow(day(1), output: 1320000, costUsd: 4.6),
              usageRow(day(2), output: 1510000, costUsd: 5.3),
              usageRow(
                day(2),
                project: 'infra',
                model: 'claude-haiku-4-5',
                output: 380000,
                costUsd: 0.4,
              ),
              usageRow(
                day(3),
                project: 'todo-web',
                output: 700000,
                costUsd: 2.5,
              ),
              usageRow(day(4), output: 1100000, costUsd: 3.8),
              usageRow(
                day(5),
                project: 'infra',
                model: 'claude-sonnet-5',
                output: 450000,
                costUsd: 0.9,
              ),
              usageRow(day(6), output: 800000, costUsd: 2.8),
            ],
          ],
        ),
        to: day(0),
      ),
    ),
  );
  final buildBoxRunner = FakeUsageRunner(
    () => FakeUsageRunner.ok(
      companion1(
        usageReplyJson(
          machine: 'build-box',
          today: day(0),
          from: day(6),
          // The same Claude account as the workstation.
          limits: limits,
          rows: [
            usageRow(
              day(0),
              project: 'ci',
              model: 'claude-sonnet-5',
              output: 420000,
              costUsd: 0.8,
            ),
            usageRow(
              day(3),
              project: 'ci',
              model: 'claude-sonnet-5',
              output: 510000,
              costUsd: 1.1,
            ),
          ],
        ),
        to: day(0),
      ),
    ),
  );
  final controller = UsageController(
    source: FakeUsageSource(
      [workstation, if (detailed) buildBox],
      {'workstation': runner, 'build-box': buildBoxRunner},
    ),
    preferences: MemoryUsagePreferencesStore(),
    observeLifecycle: false,
  );
  addTearDown(controller.dispose);
  return controller;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  WakelockPlusPlatformInterface.instance = _NoopWakelock();
  setUpAll(loadShotFonts);

  Future<ThemeController> everforest() async {
    final controller = ThemeController(
      InMemoryThemePreferences(
        const ThemePreferences(
          themeMode: ThemeMode.dark,
          palette: AppPalette.everforest,
        ),
      ),
    );
    await controller.load();
    return controller;
  }

  /// The home page: two Herdr sessions open, other workspaces listed.
  SessionConnectFlow? homeFlow;

  Future<ThemeController> pumpHome(
    WidgetTester tester, {
    bool desktop = false,
    bool thisComputer = false,
    bool withFlow = false,
    DesktopShellController? shell,
    bool? shellMode,
    AgentAttentionController? attention,
    void Function(TerminalWorkspaceController workspace)? onWorkspace,
    UsageController? usage,
    bool buildBoxUnreachable = false,
    GuideController? guide,
  }) async {
    if (desktop) {
      useDesktopView(tester);
    } else {
      usePhoneView(tester);
    }
    final theme = await everforest();
    // Unreachable: the build box on the tailnet, timing out.
    const tailnetAddress = 'build-box.tail4a2c.ts.net';
    final repository = FakeHostsRepository()
      ..persisted = [
        workstation,
        if (buildBoxUnreachable)
          buildBox.copyWith(host: tailnetAddress)
        else
          buildBox,
      ];
    final hostsController = HostsController(
      repository,
      thisComputerStore: thisComputer
          ? InMemoryThisComputerStore(
              ThisComputerSettings(
                // No agent polling timers in the screenshots.
                host: SavedHost.thisComputer(
                  hostname: 'devbox',
                  username: 'demo',
                ).copyWith(agentAttentionEnabled: false),
              ),
            )
          : null,
    );
    final workspace = TerminalWorkspaceController(DemoTerminalRepository());
    addTearDown(workspace.dispose);
    final agentAttention =
        attention ??
        AgentAttentionController(
          workspace: workspace,
          runnerFactory: (_) =>
              ScriptedAgentCommandRunner([StateError('no polling')]),
          provider: const HerdrAttentionProvider(),
        );
    addTearDown(agentAttention.dispose);
    final runners = {
      'workstation': HerdrFakeRunner(
        workspaces: workstationWorkspaces,
        tabs: workstationTabs,
        agents: workstationAgents,
        tmuxSessions: tmuxLine('scratch', minutesAgo: 12),
      ),
      'build-box': buildBoxUnreachable
          ? HerdrFakeRunner(
              error: const ConnectionFailure(
                'Could not reach build-box.',
                'SocketException: Connection timed out (OS Error: '
                    'Connection timed out, errno = 110), '
                    'address = $tailnetAddress, port = 22',
                kind: ConnectionProblemKind.unreachable,
              ),
            )
          : HerdrFakeRunner.tmuxOnly(tmuxSessions: buildBoxTmux()),
      thisComputerHostId: HerdrFakeRunner(
        workspaces: thisComputerWorkspaces,
        tabs: '{"result":{"tabs":[]}}',
        agents: '{"result":{"agents":[]}}',
        tmuxSessions: tmuxLine('dotfiles', minutesAgo: 30),
      ),
    };
    final boards = HomeBoards(
      runnerFactory: (host) => runners[host.id]!,
      pollInterval: const Duration(days: 1),
    );
    addTearDown(boards.dispose);
    homeFlow = withFlow
        ? SessionConnectFlow(
            hostsController: hostsController,
            workspace: workspace,
            runnerFactory: (host) => runners[baseHostId(host.id)]!,
            preferences: InMemoryConnectPreferencesRepository(),
          )
        : null;

    await openDemoSession(
      tester,
      workspace,
      const ConnectTarget.herdr(
        workspaceId: 'w1',
        label: 'api',
      ).apply(workstation),
      claudePermissionScreen(),
    );
    await openDemoSession(
      tester,
      workspace,
      const ConnectTarget.herdr(
        workspaceId: 'w2',
        label: 'web',
      ).apply(workstation),
      claudeWorkingScreen(),
    );
    onWorkspace?.call(workspace);

    final verifier = NoopVerifier();
    await tester.pumpWidget(
      shotApp(
        home: _withGuide(
          guide,
          _withUsage(
            usage,
            HostsPage(
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
              agentAttention: agentAttention,
              backupService: AppBackupService(
                hostsController: hostsController,
                themeController: theme,
                hostKeyVerifier: verifier,
              ),
              fileExport: RecordingFileExport(),
              homeBoards: boards,
              homePreferences: InMemoryHomePreferencesRepository(),
              connectFlow: homeFlow,
              previewRefreshInterval: const Duration(days: 1),
              desktopShell: shell,
              shellMode: shellMode,
            ),
          ),
        ),
        systemBars: !desktop,
      ),
    );
    await tester.runAsync(pumpEventQueue);
    await pumpFrames(tester);
    await tester.runAsync(pumpEventQueue);
    await pumpFrames(tester);
    return theme;
  }

  testWidgets('01 home', (tester) async {
    await pumpHome(tester);
    await saveShot(tester, '01-home');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  Future<void> tearDownPage(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    // Herdr remote-control timeouts.
    await tester.pump(const Duration(minutes: 3));
  }

  /// The terminal page on the Herdr workspace "api" running Claude Code.
  Future<TerminalSessionController> pumpTerminal(
    WidgetTester tester, {
    required bool withPrompt,
    bool inbox = false,
    bool desktop = false,
    bool moreSessions = false,
    ConnectTarget? target,
    String? screen,
    PreviewReadyController Function(TerminalSessionController)?
    previewWatcherFactory,
  }) async {
    if (desktop) {
      useDesktopView(tester);
    } else {
      usePhoneView(tester);
    }
    HerdrPaneListingCache.instance.clear();
    HerdrKeymapCache.instance.clear();
    final theme = await everforest();
    SavedHost companion(SavedHost host) => host.copyWith(
      agentAttentionEnabled: true,
      agentMonitor: AgentMonitorKind.companion,
    );
    final host =
        (target ??
                const ConnectTarget.herdr(
                  workspaceId: 'w1',
                  label: 'api',
                  tabId: 'w1:t1',
                ))
            .apply(companion(workstation));
    final hostsController = HostsController(
      FakeHostsRepository()..persisted = [workstation, buildBox],
    );
    final workspace = TerminalWorkspaceController(DemoTerminalRepository());
    addTearDown(workspace.dispose);
    final agentAttention = AgentAttentionController(
      workspace: workspace,
      runnerFactory: (host) => ScriptedAgentCommandRunner([
        ok(
          host.id.startsWith('build-box')
              ? buildBoxStatus()
              : workstationStatus(needsApproval: withPrompt, all: inbox),
        ),
      ]),
      provider: const ConductoreHostAttentionProvider(),
      pollInterval: const Duration(days: 1),
    );
    agentAttention.setAppForeground(false);
    addTearDown(agentAttention.dispose);
    final flow = SessionConnectFlow(
      hostsController: hostsController,
      workspace: workspace,
      runnerFactory: (_) => FakeHerdrRunner(workstationHerdr),
      preferences: InMemoryConnectPreferencesRepository(),
    );
    if (inbox || moreSessions) {
      await openDemoSession(
        tester,
        workspace,
        const ConnectTarget.tmux('ci').apply(companion(buildBox)),
        shellTestsScreen(),
      );
    }
    if (moreSessions) {
      await openDemoSession(
        tester,
        workspace,
        const ConnectTarget.herdr(
          workspaceId: 'w2',
          label: 'web',
        ).apply(companion(workstation)),
        claudeWorkingScreen(),
      );
    }
    final session = workspace.open(host);
    await tester.runAsync(session.connect);
    await tester.runAsync(pumpEventQueue);
    workspace.activate(session);

    await tester.pumpWidget(
      shotApp(
        home: TerminalPage(
          workspace: workspace,
          themeController: theme,
          sftpRepository: NoNetworkSftpRepository(),
          agentAttention: agentAttention,
          connectFlow: flow,
          previewWatcherFactory: previewWatcherFactory,
        ),
        systemBars: !desktop,
      ),
    );
    await pumpFrames(tester);
    session.terminal.write(
      screen ??
          claudeTerminalScreen(
            withPrompt: withPrompt,
            width: desktop ? 96 : 46,
          ),
    );
    await tester.pump(PromptMenuStrip.defaultDebounce);
    await pumpFrames(tester);

    if (inbox) {
      final context = tester.element(find.byType(TerminalPage));
      unawaited(
        showAgentAttentionSheet(
          context: context,
          controller: agentAttention,
          onOpenAgent: (_, _) {},
          onOpenChat: (_, _) {},
        ),
      );
      await pumpFrames(tester, 8);
      // Pull the sheet up to its full height.
      await tester.dragFrom(
        tester.getTopLeft(find.byType(AgentAttentionSheet)) +
            const Offset(200, 12),
        const Offset(0, -600),
      );
      await pumpFrames(tester, 8);
    }
    return session;
  }

  testWidgets('02 terminal', (tester) async {
    await pumpTerminal(tester, withPrompt: false);
    await saveShot(tester, '02-terminal');
    await tearDownPage(tester);
  });

  testWidgets('03 chat view', (tester) async {
    usePhoneView(tester);
    final thread = [
      stamped(
        userLine('u1', 'Add a due date to todos and cover it with tests'),
        const Duration(minutes: 12),
      ),
      assistantLine('a1', [
        text(
          "I'll add an optional **`dueDate`** to the todo schema, then:\n"
          '- validate it as an ISO date\n'
          '- sort overdue todos first',
        ),
        toolUse('t1', 'Bash', {
          'command': 'npm test -- todos',
          'description': 'Run the todo tests',
        }),
      ]),
      userLine('r1', [toolResult('t1', 'Tests  18 passed (18)')]),
      assistantLine('a2', [
        toolUse('t2', 'Edit', {
          'file_path': '/home/demo/todo-api/src/routes/todos.ts',
          'old_string': '  done: z.boolean(),',
          'new_string':
              '  dueDate: z.string().datetime().optional(),\n'
              '  done: z.boolean().default(false),',
        }),
        toolUse('t3', 'TodoWrite', {
          'todos': [
            {'content': 'Add a validated dueDate', 'status': 'completed'},
            {'content': 'Test overdue sorting', 'status': 'in_progress'},
          ],
        }),
        toolUse('t4', 'Bash', {
          'command': 'npm test -- due-date',
          'description': 'Run the due date tests',
        }),
      ]),
    ];
    final controller = ChatViewController(
      runner: ScriptedAgentCommandRunner([
        ok(
          livePage(
            thread,
            state: 'needs_permission',
            started: const Duration(minutes: 12),
            pending: [
              {
                'id': 'req-1',
                'toolName': 'Bash',
                'summary': 'npm test -- due-date',
                'toolInput': {
                  'command': 'npm test -- due-date',
                  'description': 'Run the due date tests',
                },
              },
            ],
          ),
        ),
      ]),
      sessionId: 's-1',
      decide: (_, _) async {},
      pollInterval: const Duration(days: 1),
    );
    // Every tool call as its own card, so the edit's diff can open.
    final theme = await everforest();
    await theme.setVoice(theme.voice.copyWith(toolActivity: ToolActivity.all));
    await tester.pumpWidget(
      VoiceSettingsScope(
        settings: theme,
        child: shotApp(home: const Scaffold()),
      ),
    );
    await pushPage(
      tester,
      ChatViewPage(
        controller: controller,
        hostName: 'workstation',
        onOpenTerminal: () {},
      ),
    );
    await pumpFrames(tester);
    await tester.tap(find.text('/home/demo/todo-api/src/routes/todos.ts'));
    await pumpFrames(tester);
    await saveShot(tester, '03-chat-view');
    await tearDownPage(tester);
  });

  testWidgets('04 agents inbox', (tester) async {
    await pumpTerminal(tester, withPrompt: true, inbox: true);
    await saveShot(tester, '04-agents-inbox');
    await tearDownPage(tester);
  });

  testWidgets('05 herdr navigator', (tester) async {
    await pumpTerminal(tester, withPrompt: false);
    await tester.tap(find.byKey(const ValueKey('toolbar-herdr')));
    await pumpFrames(tester, 8);
    await saveShot(tester, '05-herdr-navigator');
    await tearDownPage(tester);
  });

  testWidgets('06 menu buttons', (tester) async {
    await pumpTerminal(tester, withPrompt: true);
    await saveShot(tester, '06-menu-buttons');
    await tearDownPage(tester);
  });

  testWidgets('07 settings', (tester) async {
    await pumpHome(tester);
    await tester.tap(find.byTooltip('Settings'));
    await pumpFrames(tester, 8);
    await saveShot(tester, '07-settings');
    await tearDownPage(tester);
  });

  testWidgets('08 agent hooks', (tester) async {
    usePhoneView(tester);
    final installed = (await loadCompanionBundle()).version;
    final runner = MatchingRunner({
      'conductore-hostd version': ok(
        '{"version":"$installed","protocol":1,"node":"22.11.0"}',
      ),
      'conductore-hostd doctor': ok(
        '{"ok":true,"user":"demo","checks":['
        '{"name":"node","ok":true,"detail":"node 22.11.0 (need >= 18)"},'
        '{"name":"hook client","ok":true,'
        '"detail":"~/.local/share/conductore/bin/conductore-hook"},'
        '{"name":"settings.json","ok":true,"detail":"~/.claude/settings.json"},'
        '{"name":"hooks registered","ok":true,"detail":"9 events"},'
        '{"name":"daemon","ok":true,"detail":"pid 4242, seq 318"},'
        '{"name":"herdr","ok":true,"detail":"herdr 0.9.1"}]}',
      ),
      'conductore-hostd status': ok(workstationStatus(all: true)),
      'exec node --version': ok('v22.11.0\n'),
      'exec claude --version': ok('2.1.0 (Claude Code)\n'),
    });
    final controller = CompanionSetupController(
      runnerFactory: (_) => runner,
      sftpRepository: NoNetworkSftpRepository(),
      loadBundle: loadCompanionBundle,
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      CompanionSetupScope(
        controller: controller,
        child: shotApp(home: const Scaffold()),
      ),
    );
    await pushPage(
      tester,
      CompanionSetupPage(host: workstation, controller: controller),
    );
    await tester.runAsync(pumpEventQueue);
    await pumpFrames(tester, 8);
    await saveShot(tester, '08-agent-hooks');
    await tearDownPage(tester);
  });

  testWidgets('09 quick switcher', (tester) async {
    await pumpTerminal(tester, withPrompt: true, moreSessions: true);
    await tester.tap(find.byTooltip('Sessions'));
    await pumpFrames(tester, 8);
    await saveShot(tester, '09-quick-switcher');
    await tearDownPage(tester);
  });

  testWidgets('10 chat view working', (tester) async {
    usePhoneView(tester);
    final thread = [
      stamped(
        userLine('u0', 'Add a dueDate field to the todo schema'),
        const Duration(minutes: 9),
      ),
      assistantLine('a0', [
        text(
          'Added an optional `dueDate` (ISO 8601) to the schema and the '
          'create route. Asking the reviewer agent to check it.',
        ),
      ]),
      stamped(
        userLine(
          'm1',
          '<teammate-message teammate_id="reviewer" color="green" '
              'summary="Due date PR reviewed">\n'
              'Looks good. Sort overdue todos before the ones without a '
              'date.\n</teammate-message>',
        ),
        const Duration(minutes: 6),
      ),
      stamped(
        userLine('u1', 'Which date library should the due date use?'),
        const Duration(minutes: 2, seconds: 14),
      ),
      assistantLine('a1', [
        toolUse('task1', 'Task', {
          'description': 'Compare date libraries',
          'subagent_type': 'Explore',
          'prompt': 'Compare date-fns, Day.js and Luxon for this repo',
        }),
      ]),
      assistantLine('s1', [
        toolUse('g1', 'Grep', {'pattern': 'new Date\\('}),
      ], sidechain: true),
      userLine('s2', [toolResult('g1', 'Found 7 files')], sidechain: true),
      assistantLine('s3', [
        toolUse('r1', 'Read', {
          'file_path': '/home/demo/todo-api/package.json',
        }),
      ], sidechain: true),
      userLine('s4', [toolResult('r1', '{ ... }')], sidechain: true),
      userLine('u2', [toolResult('task1', 'date-fns fits best.')]),
      assistantLine('a2', [text(_dateTable)]),
      assistantLine('a3', [
        toolUse('t2', 'Bash', {
          'command': 'npm install date-fns && npm test -- due-date',
          'description': 'Install date-fns and run the due date tests',
        }),
      ]),
    ];
    final controller = ChatViewController(
      runner: ScriptedAgentCommandRunner([
        ok(livePage(thread, state: 'working')),
      ]),
      sessionId: 's-1',
      decide: (_, _) async {},
      pollInterval: const Duration(days: 1),
    );
    await tester.pumpWidget(shotApp(home: const Scaffold()));
    await pushPage(
      tester,
      ChatViewPage(
        controller: controller,
        hostName: 'workstation',
        onOpenTerminal: () {},
      ),
    );
    await pumpFrames(tester, 8);
    await saveShot(tester, '10-chat-working');
    await tearDownPage(tester);
  });

  testWidgets('11 talk mode', (tester) async {
    usePhoneView(tester);
    final theme = await everforest();
    await theme.setVoice(theme.voice.copyWith(talkSendSilenceSeconds: 2));
    final mic = FakeSpeechRecognizer();
    final dictation = DictationController(mic, language: () => 'en-US');
    addTearDown(dictation.dispose);
    final history = [
      stamped(
        userLine('u-1', 'Add a due date to todos and cover it with tests'),
        const Duration(minutes: 14),
      ),
      assistantLine('a-1', [
        text(
          'Done. Todos now have an optional **`dueDate`**:\n'
          '- validated as an ISO 8601 date in the create and update routes\n'
          '- returned by `GET /todos` and filterable with `?due=today`\n'
          '- covered by 12 new tests in `test/due-date.test.ts`',
        ),
      ]),
      stamped(
        userLine('u0', 'Sort overdue todos first'),
        const Duration(minutes: 8),
      ),
      assistantLine('a0', [
        toolUse('t0', 'Edit', {
          'file_path': '/home/demo/todo-api/src/lib/sort.ts',
          'old_string': '  return a.createdAt - b.createdAt;',
          'new_string':
              '  if (isOverdue(a) !== isOverdue(b)) {\n'
              '    return isOverdue(a) ? -1 : 1;\n'
              '  }\n'
              '  return a.createdAt - b.createdAt;',
        }),
      ]),
      userLine('r0', [toolResult('t0', 'ok')]),
      assistantLine('a00', [
        text('Overdue todos now come first; the rest keep their order.'),
      ]),
      stamped(
        userLine('u1', 'Run the due date tests'),
        const Duration(minutes: 3),
      ),
      assistantLine('a1', [
        toolUse('t1', 'Bash', {
          'command': 'npm test -- due-date',
          'description': 'Run the due date tests',
        }),
      ]),
      userLine('r1', [toolResult('t1', 'Tests  24 passed (24)')]),
      assistantLine('a2', [
        text(
          'All **24** due date tests pass, including the overdue sorting. '
          'Want me to add a reminder before a todo is due?',
        ),
      ]),
    ];
    final idle = ok(livePage(history, state: 'waiting_input'));
    final controller = ChatViewController(
      runner: ScriptedAgentCommandRunner([
        idle,
        ok('{"ok":true}'),
        for (var i = 0; i < 8; i++) idle,
      ]),
      sessionId: 's-1',
      decide: (_, _) async {},
      pollInterval: const Duration(days: 1),
    );
    await tester.pumpWidget(
      VoiceSettingsScope(
        settings: theme,
        child: shotApp(home: const Scaffold()),
      ),
    );
    await pushPage(
      tester,
      ChatViewPage(
        controller: controller,
        hostName: 'workstation',
        onOpenTerminal: () {},
        textToSpeech: FakeTts(),
        dictation: dictation,
      ),
    );
    await pumpFrames(tester);
    await tester.tap(find.byKey(const ValueKey('chat-talk')));
    await tester.pump();
    mic.say('Yes, remind me the evening before');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 2400));
    await pumpFrames(tester, 2);
    await saveShot(tester, '11-talk-mode');
    await tearDownPage(tester);
  });

  /// A phone syncing through the workstation, with a laptop and a Mac
  /// joined through setup codes. The hub is a fake in memory.
  Future<SyncController> pumpSync(WidgetTester tester) async {
    usePhoneView(tester);
    final server = FakeHubServer();
    final phone = await demoSyncDevice(server, hosts: [workstation, buildBox]);
    await phone.setUp(
      hub: workstation,
      passphrase: 'demo-passphrase-only',
      deviceName: 'Pixel 8',
    );
    for (final name in ['ThinkPad', 'MacBook']) {
      final offer = await phone.addDevice(name);
      final other = await demoSyncDevice(server);
      await other.join(
        setupCode: offer.setupCode,
        words: offer.words.join(' '),
        deviceName: name,
      );
    }
    await phone.syncNow();
    await phone.refreshDevices();
    await tester.pumpWidget(shotApp(home: const Scaffold()));
    await pushPage(tester, SyncPage(controller: phone));
    await tester.runAsync(pumpEventQueue);
    await pumpFrames(tester, 8);
    return phone;
  }

  /// Lets real async work (the fake hub, crypto) finish while frames pump.
  Future<void> pumpUntil(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 200 && !done(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    await pumpFrames(tester, 8);
  }

  testWidgets('12 sync', (tester) async {
    await pumpSync(tester);
    // Down to the device list, keeping the last switches in view.
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -470));
    await pumpFrames(tester, 8);
    await saveShot(tester, '12-sync');
    await tearDownPage(tester);
  });

  testWidgets('13 sync add device', (tester) async {
    await pumpSync(tester);
    final add = find.byKey(const ValueKey('sync-add-device'));
    await tester.scrollUntilVisible(
      add,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await pumpFrames(tester);
    await tester.tap(add);
    await pumpFrames(tester, 8);
    await tester.enterText(
      find.byKey(const ValueKey('sync-new-device-name')),
      'iPad',
    );
    await tester.tap(find.byKey(const ValueKey('sync-create-pairing')));
    await pumpFrames(tester, 8);
    await tester.tap(find.byKey(const ValueKey('sync-add-device-confirm')));
    await pumpUntil(
      tester,
      () => find.byType(QrCodeView).evaluate().isNotEmpty,
    );
    FocusManager.instance.primaryFocus?.unfocus();
    await pumpFrames(tester, 8);
    await saveShot(tester, '13-sync-add-device');
    await tearDownPage(tester);
  });

  testWidgets('14 live preview ready', (tester) async {
    final runner = ScriptedAgentCommandRunner([
      for (var i = 0; i < 4; i++) ok('{"seq":3,"ports":[]}'),
    ]);
    await pumpTerminal(
      tester,
      withPrompt: false,
      target: const ConnectTarget.tmux('web-dev'),
      screen: viteDevServerScreen(),
      previewWatcherFactory: (_) =>
          PreviewReadyController(runnerFactory: () => runner),
    );
    await tester.pump(PreviewReadyController.defaultStartDelay);
    await tester.pump(PreviewReadyController.defaultScreenDebounce);
    await pumpFrames(tester);
    await saveShot(tester, '14-live-preview-ready');
    await tearDownPage(tester);
  });

  testWidgets('15 desktop terminal', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      await pumpTerminal(tester, withPrompt: false, desktop: true);
      await saveShot(tester, '15-desktop-terminal', pixelRatio: 1);
      await tearDownPage(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('16 desktop home', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      // The README's shots from before the desktop shell (22 to 24 show
      // the shell); kept until the README moves to them.
      await pumpHome(tester, desktop: true, shellMode: false);
      await saveShot(tester, '16-desktop-home', pixelRatio: 1);
      await tearDownPage(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  /// Runs [body] as a Linux desktop.
  Future<void> asDesktop(Future<void> Function() body) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      await body();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  testWidgets('17 desktop settings', (tester) async {
    await asDesktop(() async {
      await pumpHome(tester, desktop: true, shellMode: false);
      await tester.tap(find.byTooltip('Settings'));
      await pumpFrames(tester, 8);
      await saveShot(tester, '17-desktop-settings', pixelRatio: 1);
      await tearDownPage(tester);
    });
  });

  testWidgets('18 herdr tabs', (tester) async {
    await pumpTerminal(tester, withPrompt: false);
    await tester.runAsync(pumpEventQueue);
    await pumpFrames(tester);
    await tester.tap(find.byKey(const ValueKey('mux-inline-label')));
    await tester.runAsync(pumpEventQueue);
    await pumpFrames(tester, 8);
    await saveShot(tester, '18-herdr-tabs');
    await tearDownPage(tester);
  });

  testWidgets('19 desktop tab popover', (tester) async {
    await asDesktop(() async {
      AdaptiveModalPointer.install();
      await pumpTerminal(tester, withPrompt: false, desktop: true);
      await tester.runAsync(pumpEventQueue);
      await pumpFrames(tester);
      await tester.longPress(find.byKey(const ValueKey('mux-tab-w1:t3')));
      await pumpFrames(tester, 8);
      await saveShot(tester, '19-desktop-tab-popover', pixelRatio: 1);
      await tearDownPage(tester);
    });
  });

  testWidgets('20 desktop this computer', (tester) async {
    await asDesktop(() async {
      await pumpHome(
        tester,
        desktop: true,
        thisComputer: true,
        shellMode: false,
      );
      await tester.tap(find.byKey(const ValueKey('machine-name')));
      await pumpFrames(tester, 8);
      await saveShot(tester, '20-desktop-this-computer', pixelRatio: 1);
      await tearDownPage(tester);
    });
  });

  testWidgets('21 desktop connect dialog', (tester) async {
    await asDesktop(() async {
      await pumpHome(tester, desktop: true, withFlow: true, shellMode: false);
      final context = tester.element(find.byType(HostsPage));
      unawaited(homeFlow!.connect(context, workstation, forcePicker: true));
      await tester.runAsync(pumpEventQueue);
      await pumpFrames(tester, 8);
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('adaptive-modal-dialog')),
          matching: find.text('Herdr'),
        ),
      );
      await tester.runAsync(pumpEventQueue);
      await pumpFrames(tester, 8);
      await saveShot(tester, '21-desktop-connect-dialog', pixelRatio: 1);
      await tearDownPage(tester);
    });
  });

  /// The desktop shell on Linux: sidebar, tabs, splits and dashboard.
  Future<DesktopShellController> pumpShellHome(
    WidgetTester tester, {
    AgentAttentionController? attention,
    void Function(TerminalWorkspaceController workspace)? onWorkspace,
    UsageController? usage,
  }) async {
    final shell = DesktopShellController(store: InMemoryDesktopShellStore());
    addTearDown(shell.dispose);
    await pumpHome(
      tester,
      desktop: true,
      thisComputer: true,
      withFlow: true,
      shell: shell,
      attention: attention,
      onWorkspace: onWorkspace,
      usage: usage,
    );
    await tester.runAsync(pumpEventQueue);
    await pumpFrames(tester, 6);
    return shell;
  }

  testWidgets('22 desktop shell dashboard', (tester) async {
    await asDesktop(() async {
      final shell = await pumpShellHome(tester, usage: demoUsage());
      shell.updatePrefs(
        (prefs) => prefs.setExpanded('m/workstation/h/w1', true),
      );
      shell.showHome = true;
      await pumpFrames(tester, 6);
      await saveShot(tester, '22-desktop-shell-dashboard', pixelRatio: 1);
      await tearDownPage(tester);
    });
  });

  testWidgets('23 desktop shell split', (tester) async {
    await asDesktop(() async {
      final shell = await pumpShellHome(tester);
      final views = {
        'session:workstation#herdr:w1',
        'session:workstation#herdr:w2',
      };
      shell.editLayout(
        views,
        (layout) => layout.split(
          layout.focusedPane.id,
          ShellEdge.right,
          'session:workstation#herdr:w1',
          fallbackView: 'session:workstation#herdr:w2',
        ),
      );
      await pumpFrames(tester, 6);
      await saveShot(tester, '23-desktop-shell-split', pixelRatio: 1);
      await tearDownPage(tester);
    });
  });

  testWidgets('24 desktop shell chat split', (tester) async {
    await asDesktop(() async {
      final shell = await pumpShellHome(tester);
      // A group, a pin and a couple of unread rows in the sidebar.
      shell.updatePrefs(
        (prefs) => prefs
            .addGroup(
              const SidebarGroup(
                id: 'clients',
                name: 'Clients',
                machineIds: ['build-box'],
              ),
            )
            .togglePin('m/workstation/h/w3'),
      );
      shell
        ..markUnread('m/workstation/h/w2')
        ..markUnread('m/build-box/t/ci');
      final thread = [
        stamped(
          userLine('u1', 'Add a due date to todos and cover it with tests'),
          const Duration(minutes: 12),
        ),
        assistantLine('a1', [
          text(
            "I'll add an optional **`dueDate`** to the todo schema, then "
            'validate it as an ISO date and sort overdue todos first.',
          ),
          toolUse('t1', 'Bash', {
            'command': 'npm test -- due-date',
            'description': 'Run the due date tests',
          }),
        ]),
      ];
      final controller = ChatViewController(
        runner: ScriptedAgentCommandRunner([
          ok(
            livePage(
              thread,
              state: 'needs_permission',
              started: const Duration(minutes: 12),
              pending: [
                {
                  'id': 'req-1',
                  'toolName': 'Bash',
                  'summary': 'npm test -- due-date',
                  'toolInput': {
                    'command': 'npm test -- due-date',
                    'description': 'Run the due date tests',
                  },
                },
              ],
            ),
          ),
        ]),
        sessionId: 's-api',
        fallbackName: 'todo-api',
        decide: (_, _) async {},
        pollInterval: const Duration(days: 1),
      );
      final home = tester.state<DesktopHomeState>(find.byType(DesktopHome));
      final api = const ConnectTarget.herdr(
        workspaceId: 'w1',
        label: 'api',
      ).apply(workstation);
      home.embedding.host!.presentChat(
        ChatViewRequest(
          host: api,
          agent: const AgentInfo(
            id: 's-api',
            name: 'todo-api',
            state: AgentAttentionState.needsInput,
            kind: 'claude',
          ),
          controller: controller,
          onOpenTerminal: () {},
          onDispose: () {},
        ),
      );
      await pumpFrames(tester);
      final views = home.embedding.host!.viewIds.toSet();
      shell.editLayout(
        views,
        (layout) => layout
            .showIn(layout.focusedPane.id, 'session:${api.id}')
            .split(
              layout.focusedPane.id,
              ShellEdge.right,
              'chat:${api.id}:s-api',
            ),
      );
      await pumpFrames(tester, 8);
      await saveShot(tester, '24-desktop-shell-chat-split', pixelRatio: 1);
      await tearDownPage(tester);
    });
  });

  testWidgets('25 home usage', (tester) async {
    await pumpHome(tester, usage: demoUsage(detailed: true));
    await tester.runAsync(pumpEventQueue);
    await pumpFrames(tester, 6);
    await saveShot(tester, '25-home-usage');
    await tearDownPage(tester);
  });

  testWidgets('26 usage breakdown', (tester) async {
    await pumpHome(tester, usage: demoUsage(detailed: true));
    await tester.runAsync(pumpEventQueue);
    await pumpFrames(tester, 6);
    // The bar opens the usage explorer (preview 17).
    await tester.tap(find.byType(UsageSummaryView));
    await tester.runAsync(pumpEventQueue);
    await pumpFrames(tester, 8);
    expect(find.byKey(const ValueKey('usage-explorer-page')), findsOneWidget);
    await saveShot(tester, '26-usage-breakdown');
    await tearDownPage(tester);
  });

  /// Chat View with a run of tool calls collapsed into one row, read
  /// aloud available, so the header shows its toggles and menu.
  Future<void> pumpCollapsedChat(WidgetTester tester) async {
    usePhoneView(tester);
    final theme = await everforest();
    final dictation = DictationController(
      FakeSpeechRecognizer(),
      language: () => 'en-US',
    );
    addTearDown(dictation.dispose);
    final thread = [
      stamped(
        userLine('u0', 'Add a due date to todos and sort overdue ones first'),
        const Duration(minutes: 21),
      ),
      assistantLine('b1', [
        toolUse('p1', 'Read', {
          'file_path': '/home/demo/todo-api/src/routes/todos.ts',
        }),
      ]),
      userLine('q1', [toolResult('p1', '  1 import { z } from "zod";')]),
      assistantLine('b2', [
        toolUse('p2', 'Edit', {
          'file_path': '/home/demo/todo-api/src/routes/todos.ts',
          'old_string': '  done: z.boolean(),',
          'new_string':
              '  dueDate: z.string().datetime().optional(),\n'
              '  done: z.boolean(),',
        }),
      ]),
      userLine('q2', [toolResult('p2', 'ok')]),
      assistantLine('b3', [
        toolUse('p3', 'Write', {
          'file_path': '/home/demo/todo-api/src/lib/sort.ts',
          'content': 'export function byDue(a, b) { ... }',
        }),
      ]),
      userLine('q3', [toolResult('p3', 'ok')]),
      assistantLine('b4', [
        toolUse('p4', 'Bash', {
          'command': 'npm test',
          'description': 'Run the tests',
        }),
      ]),
      userLine('q4', [toolResult('p4', 'Tests  24 passed (24)')]),
      assistantLine('b5', [
        text(
          'Todos have an optional **`dueDate`**, validated as an ISO date, '
          'and `byDue` sorts overdue todos first. All 24 tests pass.',
        ),
      ]),
      stamped(
        userLine(
          'u1',
          'Why does the overdue sort put todos without a date '
              'first?',
        ),
        const Duration(minutes: 6),
      ),
      assistantLine('a1', [
        text('Let me look at the comparator and its tests.'),
        toolUse('t1', 'Grep', {'pattern': 'isOverdue'}),
      ]),
      userLine('r1', [toolResult('t1', 'Found 3 files')]),
      assistantLine('a2', [
        toolUse('t2', 'Read', {
          'file_path': '/home/demo/todo-api/src/lib/sort.ts',
        }),
      ]),
      userLine('r2', [toolResult('t2', '  1 export function byDue(...')]),
      assistantLine('a3', [
        toolUse('t3', 'Edit', {
          'file_path': '/home/demo/todo-api/src/lib/sort.ts',
          'old_string': '  if (!a.dueDate) return -1;',
          'new_string': '  if (!a.dueDate) return 1;',
        }),
      ]),
      userLine('r3', [toolResult('t3', 'ok')]),
      assistantLine('a4', [
        toolUse('t4', 'Bash', {
          'command': 'npm test -- sort',
          'description': 'Run the sort tests',
        }),
      ]),
      userLine('r4', [toolResult('t4', 'Tests  9 passed (9)')]),
      assistantLine('a5', [
        text(
          '`byDue` returned **-1** for a todo without a date, so those '
          'came first. It now returns 1: overdue todos lead, undated ones '
          'go last, and the 9 sort tests pass.',
        ),
      ]),
    ];
    final controller = ChatViewController(
      runner: ScriptedAgentCommandRunner([
        ok(livePage(thread, state: 'waiting_input')),
      ]),
      sessionId: 's-1',
      decide: (_, _) async {},
      pollInterval: const Duration(days: 1),
    );
    await tester.pumpWidget(
      VoiceSettingsScope(
        settings: theme,
        child: shotApp(home: const Scaffold()),
      ),
    );
    await pushPage(
      tester,
      ChatViewPage(
        controller: controller,
        hostName: 'workstation',
        onOpenTerminal: () {},
        textToSpeech: FakeTts(),
        dictation: dictation,
      ),
    );
    await pumpFrames(tester, 8);
  }

  testWidgets('27 chat tool activity', (tester) async {
    await pumpCollapsedChat(tester);
    // The latest run opened, the earlier one still one line.
    await tester.tap(find.textContaining('searched once'));
    await pumpFrames(tester, 8);
    await saveShot(tester, '27-chat-tool-activity');
    await tearDownPage(tester);
  });

  testWidgets('28 chat menu', (tester) async {
    await pumpCollapsedChat(tester);
    await tester.tap(find.byKey(const ValueKey('chat-menu')));
    await pumpFrames(tester, 8);
    await saveShot(tester, '28-chat-menu');
    await tearDownPage(tester);
  });

  testWidgets('29 cant reach', (tester) async {
    await pumpHome(tester, buildBoxUnreachable: true);
    final details = find.byKey(const ValueKey('home-board-notice-details'));
    await tester.scrollUntilVisible(
      details,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await pumpFrames(tester);
    await tester.tap(details);
    await pumpFrames(tester);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -200));
    await pumpFrames(tester);
    expect(find.byType(HomeBoardNoticeTile), findsOneWidget);
    await saveShot(tester, '29-cant-reach');
    await tearDownPage(tester);
  });

  /// An attention controller watching the workstation's companion 0.8,
  /// smart approvals on: [status] for `status`, [demoApprovals] for
  /// `approvals`.
  Future<AgentAttentionController> smartAttention(
    WidgetTester tester, {
    required String status,
  }) async {
    final workspace = TerminalWorkspaceController(DemoTerminalRepository());
    addTearDown(workspace.dispose);
    final runner = CompanionRunner({
      'status': status,
      'approvals': demoApprovals(),
    });
    final attention = AgentAttentionController(
      workspace: workspace,
      runnerFactory: (_) => runner,
      provider: const ConductoreHostAttentionProvider(),
      companionProvider: const ConductoreHostAttentionProvider(),
      pollInterval: const Duration(days: 1),
    );
    attention.setAppForeground(false);
    addTearDown(attention.dispose);
    final session = workspace.open(
      workstation.copyWith(agentMonitor: AgentMonitorKind.companion),
    );
    await tester.runAsync(session.connect);
    await tester.runAsync(pumpEventQueue);
    return attention;
  }

  /// Chat View on the workstation's todo-api session, with the mic and
  /// Talk available.
  Future<void> pumpChat(
    WidgetTester tester,
    List<Map<String, Object?>> thread, {
    required String state,
    List<Map<String, Object?>> pending = const [],
    AgentAttentionController? attention,
  }) async {
    usePhoneView(tester);
    final theme = await everforest();
    final dictation = DictationController(
      FakeSpeechRecognizer(),
      language: () => 'en-US',
    );
    addTearDown(dictation.dispose);
    final controller = ChatViewController(
      runner: ScriptedAgentCommandRunner([
        ok(
          livePage(
            thread,
            state: state,
            started: const Duration(minutes: 12),
            pending: pending,
          ),
        ),
      ]),
      sessionId: 's-api',
      decide: (_, _) async {},
      pollInterval: const Duration(days: 1),
    );
    await tester.pumpWidget(
      VoiceSettingsScope(
        settings: theme,
        child: shotApp(home: const Scaffold()),
      ),
    );
    await pushPage(
      tester,
      ChatViewPage(
        controller: controller,
        hostName: 'workstation',
        onOpenTerminal: () {},
        textToSpeech: FakeTts(),
        dictation: dictation,
        attention: attention,
        hostId: attention == null ? null : workstation.id,
      ),
    );
    await tester.runAsync(pumpEventQueue);
    await pumpFrames(tester, 8);
  }

  testWidgets('30 approval risk', (tester) async {
    final attention = await smartAttention(
      tester,
      status: smartStatus(pending: [lowRiskTest]),
    );
    await pumpChat(
      tester,
      [
        stamped(
          userLine('u1', 'Add a due date to todos and cover it with tests'),
          const Duration(minutes: 12),
        ),
        assistantLine('a1', [
          text(
            "I'll add an optional **`dueDate`** to the todo schema, "
            'validate it as an ISO date and sort overdue todos first. '
            'The schema and the route are done; now the tests.',
          ),
          toolUse('t1', 'Bash', {
            'command': 'npm test -- due-date',
            'description': 'Run the due date tests',
          }),
        ]),
      ],
      state: 'needs_permission',
      pending: [jsonDecode(lowRiskTest) as Map<String, Object?>],
      attention: attention,
    );
    expect(find.text('Low risk'), findsOneWidget);
    expect(find.text('Trust…'), findsOneWidget);
    expect(find.text('Always'), findsOneWidget);
    await saveShot(tester, '30-approval-risk');
    await tearDownPage(tester);
  });

  testWidgets('31 approval rules', (tester) async {
    usePhoneView(tester);
    final attention = await smartAttention(
      tester,
      status: smartStatus(pending: const []),
    );
    await tester.pumpWidget(shotApp(home: const Scaffold()));
    await pushPage(
      tester,
      ApprovalRulesPage(
        controller: attention,
        host: workstation.copyWith(agentMonitor: AgentMonitorKind.companion),
      ),
    );
    await tester.runAsync(pumpEventQueue);
    await pumpFrames(tester, 8);
    expect(find.text('Bash(npm test *)'), findsOneWidget);
    await saveShot(tester, '31-approval-rules');
    await tearDownPage(tester);
  });

  testWidgets('32 voice guide', (tester) async {
    final mic = FakeSpeechRecognizer();
    final tts = FakeTts();
    final dictation = DictationController(mic, language: () => 'en-US');
    final speaker = ReadAloudController(
      tts: tts,
      preferences: () => VoicePreferences.defaults,
    );
    const request = PendingPermissionRequest(
      id: 'req-1',
      toolName: 'Bash',
      summary: 'npm test -- due-date',
    );
    const world = GuideWorld(
      machines: [
        GuideMachine(
          hostId: 'workstation',
          name: 'workstation',
          monitored: true,
        ),
        GuideMachine(hostId: 'build-box', name: 'build-box', monitored: true),
      ],
      agents: [
        GuideAgent(
          hostId: 'workstation',
          machineName: 'workstation',
          info: AgentInfo(
            id: 's-api',
            name: 'claude',
            project: 'todo-api',
            state: AgentAttentionState.needsInput,
            pendingRequests: [request],
          ),
        ),
        GuideAgent(
          hostId: 'workstation',
          machineName: 'workstation',
          info: AgentInfo(
            id: 's-web',
            name: 'claude',
            project: 'todo-web',
            state: AgentAttentionState.working,
          ),
        ),
      ],
    );
    final guide = GuideController(
      dictation: dictation,
      speaker: speaker,
      world: () => world,
      approvals: FakeApprovals(),
      navigator: FakeNavigator(GuideScreen.home),
      messenger: FakeMessenger(),
      preferences: () => GuidePreferences.defaults,
      speechLanguage: () => 'en-US',
      afterSpeechPause: Duration.zero,
      thinkingNotice: const Duration(seconds: 30),
    );
    addTearDown(() {
      guide.dispose();
      speaker.dispose();
      dictation.dispose();
    });
    await pumpHome(tester, guide: guide);
    expect(find.byKey(const ValueKey('home-voice-guide')), findsOneWidget);
    guide.start();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 1));
    }
    mic.say('approve');
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 1));
    }
    await pumpFrames(tester);
    expect(guide.phase, GuidePhase.speaking);
    await saveShot(tester, '32-voice-guide');
    guide.stop();
    await tearDownPage(tester);
  });

  testWidgets('33 usage accounts', (tester) async {
    await pumpHome(tester, usage: demoUsage(detailed: true, accounts: true));
    await tester.runAsync(pumpEventQueue);
    await pumpFrames(tester, 6);
    await tester.tap(find.byKey(const ValueKey('usage-accounts-chip')));
    await tester.runAsync(pumpEventQueue);
    await pumpFrames(tester, 8);
    // The details sheet (CON-080): limits, today and every account.
    expect(find.byKey(const ValueKey('usage-details')), findsOneWidget);
    expect(find.byKey(const ValueKey('usage-accounts')), findsOneWidget);
    await saveShot(tester, '33-usage-accounts');
    await tearDownPage(tester);
  });

  testWidgets('34 chat peer messages', (tester) async {
    await pumpChat(tester, [
      stamped(
        userLine('u1', 'Add a due date to todos and cover it with tests'),
        const Duration(minutes: 18),
      ),
      assistantLine('a1', [
        text(
          'Todos have an optional **`dueDate`**, validated as an ISO date. '
          'I asked the web session to show it in the list.',
        ),
      ]),
      stamped(
        userLine(
          'm1',
          'Another Claude session sent a message:\n'
              '<cross-session-message from="todo-web">\n'
              'The list shows due dates now. Can the API also return '
              '`overdue: true` so the UI does not compute it?\n'
              '</cross-session-message>\n\n'
              'This came from another Claude session — not typed by your '
              'user, but very likely working on their behalf.',
        ),
        const Duration(minutes: 9),
      ),
      assistantLine('a2', [
        toolUse('t1', 'Edit', {
          'file_path': '/home/demo/todo-api/src/routes/todos.ts',
          'old_string': '  return todo;',
          'new_string': '  return { ...todo, overdue: isOverdue(todo) };',
        }),
      ]),
      userLine('r1', [toolResult('t1', 'ok')]),
      assistantLine('a3', [
        text(
          'Done: `GET /todos` returns `overdue` for each todo. I asked the '
          'reviewer to check both changes.',
        ),
      ]),
      stamped(
        userLine(
          'm2',
          '<teammate-message teammate_id="reviewer" color="green">\n'
              '{"type":"idle_notification","from":"reviewer",'
              '"idleReason":"available",'
              '"result":"Reviewed the due date changes: no issues.\\n'
              'Both suites pass (24 and 31 tests)."}\n'
              '</teammate-message>',
        ),
        const Duration(minutes: 2),
      ),
      assistantLine('a4', [
        text(
          'The reviewer found no issues and both test suites pass. '
          'Ready to commit?',
        ),
      ]),
    ], state: 'waiting_input');
    expect(find.text('From session todo-web'), findsOneWidget);
    expect(find.text('reviewer finished'), findsOneWidget);
    await saveShot(tester, '34-chat-peer-messages');
    await tearDownPage(tester);
  });

  testWidgets('35 agents dashboard', (tester) async {
    usePhoneView(tester);
    final workspace = TerminalWorkspaceController(DemoTerminalRepository());
    addTearDown(workspace.dispose);
    final runner = CompanionRunner({
      'status': dashboardStatus(),
      'digest': jsonEncode(dashboardDigest()),
    });
    final attention = AgentAttentionController(
      workspace: workspace,
      runnerFactory: (_) => runner,
      provider: const ConductoreHostAttentionProvider(),
      companionProvider: const ConductoreHostAttentionProvider(),
      pollInterval: const Duration(days: 1),
    );
    attention.setAppForeground(false);
    addTearDown(attention.dispose);
    final digest = DigestController(
      source: AttentionDigestHostSource(attention: attention),
      observeLifecycle: false,
    );
    addTearDown(digest.dispose);
    final session = workspace.open(
      workstation.copyWith(agentMonitor: AgentMonitorKind.companion),
    );
    await tester.runAsync(session.connect);
    await tester.runAsync(pumpEventQueue);
    await tester.pumpWidget(shotApp(home: const Scaffold()));
    await pushPage(
      tester,
      AgentsDashboardPage(
        controller: digest,
        attention: attention,
        onOpenChat: (_, _) {},
        onOpenTerminal: (_, _) {},
      ),
    );
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(pumpEventQueue);
      await pumpFrames(tester);
    }
    expect(find.byKey(const ValueKey('digest-header')), findsOneWidget);
    await saveShot(tester, '35-agents-dashboard');
    await tearDownPage(tester);
  });

  testWidgets('36 chat pending bubble', (tester) async {
    usePhoneView(tester);
    final theme = await everforest();
    final dictation = DictationController(
      FakeSpeechRecognizer(),
      language: () => 'en-US',
    );
    addTearDown(dictation.dispose);
    final runner = TranscriptRunner(
      livePage(
        [
          stamped(
            userLine('u1', 'Add a due date to todos and cover it with tests'),
            const Duration(minutes: 4),
          ),
          assistantLine('a1', [
            text(
              "I'll add an optional **`dueDate`** to the todo schema, "
              'validate it as an ISO date and sort overdue todos first.',
            ),
            toolUse('t1', 'Edit', {
              'file_path': '/home/demo/todo-api/src/routes/todos.ts',
              'old_string': '  done: z.boolean(),',
              'new_string':
                  '  dueDate: z.string().datetime().optional(),\n'
                  '  done: z.boolean(),',
            }),
          ]),
          userLine('r1', [toolResult('t1', 'ok')]),
          assistantLine('a2', [
            toolUse('t2', 'Bash', {
              'command': 'npm test -- due-date',
              'description': 'Run the due date tests',
            }),
          ]),
        ],
        state: 'working',
        started: const Duration(minutes: 4),
      ),
    );
    final controller = ChatViewController(
      runner: runner,
      sessionId: 's-api',
      decide: (_, _) async {},
      pollInterval: const Duration(days: 1),
    );
    await tester.pumpWidget(
      VoiceSettingsScope(
        settings: theme,
        child: shotApp(home: const Scaffold()),
      ),
    );
    await pushPage(
      tester,
      ChatViewPage(
        controller: controller,
        hostName: 'workstation',
        onOpenTerminal: () {},
        textToSpeech: FakeTts(),
        dictation: dictation,
      ),
    );
    await tester.runAsync(pumpEventQueue);
    await pumpFrames(tester, 8);
    await tester.enterText(
      find.byType(TextField),
      'Also return overdue: true for each todo',
    );
    await tester.tap(find.byTooltip('Send'));
    await tester.runAsync(pumpEventQueue);
    await pumpFrames(tester, 8);
    FocusManager.instance.primaryFocus?.unfocus();
    await pumpFrames(tester);
    expect(runner.sent, hasLength(1));
    await saveShot(tester, '36-chat-pending-bubble');
    await tearDownPage(tester);
  });

  testWidgets('37 review cards', (tester) async {
    usePhoneView(tester);
    final review = ReviewController(
      client: ConductoreReviewClient(ReviewRunner()),
      sessionId: 's-api',
      agentName: 'todo-api',
      send: (_) async {},
    );
    await tester.pumpWidget(shotApp(home: const Scaffold()));
    await pushPage(tester, ReviewPage(controller: review));
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(pumpEventQueue);
      await pumpFrames(tester);
    }
    expect(find.byKey(const ValueKey('review-card-0')), findsOneWidget);
    await saveShot(tester, '37-review-cards');
    await tearDownPage(tester);
  });

  testWidgets('38 usage explorer day', (tester) async {
    usePhoneView(tester);
    final usage = demoExplorerUsage();
    await tester.pumpWidget(shotApp(home: const Scaffold()));
    await pushPage(tester, UsageExplorerPage(usage: usage));
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(pumpEventQueue);
      await pumpFrames(tester);
    }
    final day = find.byKey(
      ValueKey('usage-explorer-day-${usageDay(DateTime.now(), 1)}'),
    );
    await tester.tap(day);
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(pumpEventQueue);
      await pumpFrames(tester);
    }
    expect(find.byKey(const ValueKey('usage-day-page')), findsOneWidget);
    await saveShot(tester, '38-usage-explorer-day');
    await tearDownPage(tester);
  });

  /// Chat View with a reply worth copying, and other sessions to send to.
  Future<void> pumpActionsChat(WidgetTester tester) async {
    usePhoneView(tester);
    final theme = await everforest();
    final dictation = DictationController(
      FakeSpeechRecognizer(),
      language: () => 'en-US',
    );
    addTearDown(dictation.dispose);
    final controller = ChatViewController(
      runner: ScriptedAgentCommandRunner([
        ok(
          livePage([
            stamped(
              userLine('u1', 'How should the API report overdue todos?'),
              const Duration(minutes: 7),
            ),
            assistantLine('a1', [
              text(
                'Return an **`overdue`** flag with each todo, computed on '
                'the server so every client agrees:\n\n'
                '```ts\nconst overdue =\n  isPast(todo.dueDate) &&\n'
                '  !todo.done;\n```\n\n'
                'The web list can then sort and colour by it without its '
                'own date logic.',
              ),
            ]),
            stamped(
              userLine(
                'u2',
                'Good. Does the overdue sort handle todos '
                    'without a due date?',
              ),
              const Duration(minutes: 3),
            ),
            assistantLine('a2', [
              text(
                'Yes: todos without a due date are never **overdue**, so '
                'they sort after the overdue ones and keep their order. '
                'The overdue tests cover both cases.',
              ),
            ]),
          ], state: 'waiting_input'),
        ),
      ]),
      sessionId: 's-api',
      decide: (_, _) async {},
      pollInterval: const Duration(days: 1),
    );
    await tester.pumpWidget(
      VoiceSettingsScope(
        settings: theme,
        child: shotApp(home: const Scaffold()),
      ),
    );
    await pushPage(
      tester,
      ChatViewPage(
        controller: controller,
        hostName: 'workstation',
        onOpenTerminal: () {},
        textToSpeech: FakeTts(),
        dictation: dictation,
        forwardTargets: () => [
          ChatForwardTarget(
            host: workstation,
            agent: const AgentInfo(
              id: 's-web',
              name: 'todo-web',
              state: AgentAttentionState.working,
            ),
          ),
        ],
        onForward: (_, _) async {},
        share: (_) async => true,
      ),
    );
    await tester.runAsync(pumpEventQueue);
    await pumpFrames(tester, 8);
  }

  testWidgets('39 chat message menu', (tester) async {
    await pumpActionsChat(tester);
    await tester.longPress(
      find.textContaining('Return an', findRichText: true).first,
    );
    await pumpFrames(tester, 8);
    expect(find.byKey(const ValueKey('chat-action-forward')), findsOneWidget);
    await saveShot(tester, '39-chat-message-menu');
    await tearDownPage(tester);
  });

  testWidgets('40 chat find', (tester) async {
    await pumpActionsChat(tester);
    await tester.tap(find.byKey(const ValueKey('chat-search')));
    await pumpFrames(tester, 8);
    await tester.enterText(
      find.byKey(const ValueKey('chat-find-field')),
      'overdue',
    );
    await pumpFrames(tester, 8);
    await saveShot(tester, '40-chat-find');
    await tearDownPage(tester);
  });
}

/// Answers the companion by subcommand (`status`, `approvals`, …).
class CompanionRunner implements AgentCommandRunner {
  CompanionRunner(this.replies);

  final Map<String, String> replies;

  @override
  Future<AgentCommandResult> run(
    String command, {
    required Duration timeout,
  }) async {
    for (final MapEntry(:key, :value) in replies.entries) {
      if (command.contains('conductore-hostd $key')) return ok(value);
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

/// `npm test -- due-date` as companion 0.8 reports it: low risk, with the
/// rules it would suggest.
const lowRiskTest =
    '{"id":"req-1","toolName":"Bash","summary":"npm test -- due-date",'
    '"toolInput":{"command":"npm test -- due-date",'
    '"description":"Run the due date tests"},'
    '"risk":{"level":"low","reason":"Runs tests: npm test -- due-date"},'
    '"batchable":true,'
    '"suggestedRules":["Bash(npm test -- due-date)","Bash(npm test *)"],'
    '"repo":"/home/demo/todo-api"}';

/// Companion 0.8 status on the workstation, smart approvals on.
String smartStatus({required List<String> pending}) =>
    '{"version":1,"seq":4,"source":"daemon",'
    '"capabilities":["smart-approvals"],"agents":['
    '${agentJson('s-api', 'todo-api', state: pending.isEmpty ? 'working' : 'needs_permission', minutes: 0, pending: pending.join(','))}'
    ']}';

/// The workstation's rules: a time-boxed trust, two standing rules and
/// one that ends with its session.
String demoApprovals() {
  final now = DateTime.now().millisecondsSinceEpoch;
  Map<String, Object?> rule(
    String id,
    String rule,
    Map<String, Object?> scope, {
    int? expiresInMinutes,
    String? endsWithSession,
    required String source,
    int hits = 0,
  }) => {
    'id': id,
    'rule': rule,
    'scope': scope,
    'expiresAt': expiresInMinutes == null
        ? null
        : now + expiresInMinutes * 60000 + 30000,
    'endsWithSession': endsWithSession,
    'source': source,
    'createdAt': now - 3600000,
    'hits': hits,
    'lastUsedAt': hits > 0 ? now - 120000 : null,
  };
  const api = {'kind': 'repo', 'path': '/home/demo/todo-api'};
  return jsonEncode({
    'now': now,
    'rules': [
      rule(
        'r1',
        'Bash(npm test *)',
        api,
        expiresInMinutes: 45,
        source: 'trust',
        hits: 6,
      ),
      rule(
        'r2',
        'Bash(git status *)',
        const {'kind': 'any'},
        source: 'always',
        hits: 23,
      ),
      rule('r3', 'Read', api, source: 'cli', hits: 41),
      rule(
        'r4',
        'Bash(npm run lint *)',
        const {'kind': 'session', 'sessionId': 's-web', 'label': 'todo-web'},
        endsWithSession: 's-web',
        source: 'voice',
        hits: 2,
      ),
    ],
    'autoApproved': <Object>[],
  });
}

/// A Claude session's transcript that stays at [pageJson], and accepts
/// what the composer sends.
class TranscriptRunner implements AgentCommandRunner {
  TranscriptRunner(this.pageJson);

  final String pageJson;
  final List<String> sent = [];
  var _read = false;

  @override
  Future<AgentCommandResult> run(
    String command, {
    required Duration timeout,
  }) async {
    if (command.contains(' transcript ')) {
      // The thread once, then nothing new at the same offset.
      final reply = _read
          ? livePage(
              const [],
              state: 'working',
              started: const Duration(minutes: 4),
            )
          : pageJson;
      _read = true;
      return ok(reply);
    }
    sent.add(command);
    return ok('{"ok":true}');
  }

  @override
  Future<void> close() async {}
}

String usageDay(DateTime now, int back) {
  final d = now.subtract(Duration(days: back));
  return '${d.year}-${'${d.month}'.padLeft(2, '0')}-'
      '${'${d.day}'.padLeft(2, '0')}';
}

/// Companion 1.0 on the workstation for the explorer: two weeks of three
/// projects, by hour and by session when asked.
UsageController demoExplorerUsage() {
  final now = DateTime.now();
  final today = usageDay(now, 0);
  const projects = [
    ('todo-api', 'claude-opus-5', 1.0),
    ('todo-web', 'claude-sonnet-5', 0.55),
    ('infra', 'claude-haiku-4-5', 0.2),
  ];
  // Working hours, a lunch dip and an evening push.
  const hours = {
    9: 0.6,
    10: 1.0,
    11: 1.2,
    12: 0.4,
    14: 0.9,
    15: 1.3,
    16: 1.1,
    17: 0.7,
    21: 0.5,
  };
  List<Map<String, Object?>> rows({
    required String from,
    required String to,
    required bool hourly,
  }) => [
    for (var back = 0; back < 20; back++)
      if (usageDay(now, back).compareTo(from) >= 0 &&
          usageDay(now, back).compareTo(to) <= 0)
        for (final (project, model, share) in projects)
          if (hourly)
            for (final MapEntry(key: hour, value: weight) in hours.entries)
              {
                ...usageRow(
                  usageDay(now, back),
                  project: project,
                  model: model,
                  output: (90000 * share * weight * (1 + back % 3)).round(),
                  costUsd: 0.32 * share * weight * (1 + back % 3),
                ),
                'hour': hour,
              }
          else
            usageRow(
              usageDay(now, back),
              project: project,
              model: model,
              output: (720000 * share * (1 + back % 3)).round(),
              costUsd: 2.6 * share * (1 + back % 3),
            ),
  ];
  late final FakeUsageRunner runner;
  runner = FakeUsageRunner(() {
    final command = runner.commands.last;
    String? flag(String name) =>
        RegExp('--$name (\\S+)').firstMatch(command)?.group(1);
    final day = flag('day');
    final to = day ?? flag('to') ?? today;
    final from = day ?? flag('from') ?? usageDay(now, 6);
    final hourly = command.contains('--hourly');
    final list = rows(from: from, to: to, hourly: hourly);
    final json = usageReplyJson(
      machine: 'workstation',
      today: today,
      from: from,
      rows: list,
      limits: [
        {
          'label': '5h',
          'usedPct': 62,
          'resetsAt': now
              .add(const Duration(hours: 2, minutes: 14))
              .millisecondsSinceEpoch,
        },
        {
          'label': '7d',
          'usedPct': 31,
          'resetsAt': now.add(const Duration(days: 3)).millisecondsSinceEpoch,
        },
      ],
    );
    (json['claude']! as Map<String, Object?>)['bySession'] = [
      if (command.contains('--sessions'))
        for (final row in list)
          {
            ...row,
            'session': row['project'] == 'todo-api' && row['hour'] == 21
                ? 'hotfix'
                : const {
                    'todo-api': 'due dates',
                    'todo-web': 'overdue badge',
                    'infra': 'staging plan',
                  }[row['project']],
          },
    ];
    return FakeUsageRunner.ok({
      ...json,
      'version': '1.0.0',
      'to': to,
      'hourly': hourly,
      'utcOffsetMin': now.timeZoneOffset.inMinutes,
    });
  });
  final controller = UsageController(
    source: FakeUsageSource([workstation], {'workstation': runner}),
    preferences: MemoryUsagePreferencesStore(),
    observeLifecycle: false,
  );
  addTearDown(controller.dispose);
  return controller;
}

/// Companion status for the dashboard: an approval, a question, a stuck
/// agent and a finished one.
String dashboardStatus() =>
    '{"version":1,"seq":6,"source":"daemon",'
    '"capabilities":["smart-approvals","digest"],"agents":['
    '${agentJson('s-api', 'todo-api', state: 'needs_permission', minutes: 1, pending: dashboardPush)},'
    '${agentJson('s-web', 'todo-web', state: 'waiting_input', minutes: 4, message: 'Should the overdue badge be red or amber?')},'
    '${agentJson('s-infra', 'infra', state: 'working', minutes: 2)},'
    '${agentJson('s-docs', 'todo-docs', state: 'waiting_input', minutes: 25, message: 'README updated with the due date API.')}'
    ']}';

const dashboardPush =
    '{"id":"req-push","toolName":"Bash","summary":"git push origin due-date",'
    '"toolInput":{"command":"git push origin due-date"},'
    '"risk":{"level":"medium","reason":"Pushes to a remote: git push origin '
    'due-date"}}';

/// `conductore-hostd digest --summaries` for [dashboardStatus].
Map<String, Object?> dashboardDigest() {
  final now = DateTime.now();
  int ago(int minutes) =>
      now.subtract(Duration(minutes: minutes)).millisecondsSinceEpoch;
  Map<String, Object?> agent(
    String id,
    String name, {
    required String state,
    String? attention,
    required int minutes,
    String? headline,
    String? summary,
    List<Map<String, Object?>> pending = const [],
    List<Map<String, Object?>> stuck = const [],
    required Map<String, Object?> facts,
  }) => {
    'sessionId': id,
    'name': name,
    'machine': 'workstation',
    'project': name,
    'cwd': '/home/demo/$name',
    'state': state,
    'attention': attention,
    'live': true,
    'lastActivityAt': ago(minutes),
    'headline': headline,
    'pending': pending,
    'facts': facts,
    'stuck': stuck,
    'summary': summary == null
        ? null
        : {'text': summary, 'at': ago(0), 'fresh': true},
    'summaryPending': false,
  };
  Map<String, Object?> facts({
    required int turns,
    required List<String> files,
    required int added,
    required int removed,
    int tests = 0,
    int passed = 0,
    int failed = 0,
    int failedCommands = 0,
    required int tokens,
    required double cost,
  }) => {
    'turns': turns,
    'files': files,
    'filesEdited': files.length,
    'linesAdded': added,
    'linesRemoved': removed,
    'lines': 'git',
    'commands': tests + failedCommands + 2,
    'failedCommands': failedCommands,
    'testRuns': tests,
    'testsPassed': passed,
    'testsFailed': failed,
    if (tests > 0)
      'lastTest': {'ok': failed == 0, 'at': ago(3), 'command': 'npm test'},
    'waitingPermissionMs': 0,
    'waitingInputMs': 0,
    'tokens': {'total': tokens, 'output': tokens ~/ 90},
    'costUsd': cost,
    'partial': false,
  };
  return {
    'version': '1.0.0',
    'schema': 1,
    'machine': 'workstation',
    'generatedAt': now.millisecondsSinceEpoch,
    'since': ago(120),
    'source': 'daemon',
    'activity': true,
    'counts': <String, Object?>{},
    'agents': [
      agent(
        's-api',
        'todo-api',
        state: 'needs_permission',
        attention: 'permission',
        minutes: 1,
        headline: 'Pushing the branch next.',
        summary:
            'Added due dates with validation and overdue sorting; all 24 '
            'tests pass. Wants to push the branch.',
        pending: [
          {
            'id': 'req-push',
            'toolName': 'Bash',
            'summary': 'git push origin due-date',
          },
        ],
        facts: facts(
          turns: 4,
          files: ['src/routes/todos.ts', 'src/lib/sort.ts', 'test/due.ts'],
          added: 126,
          removed: 14,
          tests: 3,
          passed: 3,
          tokens: 1840000,
          cost: 6.4,
        ),
      ),
      agent(
        's-web',
        'todo-web',
        state: 'waiting_input',
        attention: 'question',
        minutes: 4,
        headline: 'Should the overdue badge be red or amber?',
        summary:
            'Shows due dates in the list and a badge for overdue todos. '
            'Asks which colour the badge should be.',
        facts: facts(
          turns: 2,
          files: ['src/TodoList.tsx', 'src/Badge.tsx'],
          added: 58,
          removed: 6,
          tokens: 610000,
          cost: 1.2,
        ),
      ),
      agent(
        's-infra',
        'infra',
        state: 'working',
        minutes: 2,
        summary:
            'Applying the staging plan; terraform apply keeps timing '
            'out on the database.',
        stuck: [
          {
            'rule': 'same-failure',
            'reason': '`terraform apply` failed 3 times',
          },
        ],
        facts: facts(
          turns: 3,
          files: ['staging/db.tf'],
          added: 4,
          removed: 2,
          failedCommands: 3,
          tokens: 380000,
          cost: 0.4,
        ),
      ),
      agent(
        's-docs',
        'todo-docs',
        state: 'waiting_input',
        minutes: 25,
        summary:
            'Documented the due date field and the overdue flag in '
            'the README.',
        facts: facts(
          turns: 1,
          files: ['README.md'],
          added: 31,
          removed: 3,
          tokens: 210000,
          cost: 0.3,
        ),
      ),
    ],
    'summaries': {
      'enabled': true,
      'pending': 0,
      'done': 4,
      'calls': 1,
      'tokens': {'total': 6300},
      'costUsd': 0.009,
    },
    'summaryUsageToday': {
      'runs': 1,
      'calls': 1,
      'tokens': {'total': 6300},
      'costUsd': 0.009,
    },
  };
}

/// Companion 1.0's `turns` and `diff` for turn 3 of todo-api.
class ReviewRunner implements AgentCommandRunner {
  static const _files = [
    (
      'src/routes/todos.ts',
      'M',
      5,
      1,
      '@@ -12,7 +12,11 @@ export const todoSchema = z.object({\n'
          '   title: z.string().min(1),\n'
          '-  done: z.boolean(),\n'
          '+  dueDate: z.string().datetime().optional(),\n'
          '+  done: z.boolean().default(false),\n'
          ' });\n'
          ' \n'
          ' router.get("/todos", async (req, res) => {\n'
          '-  res.json(await db.todos.all());\n'
          '+  const todos = await db.todos.all();\n'
          '+  const now = Date.now();\n'
          '+  res.json(todos.map((t) => ({ ...t, overdue: isOverdue(t, now) })));\n'
          ' });\n',
    ),
    (
      'src/lib/sort.ts',
      'M',
      3,
      1,
      '@@ -1,6 +1,8 @@\n'
          ' export function byDue(a: Todo, b: Todo) {\n'
          '-  if (!a.dueDate) return -1;\n'
          '+  if (!a.dueDate) return 1;\n'
          '+  if (!b.dueDate) return -1;\n'
          '+  return a.dueDate.localeCompare(b.dueDate);\n'
          ' }\n',
    ),
    (
      'test/due-date.test.ts',
      'A',
      4,
      0,
      '@@ -0,0 +1,4 @@\n'
          '+test("overdue todos sort first", () => {\n'
          '+  const sorted = [later, overdue].sort(byDue);\n'
          '+  expect(sorted[0]).toBe(overdue);\n'
          '+});\n',
    ),
  ];

  @override
  Future<AgentCommandResult> run(
    String command, {
    required Duration timeout,
  }) async {
    final now = DateTime.now();
    final word = RegExp(r'hostd (turns|diff)').firstMatch(command)?[1];
    final base = {
      'sessionId': 's-api',
      'turn': 3,
      'prompt': 'Add a due date to todos and cover it with tests',
      'repo': '/home/demo/todo-api',
      'committed': false,
      'late': false,
      'others': <String>[],
    };
    return switch (word) {
      'turns' => ok(
        jsonEncode({
          'sessionId': 's-api',
          'snapshots': true,
          'agent': {'state': 'waiting_input'},
          'pending': 0,
          'turns': [
            {
              ...base,
              'startedAt': now
                  .subtract(const Duration(minutes: 9))
                  .millisecondsSinceEpoch,
              'endedAt': now
                  .subtract(const Duration(minutes: 2))
                  .millisecondsSinceEpoch,
              'running': false,
              'files': [
                for (final (path, status, added, removed, _) in _files)
                  {
                    'path': path,
                    'status': status,
                    'added': added,
                    'removed': removed,
                  },
              ],
              'filesTotal': _files.length,
              'added': 12,
              'removed': 2,
              'before': {
                'ref': 'refs/conductore/snapshots/s-api/3/before',
                'commit': 'b' * 40,
              },
              'after': {
                'ref': 'refs/conductore/snapshots/s-api/3/after',
                'commit': 'a' * 40,
              },
              'undone': null,
            },
          ],
        }),
      ),
      'diff' => ok(
        jsonEncode({
          ...base,
          'live': false,
          'truncated': false,
          'files': [
            for (final (path, status, added, removed, patch) in _files)
              {
                'path': path,
                'status': status,
                'added': added,
                'removed': removed,
                'binary': false,
                'patch': patch,
              },
          ],
        }),
      ),
      _ => const AgentCommandResult(
        stdout: '{"error":"unknown command"}',
        stderr: '',
        exitCode: 1,
      ),
    };
  }

  @override
  Future<void> close() async {}
}
