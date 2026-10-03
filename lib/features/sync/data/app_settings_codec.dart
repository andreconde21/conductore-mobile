import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/core/theme/terminal_appearance.dart';
import 'package:conduit/core/theme/terminal_pill_items.dart';
import 'package:conduit/core/theme/theme_controller.dart';
import 'package:conduit/features/desktop_shell/domain/project_layout.dart';
import 'package:conduit/features/quick_actions/domain/quick_action.dart';
import 'package:conduit/features/terminal/domain/terminal_gesture_preferences.dart';
import 'package:conduit/features/this_computer/data/device_local_sync.dart';
import 'package:conduit/features/voice/domain/voice_preferences.dart';
import 'package:flutter/material.dart';

/// App preferences as JSON, one entry per setting, shared by backups and
/// sync (each entry is one sync record, so two devices changing different
/// settings both keep their change).
///
/// Device-only state stays out: onboarding hints and the cached theme read
/// from a followed Omarchy machine. Snippets have their own records.
abstract final class AppSettingsCodec {
  /// Settings in the order they are applied: the palette before the
  /// followed machine, because picking a palette stops following one.
  static const keys = [
    'themeMode',
    'palette',
    'omarchySyncHostId',
    'terminalFont',
    'terminalFontSize',
    'terminalKeyboardRows',
    'showLocalShell',
    'terminalMouseInput',
    'terminalEnterSequence',
    'composeSubmitEnter',
    'terminalToolbarStyle',
    'terminalPillItems',
    'menuButtonsEnabled',
    'remoteClipboardEnabled',
    'pasteImagesAsFiles',
    'restoreSessionsOnLaunch',
    'terminalGestures',
    'speechLanguage',
    'voice',
    'quickActions',
    'projects',
  ];

  static Map<String, Object?> encode(ThemeController theme) {
    final followed = theme.omarchySyncHostId;
    return {
      'themeMode': theme.themeMode.name,
      'palette': theme.selectedPalette.name,
      // Null (not following a machine) is a value too: stopping follow on
      // one device stops it on the others. "This computer" is a different
      // machine on every device, so following it stays here.
      if (followed == null || !isDeviceLocalHostId(followed))
        'omarchySyncHostId': followed ?? '',
      'terminalFont': theme.terminalFont.name,
      'terminalFontSize': theme.terminalFontSize,
      'terminalKeyboardRows': [
        for (final row in theme.terminalKeyboardRows)
          {
            'height': row.height,
            'items': [for (final item in row.items) keyboardItemToJson(item)],
          },
      ],
      'showLocalShell': theme.showLocalShell,
      'terminalMouseInput': theme.terminalMouseInput,
      'terminalEnterSequence': theme.terminalEnterSequence.name,
      'composeSubmitEnter': theme.composeSubmitEnter,
      'terminalToolbarStyle': theme.terminalToolbarStyle.name,
      'terminalPillItems': TerminalPillItem.encodeList(theme.terminalPillItems),
      'menuButtonsEnabled': theme.menuButtonsEnabled,
      'remoteClipboardEnabled': theme.remoteClipboardEnabled,
      'pasteImagesAsFiles': theme.pasteImagesAsFiles,
      'restoreSessionsOnLaunch': theme.restoreSessionsOnLaunch,
      'terminalGestures': theme.terminalGestures.toJson(),
      'speechLanguage': theme.speechLanguage,
      // Read-aloud and dictation settings; the per-session toggles stay on
      // each device.
      'voice': theme.voice.toJson(includeSessions: false),
      'quickActions': [
        for (final action in theme.quickActions) action.toJson(),
      ],
      // The project view's layout and choices (CON-065).
      'projects': theme.projectPrefs.toJson(),
    };
  }

