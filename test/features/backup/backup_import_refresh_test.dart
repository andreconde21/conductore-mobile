import 'dart:async';
import 'dart:typed_data';

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
import 'package:conduit/features/sessions/domain/session_snapshot.dart';
import 'package:conduit/features/sync/data/app_local_sync_store.dart';
import 'package:conduit/features/sync/data/sync_crypto.dart';
import 'package:conduit/features/sync/domain/local_data_changes.dart';
import 'package:conduit/features/sync/domain/local_sync_store.dart';
import 'package:conduit/features/sync/domain/sync_category.dart';
import 'package:conduit/features/terminal/domain/host_key_verifier.dart';
import 'package:conduit/features/terminal/presentation/host_key_prompt_coordinator.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:conduit/features/this_computer/domain/this_computer_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';
import '../hosts/home_board_fakes.dart';
import '../sync/sync_test_support.dart';

/// André: "after importing a backup, the imported machines' Herdr
/// workspaces only appeared after restarting the app". Imported machines
/// carry no last-connected time, so the home board lists them only when
/// their host key is trusted; the page read the trusted keys at start.
void main() {
  const password = 'Correct-Horse-9';
  const crypto = SyncCrypto(params: KdfParams.insecureFast, useIsolate: false);

  HostKeyRecord keyOf(SavedHost host) => HostKeyRecord(
    host: host.host,
    port: host.port,
    type: 'ssh-ed25519',
    fingerprint: 'SHA256:${host.id}',
    trustedAt: DateTime.utc(2026),
  );

  late HostsController hosts;
  late MemoryVerifier verifier;
  late ThemeController theme;
  late LocalDataChanges changes;
  late AppLocalSyncStore store;
  late InMemoryHomePreferencesRepository homePreferences;

  // A backup from another device: machine "b", reached before there (its
  // host key is trusted), exported with the real bundle format.
  late Uint8List backup;
  setUpAll(() async {
    final other = await LocalDevice.create(
      hosts: [machine('b')],
      trustedKeys: [keyOf(machine('b'))],
    );
    backup = await AppBackupService(
      hostsController: other.hosts,
      themeController: other.theme,
      hostKeyVerifier: other.verifier,
      localStore: other.store,
      crypto: crypto,
    ).exportBackup(includeSecrets: false, password: password);
  });

  Future<void> pumpHome(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.6;
    addTearDown(tester.view.reset);
    final workspace = TerminalWorkspaceController(
      ImmediateTerminalRepository(TrackableTerminalSession()),
    );
    addTearDown(workspace.dispose);
    final agentAttention = AgentAttentionController(
      workspace: workspace,
      runnerFactory: (_) => ScriptedAgentCommandRunner([StateError('none')]),
      provider: const HerdrAttentionProvider(),
    );
    addTearDown(agentAttention.dispose);
    final boards = HomeBoards(
      runnerFactory: (_) => HerdrFakeRunner(),
      pollInterval: const Duration(days: 1),
    );
    addTearDown(boards.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: HostsPage(
          hostsController: hosts,
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
            hostsController: hosts,
            themeController: theme,
            hostKeyVerifier: verifier,
            localStore: store,
            changes: changes,
          ),
          fileExport: RecordingFileExport(),
          homeBoards: boards,
          homePreferences: homePreferences,
          localDataChanges: changes,
          previewRefreshInterval: const Duration(days: 1),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  Finder workspaceOf(String hostId, String workspace) =>
      find.byKey(ValueKey('other-herdr-$hostId-$workspace'));

  /// Pumps frames until [future] completes (awaiting it directly would
  /// stall: its timers only run while the test clock moves).
  Future<T> pumpUntilDone<T>(WidgetTester tester, Future<T> future) async {
    var done = false;
    late T value;
    Object? error;
    unawaited(
      future.then(
        (result) {
          value = result;
          done = true;
        },
        onError: (Object failure) {
          error = failure;
          done = true;
        },
      ),
    );
    for (var i = 0; i < 400 && !done; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    if (!done) fail('did not complete');
    if (error != null) throw error!;
    return value;
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  // Built inside each test body: futures made in setUp live outside the
  // test's fake-async zone and would never complete in it.
  Future<void> createDevice({bool desktop = false}) async {
    final home = machine('a').copyWith(lastConnectedAt: DateTime.utc(2026));
    hosts = HostsController(
      FakeHostsRepository()..persisted = [home],
      thisComputerStore: desktop
          ? InMemoryThisComputerStore(
              ThisComputerSettings(host: SavedHost.thisComputer()),
            )
          : null,
    );
    await hosts.load();
    verifier = MemoryVerifier([keyOf(home)]);
    theme = ThemeController(InMemoryThemePreferences());
    await theme.load();
    changes = LocalDataChanges();
    homePreferences = InMemoryHomePreferencesRepository();
    store = AppLocalSyncStore(
      hosts: hosts,
      theme: theme,
      hostKeys: verifier,
      connectPreferences: MemoryJsonMapStore(),
      recentDirectoriesStore: MemoryJsonMapStore(),
      sessions: InMemorySessionSnapshotRepository(),
      changes: changes,
    );
  }

  testWidgets('an imported machine lists its Herdr workspaces without a '
      'restart', (tester) async {
    await createDevice();
    await pumpHome(tester);
    await settle(tester);
    expect(workspaceOf('a', 'w1'), findsOneWidget);
    expect(workspaceOf('b', 'w1'), findsNothing);

    final imported = AppBackupService(
      hostsController: hosts,
      themeController: theme,
      hostKeyVerifier: verifier,
      localStore: store,
      changes: changes,
      crypto: crypto,
    ).importBackup(backup, password: password);
    expect((await pumpUntilDone(tester, imported)).hostsImported, 1);
    await settle(tester);

    expect(hosts.hosts.map((h) => h.id), containsAll(['a', 'b']));
    expect(workspaceOf('b', 'w1'), findsOneWidget);
    expect(workspaceOf('b', 'w2'), findsOneWidget);
  });

  testWidgets('a sync pull that adds a machine lists it and resets a '
      'machine filter that no longer matches', (tester) async {
    await createDevice();
    await homePreferences.save(const HomePreferences(machineFilter: {'gone'}));
    await pumpHome(tester);
    await settle(tester);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('machine-name'))).data,
      'All machines',
    );

    final pulled = machine('c');
    final applied = store.apply(
      {
        'host:c': {
          ...pulled.toJson()
            ..remove('password')
            ..remove('lastConnectedAt'),
        },
        'knownHost:${pulled.host}:22': {
          'host': pulled.host,
          'port': 22,
          'type': 'ssh-ed25519',
          'fingerprint': 'SHA256:c',
        },
      },
      {'host:c', 'knownHost:${pulled.host}:22'},
      const LocalSyncOptions(categories: SyncCategory.defaults),
      replace: false,
    );
    await pumpUntilDone(tester, applied);
    await settle(tester);

    expect(workspaceOf('c', 'w1'), findsOneWidget);
    expect((await homePreferences.load()).machineFilter, isEmpty);
  });

  testWidgets('a sync pull keeps a "This computer" machine filter', (
    tester,
  ) async {
    await createDevice(desktop: true);
    await homePreferences.save(
      const HomePreferences(machineFilter: {thisComputerHostId}),
    );
    await pumpHome(tester);
    await settle(tester);

    final applied = store.apply(
      {
        'host:c': {...machine('c').toJson()..remove('password')},
      },
      {'host:c'},
      const LocalSyncOptions(categories: SyncCategory.defaults),
    );
    await pumpUntilDone(tester, applied);
    await settle(tester);

    expect((await homePreferences.load()).machineFilter, {thisComputerHostId});
  });
}
