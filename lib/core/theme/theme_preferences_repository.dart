import 'dart:convert';

import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/core/theme/omarchy_theme_sync.dart';
import 'package:conduit/core/theme/terminal_appearance.dart';
import 'package:conduit/core/theme/terminal_pill_items.dart';
import 'package:conduit/features/desktop_shell/domain/project_layout.dart';
import 'package:conduit/features/quick_actions/domain/quick_action.dart';
import 'package:conduit/features/snippets/domain/terminal_snippet.dart';
import 'package:conduit/features/terminal/data/ssh_keepalive_policy.dart';
import 'package:conduit/features/terminal/domain/terminal_gesture_preferences.dart';
import 'package:conduit/features/voice/domain/voice_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class ThemePreferences {
  const ThemePreferences({
    required this.themeMode,
    required this.palette,
    this.terminalFont = defaultTerminalFont,
    this.terminalFontSize = terminalFontSizeDefault,
    this.terminalKeyboardRows = defaultTerminalKeyboardRows,
    this.terminalSnippets = const [],
    this.showLocalShell = true,
    this.terminalMouseInput = false,
    this.terminalEnterSequence = TerminalEnterSequence.cr,
    this.touchModeHintSeen = false,
    this.chatButtonHintSeen = false,
    this.composeSubmitEnter = false,
    this.terminalToolbarStyle = TerminalToolbarStyle.floatingPill,
    this.terminalPillItems = defaultTerminalPillItems,
    this.menuButtonsEnabled = true,
    this.terminalGestures = TerminalGesturePreferences.defaults,
    this.speechLanguage = '',
    this.voice = VoicePreferences.defaults,
    this.quickActions = const [],
    this.projectPrefs = ProjectPrefs.defaults,
    this.remoteClipboardEnabled = true,
    this.pasteImagesAsFiles = true,
    this.restoreSessionsOnLaunch = true,
    this.multiplexerTabs = MultiplexerTabsMode.compact,
    this.herdrMayMoveFocus = false,
    this.keepScreenOn,
    this.sshKeepaliveSeconds = SshKeepalivePolicy.defaultForegroundSeconds,
    this.omarchySyncHostId,
    this.omarchySyncedTheme,
  });

  final ThemeMode themeMode;
  final AppPalette palette;
  final TerminalFontOption terminalFont;
  final double terminalFontSize;
  final List<TerminalKeyboardRow> terminalKeyboardRows;
  final List<TerminalSnippet> terminalSnippets;
  final bool showLocalShell;
  final bool terminalMouseInput;
  final TerminalEnterSequence terminalEnterSequence;

  /// Whether the one-time touch-mode discoverability hint has been shown.
  final bool touchModeHintSeen;

  /// Whether the one-time hint for the pill's Chat button has been shown.
  final bool chatButtonHintSeen;

  /// Whether the prompt composer presses Enter after inserting a prompt.
  /// Off by default so composed text lands in the TUI for review.
  final bool composeSubmitEnter;

  /// Which input toolbar the terminal page shows; the floating pill is the
  /// default, the key rows remain available as the classic layout.
  final TerminalToolbarStyle terminalToolbarStyle;

  /// Buttons on the floating pill, in order (the ⋯ button always follows).
  final List<TerminalPillItem> terminalPillItems;

  /// Whether choice prompts on screen (Claude Code menus, y/n questions)
  /// are offered as tappable buttons above the keyboard bar.
  final bool menuButtonsEnabled;

  /// Per-gesture switches for the terminal touch gestures.
  final TerminalGesturePreferences terminalGestures;

  /// BCP-47 tag dictation listens in; empty means the device locale.
  final String speechLanguage;

  /// Read-aloud and continuous-dictation settings.
  final VoicePreferences voice;

  /// Personal quick actions (Settings), for every project or one.
  final List<QuickAction> quickActions;

  /// The project view's layout and choices (CON-065).
  final ProjectPrefs projectPrefs;

  /// Whether text the remote copies with OSC 52 lands on the phone
  /// clipboard. On by default, like most desktop terminals.
  final bool remoteClipboardEnabled;

  /// Whether pasting an image uploads it to the host's share inbox and
  /// pastes its path (what Claude Code reads as an image). Off: paste text
  /// only, as before. On by default.
  final bool pasteImagesAsFiles;

  /// Whether the open sessions come back after the app restarts (their
  /// list is kept in secure storage). On by default.
  final bool restoreSessionsOnLaunch;

  /// How a phone or tablet shows the multiplexer's tabs.
  final MultiplexerTabsMode multiplexerTabs;

  /// Whether this device may move a Herdr server's focus (which every
  /// screen attached to it shares, the laptop included) on its own. Off by
  /// default, and kept per device: it is never synced.
  final bool herdrMayMoveFocus;

  /// "Keep screen on while a terminal is open"; null follows the device's
  /// default (on for phones, off for desktop). Kept per device.
  final bool? keepScreenOn;

  /// Seconds between SSH keep-alives while the app is in front; 0 is off.
  /// Kept per device.
  final int sshKeepaliveSeconds;

  /// The saved machine whose Omarchy theme the app follows; null when the
  /// app uses [palette].
  final String? omarchySyncHostId;

  /// The theme last read from that machine (cached for the next start).
  final OmarchySyncedTheme? omarchySyncedTheme;
}

