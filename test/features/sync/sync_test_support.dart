import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/core/theme/theme_controller.dart';
import 'package:conduit/core/theme/theme_preferences_repository.dart';
import 'package:conduit/features/continuity/domain/continuity_sync_port.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/hosts/presentation/hosts_controller.dart';
import 'package:conduit/features/sessions/domain/session_snapshot.dart';
import 'package:conduit/features/sync/data/app_local_sync_store.dart';
import 'package:conduit/features/terminal/domain/host_key_verifier.dart';
import 'package:conduit/features/this_computer/domain/this_computer_settings.dart';
import 'package:flutter/material.dart';

import '../../support/test_doubles.dart';

class MemoryJsonMapStore implements JsonMapStore {
  Map<String, Object?> values = {};

  @override
  Future<Map<String, Object?>> readAll() async => Map.of(values);

  @override
  Future<void> writeAll(Map<String, Object?> values) async {
    this.values = Map.of(values);
  }
}

class MemoryVerifier implements HostKeyVerifier {
  MemoryVerifier([List<HostKeyRecord> records = const []])
    : records = List.of(records);

  List<HostKeyRecord> records;

  @override
  Future<List<HostKeyRecord>> loadTrustedKeys() async => List.of(records);

  @override
  Future<void> saveTrustedKeys(List<HostKeyRecord> records) async {
    this.records = List.of(records);
  }

  @override
  Future<void> removeTrustedKey(String host, int port) async {
    records.removeWhere((record) => record.host == host && record.port == port);
  }

  @override
  Future<bool> verify({
    required String host,
    required int port,
    required String type,
    required String fingerprint,
  }) async => true;
}

/// One device's app state in memory, with its [AppLocalSyncStore].
class LocalDevice {
  LocalDevice._({
    required this.hostsRepository,
    required this.hosts,
    required this.theme,
    required this.verifier,
    required this.connect,
    required this.recentDirs,
    required this.sessions,
    required this.store,
  });

  final FakeHostsRepository hostsRepository;
  final HostsController hosts;
  final ThemeController theme;
  final MemoryVerifier verifier;
  final MemoryJsonMapStore connect;
  final MemoryJsonMapStore recentDirs;
  final InMemorySessionSnapshotRepository sessions;
  final AppLocalSyncStore store;

  static Future<LocalDevice> create({
    List<SavedHost> hosts = const [],
    List<HostKeyRecord> trustedKeys = const [],
    ThemePreferences preferences = const ThemePreferences(
      themeMode: ThemeMode.dark,
      palette: AppPalette.catppuccin,
    ),
    bool desktop = false,
    ContinuitySyncPort? continuity,
  }) async {
    final hostsRepository = FakeHostsRepository()..persisted = List.of(hosts);
    final hostsController = HostsController(
      hostsRepository,
      thisComputerStore: desktop
          ? InMemoryThisComputerStore(
              ThisComputerSettings(host: SavedHost.thisComputer()),
            )
          : null,
    );
    await hostsController.load();
    final theme = ThemeController(InMemoryThemePreferences(preferences));
    await theme.load();
    final verifier = MemoryVerifier(trustedKeys);
    final connect = MemoryJsonMapStore();
    final recentDirs = MemoryJsonMapStore();
    final sessions = InMemorySessionSnapshotRepository();
    return LocalDevice._(
      hostsRepository: hostsRepository,
      hosts: hostsController,
      theme: theme,
      verifier: verifier,
      connect: connect,
      recentDirs: recentDirs,
      sessions: sessions,
      store: AppLocalSyncStore(
        hosts: hostsController,
        theme: theme,
        hostKeys: verifier,
        connectPreferences: connect,
        recentDirectoriesStore: recentDirs,
        sessions: sessions,
        continuity: continuity,
      ),
    );
  }
}

SavedHost machine(
  String id, {
  String name = 'Machine',
  String password = '',
  String privateKey = '',
  SshAuthMethod authMethod = SshAuthMethod.password,
}) => SavedHost(
  id: id,
  name: '$name $id',
  host: '$id.example.com',
  port: 22,
  username: 'andre',
  authMethod: authMethod,
  password: password,
  privateKey: privateKey,
);
