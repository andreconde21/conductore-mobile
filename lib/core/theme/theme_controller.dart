import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/core/theme/omarchy_theme_sync.dart';
import 'package:conduit/core/theme/omarchy_theme_sync_controller.dart';
import 'package:conduit/core/theme/terminal_appearance.dart';
import 'package:conduit/core/theme/terminal_pill_items.dart';
import 'package:conduit/core/theme/theme_preferences_repository.dart';
import 'package:conduit/features/quick_actions/domain/quick_action.dart';
import 'package:conduit/features/snippets/domain/terminal_snippet.dart';
import 'package:conduit/features/terminal/domain/terminal_gesture_preferences.dart';
import 'package:conduit/features/voice/domain/voice_preferences.dart';
import 'package:flutter/material.dart';

class ThemeController extends ChangeNotifier {
  ThemeController(this._repository);

  final ThemePreferencesRepository _repository;

  /// Reads the followed machine's Omarchy theme; set once at startup so the
  /// Appearance settings can offer "Follow Omarchy theme". Null in tests
  /// and builds without it.
  OmarchyThemeSyncController? omarchySync;

  ThemeMode _themeMode = ThemeMode.dark;
  AppPalette _palette = AppPalette.defaultPalette;
  TerminalFontOption _terminalFont = defaultTerminalFont;
  String? _omarchySyncHostId;
  OmarchySyncedTheme? _omarchySyncedTheme;
  double _terminalFontSize = terminalFontSizeDefault;
  List<TerminalKeyboardRow> _terminalKeyboardRows = defaultTerminalKeyboardRows;
  List<TerminalSnippet> _terminalSnippets = const [];
  bool _showLocalShell = true;
  bool _terminalMouseInput = false;
  TerminalEnterSequence _terminalEnterSequence = TerminalEnterSequence.cr;
  bool _touchModeHintSeen = false;
  bool _chatButtonHintSeen = false;
  bool _composeSubmitEnter = false;
  TerminalToolbarStyle _terminalToolbarStyle =
      TerminalToolbarStyle.floatingPill;
  List<TerminalPillItem> _terminalPillItems = defaultTerminalPillItems;
  bool _menuButtonsEnabled = true;
  bool _remoteClipboardEnabled = true;
  bool _pasteImagesAsFiles = true;
  bool _restoreSessionsOnLaunch = true;
  MultiplexerTabsMode _multiplexerTabs = MultiplexerTabsMode.compact;
  TerminalGesturePreferences _terminalGestures =
      TerminalGesturePreferences.defaults;
  String _speechLanguage = '';
  VoicePreferences _voice = VoicePreferences.defaults;
  List<QuickAction> _quickActions = const [];

  /// The stored light/dark choice. Omarchy themes are dark or light
  /// themselves, so the app follows [effectiveThemeMode]; this stays for
  /// backups and older builds.
  ThemeMode get themeMode => _themeMode;

  /// The brightness the app renders in: the active theme's.
  ThemeMode get effectiveThemeMode => palette.themeMode;

  /// The active theme: the followed machine's Omarchy theme when that is
  /// set and has been read, else the theme picked in the app.
  AppPalette get palette {
    final synced = _omarchySyncedTheme;
    if (_omarchySyncHostId != null && synced?.hostId == _omarchySyncHostId) {
      return synced!.palette;
    }
    return _palette;
  }

  /// The theme picked in the app (used when not following a machine).
  AppPalette get selectedPalette => _palette;

  /// The saved machine whose Omarchy theme the app follows, or null.
  String? get omarchySyncHostId => _omarchySyncHostId;