class ThemePreferencesRepository {
  const ThemePreferencesRepository(this._storage);

  static const _themeModeKey = 'conduit.theme_mode.v1';

  /// Conduit's palette enum names (v1) and Omarchy theme ids (v2).
  static const _legacyPaletteKey = 'conduit.palette.v1';
  static const _paletteKey = 'conductore.palette.v2';

  /// v1 always held the old default (Atkynson) once anything was saved, so
  /// only an explicit "system" choice carries over to v2.
  static const _legacyTerminalFontKey = 'conduit.terminal_font.v1';
  static const _terminalFontKey = 'conductore.terminal_font.v2';
  static const _omarchySyncHostKey = 'conductore.omarchy_sync_host.v1';
  static const _omarchySyncedThemeKey = 'conductore.omarchy_synced_theme.v1';
  static const _terminalFontSizeKey = 'conduit.terminal_font_size.v1';
  static const _terminalKeyboardActionsKey =
      'conduit.terminal_keyboard_actions.v1';
  static const _terminalKeyboardRowsKey = 'conduit.terminal_keyboard_rows.v2';

  /// The key rows before CON-106, saved even when they were the default;
  /// read only when there are no v2 rows yet.
  static const _legacyTerminalKeyboardRowsKey =
      'conduit.terminal_keyboard_rows.v1';
  static const _terminalKeyboardSeenActionsKey =
      'conduit.terminal_keyboard_seen_actions.v1';
  static const _terminalSnippetsKey = 'conduit.terminal_snippets.v1';
  static const _showLocalShellKey = 'conduit.show_local_shell.v1';
  static const _terminalMouseInputKey = 'conduit.terminal_mouse_input.v1';
  static const _terminalEnterSequenceKey = 'conduit.terminal_enter_sequence.v1';
  static const _touchModeHintSeenKey = 'conduit.touch_mode_hint_seen.v1';
  static const _chatButtonHintSeenKey = 'conduit.chat_button_hint_seen.v1';
  static const _composeSubmitEnterKey = 'conduit.compose_submit_enter.v1';
  static const _terminalToolbarStyleKey = 'conduit.terminal_toolbar_style.v1';
  static const _terminalPillItemsKey = 'conduit.terminal_pill_items.v2';

  /// The pill list before CON-106, saved even when it was the default;
  /// read only when there is no v2 list yet.
  static const _legacyTerminalPillItemsKey = 'conduit.terminal_pill_items.v1';
  static const _menuButtonsEnabledKey = 'conduit.menu_buttons_enabled.v1';
  static const _terminalGesturesKey = 'conduit.terminal_gestures.v1';
  static const _speechLanguageKey = 'conduit.speech_language.v1';
  static const _voiceKey = 'conductore.voice.v1';
  static const _quickActionsKey = 'conductore.quick_actions.v1';
  static const _projectPrefsKey = 'conductore.project_prefs.v1';
  static const _remoteClipboardEnabledKey =
      'conduit.remote_clipboard_enabled.v1';
  static const _pasteImagesAsFilesKey = 'conductore.paste_images_as_files.v1';
  static const _restoreSessionsOnLaunchKey =
      'conductore.restore_sessions_on_launch.v1';
  static const _multiplexerTabsKey = 'conductore.multiplexer_tabs_phone.v1';
  static const _herdrMayMoveFocusKey = 'conductore.herdr_may_move_focus.v1';
  static const _keepScreenOnKey = 'conductore.keep_screen_on.v1';
  static const _sshKeepaliveSecondsKey = 'conductore.ssh_keepalive_seconds.v1';

