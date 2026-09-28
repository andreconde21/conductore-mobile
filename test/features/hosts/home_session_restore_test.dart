import 'dart:async';
import 'dart:convert';

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
import 'package:conduit/features/local_shell/presentation/local_shell_controller.dart';
import 'package:conduit/features/sessions/domain/connect_preferences.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/sessions/domain/session_snapshot.dart';
import 'package:conduit/features/sessions/presentation/session_connect_flow.dart';
import 'package:conduit/features/sessions/presentation/session_restore_controller.dart';
import 'package:conduit/features/terminal/domain/ssh_terminal_repository.dart';
import 'package:conduit/features/terminal/domain/ssh_terminal_session.dart';
import 'package:conduit/features/terminal/presentation/host_key_prompt_coordinator.dart';
import 'package:conduit/features/terminal/presentation/terminal_page.dart';
import 'package:conduit/features/terminal/presentation/terminal_session_controller.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

import '../../support/test_doubles.dart';
import 'home_board_fakes.dart';

class _NoopWakelock extends WakelockPlusPlatformInterface {
  @override
  Future<void> toggle({required bool enable}) async {}

  @override
  Future<bool> get enabled async => false;
}

/// Every connect gets a fresh session that records what was typed.
class _RecordingRepository implements SshTerminalRepository {
  final connects = <String, TrackableTerminalSession>{};

  @override
  Future<SshTerminalSession> connect(
    SavedHost host, {
    required int columns,
    required int rows,
  }) async {
    final session = TrackableTerminalSession();
    connects[host.id] = session;
    return session;
  }
}

/// One app run: its own workspace and restore controller over the same
/// saved list, like a process start.
class _AppRun {
  _AppRun(this.store, this.hosts) {
    workspace = TerminalWorkspaceController(repository);
    restore = SessionRestoreController(
      workspace: workspace,
      repository: store,
      findHost: (id) async => hosts.where((host) => host.id == id).firstOrNull,
      saveDebounce: const Duration(milliseconds: 100),
    );
  }

  final SessionSnapshotRepository store;
  final List<SavedHost> hosts;
  final repository = _RecordingRepository();
  late final TerminalWorkspaceController workspace;
  late final SessionRestoreController restore;
  late final SessionConnectFlow flow;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  WakelockPlusPlatformInterface.instance = _NoopWakelock();

  final herdrHost = buildHost(
    'a',
  ).copyWith(name: 'Dev', lastConnectedAt: DateTime.utc(2026));
  final keyHost = buildHost('k').copyWith(
    name: 'Yubi',
    authMethod: SshAuthMethod.hardwareKey,
    lastConnectedAt: DateTime.utc(2026),
  );

  Future<_AppRun> pumpHome(
    WidgetTester tester,
    SessionSnapshotRepository store,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.6;
    addTearDown(tester.view.reset);
    final hosts = [herdrHost, keyHost];
    final run = _AppRun(store, hosts);
    final themeController = ThemeController(InMemoryThemePreferences());
    await themeController.load();
    final runner = HerdrFakeRunner();
    final hostsController = HostsController(
      FakeHostsRepository()..persisted = hosts,
    );
    final attention = AgentAttentionController(
      workspace: run.workspace,
      runnerFactory: (_) => ScriptedAgentCommandRunner([StateError('none')]),
      provider: const HerdrAttentionProvider(),
      pollInterval: const Duration(days: 1),
    );
    final boards = HomeBoards(
      runnerFactory: (_) => runner,
      pollInterval: const Duration(days: 1),
    );
    run.flow = SessionConnectFlow(
      hostsController: hostsController,
      workspace: run.workspace,
      runnerFactory: (_) => runner,
      preferences: InMemoryConnectPreferencesRepository(),
    );
    addTearDown(() {
      run.restore.dispose();
      attention.dispose();
      boards.dispose();
      run.workspace.dispose();
    });
    final verifier = NoopVerifier();
    await tester.pumpWidget(
      MaterialApp(
        home: HostsPage(
          hostsController: hostsController,
          lockController: AppLockController(AlwaysAuthenticates()),
          terminalRepository: NoNetworkTerminalRepository(),
          workspaceController: run.workspace,
          localShellController: LocalShellController(),
          themeController: themeController,
          hostKeyVerifier: verifier,
          promptCoordinator: HostKeyPromptCoordinator(),
          sftpRepository: NoNetworkSftpRepository(),
          sftpBookmarksRepository: InMemorySftpBookmarks(),
          agentAttention: attention,
          backupService: AppBackupService(
            hostsController: hostsController,
            themeController: themeController,
            hostKeyVerifier: verifier,
          ),
          fileExport: RecordingFileExport(),
          homeBoards: boards,
          homePreferences: InMemoryHomePreferencesRepository(),
          connectFlow: run.flow,
          sessionRestore: run.restore,
          previewRefreshInterval: const Duration(days: 1),
          paneRefocusDelay: const Duration(milliseconds: 50),
        ),
      ),
    );
    await settle(tester);
    return run;
  }

  Future<void> unmount(WidgetTester tester, _AppRun run) async {
    await tester.pumpWidget(const SizedBox());
    unawaited(run.flow.herdr.dispose());
    await tester.pump(const Duration(seconds: 1));
  }

  String typed(TrackableTerminalSession session) =>
      session.sent.map(utf8.decode).join();

  testWidgets('a Herdr workspace opened in one run is back, reattached, '
      'in the next', (tester) async {
    final store = InMemorySessionSnapshotRepository();

    final first = await pumpHome(tester, store);
    await tester.tap(find.byKey(const ValueKey('other-herdr-a-w1')));
    await settle(tester);
    expect(find.byType(TerminalPage), findsOneWidget);
    first.workspace.activeSession!.rename('Backend');
    await settle(tester);
    expect(store.stored.entries.single.sessionHostId, 'a#herdr:w1');
    await unmount(tester, first);

    // The process died; a new one starts with nothing open.
    final second = await pumpHome(tester, store);
    final session = second.workspace.sessions.single;
    expect(session.host.id, 'a#herdr:w1');
    expect(session.title, 'Backend');
    expect(find.byKey(const ValueKey('home-session-a#herdr:w1')), findsOne);
    expect(session.status, TerminalConnectionStatus.connected);
    // A plain attach: by default the app never moves Herdr's shared focus
    // (the laptop's Herdr shows it too).
    expect(typed(second.repository.connects['a#herdr:w1']!), 'herdr\r');
    await unmount(tester, second);
  });

  testWidgets('ended shells and hardware-key sessions wait on their tiles', (
    tester,
  ) async {
    final store = InMemorySessionSnapshotRepository(
      const SessionSnapshot(
        entries: [
          SessionSnapshotEntry(hostId: 'a', target: ConnectTarget.shell()),
          SessionSnapshotEntry(hostId: 'k', target: ConnectTarget.tmux('ops')),
        ],
      ),
    );
    final run = await pumpHome(tester, store);
    expect(run.workspace.sessions, hasLength(2));
    expect(run.repository.connects, isEmpty);
    expect(find.text('Shell ended · tap to start a new one'), findsOneWidget);
    expect(find.text('Tap to reconnect'), findsOneWidget);

    // Tapping the ended shell opens the terminal on a new shell; the
    // hardware-key tab behind it stays untouched until it is shown.
    await tester.tap(find.byKey(const ValueKey('home-session-a')));
    await settle(tester);
    expect(find.byType(TerminalPage), findsOneWidget);
    expect(run.repository.connects.keys, ['a']);
    expect(run.workspace.activeSession!.isConnected, isTrue);
    await unmount(tester, run);
  });
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  }
}