  /// The theme last read from the followed machine.
  OmarchySyncedTheme? get omarchySyncedTheme =>
      _omarchySyncHostId != null &&
          _omarchySyncedTheme?.hostId == _omarchySyncHostId
      ? _omarchySyncedTheme
      : null;
  TerminalFontOption get terminalFont => _terminalFont;
  double get terminalFontSize => _terminalFontSize;
  List<TerminalKeyboardRow> get terminalKeyboardRows =>
      List.unmodifiable(_terminalKeyboardRows);
  List<TerminalSnippet> get terminalSnippets =>
      List.unmodifiable(_terminalSnippets);
  bool get showLocalShell => _showLocalShell;
  bool get terminalMouseInput => _terminalMouseInput;
  TerminalEnterSequence get terminalEnterSequence => _terminalEnterSequence;
  bool get touchModeHintSeen => _touchModeHintSeen;
  bool get chatButtonHintSeen => _chatButtonHintSeen;
  bool get composeSubmitEnter => _composeSubmitEnter;
  TerminalToolbarStyle get terminalToolbarStyle => _terminalToolbarStyle;
  List<TerminalPillItem> get terminalPillItems =>
      List.unmodifiable(_terminalPillItems);
  bool get menuButtonsEnabled => _menuButtonsEnabled;

  /// Whether OSC 52 copies from the remote reach the phone clipboard.
  bool get remoteClipboardEnabled => _remoteClipboardEnabled;

  /// Whether a pasted image is uploaded to the host and pasted as a path.
  bool get pasteImagesAsFiles => _pasteImagesAsFiles;

  /// Whether the open sessions come back after the app restarts.
  bool get restoreSessionsOnLaunch => _restoreSessionsOnLaunch;

  /// How a phone or tablet shows the multiplexer's tabs.
  MultiplexerTabsMode get multiplexerTabs => _multiplexerTabs;
  TerminalGesturePreferences get terminalGestures => _terminalGestures;

  /// BCP-47 tag dictation listens in; empty means the device locale.
  String get speechLanguage => _speechLanguage;

  /// Read-aloud and continuous-dictation settings.
  VoicePreferences get voice => _voice;

  /// Personal quick actions (Settings; synced with the appearance).
  List<QuickAction> get quickActions => _quickActions;

  Future<void> load() async {
    final preferences = await _repository.load();
    _themeMode = preferences.themeMode;
    _palette = preferences.palette;
    _terminalFont = preferences.terminalFont;
    _terminalFontSize = preferences.terminalFontSize;
    _terminalKeyboardRows = List.of(preferences.terminalKeyboardRows);
    _terminalSnippets = List.of(preferences.terminalSnippets);
    _showLocalShell = preferences.showLocalShell;
    _terminalMouseInput = preferences.terminalMouseInput;
    _terminalEnterSequence = preferences.terminalEnterSequence;
    _touchModeHintSeen = preferences.touchModeHintSeen;
    _chatButtonHintSeen = preferences.chatButtonHintSeen;
    _composeSubmitEnter = preferences.composeSubmitEnter;
    _terminalToolbarStyle = preferences.terminalToolbarStyle;
    _terminalPillItems = List.of(preferences.terminalPillItems);
    _menuButtonsEnabled = preferences.menuButtonsEnabled;
    _remoteClipboardEnabled = preferences.remoteClipboardEnabled;
    _pasteImagesAsFiles = preferences.pasteImagesAsFiles;
    _restoreSessionsOnLaunch = preferences.restoreSessionsOnLaunch;
    _multiplexerTabs = preferences.multiplexerTabs;
    _terminalGestures = preferences.terminalGestures;
    _speechLanguage = preferences.speechLanguage;
    _voice = preferences.voice;
    _quickActions = preferences.quickActions;
    _omarchySyncHostId = preferences.omarchySyncHostId;
    _omarchySyncedTheme = preferences.omarchySyncedTheme;
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    if (_themeMode == mode) {
      return;
    }
    _themeMode = mode;
    notifyListeners();
    await _save();
  }

  /// Picks a theme. Picking one while following a machine stops
  /// following it: the pick is what the user asked to see.
  Future<void> setPalette(AppPalette palette) async {
    if (_palette == palette && _omarchySyncHostId == null) {
      return;
    }
    _palette = palette;
    _omarchySyncHostId = null;
    notifyListeners();
    await _save();
  }

  /// Follows the Omarchy theme of the saved machine [hostId] (null stops).
  /// The cached theme of another machine is dropped; the next sync fills
  /// it in, and the picked theme shows until then.
  Future<void> setOmarchySyncHost(String? hostId) async {
    if (_omarchySyncHostId == hostId) {
      return;
    }
    _omarchySyncHostId = hostId;
    if (_omarchySyncedTheme?.hostId != hostId) {
      _omarchySyncedTheme = null;
    }
    notifyListeners();
    await _save();
  }

