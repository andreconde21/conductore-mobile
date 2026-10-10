import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/core/theme/terminal_appearance.dart';
import 'package:conduit/core/theme/terminal_pill_items.dart';
import 'package:conduit/core/theme/theme_preferences_repository.dart';
import 'package:conduit/features/snippets/domain/terminal_snippet.dart';
import 'package:conduit/features/terminal/domain/terminal_gesture_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/test_doubles.dart';

void main() {
  group('ThemePreferencesRepository', () {
    test(
      'loads legacy comma-separated keyboard actions as built-in items',
      () async {
        final storage = InMemorySecureStorage();
        await storage.write(
          key: 'conduit.terminal_keyboard_actions.v1',
          value: 'escape,control,arrowDown',
        );
        final repository = ThemePreferencesRepository(storage);

        final preferences = await repository.load();

        expect(preferences.terminalKeyboardRows, hasLength(1));
        expect(
          preferences.terminalKeyboardRows.first.items.map(
            (item) => item.action,
          ),
          [
            TerminalKeyboardAction.escape,
            TerminalKeyboardAction.control,
            TerminalKeyboardAction.arrowDown,
            TerminalKeyboardAction.herdrMenu,
            TerminalKeyboardAction.snippets,
            TerminalKeyboardAction.touchMode,
          ],
        );
      },
    );

    test('appends built-in keys introduced after a layout was saved', () async {
      final storage = InMemorySecureStorage();
      await storage.write(
        key: 'conduit.terminal_keyboard_actions.v1',
        value: '[{"id":"builtIn:escape","kind":"builtIn","action":"escape"}]',
      );
      final repository = ThemePreferencesRepository(storage);

      final preferences = await repository.load();

      expect(preferences.terminalKeyboardRows, [
        const TerminalKeyboardRow(
          items: [
            TerminalKeyboardItem.builtIn(TerminalKeyboardAction.escape),
            TerminalKeyboardItem.builtIn(TerminalKeyboardAction.herdrMenu),
            TerminalKeyboardItem.builtIn(TerminalKeyboardAction.snippets),
            TerminalKeyboardItem.builtIn(TerminalKeyboardAction.touchMode),
          ],
        ),
      ]);
    });

    test('does not re-append keys removed after they were seen', () async {
      final storage = InMemorySecureStorage();
      final repository = ThemePreferencesRepository(storage);

      await repository.save(
        const ThemePreferences(
          themeMode: ThemeMode.dark,
          palette: AppPalette.everforest,
          terminalKeyboardRows: [
            TerminalKeyboardRow(
              items: [
                TerminalKeyboardItem.builtIn(TerminalKeyboardAction.escape),
              ],
            ),
          ],
        ),
      );

      final preferences = await repository.load();

      expect(preferences.terminalKeyboardRows, [
        const TerminalKeyboardRow(
          items: [TerminalKeyboardItem.builtIn(TerminalKeyboardAction.escape)],
        ),
      ]);
    });

    test('persists and loads keyboard rows with heights', () async {
      final storage = InMemorySecureStorage();
      final repository = ThemePreferencesRepository(storage);
      const custom = TerminalKeyboardItem(
        id: 'custom:test',
        kind: TerminalKeyboardItemKind.customText,
        label: 'gs',
        text: 'git status',
        submit: true,
      );
      const rows = [
        TerminalKeyboardRow(
          items: [
            TerminalKeyboardItem.builtIn(TerminalKeyboardAction.escape),
            custom,
          ],
          height: 60,
        ),
        TerminalKeyboardRow(
          items: [TerminalKeyboardItem.builtIn(TerminalKeyboardAction.control)],
          height: 45,
        ),
      ];

      await repository.save(
        const ThemePreferences(
          themeMode: ThemeMode.dark,
          palette: AppPalette.everforest,
          terminalKeyboardRows: rows,
        ),
      );

      final preferences = await repository.load();

      expect(preferences.terminalKeyboardRows, rows);
    });

    test('keeps the same built-in key in multiple rows', () async {
      final storage = InMemorySecureStorage();
      final repository = ThemePreferencesRepository(storage);
      const rows = [
        TerminalKeyboardRow(
          items: [TerminalKeyboardItem.builtIn(TerminalKeyboardAction.arrowUp)],
        ),
        TerminalKeyboardRow(
          items: [
            TerminalKeyboardItem.builtIn(TerminalKeyboardAction.arrowUp),
            TerminalKeyboardItem.builtIn(TerminalKeyboardAction.arrowDown),
          ],
        ),
      ];

      await repository.save(
        const ThemePreferences(
          themeMode: ThemeMode.dark,
          palette: AppPalette.everforest,
          terminalKeyboardRows: rows,
        ),
      );

      final preferences = await repository.load();

      expect(preferences.terminalKeyboardRows, rows);
    });

    test('persists local shell visibility', () async {
      final storage = InMemorySecureStorage();
      final repository = ThemePreferencesRepository(storage);

      await repository.save(
        const ThemePreferences(
          themeMode: ThemeMode.dark,
          palette: AppPalette.everforest,
          showLocalShell: false,
        ),
      );

      final preferences = await repository.load();

      expect(preferences.showLocalShell, isFalse);
    });

    test(
      'defaults terminal mouse input off and persists when enabled',
      () async {
        final storage = InMemorySecureStorage();
        final repository = ThemePreferencesRepository(storage);

        final defaults = await repository.load();
        expect(defaults.terminalMouseInput, isFalse);

        await repository.save(
          const ThemePreferences(
            themeMode: ThemeMode.dark,
            palette: AppPalette.everforest,
            terminalMouseInput: true,
          ),
        );

        final preferences = await repository.load();
        expect(preferences.terminalMouseInput, isTrue);
      },
    );

    test('defaults enter sequence to CR and persists changes', () async {
      final storage = InMemorySecureStorage();
      final repository = ThemePreferencesRepository(storage);

      final defaults = await repository.load();
      expect(defaults.terminalEnterSequence, TerminalEnterSequence.cr);

      await repository.save(
        const ThemePreferences(
          themeMode: ThemeMode.dark,
          palette: AppPalette.everforest,
          terminalEnterSequence: TerminalEnterSequence.crlf,
        ),
      );

      final preferences = await repository.load();
      expect(preferences.terminalEnterSequence, TerminalEnterSequence.crlf);
    });

    test(
      'defaults touch mode hint to unseen and persists once shown',
      () async {
        final storage = InMemorySecureStorage();
        final repository = ThemePreferencesRepository(storage);

        final defaults = await repository.load();
        expect(defaults.touchModeHintSeen, isFalse);

        await repository.save(
          const ThemePreferences(
            themeMode: ThemeMode.dark,
            palette: AppPalette.everforest,
            touchModeHintSeen: true,
          ),
        );

        final preferences = await repository.load();
        expect(preferences.touchModeHintSeen, isTrue);
      },
    );

    test('defaults the toolbar style to the floating pill and persists a '
        'change', () async {
      final storage = InMemorySecureStorage();
      final repository = ThemePreferencesRepository(storage);

      final defaults = await repository.load();
      expect(defaults.terminalToolbarStyle, TerminalToolbarStyle.floatingPill);

      await repository.save(
        const ThemePreferences(
          themeMode: ThemeMode.dark,
          palette: AppPalette.everforest,
          terminalToolbarStyle: TerminalToolbarStyle.keyRows,
        ),
      );

      final preferences = await repository.load();
      expect(preferences.terminalToolbarStyle, TerminalToolbarStyle.keyRows);
    });

    test('defaults the pill buttons to Ctrl, Esc, Tab, Herdr, Paste and Chat '
        'and persists a reordered list', () async {
      final storage = InMemorySecureStorage();
      final repository = ThemePreferencesRepository(storage);

      final defaults = await repository.load();
      expect(defaults.terminalPillItems, defaultTerminalPillItems);
      expect(defaults.terminalPillItems.map((item) => item.button), [
        TerminalPillButton.ctrl,
        TerminalPillButton.esc,
        TerminalPillButton.tab,
        TerminalPillButton.herdr,
        TerminalPillButton.paste,
        TerminalPillButton.chat,
      ]);

      const custom = [
        TerminalPillItem.button(TerminalPillButton.herdr),
        TerminalPillItem.button(TerminalPillButton.arrows),
        TerminalPillItem.custom('my-key'),
      ];
      await repository.save(
        const ThemePreferences(
          themeMode: ThemeMode.dark,
          palette: AppPalette.everforest,
          terminalPillItems: custom,
        ),
      );
      expect((await repository.load()).terminalPillItems, custom);
    });

    test('drops unknown and duplicate pill buttons and falls back to the '
        'default on corrupt data', () async {
      final storage = InMemorySecureStorage();
      await storage.write(
        key: 'conduit.terminal_pill_items.v1',
        value: '["esc","hologram","esc","custom:","custom:k1"]',
      );
      final repository = ThemePreferencesRepository(storage);
      expect((await repository.load()).terminalPillItems, const [
        TerminalPillItem.button(TerminalPillButton.esc),
        TerminalPillItem.custom('k1'),
      ]);

      await storage.write(key: 'conduit.terminal_pill_items.v1', value: '{');
      expect(
        (await repository.load()).terminalPillItems,
        defaultTerminalPillItems,
      );
    });

    test('a pill list saved before CON-106 that is the old default gets the '
        'new default; a customized one is kept', () async {
      final storage = InMemorySecureStorage();
      await storage.write(
        key: 'conduit.terminal_pill_items.v1',
        value:
            '["ctrl","esc","tab","herdr","reconnect","paste","chat",'
            '"keyboard"]',
      );
      final repository = ThemePreferencesRepository(storage);
      expect(
        (await repository.load()).terminalPillItems,
        defaultTerminalPillItems,
      );

      await storage.write(
        key: 'conduit.terminal_pill_items.v1',
        value: '["ctrl","esc","reconnect","dictate","keyboard"]',
      );
      expect((await repository.load()).terminalPillItems, const [
        TerminalPillItem.button(TerminalPillButton.ctrl),
        TerminalPillItem.button(TerminalPillButton.esc),
        TerminalPillItem.button(TerminalPillButton.reconnect),
        TerminalPillItem.button(TerminalPillButton.dictate),
        TerminalPillItem.button(TerminalPillButton.keyboard),
      ]);
    });

    test('the old default chosen again after CON-106 stays', () async {
      final storage = InMemorySecureStorage();
      await storage.write(
        key: 'conduit.terminal_pill_items.v1',
        value: '["esc"]',
      );
      final repository = ThemePreferencesRepository(storage);
      await repository.save(
        const ThemePreferences(
          themeMode: ThemeMode.dark,
          palette: AppPalette.everforest,
          terminalPillItems: legacyDefaultTerminalPillItems,
        ),
      );
      expect(
        (await repository.load()).terminalPillItems,
        legacyDefaultTerminalPillItems,
      );
    });

    test('treats an unknown toolbar style as the floating pill', () async {
      final storage = InMemorySecureStorage();
      await storage.write(
        key: 'conduit.terminal_toolbar_style.v1',
        value: 'hologram',
      );
      final repository = ThemePreferencesRepository(storage);

      final preferences = await repository.load();

      expect(
        preferences.terminalToolbarStyle,
        TerminalToolbarStyle.floatingPill,
      );
    });

    test('treats a corrupt touch mode hint value as unseen', () async {
      final storage = InMemorySecureStorage();
      await storage.write(
        key: 'conduit.touch_mode_hint_seen.v1',
        value: 'not-a-bool',
      );
      final repository = ThemePreferencesRepository(storage);

      final preferences = await repository.load();

      expect(preferences.touchModeHintSeen, isFalse);
    });

    test('defaults menu buttons to on and persists turning them off', () async {
      final storage = InMemorySecureStorage();
      final repository = ThemePreferencesRepository(storage);

      final defaults = await repository.load();
      expect(defaults.menuButtonsEnabled, isTrue);

      await repository.save(
        const ThemePreferences(
          themeMode: ThemeMode.dark,
          palette: AppPalette.everforest,
          menuButtonsEnabled: false,
        ),
      );

      final preferences = await repository.load();
      expect(preferences.menuButtonsEnabled, isFalse);
    });

    test('persists terminal gesture switches and tolerates bad data', () async {
      final storage = InMemorySecureStorage();
      final repository = ThemePreferencesRepository(storage);

      final defaults = await repository.load();
      expect(defaults.terminalGestures, TerminalGesturePreferences.defaults);

      const gestures = TerminalGesturePreferences(
        swipeSwitchesWindow: false,
        windowSwitchTarget: TerminalWindowSwitchTarget.herdr,
        pinchZoom: false,
      );
      await repository.save(
        const ThemePreferences(
          themeMode: ThemeMode.dark,
          palette: AppPalette.everforest,
          terminalGestures: gestures,
        ),
      );
      expect((await repository.load()).terminalGestures, gestures);

      await storage.write(key: 'conduit.terminal_gestures.v1', value: '{');
      expect(
        (await repository.load()).terminalGestures,
        TerminalGesturePreferences.defaults,
      );
    });

    test('persists and loads global snippets', () async {
      final storage = InMemorySecureStorage();
      final repository = ThemePreferencesRepository(storage);
      const snippet = TerminalSnippet(
        id: 'snippet:one',
        label: 'Deploy',
        text: 'deploy production',
        hidden: true,
      );

      await repository.save(
        const ThemePreferences(
          themeMode: ThemeMode.dark,
          palette: AppPalette.everforest,
          terminalSnippets: [snippet],
        ),
      );

      final preferences = await repository.load();

      expect(preferences.terminalSnippets, [snippet]);
    });
  });
}
