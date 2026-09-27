import 'dart:convert';

import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/snippets/domain/terminal_snippet.dart';
import 'package:conduit/features/sync/data/sync_crypto.dart';
import 'package:conduit/features/sync/data/sync_setup.dart';
import 'package:conduit/features/sync/data/sync_state_store.dart';
import 'package:conduit/features/sync/domain/sync_category.dart';
import 'package:conduit/features/sync/domain/sync_config.dart';
import 'package:conduit/features/sync/domain/sync_record.dart';
import 'package:conduit/features/sync/presentation/sync_controller.dart';
import 'package:conduit/features/terminal/domain/host_key_verifier.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_hub.dart';
import 'sync_test_support.dart';

const _crypto = SyncCrypto(params: KdfParams.insecureFast, useIsolate: false);
const _passphrase = 'Correct-Horse-9';

var _clock = DateTime.utc(2026, 9, 25, 12);

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

class _Device {
  _Device._(this.local, this.state, this.timers, this.sync);

  final LocalDevice local;
  final InMemorySyncStateStore state;
  final FakeSyncTimers timers;
  final SyncController sync;

  static Future<_Device> create(
    FakeHubServer server, {
    List<SavedHost> hosts = const [],
    List<HostKeyRecord> trustedKeys = const [],
  }) async {
    final local = await LocalDevice.create(
      hosts: hosts,
      trustedKeys: trustedKeys,
    );
    final state = InMemorySyncStateStore();
    final timers = FakeSyncTimers();
    final sync = SyncController(
      state: state,
      local: local.store,
      hubFactory: server.factory,
      hosts: local.hosts,
      hostKeys: local.verifier,
      crypto: _crypto,
      setupCodec: const SyncSetupCodec(
        crypto: _crypto,
        params: KdfParams.insecureFast,
      ),
      changeSources: [local.hosts, local.theme],
      timers: timers,
      now: () => _clock,
      observeLifecycle: false,
    );
    await sync.start();
    return _Device._(local, state, timers, sync);
  }

  SavedHost host(String id) => local.hosts.hosts.firstWhere((h) => h.id == id);

  Future<void> rename(String id, String name) =>
      local.hosts.upsert(host(id).copyWith(name: name));
}