  /// Applies the settings present in [json]; missing or unreadable ones
  /// keep their current value.
  static Future<void> apply(
    ThemeController theme,
    Map<String, Object?> json,
  ) async {
    final mode = _enumByName(ThemeMode.values, json['themeMode']);
    if (mode != null) await theme.setThemeMode(mode);
    final rawPalette = json['palette'];
    if (rawPalette is String && rawPalette != theme.selectedPalette.name) {
      final following = theme.omarchySyncHostId;
      await theme.setPalette(AppPalette.fromStoredId(rawPalette));
      // setPalette stops following a machine; only the synced follow
      // setting (below) may change that.
      if (following != null && !json.containsKey('omarchySyncHostId')) {
        await theme.setOmarchySyncHost(following);
      }
    }
    final hostId = json['omarchySyncHostId'];
    // Older versions synced "This computer": it means another device here.
    if (json.containsKey('omarchySyncHostId') &&
        !(hostId is String && isDeviceLocalHostId(hostId))) {
      await theme.setOmarchySyncHost(
        hostId is String && hostId.isNotEmpty ? hostId : null,
      );
    }
    final font = _enumByName(TerminalFontOption.values, json['terminalFont']);
    if (font != null) await theme.setTerminalFont(font);
    final fontSize = json['terminalFontSize'];
    if (fontSize is num) await theme.setTerminalFontSize(fontSize.toDouble());
    if (json.containsKey('terminalKeyboardRows') ||
        json.containsKey('terminalKeyboardItems')) {
      final rows = parseKeyboardRows(json['terminalKeyboardRows']);
      if (rows.isNotEmpty) {
        await theme.setTerminalKeyboardRows(rows);
      } else {
        // Backups from before keyboard rows.
        final items = parseKeyboardItems(json['terminalKeyboardItems']);
        if (items.isNotEmpty) {
          await theme.setTerminalKeyboardRows([
            TerminalKeyboardRow(items: items),
          ]);
        }
      }
    }
    final showLocalShell = json['showLocalShell'];
    if (showLocalShell is bool) await theme.setShowLocalShell(showLocalShell);
    final mouse = json['terminalMouseInput'];
    if (mouse is bool) await theme.setTerminalMouseInput(mouse);
    final enter = _enumByName(
      TerminalEnterSequence.values,
      json['terminalEnterSequence'],
    );
    if (enter != null) await theme.setTerminalEnterSequence(enter);
    final composeSubmitEnter = json['composeSubmitEnter'];
    if (composeSubmitEnter is bool) {
      await theme.setComposeSubmitEnter(composeSubmitEnter);
    }
    final toolbar = _enumByName(
      TerminalToolbarStyle.values,
      json['terminalToolbarStyle'],
    );
    if (toolbar != null) await theme.setTerminalToolbarStyle(toolbar);
    if (json['terminalPillItems'] is List) {
      await theme.setTerminalPillItems(
        TerminalPillItem.decodeList(json['terminalPillItems']),
      );
    }
    final menuButtons = json['menuButtonsEnabled'];
    if (menuButtons is bool) await theme.setMenuButtonsEnabled(menuButtons);
    final remoteClipboard = json['remoteClipboardEnabled'];
    if (remoteClipboard is bool) {
      await theme.setRemoteClipboardEnabled(remoteClipboard);
    }
    final pasteImages = json['pasteImagesAsFiles'];
    if (pasteImages is bool) await theme.setPasteImagesAsFiles(pasteImages);
    final restoreSessions = json['restoreSessionsOnLaunch'];
    if (restoreSessions is bool) {
      await theme.setRestoreSessionsOnLaunch(restoreSessions);
    }
    final gestures = json['terminalGestures'];
    if (gestures is Map) {
      await theme.setTerminalGestures(
        TerminalGesturePreferences.fromJson(gestures),
      );
    }
    final speechLanguage = json['speechLanguage'];
    if (speechLanguage is String) await theme.setSpeechLanguage(speechLanguage);
    final voice = json['voice'];
    if (voice is Map) {
      await theme.setVoice(
        VoicePreferences.fromJson(voice, fallback: theme.voice),
      );
    }
    final quickActions = json['quickActions'];
    if (quickActions is List) {
      await theme.setQuickActions(QuickAction.listFromJson(quickActions));
    }
    final projects = json['projects'];
    if (projects is Map) {
      await theme.setProjectPrefs(ProjectPrefs.fromJson(projects));
    }
  }

  static T? _enumByName<T extends Enum>(List<T> values, Object? name) =>
      values.where((value) => value.name == name).firstOrNull;

  static List<TerminalKeyboardRow> parseKeyboardRows(Object? raw) {
    if (raw is! List) return const [];
    final rows = <TerminalKeyboardRow>[];
    for (final rawRow in raw.whereType<Map<Object?, Object?>>()) {
      final items = parseKeyboardItems(rawRow['items']);
      if (items.isEmpty) continue;
      final height = rawRow['height'];
      rows.add(
        TerminalKeyboardRow(
          items: items,
          height: height is num
              ? clampTerminalKeyboardRowHeight(height.toDouble())
              : terminalKeyboardRowHeightDefault,
        ),
      );
    }
    return rows;
  }

  static List<TerminalKeyboardItem> parseKeyboardItems(Object? raw) {
    if (raw is! List) return const [];
    return raw
        .whereType<Map<Object?, Object?>>()
        .map((json) => keyboardItemFromJson(Map<String, Object?>.from(json)))
        .whereType<TerminalKeyboardItem>()
        .toList(growable: false);
  }

  static Map<String, Object?> keyboardItemToJson(TerminalKeyboardItem item) {
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

  static TerminalKeyboardItem? keyboardItemFromJson(Map<String, Object?> json) {
    final kind = _enumByName(TerminalKeyboardItemKind.values, json['kind']);
    final id = json['id'];
    if (kind == null || id is! String) return null;
    switch (kind) {
      case TerminalKeyboardItemKind.builtIn:
        final action = _enumByName(
          TerminalKeyboardAction.values,
          json['action'],
        );
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
}