  /// Applies a theme read from the followed machine. Its font becomes the
  /// terminal font when it is one the app bundles. Ignored when the app no
  /// longer follows that machine (the user switched while it was running).
  Future<void> applyOmarchySync(OmarchySyncedTheme synced) async {
    if (synced.hostId != _omarchySyncHostId) {
      return;
    }
    final font = synced.font;
    final unchanged =
        _omarchySyncedTheme?.palette == synced.palette &&
        _omarchySyncedTheme?.fontFamily == synced.fontFamily &&
        (font == null || font == _terminalFont);
    _omarchySyncedTheme = synced;
    if (font != null) {
      _terminalFont = font;
    }
    if (!unchanged) {
      notifyListeners();
    }
    await _save();
  }

  Future<void> setTerminalFont(TerminalFontOption font) async {
    if (_terminalFont == font) {
      return;
    }
    _terminalFont = font;
    notifyListeners();
    await _save();
  }

  Future<void> setTerminalFontSize(double size) async {
    final normalized = normalizeTerminalFontSize(size);
    if (_terminalFontSize == normalized) {
      return;
    }
    _terminalFontSize = normalized;
    notifyListeners();
    await _save();
  }

  Future<void> setTerminalKeyboardRows(List<TerminalKeyboardRow> rows) async {
    final normalized = <TerminalKeyboardRow>[];
    for (final row in rows) {
      final seen = <TerminalKeyboardAction>{};
      final items = <TerminalKeyboardItem>[];
      for (final item in row.items) {
        final action = item.action;
        if (item.kind == TerminalKeyboardItemKind.builtIn && action != null) {
          if (seen.add(action)) {
            items.add(item);
          }
        } else {
          items.add(item);
        }
      }
      if (items.isEmpty) {
        continue;
      }
      normalized.add(
        TerminalKeyboardRow(
          items: items,
          height: clampTerminalKeyboardRowHeight(row.height),
        ),
      );
    }
    final next = normalized.isEmpty ? defaultTerminalKeyboardRows : normalized;
    if (_listEquals(_terminalKeyboardRows, next)) {
      return;
    }
    _terminalKeyboardRows = List.of(next);
    notifyListeners();
    await _save();
  }

  Future<void> resetTerminalKeyboardRows() {
    return setTerminalKeyboardRows(defaultTerminalKeyboardRows);
  }

  Future<void> setTerminalSnippets(List<TerminalSnippet> snippets) async {
    final seen = <String>{};
    final normalized = <TerminalSnippet>[];
    for (final snippet in snippets) {
      if (!snippet.isValid || !seen.add(snippet.id)) {
        continue;
      }
      normalized.add(snippet);
    }
    if (_listEquals(_terminalSnippets, normalized)) {
      return;
    }
    _terminalSnippets = List.of(normalized);
    notifyListeners();
    await _save();
  }

  Future<void> setShowLocalShell(bool show) async {
    if (_showLocalShell == show) {
      return;
    }
    _showLocalShell = show;
    notifyListeners();
    await _save();
  }

  Future<void> setTerminalMouseInput(bool enabled) async {
    if (_terminalMouseInput == enabled) {
      return;
    }
    _terminalMouseInput = enabled;
    notifyListeners();
    await _save();
  }

  Future<void> setTerminalEnterSequence(TerminalEnterSequence sequence) async {
    if (_terminalEnterSequence == sequence) {
      return;
    }
    _terminalEnterSequence = sequence;
    notifyListeners();
    await _save();
  }

  Future<void> markTouchModeHintSeen() async {
    if (_touchModeHintSeen) {
      return;
    }
    _touchModeHintSeen = true;
    notifyListeners();
    await _save();
  }

  Future<void> markChatButtonHintSeen() async {
    if (_chatButtonHintSeen) {
      return;
    }
    _chatButtonHintSeen = true;
    notifyListeners();
    await _save();
  }