void _tick([Duration by = const Duration(seconds: 10)]) {
  _clock = _clock.add(by);
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
    _clock = DateTime.utc(2026, 9, 25, 12);
  });

  Future<(_Device, _Device)> twoDevices() async {
    final a = await _Device.create(
      server,
      hosts: [_hub(), machine('a'), machine('b')],
      trustedKeys: [_hubKey()],
    );
    await a.sync.setUp(hub: a.host('hub'), passphrase: _passphrase);
    final b = await _Device.create(
      server,
      hosts: [_hub(id: 'my-hub')],
      trustedKeys: [_hubKey()],
    );
    _tick();
    await b.sync.setUp(hub: b.host('my-hub'), passphrase: _passphrase);
    return (a, b);
  }

  test('the first device creates the vault and pushes its data', () async {
    final a = await _Device.create(
      server,
      hosts: [
        _hub(),
        machine('a', password: 'secret-pw'),
      ],
    );
    await a.sync.setUp(hub: a.host('hub'), passphrase: _passphrase);

    expect(a.sync.status, SyncStatus.idle);
    expect(server.pushes, 1);
    final records = await _hubRecords(server);
    expect(records.keys, contains('host:a'));
    expect(records.keys, contains('setting:palette'));
    // Credentials stay home by default.
    expect(records.keys.where((k) => k.startsWith('secret:')), isEmpty);
    expect(records.toString(), isNot(contains('secret-pw')));
    expect(server.metas.values.single.devices.single.name, 'This device');
    // The server only ever sees ciphertext.
    expect(
      utf8.decode(server.bundles.values.single),
      isNot(contains('Machine a')),
    );
  });

  test('a second device joins with the passphrase and pulls everything, '
      'merging its own copy of the hub machine', () async {
    final (a, b) = await twoDevices();

    expect(b.local.hosts.hosts.map((h) => h.id), containsAll(['a', 'b']));
    // The hub it had saved under another id took the synced id.
    expect(b.sync.config!.hubHostId, 'hub');
    expect(
      b.local.hosts.hosts.where((h) => h.host == 'ws.example.com'),
      hasLength(1),
    );
    expect(server.metas.values.single.devices, hasLength(2));
    expect(a.sync.status, SyncStatus.idle);
  });

  test('a machine that takes the hub\'s id keeps its connect memory', () async {
    final a = await _Device.create(
      server,
      hosts: [_hub(), machine('a')],
      trustedKeys: [_hubKey()],
    );
    await a.sync.setUp(hub: a.host('hub'), passphrase: _passphrase);
    final b = await _Device.create(
      server,
      hosts: [_hub(id: 'my-hub')],
      trustedKeys: [_hubKey()],
    );
    b.local.connect.values = {
      'my-hub': {'rememberChoice': true},
    };
    b.local.recentDirs.values = {
      'my-hub': ['~/src'],
    };
    _tick();

    await b.sync.setUp(hub: b.host('my-hub'), passphrase: _passphrase);

    expect(b.local.connect.values.keys, ['hub']);
    expect(b.local.recentDirs.values['hub'], ['~/src']);
  });

  test('a wrong passphrase cannot join an existing hub', () async {
    await twoDevices();
    final c = await _Device.create(server, hosts: [_hub()]);
    await expectLater(
      c.sync.setUp(hub: c.host('hub'), passphrase: 'Wrong-Horse-9'),
      throwsA(isA<SyncSetupException>()),
    );
    expect(c.sync.enabled, isFalse);
  });

  test(
    'a local change is pushed after the debounce and pulled elsewhere',
    () async {
      final (a, b) = await twoDevices();
      await a.sync.syncNow();
      final pushes = server.pushes;

      _tick();
      await a.rename('a', 'Renamed on A');
      expect(server.pushes, pushes, reason: 'waits for the debounce');
      a.timers.fireDelays(const Duration(seconds: 5));
      await pumpEventQueue();
      await a.sync.syncNow();
      expect(server.pushes, pushes + 1);

      await b.sync.syncNow();
      expect(b.host('a').name, 'Renamed on A');
    },
  );

  test('a notification without a real change stays off the network', () async {
    final (a, _) = await twoDevices();
    await a.sync.syncNow();
    final reads = server.metaReads;

    a.local.theme.notifyListeners();
    a.timers.fireDelays(const Duration(seconds: 5));
    await pumpEventQueue();

    expect(server.metaReads, reads);
  });

  test('a notification without a real change does not backdate the next '
      'edit', () async {
    final (a, b) = await twoDevices();
    await a.sync.syncNow();
    await b.sync.syncNow();

    // T0: a no-op notification on A (like markConnected).
    a.local.theme.notifyListeners();
    a.timers.fireDelays(const Duration(seconds: 5));
    await pumpEventQueue();
    // T0+30m: B edits the machine.
    _tick(const Duration(minutes: 30));
    await b.rename('a', 'B at +30m');
    await b.sync.syncNow();
    // T0+60m: A edits it; the later edit must win.
    _tick(const Duration(minutes: 30));
    await a.rename('a', 'A at +60m');
    await a.sync.syncNow();

    expect(a.host('a').name, 'A at +60m');
    expect(
      (await _hubRecords(server))['host:a']!.value,
      containsPair('name', 'A at +60m'),
    );
  });

  test(
    'polls while open, pauses in the background and flushes on pause',
    () async {
      final (a, _) = await twoDevices();
      final poll = a.timers.active.where((t) => t.periodic).single;
      expect(poll.duration, const Duration(minutes: 3));

      await a.rename('a', 'Pending');
      a.sync.onPause();
      expect(poll.isActive, isFalse);
      await pumpEventQueue();
      await a.sync.syncNow();
      expect(
        (await _hubRecords(server))['host:a']!.value,
        containsPair('name', 'Pending'),
      );

      a.sync.onResume();
      expect(a.timers.active.where((t) => t.periodic), hasLength(1));
    },
  );

  test('a delete on one device removes the machine on the other', () async {
    final (a, b) = await twoDevices();
    _tick();
    await b.local.hosts.remove(b.host('b'));
    await b.sync.syncNow();
    await a.sync.syncNow();
    expect(a.local.hosts.hosts.map((h) => h.id), isNot(contains('b')));
    expect((await _hubRecords(server))['host:b']!.deleted, isTrue);
  });

  test('concurrent edits: the newer wins and the older is kept for '
      '"Keep mine"', () async {
    final (a, b) = await twoDevices();
    await a.sync.syncNow();

    _tick();
    await b.rename('a', 'Older edit on B');
    _tick();
    await a.rename('a', 'Newer edit on A');
    await a.sync.syncNow();
    await b.sync.syncNow();

    expect(b.host('a').name, 'Newer edit on A');
    final conflict = b.sync.activity.firstWhere(
      (e) => e.kind == SyncActivityKind.conflict,
    );
    expect(conflict.canRestore, isTrue);
    expect(conflict.lostValue, containsPair('name', 'Older edit on B'));

    _tick();
    await b.sync.keepMine(conflict);
    expect(b.host('a').name, 'Older edit on B');
    await a.sync.syncNow();
    expect(a.host('a').name, 'Older edit on B');
  });

  group('edits made while a sync runs', () {
    /// A renamed 'a' and synced; B's next sync downloads that change, and
    /// [edit] runs on B during the download.
    Future<(_Device, _Device)> editDuringDownload(
      Future<void> Function(_Device b) edit,
    ) async {
      final (a, b) = await twoDevices();
      await a.sync.syncNow();
      _tick();
      await a.rename('a', 'Renamed on A');
      await a.sync.syncNow();
      _tick();
      server.duringNextBundleRead = () => edit(b);
      await b.sync.syncNow();
      return (a, b);
    }

    test('a machine saved during the download is kept and pushed', () async {
      final (a, b) = await editDuringDownload(
        (b) => b.local.hosts.upsert(machine('new', password: 'pw')),
      );

      expect(b.local.hosts.hosts.map((h) => h.id), contains('new'));
      expect(b.host('new').password, 'pw');
      expect(b.host('a').name, 'Renamed on A');
      expect((await _hubRecords(server)).keys, contains('host:new'));
      await a.sync.syncNow();
      expect(a.local.hosts.hosts.map((h) => h.id), contains('new'));
    });

    test('a machine deleted during the download stays deleted', () async {
      final (_, b) = await editDuringDownload(
        (b) => b.local.hosts.remove(b.host('b')),
      );

      expect(b.local.hosts.hosts.map((h) => h.id), isNot(contains('b')));
      expect((await _hubRecords(server))['host:b']!.deleted, isTrue);
    });

    test('a machine edited during the download keeps the edit', () async {
      final (_, b) = await editDuringDownload(
        (b) => b.rename('b', 'Edited on B'),
      );

      expect(b.host('b').name, 'Edited on B');
      expect(b.host('a').name, 'Renamed on A');
      expect(
        (await _hubRecords(server))['host:b']!.value,
        containsPair('name', 'Edited on B'),
      );
    });

    test('a snippet added during the download is kept and pushed', () async {
      final (_, b) = await editDuringDownload(
        (b) => b.local.theme.setTerminalSnippets([
          ...b.local.theme.terminalSnippets,
          const TerminalSnippet(id: 'late', label: 'Late', text: 'uptime'),
        ]),
      );

      expect(b.local.theme.terminalSnippets.map((s) => s.id), contains('late'));
      expect((await _hubRecords(server)).keys, contains('snippet:late'));
    });
  });

  test('a push that loses the race merges and retries', () async {
    final (a, b) = await twoDevices();
    await a.sync.syncNow();
    _tick();
    await a.rename('a', 'From A');
    _tick();
    await b.rename('b', 'From B');
    server.beforeNextCommit = b.sync.syncNow;

    await a.sync.syncNow();

    final records = await _hubRecords(server);
    expect(records['host:a']!.value, containsPair('name', 'From A'));
    expect(records['host:b']!.value, containsPair('name', 'From B'));
    expect(a.host('b').name, 'From B');
  });

  group('turning a category back on', () {
    test('keeps an edit made here while it was off', () async {
      final (a, b) = await twoDevices();
      await a.sync.syncNow();
      await a.sync.setCategory(SyncCategory.appearance, false);
      await a.sync.syncNow();

      _tick();
      await a.local.theme.setTerminalFontSize(19);
      _tick();
      await a.sync.setCategory(SyncCategory.appearance, true);
      await a.sync.syncNow();

      expect(a.local.theme.terminalFontSize, 19);
      expect(
        (await _hubRecords(server))['setting:terminalFontSize']!.value,
        19,
      );
      await b.sync.syncNow();
      expect(b.local.theme.terminalFontSize, 19);
    });

    test('when another device changed it too, takes the hub\'s version and '
        'keeps this one restorable', () async {
      final (a, b) = await twoDevices();
      await a.sync.syncNow();
      await b.sync.syncNow();
      await a.sync.setCategory(SyncCategory.appearance, false);
      await a.sync.syncNow();

      _tick();
      await a.local.theme.setTerminalFontSize(19);
      _tick();
      await b.local.theme.setTerminalFontSize(15);
      await b.sync.syncNow();
      _tick();
      await a.sync.setCategory(SyncCategory.appearance, true);
      await a.sync.syncNow();

      expect(a.local.theme.terminalFontSize, 15);
      final conflict = a.sync.activity.firstWhere(
        (e) => e.kind == SyncActivityKind.conflict,
      );
      expect(conflict.key, 'setting:terminalFontSize');
      expect(conflict.canRestore, isTrue);
      expect(conflict.lostValue, 19);

      _tick();
      await a.sync.keepMine(conflict);
      expect(a.local.theme.terminalFontSize, 19);
    });
  });

  test('credentials sync only when turned on', () async {
    final a = await _Device.create(
      server,
      hosts: [
        _hub(),
        machine('a', password: 'secret-pw'),
      ],
    );
    await a.sync.setUp(
      hub: a.host('hub'),
      passphrase: _passphrase,
      categories: {...SyncCategory.defaults, SyncCategory.credentials},
    );
    final records = await _hubRecords(server);
    expect(
      records['secret:host:a']!.value,
      containsPair('password', 'secret-pw'),
    );
    // The hub's own login never syncs.
    expect(records.containsKey('secret:host:hub'), isFalse);
    expect(
      (records['host:hub']!.value! as Map).containsKey('authMethod'),
      isFalse,
    );
  });

  group('adding a device', () {
    test('pairs with the setup code and six words, then replaces the '
        'one-time key', () async {
      final a = await _Device.create(
        server,
        hosts: [_hub(), machine('a')],
        trustedKeys: [_hubKey()],
      );
      await a.sync.setUp(hub: a.host('hub'), passphrase: _passphrase);
      final offer = await a.sync.addDevice('iPad');
      expect(server.authorizedKeys.single, endsWith('conductore-device iPad'));

      final b = await _Device.create(server);
      _tick();
      await b.sync.join(
        setupCode: offer.setupCode,
        words: offer.words.join(' '),
      );

      expect(b.sync.enabled, isTrue);
      expect(b.sync.status, SyncStatus.idle);
      expect(b.local.hosts.hosts.map((h) => h.id), containsAll(['hub', 'a']));
      final hub = b.host('hub');
      expect(hub.authMethod, SshAuthMethod.privateKey);
      // The one-time key is gone; the device's own key replaced it.
      expect(server.authorizedKeys, hasLength(1));
      expect(
        server.authorizedKeys.single,
        isNot(contains(offer.publicKey.split(' ')[1])),
      );
      expect(
        server.authorizedKeys.single,
        contains(b.sync.config!.devicePublicKey!.split(' ')[1]),
      );
      expect(b.local.verifier.records.single.fingerprint, 'SHA256:hubkey');
      // A's login to the hub (password) did not replace B's key.
      expect(b.host('hub').password, isEmpty);

      await a.sync.refreshDevices();
      expect(
        a.sync.devices.map((d) => d.name),
        containsAll(['iPad', 'This device']),
      );
      expect(
        a.sync.devices.firstWhere((d) => d.name == 'iPad').publicKey,
        isNotNull,
      );
    });

    test('wrong words do not join and leave nothing behind', () async {
      final a = await _Device.create(
        server,
        hosts: [_hub()],
        trustedKeys: [_hubKey()],
      );
      await a.sync.setUp(hub: a.host('hub'), passphrase: _passphrase);
      final offer = await a.sync.addDevice('iPad');
      final b = await _Device.create(server);
      final wrong = [...offer.words]
        ..[5] = offer.words[5] == 'zebra' ? 'acid' : 'zebra';

      await expectLater(
        b.sync.join(setupCode: offer.setupCode, words: wrong.join(' ')),
        throwsA(isA<SyncSetupException>()),
      );
      expect(b.sync.enabled, isFalse);
      expect(b.local.hosts.hosts, isEmpty);

      await a.sync.cancelPairing(offer);
      expect(server.authorizedKeys, isEmpty);
    });

    test('removing a device revokes its key and stops it', () async {
      final a = await _Device.create(
        server,
        hosts: [_hub(), machine('a')],
        trustedKeys: [_hubKey()],
      );
      await a.sync.setUp(hub: a.host('hub'), passphrase: _passphrase);
      final offer = await a.sync.addDevice('Old phone');
      final b = await _Device.create(server);
      await b.sync.join(
        setupCode: offer.setupCode,
        words: offer.words.join(' '),
      );
      await a.sync.refreshDevices();

      await a.sync.removeDevice(
        a.sync.devices.firstWhere((d) => d.name == 'Old phone'),
      );

      expect(server.authorizedKeys, isEmpty);
      expect(server.metas.values.single.revoked, [b.sync.config!.deviceId]);
      expect(a.sync.devices.map((d) => d.name), ['This device']);
      // B can no longer log in; had it kept access, it would stop itself.
      await b.sync.syncNow();
      expect(b.sync.status, SyncStatus.error);
      expect(b.local.hosts.hosts.map((h) => h.id), contains('a'));
    });
  });

  test(
    'a device listed as revoked turns itself off and keeps its data',
    () async {
      final (a, b) = await twoDevices();
      final meta = server.metas.values.single;
      server.metas[server.metas.keys.single] = SyncHubMetaCopy.withRevoked(
        meta,
        [b.sync.config!.deviceId],
      );
      await b.sync.syncNow();
      expect(b.sync.enabled, isFalse);
      expect(b.sync.activity.single.message, contains('removed'));
      expect(b.local.hosts.hosts.map((h) => h.id), contains('a'));
      expect(a.sync.enabled, isTrue);
    },
  );

  test('turning off keeps local data and can delete the hub bundle', () async {
    final (a, b) = await twoDevices();
    await b.sync.turnOff();
    expect(b.sync.enabled, isFalse);
    expect(b.state.key, isNull);
    expect(b.local.hosts.hosts.map((h) => h.id), contains('a'));
    expect(server.bundles, isNotEmpty);

    await a.sync.turnOff(deleteHubData: true);
    expect(server.bundles, isEmpty);
    expect(server.metas, isEmpty);
  });

  test('never overwrites a hub it cannot decrypt', () async {
    final (a, _) = await twoDevices();
    final vault = server.bundles.keys.single;
    final foreign = await _crypto.newKey('Other-Passphrase-1');
    server.bundles[vault] = await _crypto.seal(
      foreign,
      utf8.encode('{}'),
      vaultId: vault,
    );
    server.metas[vault] = SyncHubMetaCopy.bump(server.metas[vault]!);
    final pushes = server.pushes;

    _tick();
    await a.rename('a', 'Local edit');
    await a.sync.syncNow();

    expect(a.sync.status, SyncStatus.error);
    expect(a.sync.error, contains('different passphrase'));
    expect(server.pushes, pushes);
  });
}
