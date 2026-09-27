import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/sync/data/sync_crypto.dart';
import 'package:conduit/features/sync/data/sync_setup.dart';
import 'package:conduit/features/sync/data/sync_state_store.dart';
import 'package:conduit/features/sync/domain/sync_category.dart';
import 'package:conduit/features/sync/presentation/sync_controller.dart';
import 'package:conduit/features/sync/presentation/sync_page.dart';
import 'package:conduit/features/sync/presentation/widgets/qr_code_view.dart';
import 'package:conduit/features/terminal/domain/host_key_verifier.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_hub.dart';
import 'sync_test_support.dart';

const _crypto = SyncCrypto(params: KdfParams.insecureFast, useIsolate: false);

Future<(SyncController, LocalDevice)> _controller(
  FakeHubServer server, {
  List<SavedHost> hosts = const [],
}) async {
  final local = await LocalDevice.create(
    hosts: hosts,
    trustedKeys: [
      HostKeyRecord(
        host: 'ws.example.com',
        port: 22,
        type: 'ssh-ed25519',
        fingerprint: 'SHA256:hub',
        trustedAt: DateTime.utc(2026),
      ),
    ],
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
    observeLifecycle: false,
  );
  await sync.start();
  return (sync, local);
}

const _hub = SavedHost(
  id: 'hub',
  name: 'Workstation',
  host: 'ws.example.com',
  port: 22,
  username: 'andre',
  authMethod: SshAuthMethod.password,
  password: 'pw',
);

