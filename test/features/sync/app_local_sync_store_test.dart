import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/sessions/domain/connect_target.dart';
import 'package:conduit/features/sessions/domain/session_snapshot.dart';
import 'package:conduit/features/snippets/domain/terminal_snippet.dart';
import 'package:conduit/features/sync/domain/local_sync_store.dart';
import 'package:conduit/features/sync/domain/sync_category.dart';
import 'package:conduit/features/terminal/domain/host_key_verifier.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sync_test_support.dart';

const _defaults = LocalSyncOptions(categories: SyncCategory.defaults);
const _everything = LocalSyncOptions(categories: {...SyncCategory.values});

void main() {
  test('credentials are not part of the default categories', () {
    expect(SyncCategory.defaults, isNot(contains(SyncCategory.credentials)));
  });

  test('a default snapshot carries no secrets, hardware keys or local-only '
      'fields', () async {
    final device = await LocalDevice.create(
      hosts: [
        machine('a', password: 'hunter2').copyWith(
          lastConnectedAt: DateTime(2026),
          snippets: const [
            TerminalSnippet(id: 's', label: 'token', text: 'T0K', hidden: true),
          ],
        ),
        const SavedHost(
          id: 'yubi',
          name: 'Yubi',
          host: 'y.example.com',
          port: 22,
          username: 'u',
          authMethod: SshAuthMethod.hardwareKey,
          hardwareKeys: [HardwareKeyEntry(id: 'k', privateKey: 'STUB')],
        ),
        SavedHost.localShell(id: 'local', name: 'This phone'),
      ],
    );

    final values = await device.store.snapshot(_defaults);
    final text = values.toString();
    expect(text, isNot(contains('hunter2')));
    expect(text, isNot(contains('STUB')));
    expect(text, isNot(contains('T0K')));
    expect(values.containsKey('host:local'), isFalse);
    final host = values['host:a']! as Map;
    expect(host.containsKey('lastConnectedAt'), isFalse);
    expect(host['authMethod'], 'password');
    expect(values.keys.where((k) => k.startsWith('secret:')), isEmpty);

    // Even with credentials on, hardware-key stubs stay home.
    final all = await device.store.snapshot(_everything);
    expect(all.toString(), contains('hunter2'));
    expect(all.toString(), contains('T0K'));
    expect(all.toString(), isNot(contains('STUB')));
  });

  test("the hub machine's login never leaves the device", () async {
    final device = await LocalDevice.create(
      hosts: [
        machine('hub', authMethod: SshAuthMethod.privateKey, privateKey: 'PEM'),
      ],
    );
    final values = await device.store.snapshot(
      const LocalSyncOptions(
        categories: {...SyncCategory.values},
        hubHostId: 'hub',
      ),
    );
    expect((values['host:hub']! as Map).containsKey('authMethod'), isFalse);
    expect(values.containsKey('secret:host:hub'), isFalse);
  });

  test(
    'applying machines keeps local secrets and removes deleted ones',
    () async {
      final source = await LocalDevice.create(
        hosts: [
          machine('a', password: 'from-source'),
          machine('b'),
        ],
      );
      final target = await LocalDevice.create(
        hosts: [
          machine('a', name: 'Old', password: 'local-password'),
          machine('gone'),
          SavedHost.localShell(id: 'local', name: 'This phone'),
        ],
      );
      final values = await source.store.snapshot(_defaults);

      await target.store.apply(values, {
        ...values.keys,
        'host:gone',
      }, _defaults);

      final hosts = {for (final h in target.hosts.hosts) h.id: h};
      expect(hosts.keys, containsAll(['a', 'b', 'local']));
      expect(hosts.containsKey('gone'), isFalse);
      expect(hosts['a']!.name, 'Machine a');
      expect(hosts['a']!.password, 'local-password');
    },
  );

  test('applying leaves machines and snippets outside the changed keys as '
      'they are now', () async {
    final source = await LocalDevice.create(
      hosts: [machine('a'), machine('b')],
    );
    await source.theme.setTerminalSnippets(const [
      TerminalSnippet(id: 'x', label: 'deploy', text: 'make deploy'),
    ]);
    final values = await source.store.snapshot(_defaults);
    final target = await LocalDevice.create(
      hosts: [
        machine('a', name: 'Old'),
        machine('b', name: 'Edited here'),
      ],
    );
    await target.theme.setTerminalSnippets(const [
      TerminalSnippet(id: 'new', label: 'new', text: 'uptime'),
    ]);

    await target.store.apply(values, {'host:a', 'snippet:x'}, _defaults);

    final hosts = {for (final h in target.hosts.hosts) h.id: h};
    expect(hosts['a']!.name, 'Machine a');
    expect(hosts['b']!.name, 'Edited here b');
    expect(target.theme.terminalSnippets.map((s) => s.id), ['x', 'new']);
  });

  test('credentials apply when that category is on', () async {
    final source = await LocalDevice.create(
      hosts: [machine('a', password: 'from-source')],
    );
    final target = await LocalDevice.create(hosts: [machine('a')]);
    final values = await source.store.snapshot(_everything);

    await target.store.apply(values, values.keys.toSet(), _everything);

    expect(target.hosts.hosts.single.password, 'from-source');
  });

  test('hidden snippet text stays local without credentials', () async {
    final source = await LocalDevice.create();
    await source.theme.setTerminalSnippets(const [
      TerminalSnippet(id: 'x', label: 'deploy', text: 'make deploy'),
      TerminalSnippet(id: 'p', label: 'pw', text: 'remote', hidden: true),
    ]);
    final target = await LocalDevice.create();
    await target.theme.setTerminalSnippets(const [
      TerminalSnippet(id: 'p', label: 'old', text: 'mine', hidden: true),
    ]);
    final values = await source.store.snapshot(_defaults);

    await target.store.apply(values, values.keys.toSet(), _defaults);

    expect(target.theme.terminalSnippets.map((s) => s.id), ['x', 'p']);
    expect(target.theme.terminalSnippets.last.label, 'pw');
    expect(target.theme.terminalSnippets.last.text, 'mine');
  });

  test('settings, trusted keys, connect memory and sessions travel', () async {
    final source = await LocalDevice.create(
      trustedKeys: [
        HostKeyRecord(
          host: 'a.example.com',
          port: 22,
          type: 'ssh-ed25519',
          fingerprint: 'SHA256:abc',
          trustedAt: DateTime(2026),
        ),
      ],
    );
    await source.theme.setPalette(AppPalette.values.last);
    await source.theme.setTerminalFontSize(17);
    await source.theme.setVoice(
      source.theme.voice.copyWith(readAloudByDefault: true, ttsRate: 1.25),
    );
    source.connect.values = {
      'a': {'rememberChoice': true},
    };
    source.recentDirs.values = {
      'a': ['~/src'],
    };
    await source.sessions.save(
      const SessionSnapshot(
        entries: [
          SessionSnapshotEntry(hostId: 'a', target: ConnectTarget.shell()),
        ],
      ),
    );
    final target = await LocalDevice.create();
    final values = await source.store.snapshot(_defaults);

    await target.store.apply(values, values.keys.toSet(), _defaults);

    expect(target.theme.selectedPalette, AppPalette.values.last);
    expect(target.theme.terminalFontSize, 17);
    expect(target.theme.voice.readAloudByDefault, isTrue);
    expect(target.theme.voice.ttsRate, 1.25);
    expect(target.verifier.records.single.fingerprint, 'SHA256:abc');
    expect(target.connect.values['a'], {'rememberChoice': true});
    expect(target.recentDirs.values['a'], ['~/src']);
    expect(target.sessions.stored.entries.single.hostId, 'a');
  });
}