  static const _loadKeys = [
    _themeModeKey,
    _paletteKey,
    _terminalFontKey,
    _omarchySyncHostKey,
    _omarchySyncedThemeKey,
    _terminalFontSizeKey,
    _terminalKeyboardActionsKey,
    _terminalKeyboardRowsKey,
    _terminalKeyboardSeenActionsKey,
    _terminalSnippetsKey,
    _showLocalShellKey,
    _terminalMouseInputKey,
    _terminalEnterSequenceKey,
    _touchModeHintSeenKey,
    _chatButtonHintSeenKey,
    _composeSubmitEnterKey,
    _terminalToolbarStyleKey,
    _terminalPillItemsKey,
    _menuButtonsEnabledKey,
    _terminalGesturesKey,
    _speechLanguageKey,
    _voiceKey,
    _quickActionsKey,
    _projectPrefsKey,
    _remoteClipboardEnabledKey,
    _restoreSessionsOnLaunchKey,
    _multiplexerTabsKey,
    _pasteImagesAsFilesKey,
    _herdrMayMoveFocusKey,
    _keepScreenOnKey,
    _sshKeepaliveSecondsKey,
  ];

  final FlutterSecureStorage _storage;

  Future<ThemePreferences> load() async {
    // Every setting is asked for at once: the platform answers them back
    // to back instead of one round trip at a time (about 30 reads at
    // launch). The legacy keys are read only when needed.
    final pending = <String, Future<String?>>{
      for (final key in _loadKeys) key: _storage.read(key: key)..ignore(),
    };
    Future<String?> read(String key) => pending[key]!;
    final rawMode = await read(_themeModeKey);
    final rawPalette =
        await read(_paletteKey) ?? await _storage.read(key: _legacyPaletteKey);
    final rawTerminalFont = await read(_terminalFontKey);
    final rawLegacyTerminalFont = rawTerminalFont == null
        ? await _storage.read(key: _legacyTerminalFontKey)
        : null;
    final rawOmarchySyncHost = await read(_omarchySyncHostKey);
    final rawOmarchySyncedTheme = await read(_omarchySyncedThemeKey);
    final rawTerminalFontSize = await read(_terminalFontSizeKey);
    final rawTerminalKeyboardActions = await read(_terminalKeyboardActionsKey);
    final rawTerminalKeyboardRowsV2 = await read(_terminalKeyboardRowsKey);
    final rawTerminalKeyboardRows =
        rawTerminalKeyboardRowsV2 ??
        await _storage.read(key: _legacyTerminalKeyboardRowsKey);
    final rawTerminalKeyboardSeenActions = await read(
      _terminalKeyboardSeenActionsKey,
    );
    final rawTerminalSnippets = await read(_terminalSnippetsKey);
    final rawShowLocalShell = await read(_showLocalShellKey);
    final rawTerminalMouseInput = await read(_terminalMouseInputKey);
    final rawTerminalEnterSequence = await read(_terminalEnterSequenceKey);
    final rawTouchModeHintSeen = await read(_touchModeHintSeenKey);
    final rawChatButtonHintSeen = await read(_chatButtonHintSeenKey);
    final rawComposeSubmitEnter = await read(_composeSubmitEnterKey);
    final rawTerminalToolbarStyle = await read(_terminalToolbarStyleKey);
    final rawTerminalPillItems = await read(_terminalPillItemsKey);
    final rawLegacyTerminalPillItems = rawTerminalPillItems == null
        ? await _storage.read(key: _legacyTerminalPillItemsKey)
        : null;

    final rawMenuButtonsEnabled = await read(_menuButtonsEnabledKey);
    final rawTerminalGestures = await read(_terminalGesturesKey);
    final rawSpeechLanguage = await read(_speechLanguageKey);
    final rawVoice = await read(_voiceKey);
    final rawQuickActions = await read(_quickActionsKey);
    final rawProjectPrefs = await read(_projectPrefsKey);
    final rawRemoteClipboardEnabled = await read(_remoteClipboardEnabledKey);
    final rawRestoreSessionsOnLaunch = await read(_restoreSessionsOnLaunchKey);
    final rawMultiplexerTabs = await read(_multiplexerTabsKey);
    final rawHerdrMayMoveFocus = await read(_herdrMayMoveFocusKey);
    final rawKeepScreenOn = await read(_keepScreenOnKey);
    final sshKeepaliveSeconds = int.tryParse(
      await read(_sshKeepaliveSecondsKey) ?? '',
    );
    final rawPasteImagesAsFiles = await read(_pasteImagesAsFilesKey);
    final terminalFontSize = double.tryParse(rawTerminalFontSize ?? '');
    final parsedRows = _parseTerminalKeyboardRows(
      rawTerminalKeyboardRows,
      rawTerminalKeyboardActions,
    );
    final terminalKeyboardRows = _appendUnseenBuiltIns(
      rawTerminalKeyboardRowsV2 == null
          ? migratePreChatKeyboardRows(parsedRows)
          : parsedRows,
      _parseSeenActionNames(rawTerminalKeyboardSeenActions),
    );

    return ThemePreferences(
      themeMode: ThemeMode.values.firstWhere(
        (mode) => mode.name == rawMode,
        orElse: () => ThemeMode.dark,
      ),
      palette: AppPalette.fromStoredId(rawPalette),
      terminalFont: _parseTerminalFont(rawTerminalFont, rawLegacyTerminalFont),
      terminalFontSize: terminalFontSize == null
          ? terminalFontSizeDefault
          : clampTerminalFontSize(terminalFontSize),
      terminalKeyboardRows: terminalKeyboardRows,
      terminalSnippets: _parseTerminalSnippets(rawTerminalSnippets),
      showLocalShell: rawShowLocalShell == null || rawShowLocalShell == 'true',
      terminalMouseInput: rawTerminalMouseInput == 'true',
      terminalEnterSequence: TerminalEnterSequence.values.firstWhere(
        (sequence) => sequence.name == rawTerminalEnterSequence,
        orElse: () => TerminalEnterSequence.cr,
      ),
      touchModeHintSeen: rawTouchModeHintSeen == 'true',
      chatButtonHintSeen: rawChatButtonHintSeen == 'true',
      composeSubmitEnter: rawComposeSubmitEnter == 'true',
      terminalToolbarStyle: TerminalToolbarStyle.values.firstWhere(
        (style) => style.name == rawTerminalToolbarStyle,
        orElse: () => TerminalToolbarStyle.floatingPill,
      ),
      terminalPillItems: rawTerminalPillItems == null
          ? migrateLegacyPillItems(
              _parseTerminalPillItems(rawLegacyTerminalPillItems),
            )
          : _parseTerminalPillItems(rawTerminalPillItems),
      menuButtonsEnabled:
          rawMenuButtonsEnabled == null || rawMenuButtonsEnabled == 'true',
      terminalGestures: TerminalGesturePreferences.decode(rawTerminalGestures),
      speechLanguage: rawSpeechLanguage?.trim() ?? '',
      voice: VoicePreferences.decode(rawVoice),
      quickActions: QuickAction.decodeList(rawQuickActions),
      projectPrefs: _parseProjectPrefs(rawProjectPrefs),
      remoteClipboardEnabled:
          rawRemoteClipboardEnabled == null ||
          rawRemoteClipboardEnabled == 'true',
      restoreSessionsOnLaunch:
          rawRestoreSessionsOnLaunch == null ||
          rawRestoreSessionsOnLaunch == 'true',
      multiplexerTabs: MultiplexerTabsMode.values.firstWhere(
        (value) => value.name == rawMultiplexerTabs,
        orElse: () => MultiplexerTabsMode.compact,
      ),
      herdrMayMoveFocus: rawHerdrMayMoveFocus == 'true',
      keepScreenOn: switch (rawKeepScreenOn) {
        'true' => true,
        'false' => false,
        _ => null,
      },
      sshKeepaliveSeconds:
          SshKeepalivePolicy.choices.contains(sshKeepaliveSeconds)
          ? sshKeepaliveSeconds!
          : SshKeepalivePolicy.defaultForegroundSeconds,
      pasteImagesAsFiles:
          rawPasteImagesAsFiles == null || rawPasteImagesAsFiles == 'true',
      omarchySyncHostId: (rawOmarchySyncHost?.trim().isEmpty ?? true)
          ? null
          : rawOmarchySyncHost!.trim(),
      omarchySyncedTheme: _parseSyncedTheme(rawOmarchySyncedTheme),
    );
  }

