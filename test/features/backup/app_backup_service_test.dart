import 'dart:convert';

import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/core/theme/terminal_appearance.dart';
import 'package:conduit/core/theme/terminal_pill_items.dart';
import 'package:conduit/core/theme/theme_controller.dart';
import 'package:conduit/core/theme/theme_preferences_repository.dart';
import 'package:conduit/features/backup/data/app_backup_service.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/hosts/domain/saved_hosts_repository.dart';
import 'package:conduit/features/hosts/presentation/hosts_controller.dart';
import 'package:conduit/features/sessions/domain/session_snapshot.dart';
import 'package:conduit/features/sync/data/app_local_sync_store.dart';
import 'package:conduit/features/sync/data/sync_crypto.dart';
import 'package:conduit/features/sync/domain/sync_record.dart';
import 'package:conduit/features/terminal/domain/host_key_verifier.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';
import '../sync/sync_test_support.dart';

void main() {
  group('AppBackupPasswordPolicy', () {
    test('enforces length, whitespace, and character variety', () {
      expect(AppBackupPasswordPolicy.validate('Short1!'), isNotNull);
      expect(AppBackupPasswordPolicy.validate(' StrongPass123!'), isNotNull);
      expect(AppBackupPasswordPolicy.validate('strongpassword12'), isNotNull);
      expect(AppBackupPasswordPolicy.validate('StrongPass123!'), isNull);
    });
  });

  group('AppBackupService', () {
    const password = 'StrongPass123!';

    Future<Map<String, Object?>> openRecords(List<int> bytes) async {
      final plaintext = await _crypto.open(
        Uint8List.fromList(bytes),
        passphrase: password,
      );
      final document = SyncDocument.fromJson(
        jsonDecode(utf8.decode(plaintext)),
      );
      return {
        for (final record in document.records.values) record.key: record.value,
      };
    }

    test('exports an encrypted bundle without credentials', () async {
      final fixture = await _Fixture.create();

      final bytes = await fixture.service.exportBackup(
        includeSecrets: false,
        password: password,
      );
      final text = utf8.decode(bytes);
      expect(SyncCrypto.isBundle(bytes), isTrue);
      expect(text, isNot(contains('Production')));

      final records = await openRecords(bytes);
      final host = records['host:existing']! as Map<String, Object?>;
      expect(host['name'], 'Production');
      expect(host.containsKey('password'), isFalse);
      expect(host.containsKey('hardwareKeys'), isFalse);
      expect(records.keys.where((k) => k.startsWith('secret:')), isEmpty);
      expect(records['knownHost:example.com:2222'], isNotNull);
      expect(records['setting:palette'], AppPalette.catppuccin.name);
    });

    group('the sync hub\'s login stays on each device', () {
      SavedHost hub(String key) => const SavedHost(
        id: 'hub',
        name: 'Workstation',
        host: 'ws.example.com',
        port: 22,
        username: 'andre',
        authMethod: SshAuthMethod.privateKey,
      ).copyWith(privateKey: key);

      AppBackupService serviceFor(LocalDevice device, {String? hubId}) =>
          AppBackupService(
            hostsController: device.hosts,
            themeController: device.theme,
            hostKeyVerifier: device.verifier,
            localStore: device.store,
            syncHubHostId: () => hubId,
            crypto: _crypto,
          );

      test('an export leaves out the hub\'s device key', () async {
        final a = await LocalDevice.create(
          hosts: [
            hub('KEY-OF-A'),
            machine('a', password: 'pw'),
          ],
        );
        final bytes = await serviceFor(
          a,
          hubId: 'hub',
        ).exportBackup(includeSecrets: true, password: password);

        final records = await openRecords(bytes);
        expect(records.containsKey('secret:host:hub'), isFalse);
        expect(records['secret:host:a'], containsPair('password', 'pw'));
        expect(records['host:hub'], containsPair('host', 'ws.example.com'));
      });

      test('an import keeps this device\'s hub login', () async {
        final a = await LocalDevice.create(hosts: [hub('KEY-OF-A')]);
        // A backup from before, or from a device without sync.
        final bytes = await serviceFor(
          a,
        ).exportBackup(includeSecrets: true, password: password);
        final b = await LocalDevice.create(hosts: [hub('KEY-OF-B')]);

        await serviceFor(
          b,
          hubId: 'hub',
        ).importBackup(bytes, password: password);

        final imported = b.hosts.hosts.single;
        expect(imported.privateKey, 'KEY-OF-B');
        expect(imported.authMethod, SshAuthMethod.privateKey);
      });

      test('a version 1 import keeps this device\'s hub login', () async {
        final payload = {
          'format': 'conduit.backup',
          'version': 1,
          'encrypted': false,
          'payload': {
            'hosts': [hub('KEY-OF-A').copyWith(name: 'Renamed').toJson()],
            'hostSortMode': 'name',
            'hostManualOrder': <String>[],
            'trustedHostKeys': <Object?>[],
          },
        };
        final b = await LocalDevice.create(hosts: [hub('KEY-OF-B')]);

        await serviceFor(
          b,
          hubId: 'hub',
        ).importBackup(Uint8List.fromList(utf8.encode(jsonEncode(payload))));

        final imported = b.hosts.hosts.single;
        expect(imported.name, 'Renamed');
        expect(imported.privateKey, 'KEY-OF-B');
      });
    });

    test('refuses a weak password', () async {
      final fixture = await _Fixture.create();
      await expectLater(
        fixture.service.exportBackup(includeSecrets: false, password: 'short'),
        throwsA(isA<AppBackupException>()),
      );
    });

    test(
      'exports with credentials and imports them with the password',
      () async {
        final source = await _Fixture.create();

        final bytes = await source.service.exportBackup(
          includeSecrets: true,
          password: password,
        );
        final exported = utf8.decode(bytes);

        expect(exported, isNot(contains('secret-password')));
        expect(exported, isNot(contains('hardware-stub')));

        final target = await _Fixture.create(empty: true);
        final result = await target.service.importBackup(
          bytes,
          password: password,
        );

        expect(result.hostsImported, 1);
        expect(result.trustedKeysImported, 1);
        final host = target.hostsRepository.persisted.single;
        expect(host.password, 'secret-password');
        expect(host.hardwareKeys.single.privateKey, 'hardware-stub');
        expect(host.lastConnectedAt, isNull);
        expect(target.verifier.records, hasLength(1));
        expect(target.themeController.palette, AppPalette.catppuccin);
        expect(target.themeController.terminalKeyboardRows, [
          const TerminalKeyboardRow(
            items: [
              TerminalKeyboardItem.builtIn(TerminalKeyboardAction.escape),
            ],
          ),
        ]);
      },
    );

    test('a wrong or missing password is reported', () async {
      final source = await _Fixture.create();
      final bytes = await source.service.exportBackup(
        includeSecrets: false,
        password: password,
      );
      final target = await _Fixture.create(empty: true);
      await expectLater(
        target.service.importBackup(bytes),
        throwsA(
          isA<AppBackupException>().having(
            (e) => e.message,
            'message',
            contains('password'),
          ),
        ),
      );
      await expectLater(
        target.service.importBackup(bytes, password: 'WrongPass123!'),
        throwsA(
          isA<AppBackupException>().having(
            (e) => e.message,
            'message',
            contains('password'),
          ),
        ),
      );
    });

    test('backs up and restores the pill toolbar buttons', () async {
      final source = await _Fixture.create();
      const items = [
        TerminalPillItem.button(TerminalPillButton.herdr),
        TerminalPillItem.button(TerminalPillButton.esc),
        TerminalPillItem.custom('deploy'),
      ];
      await source.themeController.setTerminalPillItems(items);

      final bytes = await source.service.exportBackup(
        includeSecrets: false,
        password: password,
      );
      final target = await _Fixture.create(empty: true);
      expect(
        target.themeController.terminalPillItems,
        defaultTerminalPillItems,
      );

      await target.service.importBackup(bytes, password: password);

      expect(target.themeController.terminalPillItems, items);
    });

    test(
      'imports by merging matching hosts and keeping unrelated hosts',
      () async {
        final source = await _Fixture.create();
        final bytes = await source.service.exportBackup(
          includeSecrets: false,
          password: password,
        );
        final target = await _Fixture.create(empty: true);
        target.hostsRepository.persisted = [
          buildHost('existing', username: 'before'),
          buildHost('unrelated', username: 'keep'),
        ];
        await target.hostsController.load();

        await target.service.importBackup(bytes, password: password);

        expect(target.hostsRepository.persisted, hasLength(2));
        final existing = target.hostsRepository.persisted.firstWhere(
          (host) => host.id == 'existing',
        );
        expect(existing.username, 'alice');
        // Credentials were not in the file: the local ones stay.
        expect(existing.password, 'pw');
        expect(
          target.hostsRepository.persisted
              .firstWhere((host) => host.id == 'unrelated')
              .username,
          'keep',
        );
        expect(
          target.hostsRepository.persistedSortMode,
          HostListSortMode.manual,
        );
        expect(target.hostsRepository.persistedManualOrder.first, 'existing');
      },
    );

    test('still imports version 1 backups', () async {
      final legacyHost = buildHost('legacy').toJson();
      final payload = {
        'hosts': [legacyHost],
        'hostSortMode': 'name',
        'hostManualOrder': <String>[],
        'theme': {'palette': AppPalette.catppuccin.name},
        'trustedHostKeys': <Object?>[],
      };
      final encrypted = const AppBackupCrypto().encrypt(
        Uint8List.fromList(utf8.encode(jsonEncode(payload))),
        password,
      );
      final target = await _Fixture.create(empty: true);
      final result = await target.service.importBackup(
        Uint8List.fromList(utf8.encode(jsonEncode(encrypted))),
        password: password,
      );
      expect(result.hostsImported, 1);
      expect(target.hostsRepository.persisted.single.password, 'pw');

      final plain = {
        'format': 'conduit.backup',
        'version': 1,
        'encrypted': false,
        'payload': payload,
      };
      final again = await _Fixture.create(empty: true);
      await again.service.importBackup(
        Uint8List.fromList(utf8.encode(jsonEncode(plain))),
      );
      expect(again.hostsRepository.persisted.single.id, 'legacy');
    });
  });
}