Future<void> _open(WidgetTester tester, SyncController sync) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.5;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: SyncPage(controller: sync)));
  await tester.pumpAndSettle();
}

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// Lets real async work (the fake hub, crypto) finish while frames pump.
Future<void> _until(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(done(), isTrue);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('sets up sync with a new passphrase', (tester) async {
    final server = FakeHubServer();
    final (sync, _) = await _controller(server, hosts: [_hub]);
    await _open(tester, sync);

    expect(find.text('Sync through your own machine'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('sync-set-up')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('sync-hub-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Workstation').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sync-check-hub')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('sync-passphrase')),
      'Correct-Horse-9',
    );
    await tester.enterText(
      find.byKey(const ValueKey('sync-passphrase-confirm')),
      'Different-Horse-9',
    );
    await tester.tap(find.byKey(const ValueKey('sync-set-up-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('The passphrases do not match.'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('sync-passphrase-confirm')),
      'Correct-Horse-9',
    );
    await tester.tap(find.byKey(const ValueKey('sync-set-up-confirm')));
    await _until(
      tester,
      () =>
          sync.status == SyncStatus.idle &&
          find.text('Hub: Workstation').evaluate().isNotEmpty,
    );

    expect(sync.enabled, isTrue);
    expect(find.text('Hub: Workstation'), findsOneWidget);
    expect(find.byKey(const ValueKey('sync-now')), findsOneWidget);
    expect(server.pushes, 1);
  });

  testWidgets('turning on credentials asks first', (tester) async {
    final server = FakeHubServer();
    final (sync, local) = await _controller(server, hosts: [_hub]);
    await sync.setUp(
      hub: local.hosts.hosts.single,
      passphrase: 'Correct-Horse-9',
    );
    await _open(tester, sync);

    final credentials = find.byKey(const ValueKey('sync-category-credentials'));
    await _tapVisible(tester, credentials);
    expect(find.text('Sync SSH keys and passwords?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(sync.config!.categories, isNot(contains(SyncCategory.credentials)));

    await _tapVisible(tester, credentials);
    await tester.tap(find.byKey(const ValueKey('sync-credentials-confirm')));
    await tester.pumpAndSettle();
    expect(sync.config!.categories, contains(SyncCategory.credentials));
  });

  testWidgets('adds a device: confirm, QR and words, cancel removes the key', (
    tester,
  ) async {
    final server = FakeHubServer();
    final (sync, local) = await _controller(server, hosts: [_hub]);
    await sync.setUp(
      hub: local.hosts.hosts.single,
      passphrase: 'Correct-Horse-9',
    );
    await _open(tester, sync);

    await _tapVisible(tester, find.byKey(const ValueKey('sync-add-device')));
    await tester.enterText(
      find.byKey(const ValueKey('sync-new-device-name')),
      'iPad',
    );
    await tester.tap(find.byKey(const ValueKey('sync-create-pairing')));
    await tester.pumpAndSettle();
    expect(find.textContaining('authorized_keys'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('sync-add-device-confirm')));
    await _until(tester, () => find.byType(QrCodeView).evaluate().isNotEmpty);

    expect(find.byType(QrCodeView), findsOneWidget);
    expect(find.byType(Chip), findsNWidgets(6));
    expect(server.authorizedKeys.single, endsWith('conductore-device iPad'));

    await _tapVisible(
      tester,
      find.byKey(const ValueKey('sync-pairing-cancel')),
    );
    expect(server.authorizedKeys, isEmpty);
  });

  testWidgets('turn off asks, and can delete the hub data', (tester) async {
    final server = FakeHubServer();
    final (sync, local) = await _controller(server, hosts: [_hub]);
    await sync.setUp(
      hub: local.hosts.hosts.single,
      passphrase: 'Correct-Horse-9',
    );
    await _open(tester, sync);

    await _tapVisible(tester, find.byKey(const ValueKey('sync-turn-off')));
    await tester.tap(find.byKey(const ValueKey('sync-delete-hub-data')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sync-turn-off-confirm')));
    await _until(tester, () => !sync.enabled);

    expect(sync.enabled, isFalse);
    expect(server.bundles, isEmpty);
    expect(find.byKey(const ValueKey('sync-set-up')), findsOneWidget);
  });

  testWidgets('joins with a pasted code and the six words', (tester) async {
    final server = FakeHubServer();
    final (a, aLocal) = await _controller(
      server,
      hosts: [_hub, machine('laptop')],
    );
    await a.setUp(hub: aLocal.hosts.hosts.first, passphrase: 'Correct-Horse-9');
    final offer = await a.addDevice('Desktop');
    final (b, bLocal) = await _controller(server);
    await _open(tester, b);

    await tester.tap(find.byKey(const ValueKey('sync-join')));
    await tester.pumpAndSettle();
    // Widget tests run as Android: the scanner is offered next to paste.
    expect(find.byKey(const ValueKey('sync-scan')), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('sync-setup-code')),
      offer.setupCode,
    );
    await tester.enterText(
      find.byKey(const ValueKey('sync-setup-words')),
      offer.words.join(' '),
    );
    await tester.tap(find.byKey(const ValueKey('sync-join-confirm')));
    await _until(
      tester,
      () =>
          b.status == SyncStatus.idle &&
          find.text('Hub: Workstation').evaluate().isNotEmpty,
    );

    expect(b.enabled, isTrue);
    expect(bLocal.hosts.hosts.map((h) => h.id), contains('laptop'));
    expect(find.text('Hub: Workstation'), findsOneWidget);
  });

  group('desktop forms (A-063, A-065)', () {
    final frame = find.byKey(const ValueKey('desktop-page-frame'));
    const mismatch = 'The passphrases do not match.';

    Future<void> startSetUp(WidgetTester tester, SyncController sync) async {
      await _open(tester, sync);
      await tester.tap(find.byKey(const ValueKey('sync-set-up')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sync-hub-picker')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Workstation').last);
      await tester.pumpAndSettle();
    }

    testWidgets(
      'desktop: Set up is a dialog and Enter moves the form along',
      (tester) async {
        final (sync, _) = await _controller(FakeHubServer(), hosts: [_hub]);
        await startSetUp(tester, sync);
        expect(frame, findsOneWidget);

        // Enter on the device name checks the hub.
        await tester.enterText(find.byType(TextField).first, 'Laptop');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await _until(
          tester,
          () => find
              .byKey(const ValueKey('sync-passphrase'))
              .evaluate()
              .isNotEmpty,
        );

        await tester.enterText(
          find.byKey(const ValueKey('sync-passphrase')),
          'Correct-Horse-9',
        );
        await tester.enterText(
          find.byKey(const ValueKey('sync-passphrase-confirm')),
          'Different-Horse-9',
        );
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
        expect(find.text(mismatch), findsOneWidget);
      },
      variant: TargetPlatformVariant({
        TargetPlatform.linux,
        TargetPlatform.windows,
        TargetPlatform.macOS,
      }),
    );

    testWidgets('phone: Set up is a full page and Enter submits nothing', (
      tester,
    ) async {
      final (sync, _) = await _controller(FakeHubServer(), hosts: [_hub]);
      await startSetUp(tester, sync);
      expect(frame, findsNothing);

      await tester.enterText(find.byType(TextField).first, 'Laptop');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('sync-passphrase')), findsNothing);
      expect(find.byKey(const ValueKey('sync-check-hub')), findsOneWidget);
    });
  });
}