  static TerminalFontOption _parseTerminalFont(String? raw, String? legacy) {
    if (raw == null) {
      return legacy == TerminalFontOption.systemMonospace.name
          ? TerminalFontOption.systemMonospace
          : defaultTerminalFont;
    }
    return TerminalFontOption.values.firstWhere(
      (font) => font.name == raw,
      orElse: () => defaultTerminalFont,
    );
  }

  static ProjectPrefs _parseProjectPrefs(String? raw) {
    if (raw == null || raw.trim().isEmpty) return ProjectPrefs.defaults;
    try {
      return ProjectPrefs.fromJson(jsonDecode(raw));
    } catch (_) {
      return ProjectPrefs.defaults;
    }
  }

  static OmarchySyncedTheme? _parseSyncedTheme(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }
    try {
      return OmarchySyncedTheme.fromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  Future<void> save(ThemePreferences preferences) async {
    await _storage.write(key: _themeModeKey, value: preferences.themeMode.name);
    await _storage.write(key: _paletteKey, value: preferences.palette.name);
    await _storage.write(
      key: _terminalFontKey,
      value: preferences.terminalFont.name,
    );
    await _storage.write(
      key: _terminalFontSizeKey,
      value: preferences.terminalFontSize.toStringAsFixed(1),
    );
    await _storage.write(
      key: _terminalKeyboardRowsKey,
      value: jsonEncode([
        for (final row in preferences.terminalKeyboardRows)
          {
            'height': row.height,
            'items': row.items.map(_keyboardItemToJson).toList(),
          },
      ]),
    );
    await _storage.write(
      key: _terminalKeyboardSeenActionsKey,
      value: TerminalKeyboardAction.values
          .map((action) => action.name)
          .join(','),
    );
    await _storage.write(
      key: _terminalSnippetsKey,
      value: jsonEncode(
        preferences.terminalSnippets
            .map((snippet) => snippet.toJson())
            .toList(),
      ),
    );
    await _storage.write(
      key: _showLocalShellKey,
      value: preferences.showLocalShell.toString(),
    );
    await _storage.write(
      key: _terminalMouseInputKey,
      value: preferences.terminalMouseInput.toString(),
    );
    await _storage.write(
      key: _terminalEnterSequenceKey,
      value: preferences.terminalEnterSequence.name,
    );
    await _storage.write(
      key: _touchModeHintSeenKey,
      value: preferences.touchModeHintSeen.toString(),
    );
    await _storage.write(
      key: _chatButtonHintSeenKey,
      value: preferences.chatButtonHintSeen.toString(),
    );
    await _storage.write(
      key: _composeSubmitEnterKey,
      value: preferences.composeSubmitEnter.toString(),
    );
    await _storage.write(
      key: _terminalToolbarStyleKey,
      value: preferences.terminalToolbarStyle.name,
    );
    await _storage.write(
      key: _terminalPillItemsKey,
      value: jsonEncode(
        TerminalPillItem.encodeList(preferences.terminalPillItems),
      ),
    );
    await _storage.write(
      key: _menuButtonsEnabledKey,
      value: preferences.menuButtonsEnabled.toString(),
    );
    await _storage.write(
      key: _terminalGesturesKey,
      value: preferences.terminalGestures.encode(),
    );
    await _storage.write(
      key: _speechLanguageKey,
      value: preferences.speechLanguage,
    );
    await _storage.write(key: _voiceKey, value: preferences.voice.encode());
    await _storage.write(
      key: _quickActionsKey,
      value: QuickAction.encodeList(preferences.quickActions),
    );
    await _storage.write(
      key: _projectPrefsKey,
      value: jsonEncode(preferences.projectPrefs.toJson()),
    );
    await _storage.write(
      key: _remoteClipboardEnabledKey,
      value: preferences.remoteClipboardEnabled.toString(),
    );
    await _storage.write(
      key: _restoreSessionsOnLaunchKey,
      value: preferences.restoreSessionsOnLaunch.toString(),
    );
    await _storage.write(
      key: _multiplexerTabsKey,
      value: preferences.multiplexerTabs.name,
    );
    await _storage.write(
      key: _herdrMayMoveFocusKey,
      value: preferences.herdrMayMoveFocus.toString(),
    );
    await _storage.write(
      key: _sshKeepaliveSecondsKey,
      value: preferences.sshKeepaliveSeconds.toString(),
    );
    await _storage.write(
      key: _keepScreenOnKey,
      value: preferences.keepScreenOn?.toString() ?? '',
    );
    await _storage.write(
      key: _pasteImagesAsFilesKey,
      value: preferences.pasteImagesAsFiles.toString(),
    );
    await _storage.write(
      key: _omarchySyncHostKey,
      value: preferences.omarchySyncHostId ?? '',
    );
    final synced = preferences.omarchySyncedTheme;
    await _storage.write(
      key: _omarchySyncedThemeKey,
      value: synced == null ? '' : jsonEncode(synced.toJson()),
    );
  }

  List<TerminalPillItem> _parseTerminalPillItems(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return defaultTerminalPillItems;
    }
    try {
      return TerminalPillItem.decodeList(jsonDecode(raw));
    } catch (_) {
      return defaultTerminalPillItems;
    }
  }

