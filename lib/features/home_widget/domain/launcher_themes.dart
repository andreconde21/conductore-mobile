import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/core/theme/omarchy_colors.dart';
import 'package:conduit/core/theme/omarchy_theme_sync.dart';
import 'package:flutter/painting.dart';

/// Where the Android launcher details provider (CON-075) reads the theme
/// catalog: generated from [launcherThemeCatalog] by
/// test/features/home_widget/launcher_themes_test.dart, so it ships with
/// the app and the provider never needs the Flutter engine.
const launcherThemesAssetPath =
    'android/app/src/main/res/raw/launcher_themes.json';

/// The Omarchy roles the launcher asks for, under its column names.
Map<String, String> launcherThemeRoles(OmarchyColors colors) => {
  'accent': launcherHex(colors.accent),
  'background': launcherHex(colors.background),
  'foreground': launcherHex(colors.foreground),
  'muted': launcherHex(colors.muted),
  'selection': launcherHex(colors.selection),
  'lighter_background': launcherHex(colors.lighterBackground),
  'red': launcherHex(colors.red),
  'green': launcherHex(colors.green),
  'yellow': launcherHex(colors.yellow),
  'blue': launcherHex(colors.blue),
  'magenta': launcherHex(colors.magenta),
  'cyan': launcherHex(colors.cyan),
  'orange': launcherHex(colors.orange),
};

/// `#RRGGBB`, uppercase, alpha dropped.
String launcherHex(Color color) =>
    '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

/// The Omarchy theme name of [palette]: its directory name (`tokyo-night`),
/// also for a machine's own theme.
String launcherThemeName(AppPalette palette) => palette.custom
    ? palette.id.substring(AppPalette.customIdPrefix.length)
    : palette.id;

Map<String, Object?> _themeJson(AppPalette palette) => {
  'name': launcherThemeName(palette),
  'label': palette.label,
  'mode': palette.isDark ? 'dark' : 'light',
  'colors': launcherThemeRoles(palette.colors),
};

/// Every bundled theme in the theme picker's order (dark ones, then light
/// ones, each in Omarchy's order).
List<Map<String, Object?>> launcherThemeCatalog() => [
  for (final palette in AppPalette.values)
    if (palette.isDark) _themeJson(palette),
  for (final palette in AppPalette.values)
    if (!palette.isDark) _themeJson(palette),
];

/// The theme the followed Omarchy machine last reported, for the
/// launcher's `pc_theme`: never the theme picked in the app.
class AgentStatusPcTheme {
  const AgentStatusPcTheme({
    required this.name,
    required this.label,
    required this.dark,
    required this.colors,
    required this.syncedAt,
    this.machine,
  });

  /// Null while the app follows no machine or has not read it yet.
  static AgentStatusPcTheme? fromSynced(
    OmarchySyncedTheme? synced, {
    String? machine,
  }) {
    if (synced == null) return null;
    return AgentStatusPcTheme(
      name: launcherThemeName(synced.palette),
      label: synced.palette.label,
      dark: synced.palette.isDark,
      colors: launcherThemeRoles(synced.palette.colors),
      syncedAt: synced.syncedAt,
      machine: machine,
    );
  }

  final String name;
  final String label;
  final bool dark;

  /// [launcherThemeRoles] of the theme.
  final Map<String, String> colors;
  final DateTime syncedAt;

  /// The saved machine's name; null when it is no longer saved.
  final String? machine;

  Map<String, Object?> toJson() => {
    'name': name,
    'label': label,
    'mode': dark ? 'dark' : 'light',
    'colors': colors,
    'machine': ?machine,
    'updatedAt': syncedAt.toUtc().millisecondsSinceEpoch,
  };

  static AgentStatusPcTheme? fromJson(Object? json) {
    if (json is! Map ||
        json['name'] is! String ||
        json['updatedAt'] is! int ||
        json['colors'] is! Map) {
      return null;
    }
    return AgentStatusPcTheme(
      name: json['name'] as String,
      label: json['label'] is String ? json['label'] as String : '',
      dark: json['mode'] != 'light',
      colors: {
        for (final entry in (json['colors'] as Map).entries)
          if (entry.key is String && entry.value is String)
            entry.key as String: entry.value as String,
      },
      syncedAt: DateTime.fromMillisecondsSinceEpoch(
        json['updatedAt'] as int,
        isUtc: true,
      ),
      machine: json['machine'] is String ? json['machine'] as String : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AgentStatusPcTheme &&
      other.name == name &&
      other.label == label &&
      other.dark == dark &&
      other.machine == machine &&
      other.syncedAt == syncedAt &&
      other.colors.length == colors.length &&
      colors.entries.every((e) => other.colors[e.key] == e.value);

  @override
  int get hashCode => Object.hash(
    name,
    label,
    dark,
    machine,
    syncedAt,
    Object.hashAllUnordered(colors.entries.map((e) => '${e.key}=${e.value}')),
  );
}