  Future<void> setComposeSubmitEnter(bool enabled) async {
    if (_composeSubmitEnter == enabled) {
      return;
    }
    _composeSubmitEnter = enabled;
    notifyListeners();
    await _save();
  }

  Future<void> setTerminalToolbarStyle(TerminalToolbarStyle style) async {
    if (_terminalToolbarStyle == style) {
      return;
    }
    _terminalToolbarStyle = style;
    notifyListeners();
    await _save();
  }

  Future<void> setTerminalPillItems(List<TerminalPillItem> items) async {
    if (_listEquals(_terminalPillItems, items)) {
      return;
    }
    _terminalPillItems = List.of(items);
    notifyListeners();
    await _save();
  }

  Future<void> setMenuButtonsEnabled(bool enabled) async {
    if (_menuButtonsEnabled == enabled) {
      return;
    }
    _menuButtonsEnabled = enabled;
    notifyListeners();
    await _save();
  }

  Future<void> setRemoteClipboardEnabled(bool enabled) async {
    if (_remoteClipboardEnabled == enabled) {
      return;
    }
    _remoteClipboardEnabled = enabled;
    notifyListeners();
    await _save();
  }

  Future<void> setPasteImagesAsFiles(bool enabled) async {
    if (_pasteImagesAsFiles == enabled) {
      return;
    }
    _pasteImagesAsFiles = enabled;
    notifyListeners();
    await _save();
  }

  Future<void> setMultiplexerTabs(MultiplexerTabsMode value) async {
    if (_multiplexerTabs == value) {
      return;
    }
    _multiplexerTabs = value;
    notifyListeners();
    await _save();
  }

  Future<void> setRestoreSessionsOnLaunch(bool enabled) async {
    if (_restoreSessionsOnLaunch == enabled) {
      return;
    }
    _restoreSessionsOnLaunch = enabled;
    notifyListeners();
    await _save();
  }

  Future<void> setTerminalGestures(TerminalGesturePreferences gestures) async {
    if (_terminalGestures == gestures) {
      return;
    }
    _terminalGestures = gestures;
    notifyListeners();
    await _save();
  }

  Future<void> setSpeechLanguage(String tag) async {
    final normalized = tag.trim();
    if (_speechLanguage == normalized) {
      return;
    }
    _speechLanguage = normalized;
    notifyListeners();
    await _save();
  }

  Future<void> setVoice(VoicePreferences voice) async {
    if (_voice == voice) {
      return;
    }
    _voice = voice;
    notifyListeners();
    await _save();
  }

  Future<void> setQuickActions(List<QuickAction> actions) async {
    if (_listEquals(_quickActions, actions)) return;
    _quickActions = List.unmodifiable(actions);
    notifyListeners();
    await _save();
  }

  Future<void> _save() {
    return _repository.save(
      ThemePreferences(
        themeMode: _themeMode,
        palette: _palette,
        terminalFont: _terminalFont,
        terminalFontSize: _terminalFontSize,
        terminalKeyboardRows: _terminalKeyboardRows,
        terminalSnippets: _terminalSnippets,
        showLocalShell: _showLocalShell,
        terminalMouseInput: _terminalMouseInput,
        terminalEnterSequence: _terminalEnterSequence,
        touchModeHintSeen: _touchModeHintSeen,
        chatButtonHintSeen: _chatButtonHintSeen,
        composeSubmitEnter: _composeSubmitEnter,
        terminalToolbarStyle: _terminalToolbarStyle,
        terminalPillItems: _terminalPillItems,
        menuButtonsEnabled: _menuButtonsEnabled,
        terminalGestures: _terminalGestures,
        speechLanguage: _speechLanguage,
        voice: _voice,
        quickActions: _quickActions,
        remoteClipboardEnabled: _remoteClipboardEnabled,
        pasteImagesAsFiles: _pasteImagesAsFiles,
        restoreSessionsOnLaunch: _restoreSessionsOnLaunch,
        multiplexerTabs: _multiplexerTabs,
        omarchySyncHostId: _omarchySyncHostId,
        omarchySyncedTheme: _omarchySyncedTheme,
      ),
    );
  }

  bool _listEquals<T>(List<T> a, List<T> b) {
    if (a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i += 1) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }
}
