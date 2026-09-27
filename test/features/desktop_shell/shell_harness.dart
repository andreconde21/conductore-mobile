import 'dart:async';
import 'dart:convert';

import 'package:conduit/core/theme/theme_controller.dart';
import 'package:conduit/features/agent_attention/data/herdr_attention_provider.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/app_lock/presentation/app_lock_controller.dart';
import 'package:conduit/features/backup/data/app_backup_service.dart';
import 'package:conduit/features/desktop_shell/data/desktop_shell_store.dart';
import 'package:conduit/features/desktop_shell/presentation/desktop_home.dart';
import 'package:conduit/features/desktop_shell/presentation/desktop_shell_controller.dart';
import 'package:conduit/features/hosts/domain/home_preferences.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/hosts/presentation/home_board_controller.dart';
import 'package:conduit/features/hosts/presentation/hosts_controller.dart';
import 'package:conduit/features/hosts/presentation/hosts_page.dart';
import 'package:conduit/features/local_shell/presentation/local_shell_controller.dart';
import 'package:conduit/features/session_navigation/presentation/session_view_controller.dart';
import 'package:conduit/features/sessions/domain/connect_preferences.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/sessions/presentation/session_connect_flow.dart';
import 'package:conduit/features/terminal/domain/ssh_terminal_repository.dart';
import 'package:conduit/features/terminal/domain/ssh_terminal_session.dart';
import 'package:conduit/features/terminal/presentation/host_key_prompt_coordinator.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:conduit/features/usage/presentation/usage_controller.dart';
import 'package:conduit/features/usage/presentation/usage_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';
import '../hosts/home_board_fakes.dart';

/// Demo machines for the shell tests.
final workstation = buildHost(
  'workstation',
).copyWith(name: 'workstation', lastConnectedAt: DateTime.utc(2026, 9, 2));
final buildBox = buildHost(
  'build-box',
).copyWith(name: 'build-box', lastConnectedAt: DateTime.utc(2026, 9, 2));

/// A home page running as the desktop shell over fake machines:
/// workstation (Herdr: Infrastructure needs you, TheCalendar done; tmux
/// main and build) and build-box (tmux only).
class ShellHarness {
  late ThemeController theme;
  late HostsController hosts;
  late TerminalWorkspaceController workspace;
  late AgentAttentionController attention;
  late HomeBoards boards;
  late SessionConnectFlow flow;
  late DesktopShellController shell;
  late InMemoryDesktopShellStore store;
  late OutputTerminalRepository terminals;

  /// The shell's clock; tests move it past the reconnect settle time.
  DateTime now = DateTime.utc(2026, 9, 25, 12);

  /// Opens a session on [host] at [target] and connects it.
  Future<TerminalSessionController> open(
    WidgetTester tester,
    SavedHost host,
    ConnectTarget target,
  ) async {
    final session = workspace.open(target.apply(host), target: target);
    await tester.pump();
    await tester.pump();
    return session;
  }

  final runners = <String, HerdrFakeRunner>{
    'workstation': HerdrFakeRunner(tmuxSessions: TmuxFixtures.sessions),
    'build-box': HerdrFakeRunner.tmuxOnly(
      tmuxSessions: 'ci\t1\t2\t1790229600\n',
    ),
  };

  HerdrFakeRunner runnerFor(SavedHost host) =>
      runners[baseHostId(host.id)] ?? HerdrFakeRunner.tmuxOnly();

  /// The app's usage controller, provided above the page when set.
  UsageController? usageController;

  /// "Open Claude sessions in", provided above the page when set.
  SessionViewController? sessionViews;

