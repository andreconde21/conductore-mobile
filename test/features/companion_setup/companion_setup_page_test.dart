import 'package:conduit/features/companion_setup/presentation/companion_install_sheet.dart';
import 'package:conduit/features/companion_setup/presentation/companion_setup_controller.dart';
import 'package:conduit/features/companion_setup/presentation/companion_setup_page.dart';
import 'package:conduit/features/companion_setup/presentation/companion_status_chip.dart';
import 'package:conduit/features/hosts/presentation/host_form_page.dart';
import 'package:conduit/features/hosts/presentation/hosts_controller.dart';
import 'package:conduit/features/hosts/presentation/widgets/machine_switcher.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';
import 'companion_fakes.dart';

void main() {
  final host = buildHost('box');
  late MatchingRunner runner;
  late FakeSftpSession sftp;
  late CompanionSetupController controller;

  setUp(() {
    runner = MatchingRunner({});
    sftp = FakeSftpSession(home: '/home/andre', tree: {});
    controller = CompanionSetupController(
      runnerFactory: (_) => runner,
      sftpRepository: FakeSftpRepository(sftp),
      loadBundle: () async => fakeBundle(),
    );
  });

  tearDown(() => controller.dispose());

  /// Samsung Galaxy M53: 1080x2400 at 2.625, with a 48 dp three-button
  /// navigation bar reported as bottom view padding.
  void galaxyM53(WidgetTester tester) {
    tester.view.devicePixelRatio = 2.625;
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.viewPadding = const FakeViewPadding(bottom: 48 * 2.625);
    tester.view.padding = const FakeViewPadding(bottom: 48 * 2.625);
    addTearDown(tester.view.reset);
  }

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      CompanionSetupScope(
        controller: controller,
        child: MaterialApp(
          home: CompanionSetupPage(host: host, controller: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> scrollTo(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(
      finder,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
  }

  Finder badge(String label) => find.descendant(
    of: find.byKey(const ValueKey('companion-status-badge')),
    matching: find.text(label),
  );

  testWidgets('not installed offers the one-tap install', (tester) async {
    runner.responses.addAll({
      'exec node --version': ok('v22.1.0'),
      'conductore-hostd version': notFound,
    });
    await pumpPage(tester);

    expect(find.text('Agent hooks'), findsOneWidget);
    expect(badge('Not installed'), findsOneWidget);
    expect(find.text('Install agent hooks'), findsOneWidget);
    expect(find.text('Uninstall'), findsNothing);
    expect(find.text('22.1.0'), findsOneWidget);
  });

  testWidgets('missing node is called out before installing', (tester) async {
    runner.responses['conductore-hostd version'] = notFound;
    await pumpPage(tester);
    expect(find.textContaining('Node.js was not found'), findsOneWidget);
  });

  testWidgets('hooks not registered offers a reinstall and lists the '
      'doctor checks', (tester) async {
    runner.responses.addAll({
      ...healthyResponses(),
      'conductore-hostd doctor': ok(doctorJson(hooks: false)),
    });
    await pumpPage(tester);

    expect(badge('Hooks not registered'), findsOneWidget);
    expect(find.text('Reinstall and register hooks'), findsOneWidget);
    await scrollTo(tester, find.text('Doctor checks'));
    expect(find.text('hooks registered'), findsOneWidget);
    expect(find.text('missing: SessionStart, Stop'), findsOneWidget);
    expect(find.text('herdr (optional)'), findsOneWidget);
  });

  testWidgets('waiting for first event offers the test event and an update '
      'to the bundled version', (tester) async {
    runner.responses.addAll(healthyResponses(daemon: false));
    await pumpPage(tester);

    expect(badge('Waiting for first event'), findsOneWidget);
    expect(find.text('Send test event'), findsOneWidget);
    // The fake bundle (0.3.0) is newer than the installed 0.2.0.
    expect(find.text('Update to 0.3.0'), findsOneWidget);
    expect(find.text('Stop daemon'), findsNothing);
    expect(find.text('Uninstall'), findsOneWidget);
  });

  testWidgets('active shows the last event, agent count and stop daemon', (
    tester,
  ) async {
    runner.responses.addAll({
      ...healthyResponses(),
      'conductore-hostd status': ok(
        statusJson(
          source: 'daemon',
          seq: 4,
          agents: [
            agent(
              'a',
              updatedAt: DateTime.now().subtract(const Duration(minutes: 5)),
            ),
          ],
        ),
      ),
    });
    await pumpPage(tester);

    expect(badge('Active'), findsOneWidget);
    expect(find.text('5 min ago'), findsOneWidget);
    expect(find.text('1 live, 1 reported'), findsOneWidget);
    expect(find.text('Stop daemon'), findsOneWidget);
  });

  testWidgets('outdated offers the update', (tester) async {
    runner.responses.addAll({
      ...healthyResponses(),
      'conductore-hostd version': ok(versionJson(version: '0.0.5')),
    });
    await pumpPage(tester);
    expect(badge('Update available'), findsOneWidget);
    expect(
      find.widgetWithText(FilledButton, 'Update to 0.3.0'),
      findsOneWidget,
    );
  });

  testWidgets('an error shows stderr and a retry', (tester) async {
    runner.responses['conductore-hostd version'] = failed(
      1,
      stderr: 'Error: Cannot find module ../lib/cli',
    );
    await pumpPage(tester);
    expect(badge('Check failed'), findsOneWidget);
    expect(
      find.textContaining('Cannot find module ../lib/cli'),
      findsOneWidget,
    );
    expect(find.text('Check again'), findsOneWidget);
    expect(find.text('Install anyway'), findsOneWidget);
  });

  testWidgets('the confirmation sheet spells out every change', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: CompanionInstallSheet(hostName: 'box', version: '0.2.0'),
        ),
      ),
    );
    expect(find.text('Install agent hooks on box?'), findsOneWidget);
    expect(
      find.textContaining('~/.local/share/conductore-src/0.2.0/'),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        '~/.local/share/conductore and links ~/.local/bin/conductore-hostd '
        'and ~/.local/bin/conductore-hook',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('Adds 9 hook entries to ~/.claude/settings.json'),
      findsOneWidget,
    );
    expect(find.textContaining('PermissionRequest'), findsOneWidget);
    expect(find.textContaining('settings.json.bak'), findsOneWidget);
    expect(
      find.textContaining('Leaves your other hooks and settings untouched'),
      findsOneWidget,
    );
    expect(find.widgetWithText(FilledButton, 'Install'), findsOneWidget);
    expect(companionHookEvents, hasLength(9));
  });

  testWidgets('install asks first, then uploads, runs install.sh and shows '
      'the new status', (tester) async {
    galaxyM53(tester);
    runner.responses.addAll({
      'exec node --version': ok('v22.1.0'),
      'conductore-hostd version': notFound,
      'mkdir -p': ok(''),
      'install.sh': ok('{"ok":true}'),
    });
    await pumpPage(tester);

    await tester.tap(find.text('Install agent hooks'));
    await tester.pumpAndSettle();
    final install = find.byKey(const ValueKey('companion-install-confirm'));
    expect(install, findsOneWidget);
    // The sheet's buttons clear the three-button navigation bar.
    expect(tester.getBottomLeft(install).dy, lessThanOrEqualTo(915 - 48));

    // Cancel changes nothing.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(runner.ran('install.sh'), isFalse);

    await tester.tap(find.text('Install agent hooks'));
    await tester.pumpAndSettle();
    runner.responses.addAll(healthyResponses(daemon: false));
    runner.responses['conductore-hostd version'] = ok(versionJson());
    await tester.tap(install);
    await tester.pumpAndSettle();

    expect(sftp.writtenFiles.keys.single, endsWith('/companion.tar.gz'));
    expect(runner.ran('install.sh'), isTrue);
    expect(badge('Waiting for first event'), findsOneWidget);
    expect(find.byKey(const ValueKey('companion-log')), findsOneWidget);
    expect(find.textContaining('Installed.'), findsOneWidget);
  });

  testWidgets('send test event shows the result', (tester) async {
    runner.responses.addAll({
      'conductore-hook Notification': ok(''),
      ...healthyResponses(),
      'conductore-hostd status': ok(
        statusJson(
          source: 'daemon',
          seq: 2,
          agents: [agent('conductore-test', updatedAt: DateTime.now())],
        ),
      ),
    });
    await pumpPage(tester);
    await tester.tap(find.text('Send test event'));
    await tester.pumpAndSettle();
    expect(find.text('Test event received'), findsOneWidget);
    expect(find.textContaining('pruned after an hour'), findsOneWidget);
  });

  testWidgets('uninstall asks for confirmation', (tester) async {
    runner.responses.addAll({
      ...healthyResponses(),
      'mkdir -p': ok(''),
      'install.sh': ok('removed'),
    });
    await pumpPage(tester);
    await tester.tap(find.text('Uninstall'));
    await tester.pumpAndSettle();
    expect(find.text('Uninstall agent hooks?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('companion-uninstall-confirm')));
    await tester.pumpAndSettle();
    expect(
      runner.commands.any(
        (c) => c.contains('install.sh') && c.contains('--uninstall'),
      ),
      isTrue,
    );
  });

  testWidgets('manual instructions are copyable and quote the hooks docs', (
    tester,
  ) async {
    runner.responses['conductore-hostd version'] = notFound;
    await pumpPage(tester);
    await scrollTo(tester, find.text('Install manually'));
    await tester.tap(find.text('Install manually'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'git clone https://github.com/andreconde21/conductore-mobile && cd conductore-mobile/host '
        '&& ./install.sh',
      ),
      findsOneWidget,
    );
    expect(find.text('conductore-hostd doctor'), findsOneWidget);
    expect(find.textContaining('file watcher'), findsOneWidget);
    expect(find.byTooltip('Copy'), findsNWidgets(2));
  });

  testWidgets('the last section stays above a three-button nav bar', (
    tester,
  ) async {
    galaxyM53(tester);
    runner.responses.addAll(healthyResponses());
    await pumpPage(tester);
    final manual = find.byKey(const ValueKey('companion-manual'));
    await scrollTo(tester, manual);
    await tester.tap(find.text('Install manually'));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -3000));
    await tester.pumpAndSettle();
    expect(tester.getBottomLeft(manual).dy, lessThanOrEqualTo(915 - 48));
  });

  group('entry points', () {
    testWidgets('the install banner opens the screen and hides once '
        'installed', (tester) async {
      runner.responses['conductore-hostd version'] = notFound;
      await tester.pumpWidget(
        CompanionSetupScope(
          controller: controller,
          child: MaterialApp(
            home: Scaffold(body: CompanionInstallBanner(host: host)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Install agent hooks to get approvals and chat'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('companion-install-banner')));
      await tester.pumpAndSettle();
      expect(find.byType(CompanionSetupPage), findsOneWidget);

      runner.responses.addAll(healthyResponses());
      runner.responses['conductore-hostd version'] = ok(versionJson());
      await controller.refresh(host);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('companion-install-banner')),
        findsNothing,
      );
    });

    testWidgets('the status chip shows the state', (tester) async {
      runner.responses.addAll(healthyResponses());
      await tester.pumpWidget(
        CompanionSetupScope(
          controller: controller,
          child: MaterialApp(
            home: Scaffold(body: CompanionStatusChip(host: host)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Agent hooks: Active'), findsOneWidget);
    });

    testWidgets('chip, banner and tile render nothing without a scope', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                CompanionStatusChip(host: host),
                CompanionInstallBanner(host: host),
                CompanionSetupTile(host: host, resolveHost: () => host),
              ],
            ),
          ),
        ),
      );
      expect(find.byType(ActionChip), findsNothing);
      expect(find.byType(ListTile), findsNothing);
      expect(runner.commands, isEmpty);
    });

    testWidgets('the host form shows Agent hooks with the status', (
      tester,
    ) async {
      runner.responses.addAll(healthyResponses());
      await tester.pumpWidget(
        CompanionSetupScope(
          controller: controller,
          child: MaterialApp(
            home: HostFormPage(
              host: host.copyWith(agentAttentionEnabled: true),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final tile = find.byKey(const ValueKey('companion-setup-tile'));
      await scrollTo(tester, tile);
      expect(find.text('Agent hooks: Active'), findsOneWidget);
      expect(find.text('Set up companion'), findsNothing);
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(find.byType(CompanionSetupPage), findsOneWidget);
    });

    testWidgets('the machine menu has Agent hooks', (tester) async {
      MachineSheetResult? result;
      final hosts = HostsController(FakeHostsRepository()..persisted = [host]);
      await hosts.load();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MachineSheet(
              hostsController: hosts,
              filter: const MachineFilter({}),
              onFilterChanged: (_) {},
              liveKeys: const {},
              onResult: (value) => result = value,
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('machine-menu-box')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Agent hooks'));
      await tester.pumpAndSettle();
      expect(result, isA<MachineMenuRequested>());
      expect(
        (result! as MachineMenuRequested).choice,
        MachineMenuChoice.agentHooks,
      );
      expect(MachineMenuChoice.agentHooks.hostAction, isNull);
    });

    testWidgets('opening the screen with a stale status while a chip '
        'listens does not rebuild during build', (tester) async {
      runner.responses.addAll(healthyResponses());
      final stale = CompanionSetupController(
        runnerFactory: (_) => runner,
        sftpRepository: FakeSftpRepository(sftp),
        loadBundle: () async => fakeBundle(),
        staleAfter: Duration.zero,
      );
      addTearDown(stale.dispose);
      await tester.pumpWidget(
        CompanionSetupScope(
          controller: stale,
          child: MaterialApp(
            home: Scaffold(body: CompanionStatusChip(host: host)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(ActionChip));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(CompanionSetupPage), findsOneWidget);
      expect(
        runner.commands.where((c) => c.contains('hostd version')),
        hasLength(2),
      );
    });

    testWidgets('showCompanionSetup uses the scope', (tester) async {
      runner.responses['conductore-hostd version'] = notFound;
      await tester.pumpWidget(
        CompanionSetupScope(
          controller: controller,
          child: MaterialApp(
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () => showCompanionSetup(context, host),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(CompanionSetupPage), findsOneWidget);
    });
  });

  group('desktop (A-070, A-071, A-072)', () {
    final frame = find.byKey(const ValueKey('desktop-page-frame'));
    final primary = find.widgetWithText(FilledButton, 'Install agent hooks');
    final actions = find.byKey(const ValueKey('companion-install-actions'));

    Future<void> open(WidgetTester tester) async {
      runner.responses.addAll({
        'exec node --version': ok('v22.1.0'),
        'conductore-hostd version': notFound,
      });
      await tester.pumpWidget(
        CompanionSetupScope(
          controller: controller,
          child: MaterialApp(
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () => showCompanionSetup(context, host),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets(
      'desktop: a dialog with a normal-sized button and dialog actions',
      (tester) async {
        await open(tester);
        expect(frame, findsOneWidget);
        expect(find.byType(CompanionSetupPage), findsOneWidget);
        expect(tester.getSize(primary).width, lessThan(400));

        await tester.tap(primary);
        await tester.pumpAndSettle();
        expect(actions, findsOneWidget);
        // Cancel sits left of Install, both at their own size.
        final cancel = find.widgetWithText(OutlinedButton, 'Cancel');
        final install = find.byKey(const ValueKey('companion-install-confirm'));
        expect(tester.getSize(install).width, lessThan(250));
        expect(
          tester.getTopRight(cancel).dx,
          lessThan(tester.getTopLeft(install).dx),
        );
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.linux,
        TargetPlatform.windows,
        TargetPlatform.macOS,
      }),
    );

    testWidgets('phone: a full page with the full-width button and sheet', (
      tester,
    ) async {
      galaxyM53(tester);
      await open(tester);
      expect(frame, findsNothing);
      final width = tester.getSize(find.byType(CompanionSetupPage)).width;
      expect(tester.getSize(primary).width, greaterThan(width - 40));

      await tester.tap(primary);
      await tester.pumpAndSettle();
      expect(actions, findsNothing);
      expect(
        find.byKey(const ValueKey('companion-install-confirm')),
        findsOneWidget,
      );
    });
  });
}
