import 'dart:convert';
import 'dart:io';

import 'package:conduit/core/theme/app_palette.dart';
import 'package:conduit/core/theme/omarchy_theme_sync.dart';
import 'package:conduit/features/home_widget/domain/agent_status_snapshot.dart';
import 'package:conduit/features/home_widget/domain/launcher_themes.dart';
import 'package:conduit/features/home_widget/presentation/agent_status_widget_pusher.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the shipped catalog is the theme picker, in its order', () {
    final expected =
        '${const JsonEncoder.withIndent('  ').convert(launcherThemeCatalog())}\n';
    final file = File(launcherThemesAssetPath);
    // `flutter test --update-goldens` rewrites it after a theme change.
    if (autoUpdateGoldenFiles) file.writeAsStringSync(expected);
    expect(
      file.readAsStringSync(),
      expected,
      reason: 'Run flutter test --update-goldens $launcherThemesAssetPath',
    );
  });

  test('the catalog lists every bundled theme, dark ones first', () {
    final catalog = launcherThemeCatalog();
    expect(catalog, hasLength(AppPalette.values.length));
    final modes = [for (final theme in catalog) theme['mode']];
    expect(modes.indexOf('light'), modes.where((m) => m == 'dark').length);
    expect(modes.lastIndexOf('dark') < modes.indexOf('light'), isTrue);
    final tokyo = catalog.firstWhere((t) => t['name'] == 'tokyo-night');
    expect(tokyo['label'], 'Tokyo Night');
    expect(tokyo['mode'], 'dark');
    expect((tokyo['colors']! as Map).keys, [
      'accent',
      'background',
      'foreground',
      'muted',
      'selection',
      'lighter_background',
      'red',
      'green',
      'yellow',
      'blue',
      'magenta',
      'cyan',
      'orange',
    ]);
    expect(
      (catalog.firstWhere((t) => t['name'] == 'catppuccin')['colors']!
          as Map)['lighter_background'],
      '#313244',
    );
  });

  group('pc theme', () {
    final at = DateTime.utc(2026, 10, 4, 20);

    test('a bundled theme read from the machine, with its name', () {
      final pc = AgentStatusPcTheme.fromSynced(
        OmarchySyncedTheme(
          hostId: 'h1',
          palette: AppPalette.flexokiLight,
          syncedAt: at,
        ),
        machine: 'omarchy-pc',
      )!;
      expect(pc.toJson(), {
        'name': 'flexoki-light',
        'label': 'Flexoki Light',
        'mode': 'light',
        'colors': launcherThemeRoles(AppPalette.flexokiLight.colors),
        'machine': 'omarchy-pc',
        'updatedAt': at.millisecondsSinceEpoch,
      });
      expect(AgentStatusPcTheme.fromJson(pc.toJson()), pc);
    });

    test("a machine's own theme keeps its directory name", () {
      final pc = AgentStatusPcTheme.fromSynced(
        OmarchySyncedTheme(
          hostId: 'h1',
          palette: AppPalette.custom(
            name: 'My Theme',
            colors: AppPalette.nord.colors,
          ),
          syncedAt: at,
        ),
      )!;
      expect(pc.name, 'my-theme');
      expect(pc.machine, isNull);
      expect(pc.colors['accent'], launcherHex(AppPalette.nord.colors.accent));
    });

    test('nothing followed: no pc theme', () {
      expect(AgentStatusPcTheme.fromSynced(null), isNull);
    });

    test('travels in the snapshot; its read time alone is no new push', () {
      AgentStatusSnapshot snap(DateTime syncedAt) => AgentStatusSnapshot.build(
        hosts: const [],
        monitoring: false,
        now: at,
        pcTheme: AgentStatusPcTheme.fromSynced(
          OmarchySyncedTheme(
            hostId: 'h1',
            palette: AppPalette.nord,
            syncedAt: syncedAt,
          ),
          machine: 'pc',
        ),
      );
      final snapshot = snap(at);
      expect(AgentStatusSnapshot.decode(snapshot.encode()), snapshot);
      expect(
        AgentStatusWidgetPusher.contentOf(snapshot),
        AgentStatusWidgetPusher.contentOf(
          snap(at.add(const Duration(minutes: 5))),
        ),
      );
    });
  });

  test('hex drops alpha and pads', () {
    expect(launcherHex(const Color(0xFF00010A)), '#00010A');
  });
}
