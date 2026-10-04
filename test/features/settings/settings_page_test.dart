import 'package:conduit/core/theme/theme_controller.dart';
import 'package:conduit/features/agent_attention/data/herdr_attention_provider.dart';
import 'package:conduit/features/agent_attention/presentation/agent_attention_controller.dart';
import 'package:conduit/features/backup/data/app_backup_service.dart';
import 'package:conduit/features/hosts/domain/saved_host.dart';
import 'package:conduit/features/hosts/presentation/hosts_controller.dart';
import 'package:conduit/features/session_navigation/domain/session_view_preferences.dart';
import 'package:conduit/features/session_navigation/presentation/session_view_controller.dart';
import 'package:conduit/features/settings/presentation/settings_catalog.dart';
import 'package:conduit/features/settings/presentation/settings_page.dart';
import 'package:conduit/features/settings/presentation/settings_services.dart';
import 'package:conduit/features/terminal/presentation/terminal_workspace_controller.dart';
import 'package:conduit/features/this_computer/domain/local_shell_launch.dart';
import 'package:conduit/features/this_computer/domain/this_computer_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';

void main() {
  late ThemeController theme;
  late HostsController hosts;
  late SettingsServices services;
  var locked = 0;

  setUp(() async {
    theme = ThemeController(InMemoryThemePreferences());
    await theme.load();
    hosts = HostsController(
      FakeHostsRepository()..persisted = [buildHost('a')],
    );
    await hosts.load();
    final verifier = NoopVerifier();
    locked = 0;
    services = SettingsServices(
      theme: theme,
      backupService: AppBackupService(
        hostsController: hosts,
        themeController: theme,
        hostKeyVerifier: verifier,
      ),
      hostsController: hosts,
      hostKeyVerifier: verifier,
      onLockNow: () async => locked++,
    );
  });

  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.6;
    addTearDown(tester.view.reset);
  }

  void desktop(WidgetTester tester) {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  /// A page with a button that opens Settings the way the home gear does.
  Future<void> pumpLauncher(
    WidgetTester tester, {
    SettingsSection? section,
  }) async {
    final workspace = TerminalWorkspaceController(
      NoNetworkTerminalRepository(),
    );
    addTearDown(workspace.dispose);
    final attention = AgentAttentionController(
      workspace: workspace,
      runnerFactory: (_) => ScriptedAgentCommandRunner([StateError('none')]),
      provider: const HerdrAttentionProvider(),
    );
    addTearDown(attention.dispose);
    final views = SessionViewController(
      InMemorySessionViewPreferencesRepository(),
    );
    await tester.pumpWidget(
      SessionViewScope(
        controller: views,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () => showSettings(
                    context,
                    services: SettingsServices(
                      theme: services.theme,
                      backupService: services.backupService,
                      hostsController: services.hostsController,
                      hostKeyVerifier: services.hostKeyVerifier,
                      agentAttention: attention,
                      onLockNow: services.onLockNow,
                    ),
                    section: section,
                  ),
                  child: const Text('Open settings'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();
  }

  Finder sectionTile(SettingsSection section) =>
      find.byKey(ValueKey('settings-section-${section.name}'));

  testWidgets('Terminal has "Phone may move Herdr focus", off by default', (
    tester,
  ) async {
    phone(tester);
    await pumpLauncher(tester, section: SettingsSection.terminal);
    final title = find.text('Phone may move Herdr focus');
    await tester.scrollUntilVisible(title, 200);
    expect(
      find.textContaining('Herdr shares one focus across all screens'),
      findsOneWidget,
    );
    expect(theme.herdrMayMoveFocus, isFalse);
    // Fully on screen, not just scrolled to the edge.
    await tester.ensureVisible(title);
    await tester.pumpAndSettle();
    await tester.tap(title);
    await tester.pumpAndSettle();
    expect(theme.herdrMayMoveFocus, isTrue);
    expect(
      settingsCatalog.where((entry) => entry.title.contains('Herdr focus')),
      hasLength(2),
    );
  });

  test('the catalog keeps every setting the Appearance sheet had', () {
    final titles = {for (final entry in settingsCatalog) entry.title};
    for (final title in [
      'Follow Omarchy theme from machine',
      'Themes',
      'Terminal font',
      'Font size',
      'Show local shell',
      'Enter sends',
      'Send mouse taps',
      'Remote clipboard',
      'Menu buttons',
      'Paste images as uploaded files',
      'Restore sessions on launch',
      'Open agent sessions in',
      'Multiplexer tabs on phone',
      'This computer: shell',
      'Keyboard shortcuts',
      'Global snippets',
      'Toolbar style',
      'Pill buttons',
      'Key rows',
      'Swipe switches window',
      'Drag scrolls the remote app (mouse wheel)',
      'Press Enter after inserting',
      'Language',
      'Keep listening until I tap stop',
      'Silence beeps between phrases',
      'Read replies aloud by default',
      'Talk: send after a pause of',
      'Agent hooks',
      'Notifications',
      'Usage',
      'Add quick-settings tile',
      'Device sync',
      'Export backup',
      'Import backup',
      'App lock',
      'Lock now',
      'Trusted host keys',
      'Based on Conduit by gwitko (Apache-2.0)',
      'Open-source licenses',
      'Recent errors',
    ]) {
      expect(titles, contains(title));
    }
  });

  testWidgets('every available catalog entry is on its section page', (
    tester,
  ) async {
    phone(tester);
    final workspace = TerminalWorkspaceController(
      NoNetworkTerminalRepository(),
    );
    addTearDown(workspace.dispose);
    final attention = AgentAttentionController(
      workspace: workspace,
      runnerFactory: (_) => ScriptedAgentCommandRunner([StateError('none')]),
      provider: const HerdrAttentionProvider(),
    );
    addTearDown(attention.dispose);
    final full = SettingsServices(
      theme: services.theme,
      backupService: services.backupService,
      hostsController: services.hostsController,
      hostKeyVerifier: services.hostKeyVerifier,
      agentAttention: attention,
      onLockNow: services.onLockNow,
      hasSessionViews: true,
    );
    final views = SessionViewController(
      InMemorySessionViewPreferencesRepository(),
    );
    for (final section in SettingsSection.values) {
      await tester.pumpWidget(
        SessionViewScope(
          controller: views,
          child: MaterialApp(
            home: SettingsSectionPage(section: section, services: full),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final scrollable = find
          .descendant(
            of: find.byKey(ValueKey('settings-body-${section.name}')),
            matching: find.byType(Scrollable),
          )
          .first;
      for (final entry in settingsCatalog) {
        if (entry.section != section || !entry.isAvailable(full)) continue;
        final finder = find.textContaining(entry.title, findRichText: true);
        // Lists build lazily: from the top, scroll until it is built.
        await tester.drag(scrollable, const Offset(0, 20000));
        await tester.pumpAndSettle();
        for (var i = 0; i < 80 && finder.evaluate().isEmpty; i++) {
          await tester.drag(scrollable, const Offset(0, -150));
          await tester.pumpAndSettle();
        }
        expect(
          finder,
          findsWidgets,
          reason: '${section.title}: ${entry.title}',
        );
      }
    }
  });

  testWidgets('phone: the section list opens each section as a page', (
    tester,
  ) async {
    phone(tester);
    await pumpLauncher(tester);

    expect(find.text('Settings'), findsOneWidget);
    for (final section in SettingsSection.values) {
      expect(sectionTile(section), findsOneWidget, reason: section.title);
    }
    expect(find.byKey(const ValueKey('settings-two-pane')), findsNothing);

    await tester.tap(sectionTile(SettingsSection.terminal));
    await tester.pumpAndSettle();
    expect(find.text('Send mouse taps'), findsOneWidget);
    final before = theme.terminalMouseInput;
    await tester.tap(find.text('Send mouse taps'));
    await tester.pumpAndSettle();
    expect(theme.terminalMouseInput, !before);

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(sectionTile(SettingsSection.syncBackup), findsOneWidget);

    // Backup is under Sync & Backup, clearly labelled.
    await tester.tap(sectionTile(SettingsSection.syncBackup));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Import backup'),
      200,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('settings-body-syncBackup')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('Export backup'), findsOneWidget);
    expect(find.textContaining('every setting'), findsOneWidget);
  });

  testWidgets('phone: opening at a section pushes it', (tester) async {
    phone(tester);
    await pumpLauncher(tester, section: SettingsSection.security);
    expect(find.text('Trusted host keys'), findsOneWidget);
    await tester.tap(find.text('Lock now'));
    await tester.pumpAndSettle();
    expect(locked, 1);
  });

  testWidgets('search finds a setting by title or keyword', (tester) async {
    phone(tester);
    await pumpLauncher(tester);

    await tester.enterText(
      find.byKey(const ValueKey('settings-search')),
      'osc 52',
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('settings-result-Remote clipboard')),
      findsOneWidget,
    );
    expect(sectionTile(SettingsSection.terminal), findsNothing);

    await tester.enterText(
      find.byKey(const ValueKey('settings-search')),
      'backup',
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('settings-result-Import backup')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('settings-result-Import backup')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings-body-syncBackup')), findsOne);

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('settings-search')),
      'zzzz',
    );
    await tester.pumpAndSettle();
    expect(find.text('No setting matches "zzzz".'), findsOneWidget);
  });

  testWidgets('desktop: the list and the open section side by side', (
    tester,
  ) async {
    desktop(tester);
    await pumpLauncher(tester);

    expect(find.byKey(const ValueKey('settings-two-pane')), findsOneWidget);
    // Appearance is open by default, beside the list.
    expect(find.byKey(const ValueKey('settings-body-appearance')), findsOne);
    expect(sectionTile(SettingsSection.about), findsOneWidget);

    await tester.tap(sectionTile(SettingsSection.security));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings-body-security')), findsOne);
    expect(find.text('Trusted host keys'), findsOneWidget);
    // Still one route: the list stays on screen.
    expect(sectionTile(SettingsSection.appearance), findsOneWidget);
    expect(
      tester.widget<ListTile>(sectionTile(SettingsSection.security)).selected,
      isTrue,
    );

    await tester.enterText(
      find.byKey(const ValueKey('settings-search')),
      'pinch',
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('settings-result-Pinch to zoom')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings-body-input')), findsOne);
  });

  testWidgets('Agents: per-machine hooks and notification level', (
    tester,
  ) async {
    phone(tester);
    await pumpLauncher(tester, section: SettingsSection.agents);
    // Once for its agent hooks, once under Approval rules.
    expect(find.text('Host a'), findsNWidgets(2));
    expect(find.text('Approval rules'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('settings-approval-rules-a')),
      findsOneWidget,
    );
    expect(find.text('Approvals and errors'), findsNothing);
    final dropdown = find.byKey(const ValueKey('settings-notify-a'));
    await tester.tap(dropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('None').last);
    await tester.pumpAndSettle();
    expect(hosts.hosts.single.agentNotifyLevel, AgentNotifyLevel.none);
  });

  testWidgets(
    'Windows desktop: Settings is a page, with the shell and shortcuts',
    (tester) async {
      desktop(tester);
      final local = HostsController(
        FakeHostsRepository(),
        thisComputerStore: InMemoryThisComputerStore(
          ThisComputerSettings(host: SavedHost.thisComputer()),
        ),
      );
      await local.load();
      services = SettingsServices(theme: theme, hostsController: local);
      await pumpLauncher(tester);

      // A route of its own, not a bottom sheet or a dialog.
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byKey(const ValueKey('adaptive-modal-dialog')), findsNothing);
      expect(find.byKey(const ValueKey('settings-two-pane')), findsOneWidget);

      await tester.tap(sectionTile(SettingsSection.terminal));
      await tester.pumpAndSettle();
      expect(find.text('This computer: shell'), findsOneWidget);
      await tester.tap(find.text('WSL'));
      await tester.pumpAndSettle();
      expect(local.windowsShell, WindowsShellKind.wsl);

      await tester.tap(sectionTile(SettingsSection.input));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Keyboard shortcuts'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('adaptive-modal-dialog')), findsOne);
      expect(find.byType(BottomSheet), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  group('desktop pages (A-060, A-061, A-062)', () {
    const desktops = TargetPlatformVariant({
      TargetPlatform.linux,
      TargetPlatform.windows,
      TargetPlatform.macOS,
    });
    final frame = find.byKey(const ValueKey('desktop-page-frame'));

    testWidgets(
      'desktop: Settings and Trusted keys open as dialogs over the window',
      (tester) async {
        desktop(tester);
        await pumpLauncher(tester);

        expect(frame, findsOneWidget);
        expect(find.byKey(const ValueKey('settings-two-pane')), findsOne);
        // The launcher stays underneath, in sight.
        expect(find.text('Open settings', skipOffstage: false), findsOne);

        await tester.tap(sectionTile(SettingsSection.security));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('settings-trusted-keys')));
        await tester.pumpAndSettle();
        expect(frame, findsNWidgets(2));
      },
      variant: desktops,
    );

    testWidgets('desktop: a narrow window opens sections as dialogs too', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pumpLauncher(tester);

      expect(find.byKey(const ValueKey('settings-two-pane')), findsNothing);
      await tester.tap(sectionTile(SettingsSection.security));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('settings-body-security')), findsOne);
      expect(frame, findsNWidgets(2));
    }, variant: desktops);

    testWidgets('phone: Settings and its pages stay full-screen pages', (
      tester,
    ) async {
      phone(tester);
      await pumpLauncher(tester);
      expect(frame, findsNothing);
      expect(
        ModalRoute.of(tester.element(sectionTile(SettingsSection.security))),
        isA<MaterialPageRoute<void>>(),
      );

      await tester.tap(sectionTile(SettingsSection.security));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-trusted-keys')));
      await tester.pumpAndSettle();
      expect(frame, findsNothing);
      expect(find.text('Trusted host keys'), findsWidgets);
    });

    testWidgets(
      'desktop: Enter opens the first result, Down reaches the list',
      (tester) async {
        desktop(tester);
        await pumpLauncher(tester);

        final search = find.byKey(const ValueKey('settings-search'));
        await tester.enterText(search, 'backup');
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        expect(
          FocusManager.instance.primaryFocus?.debugLabel,
          'settings-first-row',
        );

        await tester.tap(search);
        await tester.enterText(search, 'pinch');
        await tester.pumpAndSettle();
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('settings-body-input')), findsOne);
      },
      variant: desktops,
    );

    testWidgets('phone: Enter in the search opens nothing', (tester) async {
      phone(tester);
      await pumpLauncher(tester);

      await tester.enterText(
        find.byKey(const ValueKey('settings-search')),
        'pinch',
      );
      await tester.pumpAndSettle();
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('settings-body-input')), findsNothing);
      expect(
        find.byKey(const ValueKey('settings-result-Pinch to zoom')),
        findsOneWidget,
      );
    });
  });
}