const _crypto = SyncCrypto(params: KdfParams.insecureFast, useIsolate: false);

class _Fixture {
  _Fixture({
    required this.hostsRepository,
    required this.hostsController,
    required this.themeController,
    required this.verifier,
    required this.service,
  });

  final FakeHostsRepository hostsRepository;
  final HostsController hostsController;
  final ThemeController themeController;
  final MemoryVerifier verifier;
  final AppBackupService service;

  static Future<_Fixture> create({bool empty = false}) async {
    final hostsRepository = FakeHostsRepository();
    if (!empty) {
      hostsRepository.persisted = [
        const SavedHost(
          id: 'existing',
          name: 'Production',
          host: 'example.com',
          port: 2222,
          username: 'alice',
          authMethod: SshAuthMethod.hardwareKey,
          password: 'secret-password',
          hardwareKeys: [
            HardwareKeyEntry(
              id: 'key-1',
              label: 'YubiKey',
              privateKey: 'hardware-stub',
              passphrase: 'hardware-passphrase',
            ),
          ],
          tags: ['prod'],
        ),
      ];
      hostsRepository.persistedSortMode = HostListSortMode.manual;
      hostsRepository.persistedManualOrder = ['existing'];
    }
    final hostsController = HostsController(hostsRepository);
    await hostsController.load();

    final themeController = ThemeController(
      InMemoryThemePreferences(
        const ThemePreferences(
          themeMode: ThemeMode.dark,
          palette: AppPalette.catppuccin,
          terminalKeyboardRows: [
            TerminalKeyboardRow(
              items: [
                TerminalKeyboardItem.builtIn(TerminalKeyboardAction.escape),
              ],
            ),
          ],
        ),
      ),
    );
    await themeController.load();

    final verifier = MemoryVerifier(
      empty
          ? const []
          : [
              HostKeyRecord(
                host: 'example.com',
                port: 2222,
                type: 'ssh-ed25519',
                fingerprint: 'SHA256:test',
                trustedAt: DateTime.parse('2026-01-02T03:04:05Z'),
              ),
            ],
    );
    final service = AppBackupService(
      hostsController: hostsController,
      themeController: themeController,
      hostKeyVerifier: verifier,
      localStore: AppLocalSyncStore(
        hosts: hostsController,
        theme: themeController,
        hostKeys: verifier,
        connectPreferences: MemoryJsonMapStore(),
        recentDirectoriesStore: MemoryJsonMapStore(),
        sessions: InMemorySessionSnapshotRepository(),
      ),
      crypto: _crypto,
      now: () => DateTime.parse('2026-02-03T04:05:06Z'),
    );

    return _Fixture(
      hostsRepository: hostsRepository,
      hostsController: hostsController,
      themeController: themeController,
      verifier: verifier,
      service: service,
    );
  }
}
