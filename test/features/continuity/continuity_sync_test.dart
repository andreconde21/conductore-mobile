import 'dart:convert';

import 'package:conduit/features/continuity/domain/continuity_record.dart';
import 'package:conduit/features/continuity/domain/continuity_rules.dart';
import 'package:conduit/features/continuity/domain/continuity_state.dart';
import 'package:conduit/features/continuity/presentation/continuity_controller.dart';
import 'package:conduit/features/continuity/presentation/continuity_sync_link.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/sync/data/sync_crypto.dart';
import 'package:conduit/features/sync/data/sync_setup.dart';
import 'package:conduit/features/sync/data/sync_state_store.dart';
import 'package:conduit/features/sync/domain/sync_category.dart';
import 'package:conduit/features/sync/domain/sync_config.dart';
import 'package:conduit/features/sync/domain/sync_record.dart';
import 'package:conduit/features/sync/presentation/sync_controller.dart';
import 'package:conduit/features/terminal/domain/host_key_verifier.dart';
import 'package:flutter_test/flutter_test.dart';

import '../sync/fake_sync_hub.dart';
import '../sync/sync_test_support.dart';

const _crypto = SyncCrypto(params: KdfParams.insecureFast, useIsolate: false);
const _passphrase = 'Correct-Horse-9';

var _clock = DateTime(2026, 9, 28, 12);

SavedHost _hub({String id = 'hub'}) => SavedHost(
  id: id,
  name: 'Workstation',
  host: 'ws.example.com',
  port: 22,
  username: 'andre',
  authMethod: SshAuthMethod.password,
  password: 'hub-password',
);

HostKeyRecord _hubKey() => HostKeyRecord(
  host: 'ws.example.com',
  port: 22,
  type: 'ssh-ed25519',
  fingerprint: 'SHA256:hubkey',
  trustedAt: DateTime.utc(2026),
);

/// A device with sync and continuity, like the app wires them.
class _Device {
  _Device._(this.local, this.sync, this.continuity);

  final LocalDevice local;
  final SyncController sync;
  final ContinuityController continuity;

  static Future<_Device> create(
    FakeHubServer server, {
    required String name,
    List<SavedHost> hosts = const [],
    bool desktop = false,
  }) async {
    final link = SyncControllerContinuityLink();
    late final LocalDevice local;
    final continuity = ContinuityController(
      store: InMemoryContinuityStore(),
      sync: link,
      machineFor: (id) => localMachineFor(
        id,
        findById: local.hosts.findById,
        selfMachineId: local.hosts.selfMachine?.id,
        thisComputer: local.hosts.thisComputer,
      ),
      selfMachineId: () => local.hosts.selfMachine?.id,
      desktop: desktop,
      now: () => _clock,
      observeLifecycle: false,
    );
    local = await LocalDevice.create(
      hosts: hosts,
      trustedKeys: [_hubKey()],
      desktop: desktop,
      continuity: continuity,
    );
    final sync = SyncController(
      state: InMemorySyncStateStore(),
      local: local.store,
      hubFactory: server.factory,
      hosts: local.hosts,
      hostKeys: local.verifier,
      crypto: _crypto,
      setupCodec: const SyncSetupCodec(
        crypto: _crypto,
        params: KdfParams.insecureFast,
      ),
      timers: FakeSyncTimers(),
      now: () => _clock,
      observeLifecycle: false,
    );
    link.controller = sync;
    await sync.start();
    await continuity.start();
    return _Device._(local, sync, continuity);
  }

  Future<void> setUp(String hubId, String name) async {
    await sync.setUp(
      hub: local.hosts.hosts.firstWhere((h) => h.id == hubId),
      passphrase: _passphrase,
      deviceName: name,
    );
  }

  void dispose() {
    continuity.dispose();
    sync.dispose();
  }
}

Future<Map<String, SyncRecord>> _hubRecords(FakeHubServer server) async {
  final vault = server.bundles.keys.single;
  final plaintext = await _crypto.open(
    server.bundles[vault]!,
    passphrase: _passphrase,
  );
  return SyncDocument.fromJson(jsonDecode(utf8.decode(plaintext))).records;
}

void main() {
  late FakeHubServer server;

  setUp(() {
    server = FakeHubServer();
    _clock = DateTime(2026, 9, 28, 12);
  });

  test('the desktop offers where the phone is, and neither device ever '
      'writes the other\'s record', () async {
    final phone = await _Device.create(
      server,
      name: 'Phone',
      hosts: [_hub(), machine('vtm')],
    );
    await phone.setUp('hub', 'Phone');
    final desk = await _Device.create(
      server,
      name: 'Omarchy',
      hosts: [_hub()],
      desktop: true,
    );
    _clock = _clock.add(const Duration(seconds: 10));
    await desk.setUp('hub', 'Omarchy');
    expect(desk.sync.config!.categories, contains(SyncCategory.continuity));

    // The phone opens a Claude session's Chat View.
    _clock = _clock.add(const Duration(minutes: 1));
    phone.continuity.reportPlace(
      const ContinuityPlace(
        machineId: 'vtm#herdr:w1',
        machineName: 'Machine vtm',
        view: ContinuityView.chat,
        agentId: 'agent-1',
        agentName: 'VTM',
        target: ConnectTarget.herdr(workspaceId: 'w1'),
      ),
    );
    phone.continuity.noteDraft('agent-1', 'half a prompt');
    await phone.sync.syncNow();

    _clock = _clock.add(const Duration(seconds: 30));
    await desk.sync.syncNow();

    final offer = desk.continuity.offer!;
    expect(offer.device.name, 'Phone');
    expect(offer.context.place.machineId, 'vtm');
    expect(offer.context.place.summary, 'VTM · Chat view');
    expect(desk.continuity.resolveDraftFor('agent-1', ''), isA<DraftFill>());

    // The desktop moves on; the phone sees it and keeps its own record.
    _clock = _clock.add(const Duration(minutes: 1));
    desk.continuity.reportPlace(
      const ContinuityPlace(
        machineId: 'vtm#tmux:work',
        target: ConnectTarget.tmux('work'),
      ),
    );
    await desk.sync.syncNow();
    await phone.sync.syncNow();

    final records = await _hubRecords(server);
    final phoneId = phone.sync.config!.deviceId;
    final deskId = desk.sync.config!.deviceId;
    expect(records.keys.where((key) => key.startsWith('continuity:')).toSet(), {
      'continuity:$phoneId',
      'continuity:$deskId',
    });
    expect(records['continuity:$phoneId']!.clock.device, phoneId);
    expect(records['continuity:$deskId']!.clock.device, deskId);
    expect(
      phone.continuity.devices.single.context!.place.target,
      const ConnectTarget.tmux('work'),
    );
    // Continuity never shows in the sync activity.
    for (final device in [phone, desk]) {
      for (final entry in device.sync.activity) {
        expect(entry.key, isNot(startsWith('continuity:')));
      }
    }

    phone.dispose();
    desk.dispose();
  });

  test('a setup saved before continuity existed turns it on', () {
    final old = SyncConfig.fromJson({
      'vaultId': 'v',
      'hubHostId': 'hub',
      'deviceId': 'd',
      'categories': ['machines', 'snippets'],
    })!;
    expect(old.categories, contains(SyncCategory.continuity));

    final turnedOff = SyncConfig.fromJson(
      const SyncConfig(
        vaultId: 'v',
        hubHostId: 'hub',
        deviceId: 'd',
        deviceName: 'Phone',
        categories: {SyncCategory.machines},
      ).toJson(),
    )!;
    expect(turnedOff.categories, {SyncCategory.machines});
  });
}