  List<TerminalSnippet> _parseTerminalSnippets(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return const [];
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        return const [];
      }
      return decoded
          .map(TerminalSnippet.fromJson)
          .whereType<TerminalSnippet>()
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  List<TerminalKeyboardRow> _parseTerminalKeyboardRows(
    String? rawRows,
    String? rawLegacyItems,
  ) {
    if (rawRows == null || rawRows.trim().isEmpty) {
      return [
        TerminalKeyboardRow(items: _parseTerminalKeyboardItems(rawLegacyItems)),
      ];
    }
    try {
      final decoded = jsonDecode(rawRows);
      if (decoded is! List) {
        return defaultTerminalKeyboardRows;
      }
      final rows = <TerminalKeyboardRow>[];
      for (final rawRow in decoded) {
        if (rawRow is! Map) {
          continue;
        }
        final rawItems = rawRow['items'];
        if (rawItems is! List) {
          continue;
        }
        final seenBuiltIns = <TerminalKeyboardAction>{};
        final items = <TerminalKeyboardItem>[];
        for (final rawItem in rawItems) {
          if (rawItem is! Map) {
            continue;
          }
          final item = _keyboardItemFromJson(
            Map<String, Object?>.from(rawItem),
          );
          if (item == null) {
            continue;
          }
          final action = item.action;
          if (item.kind == TerminalKeyboardItemKind.builtIn &&
              action != null &&
              !seenBuiltIns.add(action)) {
            continue;
          }
          items.add(item);
        }
        if (items.isEmpty) {
          continue;
        }
        final rawHeight = rawRow['height'];
        rows.add(
          TerminalKeyboardRow(
            items: items,
            height: rawHeight is num
                ? clampTerminalKeyboardRowHeight(rawHeight.toDouble())
                : terminalKeyboardRowHeightDefault,
          ),
        );
      }
      return rows.isEmpty ? defaultTerminalKeyboardRows : rows;
    } catch (_) {
      return defaultTerminalKeyboardRows;
    }
  }