  Widget page({bool? shellMode, UsageSummaryBuilder? usage}) => MaterialApp(
    home: _withUsage(
      HostsPage(
        hostsController: hosts,
        lockController: AppLockController(AlwaysAuthenticates()),
        terminalRepository: NoNetworkTerminalRepository(),
        workspaceController: workspace,
        localShellController: LocalShellController(),
        themeController: theme,
        hostKeyVerifier: NoopVerifier(),
        promptCoordinator: HostKeyPromptCoordinator(),
        sftpRepository: NoNetworkSftpRepository(),
        sftpBookmarksRepository: InMemorySftpBookmarks(),
        agentAttention: attention,
        backupService: AppBackupService(
          hostsController: hosts,
          themeController: theme,
          hostKeyVerifier: NoopVerifier(),
        ),
        fileExport: RecordingFileExport(),
        homeBoards: boards,
        homePreferences: InMemoryHomePreferencesRepository(),
        connectFlow: flow,
        previewRefreshInterval: const Duration(days: 1),
        desktopShell: shell,
        shellMode: shellMode,
        usageSummary: usage,
      ),
    ),
  );

  Widget _withUsage(Widget page) {
    final usage = usageController;
    final views = sessionViews;
    final withUsage = usage == null
        ? page
        : UsageScope(controller: usage, child: page);
    return views == null
        ? withUsage
        : SessionViewScope(controller: views, child: withUsage);
  }
}

Future<ShellHarness> pumpShell(
  WidgetTester tester, {
  InMemoryDesktopShellStore? store,
  Size size = const Size(1280, 800),
  double pixelRatio = 1,
  bool? shellMode,
  UsageSummaryBuilder? usage,
  void Function(ShellHarness harness)? before,
}) async {
  tester.view.physicalSize = size * pixelRatio;
  tester.view.devicePixelRatio = pixelRatio;
  addTearDown(tester.view.reset);
  final harness = ShellHarness();
  harness.theme = ThemeController(InMemoryThemePreferences());
  await harness.theme.load();
  final repository = FakeHostsRepository()..persisted = [workstation, buildBox];
  harness.hosts = HostsController(repository);
  await harness.hosts.load();
  harness.terminals = OutputTerminalRepository();
  harness.workspace = TerminalWorkspaceController(harness.terminals);
  addTearDown(harness.workspace.dispose);
  harness.attention = AgentAttentionController(
    workspace: harness.workspace,
    runnerFactory: (_) =>
        ScriptedAgentCommandRunner([StateError('no polling here')]),
    provider: const HerdrAttentionProvider(),
  );
  addTearDown(harness.attention.dispose);
  harness.boards = HomeBoards(
    runnerFactory: harness.runnerFor,
    pollInterval: const Duration(days: 1),
  );
  addTearDown(harness.boards.dispose);
  harness.flow = SessionConnectFlow(
    hostsController: harness.hosts,
    workspace: harness.workspace,
    runnerFactory: harness.runnerFor,
    preferences: InMemoryConnectPreferencesRepository(),
  );
  harness.store = store ?? InMemoryDesktopShellStore();
  harness.shell = DesktopShellController(
    store: harness.store,
    saveDelay: const Duration(milliseconds: 10),
    clock: () => harness.now,
  );
  addTearDown(harness.shell.dispose);
  before?.call(harness);
  await tester.pumpWidget(harness.page(shellMode: shellMode, usage: usage));
  await settleShell(tester);
  return harness;
}

/// Lets boards list, the layout load and a few frames run.
Future<void> settleShell(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Unmounts the page and lets timers (Herdr timeouts, debounces) finish.
Future<void> tearDownShell(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(minutes: 3));
}

/// A terminal session whose output the test writes.
class OutputTerminalSession extends TrackableTerminalSession {
  final _stdout = StreamController<List<int>>.broadcast();

  @override
  Stream<List<int>> get stdout => _stdout.stream;

  bool get listened => _stdout.hasListener;

  void print(String text) => _stdout.add(utf8.encode(text));
}

/// Hands out an [OutputTerminalSession] per connect, by session host id.
class OutputTerminalRepository implements SshTerminalRepository {
  final Map<String, List<OutputTerminalSession>> connects = {};

  /// The live connection of [hostId] (the last one, reconnects included).
  OutputTerminalSession? session(String hostId) => connects[hostId]?.last;

  @override
  Future<SshTerminalSession> connect(
    SavedHost host, {
    required int columns,
    required int rows,
  }) async {
    final session = OutputTerminalSession();
    (connects[host.id] ??= []).add(session);
    return session;
  }
}
