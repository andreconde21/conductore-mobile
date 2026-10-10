import 'package:conduit/core/diagnostics/app_error_log.dart';
import 'package:conduit/core/presentation/theme_sheet.dart';
import 'package:conduit/core/theme/terminal_appearance.dart';
import 'package:conduit/core/theme/theme_controller.dart';
import 'package:conduit/features/app_lock/domain/app_lock_preferences.dart';
import 'package:conduit/features/app_lock/presentation/app_lock_controller.dart';
import 'package:conduit/features/settings/presentation/settings_catalog.dart';
import 'package:conduit/features/settings/presentation/settings_page.dart';
import 'package:conduit/features/settings/presentation/settings_services.dart';
import 'package:conduit/features/usage/data/usage_preferences.dart';
import 'package:conduit/features/usage/presentation/usage_controller.dart';
import 'package:conduit/features/usage/presentation/usage_widgets.dart';
import 'package:conduit/features/voice/domain/voice_preferences.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/test_doubles.dart';
import '../usage/usage_fakes.dart';

/// The settings that used to live in the Appearance sheet, each on its
/// Settings section page now.
void main() {
  late ThemeController controller;

  setUp(() async {
    controller = ThemeController(InMemoryThemePreferences());
    await controller.load();
  });

  Future<void> openSection(WidgetTester tester, SettingsSection section) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsSectionPage(
          section: section,
          services: SettingsServices(theme: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder body(SettingsSection section) => find.descendant(
    of: find.byKey(ValueKey('settings-body-${section.name}')),
    matching: find.byType(Scrollable),
  );

  Future<void> reveal(
    WidgetTester tester,
    SettingsSection section,
    Finder finder,
  ) async {
    await tester.scrollUntilVisible(
      finder,
      200,
      scrollable: body(section).first,
    );
    await tester.pumpAndSettle();
  }

  testWidgets('Security: a lock delay above 15 minutes warns first, each '
      'time it is chosen (CON-118)', (tester) async {
    final lock = AppLockController(AlwaysAuthenticates());
    addTearDown(lock.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsSectionPage(
          section: SettingsSection.security,
          services: SettingsServices(theme: controller, appLock: lock),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final dropdown = find.byKey(const ValueKey('settings-relock-delay'));
    final warning = find.byKey(const ValueKey('settings-relock-warning'));

    Future<void> choose(String label) async {
      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
    }

    await choose('After 5 minutes');
    expect(warning, findsNothing);
    expect(lock.relockDelay, RelockDelay.fiveMinutes);

    await choose('After 8 hours');
    expect(warning, findsOneWidget);
    expect(
      find.textContaining('approve agent actions for up to 8 hours'),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(lock.relockDelay, RelockDelay.fiveMinutes);

    await choose('After 8 hours');
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(lock.relockDelay, RelockDelay.eightHours);
    expect(find.text('Lock again after unlocking'), findsOneWidget);

    await choose('After 1 day');
    expect(find.textContaining('for up to 1 day'), findsOneWidget);
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(lock.relockDelay, RelockDelay.oneDay);
  });

  testWidgets('Agents: the 5-hour alert is a per-device switch (Android)', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final store = MemoryUsagePreferencesStore();
    final usage = UsageController(
      source: FakeUsageSource(const [], {}),
      preferences: store,
      observeLifecycle: false,
    );
    addTearDown(usage.dispose);
    await tester.pumpWidget(
      UsageScope(
        controller: usage,
        child: MaterialApp(
          home: SettingsSectionPage(
            section: SettingsSection.agents,
            services: SettingsServices(theme: controller),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final toggle = find.byKey(const ValueKey('settings-usage-alert'));
    expect(toggle, findsOneWidget);
    expect(find.text('Alert near the 5-hour limit'), findsOneWidget);
    await tester.tap(
      find.descendant(of: toggle, matching: find.byType(Switch)),
    );
    await tester.pumpAndSettle();
    expect(store.value.alertEnabled, isTrue);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Appearance toggles local shell visibility', (tester) async {
    await openSection(tester, SettingsSection.appearance);
    await reveal(
      tester,
      SettingsSection.appearance,
      find.text('Show local shell'),
    );
    expect(controller.showLocalShell, isTrue);
    await tester.tap(find.text('Show local shell'));
    await tester.pumpAndSettle();
    expect(controller.showLocalShell, isFalse);
  });

  testWidgets('desktops hide the proot local shell toggle', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      await openSection(tester, SettingsSection.appearance);
      expect(find.text('Show local shell'), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  for (final (title, read) in <(String, bool Function(ThemeController))>[
    ('Send mouse taps', (c) => c.terminalMouseInput),
    ('Menu buttons', (c) => c.menuButtonsEnabled),
    ('Restore sessions on launch', (c) => c.restoreSessionsOnLaunch),
    ('Paste images as uploaded files', (c) => c.pasteImagesAsFiles),
    ('Remote clipboard', (c) => c.remoteClipboardEnabled),
  ]) {
    testWidgets('Terminal toggles "$title"', (tester) async {
      await openSection(tester, SettingsSection.terminal);
      await reveal(tester, SettingsSection.terminal, find.text(title));
      final before = read(controller);
      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
      expect(read(controller), !before);
    });
  }

  testWidgets('Terminal changes the enter sequence', (tester) async {
    await openSection(tester, SettingsSection.terminal);
    expect(controller.terminalEnterSequence, TerminalEnterSequence.cr);
    await tester.tap(find.text('CRLF'));
    await tester.pumpAndSettle();
    expect(controller.terminalEnterSequence, TerminalEnterSequence.crlf);
  });

  testWidgets('Input switches the toolbar style', (tester) async {
    await openSection(tester, SettingsSection.input);
    expect(controller.terminalToolbarStyle, TerminalToolbarStyle.floatingPill);
    await tester.tap(
      find.descendant(
        of: find.byType(SegmentedButton<TerminalToolbarStyle>),
        matching: find.text('Key rows'),
      ),
    );
    await tester.pumpAndSettle();
    expect(controller.terminalToolbarStyle, TerminalToolbarStyle.keyRows);
  });

  testWidgets('Input shows the gestures and toggles pinch to zoom', (
    tester,
  ) async {
    await openSection(tester, SettingsSection.input);
    await reveal(tester, SettingsSection.input, find.text('Gestures'));
    await reveal(tester, SettingsSection.input, find.text('Pinch to zoom'));
    expect(controller.terminalGestures.pinchZoom, isTrue);
    await tester.tap(find.text('Pinch to zoom'));
    await tester.pumpAndSettle();
    expect(controller.terminalGestures.pinchZoom, isFalse);
  });

  testWidgets('Chat & Voice toggles pressing Enter after inserting', (
    tester,
  ) async {
    await openSection(tester, SettingsSection.chatVoice);
    expect(controller.composeSubmitEnter, isFalse);
    await tester.tap(find.text('Press Enter after inserting'));
    await tester.pumpAndSettle();
    expect(controller.composeSubmitEnter, isTrue);
    // Android (the test platform) has dictation and read aloud.
    await reveal(
      tester,
      SettingsSection.chatVoice,
      find.text('Keep listening until I tap stop'),
    );
  });

  testWidgets('Chat & Voice: Review opens on demand or after each turn', (
    tester,
  ) async {
    await openSection(tester, SettingsSection.chatVoice);
    final card = find.byKey(const ValueKey('chat-review-opens'));
    await reveal(tester, SettingsSection.chatVoice, card);
    expect(controller.voice.reviewOpens, ReviewOpens.onDemand);
    await tester.tap(
      find.descendant(of: card, matching: find.text('After each turn')),
    );
    await tester.pumpAndSettle();
    expect(controller.voice.reviewOpens, ReviewOpens.afterEachTurn);
    expect(
      find.textContaining('When a turn ends in Chat View'),
      findsOneWidget,
    );
  });

  testWidgets('the key row editor adds and saves a custom text key', (
    tester,
  ) async {
    await openSection(tester, SettingsSection.input);
    await reveal(
      tester,
      SettingsSection.input,
      find.byKey(const ValueKey('key-rows-edit')),
    );
    final initialCount = controller.terminalKeyboardRows.first.items.length;
    await tester.tap(find.byKey(const ValueKey('key-rows-edit')));
    await tester.pumpAndSettle();
    expect(find.text('Key Rows (1)'), findsOneWidget);

    await tester.tap(find.byTooltip('Edit keys'));
    await tester.pumpAndSettle();
    expect(find.text('Row 1 Keys ($initialCount)'), findsOneWidget);

    await tester.drag(
      find.byType(ReorderableListView).last,
      const Offset(0, -500),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ActionChip, 'Custom'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).at(0), 'gs');
    await tester.enterText(find.byType(TextField).at(1), 'git status');
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();
    expect(find.text('gs'), findsOneWidget);
    expect(find.text('Row 1 Keys (${initialCount + 1})'), findsOneWidget);
    expect(
      controller.terminalKeyboardRows.first.items.length,
      initialCount + 1,
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Done').last);
    await tester.pumpAndSettle();

    final custom = controller.terminalKeyboardRows.first.items.first;
    expect(custom.kind, TerminalKeyboardItemKind.customText);
    expect(custom.label, 'gs');
    expect(custom.text, 'git status');
  });

  testWidgets('About credits upstream Conduit and lists recent errors', (
    tester,
  ) async {
    addTearDown(AppErrorLog.instance.clear);
    AppErrorLog.instance.clear();
    await openSection(tester, SettingsSection.about);

    expect(find.text('Conductore'), findsOneWidget);
    expect(find.byKey(const ValueKey('about-upstream-credit')), findsOneWidget);
    expect(
      find.text('Based on Conduit by gwitko (Apache-2.0)'),
      findsOneWidget,
    );
    expect(find.text('Recent errors'), findsOneWidget);

    AppErrorLog.instance.recordError(StateError('boom'), null);
    await tester.pump();
    await tester.tap(find.text('Recent errors (1)'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('recent-errors')), findsOneWidget);
    expect(find.text('Bad state: boom'), findsOneWidget);
    expect(find.byKey(const ValueKey('recent-errors-copy')), findsOneWidget);
  });

  testWidgets('the lock screen theme sheet shows only the look', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () =>
                    showThemeSheet(context: context, controller: controller),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Appearance'), findsOneWidget);
    expect(find.text('Dark'), findsOneWidget);
    expect(find.text('Send mouse taps'), findsNothing);
    expect(find.text('Import backup'), findsNothing);
  });

  group('desktop (A-067, A-068)', () {
    const desktops = TargetPlatformVariant({
      TargetPlatform.linux,
      TargetPlatform.windows,
      TargetPlatform.macOS,
    });

    Future<void> openThemeSheet(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showThemeSheet(context: context, controller: controller),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    DraggableScrollableSheet sheet(WidgetTester tester) =>
        tester.widget(find.byType(DraggableScrollableSheet));

    testWidgets('desktop: the Appearance sheet fills its dialog', (
      tester,
    ) async {
      await openThemeSheet(tester);
      expect(sheet(tester).initialChildSize, 1.0);
      expect(sheet(tester).minChildSize, 1.0);
      expect(
        find.byKey(const ValueKey('adaptive-modal-dialog')),
        findsOneWidget,
      );
    }, variant: desktops);

    testWidgets('phone: the Appearance sheet keeps its drag sizes', (
      tester,
    ) async {
      await openThemeSheet(tester);
      expect(sheet(tester).initialChildSize, 0.7);
      expect(sheet(tester).minChildSize, 0.4);
      expect(sheet(tester).maxChildSize, 0.92);
    });

    Future<int> addCustomKeyWithEnter(WidgetTester tester) async {
      await openSection(tester, SettingsSection.input);
      await reveal(
        tester,
        SettingsSection.input,
        find.byKey(const ValueKey('key-rows-edit')),
      );
      final initialCount = controller.terminalKeyboardRows.first.items.length;
      await tester.tap(find.byKey(const ValueKey('key-rows-edit')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Edit keys'));
      await tester.pumpAndSettle();
      final custom = find.widgetWithText(ActionChip, 'Custom');
      await tester.ensureVisible(custom);
      await tester.pumpAndSettle();
      await tester.tap(custom);
      await tester.pumpAndSettle();

      final fields = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );
      await tester.enterText(fields.at(0), 'gs');
      await tester.enterText(fields.at(1), 'git status');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      return initialCount;
    }

    testWidgets('desktop: Enter in the custom key dialog adds the key', (
      tester,
    ) async {
      final initialCount = await addCustomKeyWithEnter(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Row 1 Keys (${initialCount + 1})'), findsOneWidget);
    }, variant: desktops);

    testWidgets('phone: Enter in the custom key dialog adds nothing', (
      tester,
    ) async {
      final initialCount = await addCustomKeyWithEnter(tester);
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Row 1 Keys ($initialCount)'), findsOneWidget);
    });
  });
}