  List<TerminalKeyboardItem> _parseTerminalKeyboardItems(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return defaultTerminalKeyboardItems;
    }

    final trimmed = raw.trim();
    if (trimmed.startsWith('[')) {
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is List) {
          final items = <TerminalKeyboardItem>[];
          final seenBuiltIns = <TerminalKeyboardAction>{};
          for (final rawItem in decoded) {
            if (rawItem is! Map) {
              continue;
            }
            final item = _keyboardItemFromJson(
              Map<String, Object?>.from(rawItem),
            );
            if (item == null) {
              continue;
            }
            final action = item.action;
            if (item.kind == TerminalKeyboardItemKind.builtIn &&
                action != null &&
                !seenBuiltIns.add(action)) {
              continue;
            }
            items.add(item);
          }
          if (items.isNotEmpty) {
            return items;
          }
        }
      } catch (_) {
        return defaultTerminalKeyboardItems;
      }
    }

    final actions = <TerminalKeyboardAction>[];
    for (final name in trimmed.split(',')) {
      TerminalKeyboardAction? action;
      for (final candidate in TerminalKeyboardAction.values) {
        if (candidate.name == name.trim()) {
          action = candidate;
          break;
        }
      }
      if (action != null && !actions.contains(action)) {
        actions.add(action);
      }
    }

    if (actions.isEmpty ||
        _sameActions(actions, legacyDefaultTerminalKeyboardActions)) {
      return defaultTerminalKeyboardItems;
    }
    return [for (final action in actions) TerminalKeyboardItem.builtIn(action)];
  }

  Set<String> _parseSeenActionNames(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return preTrackingTerminalKeyboardActionNames;
    }
    return raw.split(',').map((name) => name.trim()).toSet();
  }

  List<TerminalKeyboardRow> _appendUnseenBuiltIns(
    List<TerminalKeyboardRow> rows,
    Set<String> seenActionNames,
  ) {
    final present = <TerminalKeyboardAction>{
      for (final row in rows)
        for (final item in row.items)
          if (item.action != null) item.action!,
    };
    final unseen = TerminalKeyboardAction.values
        .where(
          (action) =>
              !seenActionNames.contains(action.name) &&
              !present.contains(action),
        )
        .toList(growable: false);
    if (unseen.isEmpty || rows.isEmpty) {
      return rows;
    }
    final first = rows.first;
    return [
      first.copyWith(
        items: [
          ...first.items,
          for (final action in unseen) TerminalKeyboardItem.builtIn(action),
        ],
      ),
      ...rows.skip(1),
    ];
  }

  Map<String, Object?> _keyboardItemToJson(TerminalKeyboardItem item) {
    return {
      'id': item.id,
      'kind': item.kind.name,
      'label': item.label,
      'action': item.action?.name,
      'text': item.text,
      'controlKey': item.controlKey,
      'submit': item.submit,
    };
  }

  TerminalKeyboardItem? _keyboardItemFromJson(Map<String, Object?> json) {
    final kindName = json['kind'];
    final id = json['id'];
    if (kindName is! String || id is! String) {
      return null;
    }
    final kind = TerminalKeyboardItemKind.values
        .where((candidate) => candidate.name == kindName)
        .firstOrNull;
    if (kind == null) {
      return null;
    }
    switch (kind) {
      case TerminalKeyboardItemKind.builtIn:
        final actionName = json['action'];
        if (actionName is! String) {
          return null;
        }
        final action = TerminalKeyboardAction.values
            .where((candidate) => candidate.name == actionName)
            .firstOrNull;
        return action == null ? null : TerminalKeyboardItem.builtIn(action);
      case TerminalKeyboardItemKind.customText:
        final label = json['label'];
        final text = json['text'];
        if (id.trim().isEmpty ||
            label is! String ||
            text is! String ||
            label.trim().isEmpty) {
          return null;
        }
        return TerminalKeyboardItem(
          id: id,
          kind: kind,
          label: label,
          text: text,
          submit: json['submit'] == true,
        );
      case TerminalKeyboardItemKind.customControl:
        final label = json['label'];
        final controlKey = json['controlKey'];
        if (id.trim().isEmpty ||
            label is! String ||
            controlKey is! String ||
            label.trim().isEmpty ||
            !terminalKeyboardControlKeys.contains(controlKey)) {
          return null;
        }
        return TerminalKeyboardItem(
          id: id,
          kind: kind,
          label: label,
          controlKey: controlKey,
        );
    }
  }

  bool _sameActions(
    List<TerminalKeyboardAction> first,
    List<TerminalKeyboardAction> second,
  ) {
    if (first.length != second.length) {
      return false;
    }
    for (var index = 0; index < first.length; index += 1) {
      if (first[index] != second[index]) {
        return false;
      }
    }
    return true;
  }
}
